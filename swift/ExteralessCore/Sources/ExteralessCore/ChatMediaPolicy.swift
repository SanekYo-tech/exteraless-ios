import Foundation

public enum ChatMediaPolicy {
    /// VideoPlayer.getDefaultSavedQuality: try the selected band, then each lower
    /// band. Native quality values are pixel heights; "original" selects the highest.
    public static func videoQuality(available: [Int], preferOriginal: Bool, defaultHls: Int) -> Int? {
        let available = available.filter { $0 > 0 }.sorted(by: >)
        if preferOriginal || defaultHls == 1 { return available.first }
        let bands = [1440 ... Int.max, 1000 ... 1440, 700 ... 1000, 1 ... 700]
        guard (2 ... 5).contains(defaultHls) else { return nil }
        for band in bands.dropFirst(defaultHls - 2) {
            if let quality = available.first(where: { band.contains($0) }) { return quality }
        }
        return nil
    }

    public static func translateInSheet(enabled: Bool, hasContent: Bool, poll: Bool, voice: Bool, alreadyTranslated: Bool) -> Bool {
        enabled && hasContent && !poll && !voice && !alreadyTranslated
    }
}

/// Resume only the video this policy paused, never a newly selected gallery item
/// or a video that was already paused by the user before entering the background.
public struct ChatVideoBackgroundPolicy<Identity: Equatable> {
    public enum Effect: Equatable { case none, pause, resume }
    private var pausedIdentity: Identity?
    public init() {}
    public mutating func clear() { pausedIdentity = nil }

    public mutating func update(foreground: Bool, enabled: Bool, identity: Identity?, playing: Bool, eligible: Bool) -> Effect {
        guard enabled, eligible, let identity else { clear(); return .none }
        if foreground {
            defer { clear() }
            return pausedIdentity == identity ? .resume : .none
        }
        if playing { pausedIdentity = identity; return .pause }
        return .none
    }
}
