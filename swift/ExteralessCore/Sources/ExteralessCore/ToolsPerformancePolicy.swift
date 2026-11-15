import Foundation

/// nagram.performanceClass, adapted to native presentation budgets. This does not
/// describe hardware, grant fetch permission, or change stored native preferences.
public enum ToolsPerformancePolicy {
    public static let key = "tools.performanceClass"
    /// Registration belongs to the native composition, after its consumers land.
    public static let definition = ClientSettingDefinition(
        key: key, title: "Performance profile", section: "Tools", defaultValue: .integer(0),
        options: [
            .init(value: .integer(0), title: "Automatic"),
            .init(value: .integer(1), title: "High"),
            .init(value: .integer(2), title: "Average"),
            .init(value: .integer(3), title: "Low")
        ],
        explanation: "Native animation and energy budgets. High requests up to 60 fps; Average limits cached animations to 30 fps and reduces effects; Low uses static cached animations. Power-saving and individual native settings still apply.",
        androidSymbols: ["NaConfig.performanceClass"])

    /// The application Root and the SDK's consumed Root fixture use this same group.
    public static let definitions: [ClientSettingDefinition] = [definition]

    public enum Mode: Int64, CaseIterable, Sendable {
        case automatic = 0, high = 1, average = 2, low = 3
    }

    public struct Selection: Equatable, Sendable {
        public let mode: Mode
        public let isStoredOverride: Bool

        public init(mode: Mode, isStoredOverride: Bool = false) {
            self.mode = mode; self.isStoredOverride = isStoredOverride
        }

        /// Reads a coherent public cache only. An unregistered/invalid/secret key
        /// cannot become a profile, and a reset preserves absence rather than 0.
        public init(snapshot: ClientSettingsSnapshot) {
            let key = ToolsPerformancePolicy.key
            guard !snapshot.secretKeys.contains(key),
                  snapshot.definitions.contains(where: { $0.key == key && !$0.isSecret }),
                  case let .integer(raw)? = snapshot.values[key], let mode = Mode(rawValue: raw) else {
                self.init(mode: .automatic)
                return
            }
            self.init(mode: mode, isStoredOverride: snapshot.storedKeys.contains(key))
        }
    }

    /// The caller supplies the already decoded native permissions/defaults. Even
    /// High cannot turn a false native flag into true, including background work.
    public struct Energy: Equatable, Sendable {
        public var autoplayVideo: Bool
        public var autoplayGif: Bool
        public var loopStickers: Bool
        public var loopEmoji: Bool
        public var fullTranslucency: Bool
        public var extendBackgroundWork: Bool
        public var autodownloadInBackground: Bool

        public init(autoplayVideo: Bool, autoplayGif: Bool, loopStickers: Bool, loopEmoji: Bool,
                    fullTranslucency: Bool, extendBackgroundWork: Bool, autodownloadInBackground: Bool) {
            self.autoplayVideo = autoplayVideo; self.autoplayGif = autoplayGif
            self.loopStickers = loopStickers; self.loopEmoji = loopEmoji
            self.fullTranslucency = fullTranslucency; self.extendBackgroundWork = extendBackgroundWork
            self.autodownloadInBackground = autodownloadInBackground
        }

        fileprivate mutating func stopVisualWork() {
            autoplayVideo = false; autoplayGif = false; loopStickers = false
            loopEmoji = false; fullTranslucency = false
        }
        fileprivate mutating func stopBackgroundWork() {
            extendBackgroundWork = false; autodownloadInBackground = false
        }
    }

    public enum Thermal: Equatable, Sendable { case nominal, fair, serious, critical, unknown }

    public struct Environment: Equatable, Sendable {
        public var isInForeground: Bool
        public var lowPowerMode: Bool
        /// Result of the existing native threshold/unknown-battery policy.
        public var batterySaving: Bool
        public var thermal: Thermal
        public var reduceMotion: Bool
        public var reduceTransparency: Bool

        public init(isInForeground: Bool, lowPowerMode: Bool, batterySaving: Bool, thermal: Thermal,
                    reduceMotion: Bool = false, reduceTransparency: Bool = false) {
            self.isInForeground = isInForeground; self.lowPowerMode = lowPowerMode
            self.batterySaving = batterySaving; self.thermal = thermal
            self.reduceMotion = reduceMotion; self.reduceTransparency = reduceTransparency
        }
    }

    public struct Input: Equatable, Sendable {
        public let selection: Selection
        public let nativeEnergy: Energy
        public let environment: Environment
        /// The native renderer's measured automatic heuristic (currently 30/60).
        public let automaticFramesPerSecond: Int
        /// The actual renderer/display ceiling, not a fabricated device class.
        public let maximumFramesPerSecond: Int

        public init(selection: Selection, nativeEnergy: Energy, environment: Environment,
                    automaticFramesPerSecond: Int, maximumFramesPerSecond: Int) {
            self.selection = selection; self.nativeEnergy = nativeEnergy; self.environment = environment
            self.maximumFramesPerSecond = max(0, min(60, maximumFramesPerSecond))
            self.automaticFramesPerSecond = max(0, min(self.maximumFramesPerSecond, automaticFramesPerSecond))
        }
    }

    public enum AnimationKind: Sendable { case emoji, sticker, effect }

    public struct Budget: Equatable, Sendable {
        public let energy: Energy
        /// Zero pauses cached animation advancement; first-frame loading survives.
        public let animationFramesPerSecond: Int

        /// Intersected with the target's existing visibility/playback request. A
        /// native emoji opt-out must not be re-enabled when High resumes a clock.
        public func allowsAnimation(_ kind: AnimationKind) -> Bool {
            guard animationFramesPerSecond > 0 else { return false }
            switch kind {
            case .emoji: return energy.loopEmoji
            case .sticker: return energy.loopStickers
            case .effect: return energy.fullTranslucency
            }
        }
    }

    public static func resolve(_ input: Input) -> Budget {
        var energy = input.nativeEnergy
        var fps: Int
        switch input.selection.mode {
        case .automatic:
            fps = input.automaticFramesPerSecond
        case .high:
            fps = input.maximumFramesPerSecond
        case .average:
            fps = min(30, input.maximumFramesPerSecond)
            energy.fullTranslucency = false
            energy.stopBackgroundWork()
        case .low:
            fps = 0
            energy.stopVisualWork()
            energy.stopBackgroundWork()
        }

        switch input.environment.thermal {
        case .nominal: break
        case .fair:
            fps = min(fps, 30)
            energy.fullTranslucency = false
        case .serious, .critical, .unknown:
            fps = 0
            energy.stopVisualWork()
            energy.stopBackgroundWork()
        }
        if input.environment.lowPowerMode || input.environment.batterySaving {
            fps = 0
            energy.stopVisualWork()
            energy.stopBackgroundWork()
        }
        if !input.environment.isInForeground || input.environment.reduceMotion {
            fps = 0
            energy.stopVisualWork()
        }
        if input.environment.reduceTransparency { energy.fullTranslucency = false }
        return Budget(energy: energy, animationFramesPerSecond: fps)
    }

    public struct FrameAdvance: Equatable, Sendable {
        public let frames: Int
        public let index: Int
        public let remainingDuration: Double
        public let didLoop: Bool
    }

    /// A slower render clock drops intermediate decoded frames, not animation
    /// time. Work is bounded even for malformed/zero-duration cache metadata.
    public static func advanceFrames(frameCount: Int, frameIndex: Int, remainingDuration: Double,
                                     durations: [Double], elapsed: Double) -> FrameAdvance {
        guard frameCount > 0, frameIndex >= 0, frameIndex < frameCount else {
            return FrameAdvance(frames: 0, index: 0, remainingDuration: 1.0 / 60.0, didLoop: false)
        }
        func duration(at index: Int) -> Double {
            guard index < durations.count, durations[index].isFinite, durations[index] > 0 else { return 1.0 / 60.0 }
            return max(1.0 / 240.0, durations[index])
        }
        var remaining = remainingDuration.isFinite && remainingDuration >= 0 ? remainingDuration : duration(at: frameIndex)
        guard elapsed.isFinite, elapsed > 0 else {
            return FrameAdvance(frames: 0, index: frameIndex, remainingDuration: remaining, didLoop: false)
        }
        remaining -= min(0.25, elapsed)
        var frames = 0, index = frameIndex
        var didLoop = false
        while remaining <= 1.0e-9 && frames < 64 {
            index += 1
            if index == frameCount { index = 0; didLoop = frameCount > 1 }
            frames += 1
            remaining += duration(at: index)
        }
        if remaining <= 0 { remaining = duration(at: index) }
        return FrameAdvance(frames: frames, index: index, remainingDuration: remaining, didLoop: didLoop)
    }
}

/// One process-local publication, not a ClientSettings disk revision. Consumers
/// read the latest immutable snapshot after an invalidation instead of replaying
/// queued setting values. A selection/reset or environment change advances it.
public struct ToolsPerformancePublication: Equatable, Sendable {
    public let revision: UInt64
    public let input: ToolsPerformancePolicy.Input
    public let budget: ToolsPerformancePolicy.Budget
}

public final class ToolsPerformancePolicyStore: NSObject, @unchecked Sendable {
    public static let shared = ToolsPerformancePolicyStore()
    public static let didChange = Notification.Name("ExteralessToolsPerformancePolicyDidChange")
    private let lock = NSLock()
    private let notifications: NotificationCenter
    private var value: ToolsPerformancePublication?

    public init(notifications: NotificationCenter = .default) { self.notifications = notifications; super.init() }

    public func snapshot() -> ToolsPerformancePublication? {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    @discardableResult public func publish(_ input: ToolsPerformancePolicy.Input) -> ToolsPerformancePublication {
        lock.lock()
        if let value, value.input == input { lock.unlock(); return value }
        let next = ToolsPerformancePublication(revision: (value?.revision ?? 0) + 1, input: input, budget: ToolsPerformancePolicy.resolve(input))
        value = next
        lock.unlock()
        // Never notify under the lock: a subscriber may synchronously read back.
        notifications.post(name: Self.didChange, object: self)
        return next
    }
}

/// A renderer can receive queued invalidations after a newer publication. This
/// cursor accepts only a new revision from its one process-local policy store.
public struct ToolsPerformancePublicationCursor: Sendable {
    public private(set) var revision: UInt64 = 0
    public init() {}
    public mutating func accept(_ publication: ToolsPerformancePublication) -> ToolsPerformancePolicy.Budget? {
        guard publication.revision > revision else { return nil }
        revision = publication.revision
        return publication.budget
    }
}
