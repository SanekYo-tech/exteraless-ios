import Foundation

/// Pure policies for the explicitly handed-off native mode/encoder hunks. Their
/// definitions are NOT registered until the owning composition installs consumers.
public enum ToolsNativeModePolicy {
    public static let videoBitrateDefinition = ClientSettingDefinition(key: "tools.enhancedVideoBitrate", title: "Higher video export bitrate", section: "Camera", defaultValue: .bool(false),
        explanation: "Raises eligible native video export targets using the original HD bitrate rungs. Stickers, avatars and round-video presets retain their budgets.", androidSymbols: ["NaConfig.enhancedVideoBitrate"])
    public static let voiceEnhancementDefinition = ClientSettingDefinition(key: "tools.voiceEnhancement", title: "Voice-note noise suppression and gain control", section: "Camera", defaultValue: .bool(false),
        explanation: "Uses Apple's voice-processing input unit for ordinary voice notes. Capture/route support must be confirmed by the native audio session.", androidSymbols: ["NaConfig.noiseSuppressAndVoiceEnhance"])
    public static let groupAudioBitrateDefinition = ClientSettingDefinition(key: "tools.groupAudioBitrate", title: "Group-call audio bitrate", section: "Tools", defaultValue: .integer(0),
        options: [0, 32, 64, 128, 192, 256, 320].map { .init(value: .integer(Int64($0)), title: $0 == 0 ? "Native/server default" : "\($0) kbit/s") },
        explanation: "Outgoing group-call audio only; does not change voice-note encoding or private calls.", androidSymbols: ["NekoConfig.customAudioBitrate"])
    public static let rpcErrorsDefinition = ClientSettingDefinition(key: "tools.showRPCError", title: "Keep recent RPC failure codes", section: "Tools", defaultValue: .bool(false),
        explanation: "Bounded local method/code diagnostics. Raw RPC error text and request parameters are never retained.", androidSymbols: ["NaConfig.showRPCError"])

    public static func videoBitrateKbps(native: Int, width: Int, height: Int, enabled: Bool) -> Int {
        guard enabled, native > 0 else { return native }
        let side = min(width, height)
        let rung: Int
        if side >= 2_160 { rung = 28_400 }
        else if side >= 1_080 { rung = 14_000 }
        else if side >= 720 { rung = 6_800 }
        else { return native }
        return max(native, rung)
    }

    public static func groupAudioBitrate(preferred: Int, native: Int32?) -> Int32? {
        guard [32, 64, 128, 192, 256, 320].contains(preferred) else { return native }
        return Int32(preferred)
    }
}

public struct ToolsRPCFailure: Equatable, Sendable {
    public let method: String
    public let code: Int32
    public let time: Date
}

/// Pull-based bounded diagnostics. There is no unbounded main-queue fanout and no
/// API that accepts raw error text or request arguments.
public final class ToolsRPCFailureBuffer: @unchecked Sendable {
    public static let shared = ToolsRPCFailureBuffer()
    private let lock = NSLock()
    private let capacity: Int
    private var entries: [ToolsRPCFailure] = []
    public init(capacity: Int = 40) { self.capacity = max(1, min(40, capacity)) }
    public func record(method: String?, code: Int32, at time: Date = Date()) {
        let name: String
        if let method, method.utf8.count <= 128, method.contains("."), method.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 46 || $0 == 95 }) {
            name = method
        } else { name = "RPC" }
        lock.lock(); defer { lock.unlock() }
        if entries.count == capacity { entries.removeFirst() }
        entries.append(.init(method: name, code: code, time: time))
    }
    public func snapshot() -> [ToolsRPCFailure] { lock.lock(); defer { lock.unlock() }; return entries }
    public func clear() { lock.lock(); entries.removeAll(); lock.unlock() }
}
