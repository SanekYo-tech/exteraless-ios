import Foundation

public struct NativeServicePlaybackFrame: Sendable {
    public let identity: String
    public let messageId: Int64
    public let message: PluginJSONValue
    public let state: String
    public let position: Double
    public let duration: Double
    public let rate: Double
    public let seekId: Int64
    public init(identity: String, messageId: Int64, message: PluginJSONValue, state: String,
                position: Double, duration: Double, rate: Double, seekId: Int64) throws {
        guard position.isFinite, duration.isFinite, rate.isFinite else { throw BridgeFailure.malformed("Non-finite native player status") }
        self.identity = identity
        self.messageId = messageId
        self.message = message
        self.state = state
        self.position = position
        self.duration = duration
        self.rate = rate
        self.seekId = seekId
    }
    public var progress: Double? { duration > 0 && position >= 0 ? min(1, position / duration) : nil }
    public var value: PluginJSONValue {
        .object(["active": .bool(true), "message": message, "state": .string(state),
            "position": .number(position), "duration": .number(duration), "rate": .number(rate),
            "progress": progress.map(PluginJSONValue.number) ?? .null])
    }
}

/// Deltas of actual MediaPlayerStatus publications. No 17ms synthetic tick, no
/// guessed seek from a timestamp jump, no fabricated Android stopService flag.
public struct NativeServicePlaybackReducer: Sendable {
    private var previous: NativeServicePlaybackFrame?
    private var initialized = false
    public init() {}
    public mutating func receive(_ frame: NativeServicePlaybackFrame?) -> [(NativeServiceNotification, [PluginJSONValue])] {
        defer { previous = frame; initialized = true }
        guard initialized else { return [] }
        guard let frame else {
            return previous.map { [(.messagePlayingPlayStateChanged, [.integer($0.messageId)])] } ?? []
        }
        var events: [(NativeServiceNotification, [PluginJSONValue])] = []
        if previous?.identity != frame.identity {
            events.append((.messagePlayingDidStart, [frame.message, previous?.message ?? .null]))
        }
        if previous?.identity != frame.identity || previous?.state != frame.state {
            events.append((.messagePlayingPlayStateChanged, [.integer(frame.messageId)]))
        }
        if let progress = frame.progress {
            if previous?.identity == frame.identity, previous?.seekId != frame.seekId {
                events.append((.messagePlayingDidSeek, [.integer(frame.messageId), .number(progress)]))
            }
            if previous?.identity != frame.identity || previous?.position != frame.position || previous?.duration != frame.duration {
                events.append((.messagePlayingProgressDidChanged, [.integer(frame.messageId), .number(progress)]))
            }
        }
        return events
    }
}
