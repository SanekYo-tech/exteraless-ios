import Foundation

public enum ChatComposerPolicy {
    public static let scheduleMinutes = Array(stride(from: 5, through: 60, by: 5))
        + Array(stride(from: 120, through: 720, by: 60)) + (1 ... 7).map { $0 * 1440 }

    /// Original 30-step schedule slider; ties choose the earlier step. Explicit dates win.
    public static func initialScheduleTime(current: Int32?, now: TimeInterval, minutes: Int) -> Int32? {
        if let current, current > 0, current != Int32.max - 1 { return current }
        guard now.isFinite, now >= 0 else { return nil }
        let delay = scheduleMinutes.min { abs(Double($0) - Double(minutes)) < abs(Double($1) - Double(minutes)) } ?? 10
        let timestamp = ceil((now + Double(delay * 60)) / 60) * 60
        return timestamp < Double(Int32.max - 1) ? Int32(timestamp) : nil
    }

    /// A forwarding comment is moved as complete native message values, never reconstructed text.
    public static func ordering<T>(_ values: [T], commentAfterForward: Bool, isForward: (T) -> Bool) -> [T] {
        guard commentAfterForward, values.contains(where: isForward) else { return values }
        return values.filter(isForward) + values.filter { !isForward($0) }
    }

    /// Contiguous native forwarding batches, including the non-forward comment before/after them.
    public static func batches<T, Key: Equatable>(_ values: [T], key: (T) -> Key) -> [[T]] {
        var result: [[T]] = []
        var previous: Key?
        for value in values {
            let current = key(value)
            if !result.isEmpty, previous == current { result[result.count - 1].append(value) }
            else { result.append([value]) }
            previous = current
        }
        return result
    }

    /// The marker is local draft metadata in Telegram's existing per-URL preview override list.
    /// It is never handed to URL detection or the network. Dismissing an individual URL still wins.
    public static let allowPreviewMarker = "exteraless:explicit-link-preview"
    public static func disablesPreview(url: String, overrides: [String], defaultDisabled: Bool) -> Bool {
        overrides.contains(url) || (defaultDisabled && !overrides.contains(allowPreviewMarker))
    }
}

public enum ChatPreviewLinkRules {
    // PagePreviewRulesHelper.applyBuiltInRules; only the preview request is redirected.
    private static let hosts = ["x.com": "fixupx.com", "twitter.com": "fxtwitter.com", "coolapk.com": "coolapk1s.com",
        "www.instagram.com": "kkinstagram.com", "vm.tiktok.com": "vm.kktiktok.com", "vt.tiktok.com": "vt.kktiktok.com",
        "www.tiktok.com": "www.kktiktok.com", "www.reddit.com": "www.rxddit.com", "bsky.app": "fxbsky.app", "www.pixiv.net": "www.phixiv.net"]

    public static func previewURL(_ value: String) -> String {
        guard ChatAdGuardRules.allowsRewriting(value), let separator = value.range(of: "://") else { return value }
        let start = separator.upperBound
        let end = value[start...].firstIndex(where: { "/?#".contains($0) }) ?? value.endIndex
        let authority = value[start ..< end]
        let hostEnd = authority.firstIndex(of: ":") ?? end
        guard let host = hosts[value[start ..< hostEnd].lowercased()] else { return value }
        return String(value[..<start]) + host + String(value[hostEnd...])
    }
}
