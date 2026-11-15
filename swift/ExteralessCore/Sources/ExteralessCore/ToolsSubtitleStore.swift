import Foundation

public struct ToolsSubtitlePlaybackSample: Equatable, Sendable {
    public let timestamp: Double
    public let generationTimestamp: Double
    public let duration: Double
    public let rate: Double
    public let playing: Bool
    public init(timestamp: Double, generationTimestamp: Double, duration: Double, rate: Double, playing: Bool) {
        self.timestamp = timestamp; self.generationTimestamp = generationTimestamp
        self.duration = duration; self.rate = rate; self.playing = playing
    }
    /// Telegram MediaPlayerStatus uses CACurrentMediaTime for generationTimestamp.
    public func time(at monotonicTime: Double) -> Double? {
        guard timestamp.isFinite, timestamp >= 0, generationTimestamp.isFinite, monotonicTime.isFinite,
              duration.isFinite, duration >= 0, rate.isFinite, rate > 0, rate <= 4 else { return nil }
        let value = timestamp + (playing ? max(0, monotonicTime - generationTimestamp) * rate : 0)
        return duration > 0 ? min(duration, value) : value
    }
}

/// Caller supplies an account-and-document scoped identity, never a display name.
/// Only its SHA-256 is used as a filename. No video data or external URL is stored.
public actor ToolsSubtitleStore {
    private struct Envelope: Codable { let version: Int; let data: Data; let sha256: String }
    private let directory: URL
    public init(directory: URL) { self.directory = directory }

    public func load(identity: String) throws -> ToolsSubtitleTrack? {
        let url = try file(identity)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let bytes = try ToolsFileSafety.read(url, maximumBytes: 2 * ToolsSubtitleTrack.maximumBytes)
        try ToolsFileSafety.checkJSON(bytes, maximumBytes: 2 * ToolsSubtitleTrack.maximumBytes)
        let envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
        guard envelope.version == 1, envelope.data.count <= ToolsSubtitleTrack.maximumBytes,
              envelope.sha256 == ToolsSHA256.hex(envelope.data) else { throw ToolsError.checksumMismatch }
        return try ToolsSubtitleTrack(data: envelope.data)
    }

    @discardableResult public func save(_ data: Data, identity: String) throws -> ToolsSubtitleTrack {
        try Task.checkCancellation()
        let track = try ToolsSubtitleTrack(data: data)
        let url = try file(identity)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let bytes = try ToolsFileSafety.encode(Envelope(version: 1, data: data, sha256: ToolsSHA256.hex(data)))
        try bytes.write(to: url, options: .atomic)
        return track
    }

    public func clear(identity: String) throws {
        try Task.checkCancellation()
        let url = try file(identity)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private func file(_ identity: String) throws -> URL {
        guard !identity.isEmpty, identity.utf8.count <= 1_024, !identity.contains("\0") else { throw ToolsError.unsafePath }
        return try ToolsFileSafety.checkedChild(ToolsSHA256.hex(Data(identity.utf8)) + ".json", root: directory)
    }
}
