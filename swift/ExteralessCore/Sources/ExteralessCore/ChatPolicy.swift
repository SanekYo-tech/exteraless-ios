import Foundation

public enum ChatFormattingPolicy {
    public struct Action: Equatable, Sendable {
        public let id: String
        public let settingField: String
        public let title: String
    }

    public static let defaultOrder = "translate,bold,italic,mono,code,strike,underline,quote,spoiler,link,mention,date,regular"
    public static let actions: [Action] = [
        Action(id: "translate", settingField: "showTextTranslate", title: "Translate"),
        Action(id: "bold", settingField: "showTextBold", title: "Bold"),
        Action(id: "italic", settingField: "showTextItalic", title: "Italic"),
        Action(id: "mono", settingField: "showTextMono", title: "Monospace"),
        Action(id: "code", settingField: "showTextMonoCode", title: "Code block"),
        Action(id: "strike", settingField: "showTextStrikethrough", title: "Strikethrough"),
        Action(id: "underline", settingField: "showTextUnderline", title: "Underline"),
        Action(id: "quote", settingField: "showTextQuote", title: "Quote"),
        Action(id: "spoiler", settingField: "showTextSpoiler", title: "Spoiler"),
        Action(id: "link", settingField: "showTextCreateLink", title: "Link"),
        Action(id: "date", settingField: "showTextCreateDate", title: "Date"),
        Action(id: "regular", settingField: "showTextRegular", title: "Clear formatting")
    ]

    /// Unknown entries never hide newly available native actions. Duplicates cannot duplicate a command.
    public static func ordered(_ available: [String], order: String, hidden: Set<String>) -> [String] {
        var seen = Set<String>()
        let known = Set(available)
        let requested = order.prefix(1024).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return (requested + available).filter { known.contains($0) && !hidden.contains($0) && seen.insert($0).inserted }
    }
}

public enum ChatPlaybackPolicy {
    public static let speedCycle: [Double] = [1.0, 1.2, 1.5, 1.7, 2.0, 0.5]

    public static func nextSpeed(after speed: Double) -> Double {
        guard let index = speedCycle.firstIndex(where: { abs($0 - speed) < 0.01 }) else { return 1.0 }
        return speedCycle[(index + 1) % speedCycle.count]
    }

    public static func musicSpeed(_ speed: Double) -> Double {
        return speed.isFinite ? min(2.0, max(0.5, speed)) : 1.0
    }

    public static func seekDuration(index: Int) -> Double {
        let durations: [Double] = [5, 10, 15, 30]
        return durations.indices.contains(index) ? durations[index] : durations[1]
    }

    public static func seekPosition(timestamp: Double, delta: Double, duration: Double) -> Double? {
        guard timestamp.isFinite, delta.isFinite, duration.isFinite, duration > 0 else { return nil }
        return min(duration, max(0, timestamp + delta))
    }

    public static func storedSpeed(_ speed: Double) -> Double {
        return speed.isFinite && speed > 0 ? min(16, max(0.2, speed)) : 1
    }
}

/// A scrub gesture belongs to the track on which it began, not a later automatic queue item.
public struct ChatPlaybackSeekLease<Identity: Hashable> {
    private var identity: Identity?
    public init() {}
    public mutating func begin(identity: Identity) { self.identity = identity }
    public mutating func cancel() { self.identity = nil }
    public mutating func finish(identity: Identity, fraction: Double, duration: Double) -> Double? {
        let accepted = self.identity == identity
        self.identity = nil
        guard accepted, fraction.isFinite, duration.isFinite, duration > 0 else { return nil }
        return min(1, max(0, fraction)) * duration
    }
}

/// URL edits are separate from attributed/rich-text splicing, which belongs to the native composer.
public enum ChatLinkPolicy {
    public static func removingTracking(from text: String) -> String {
        return ChatTrackingRulesStore.shared.clean(text)
    }

    public struct Replacement: Equatable, Sendable {
        public let range: Range<Int>
        public let text: String
    }

    /// Input ranges come from the platform URL detector. Return edits in reverse order so applying
    /// them to NSMutableAttributedString preserves every unrelated entity/UTF-16 offset.
    public static func replacements(in text: String, urlRanges: [Range<Int>], clean: (String) -> String = ChatLinkPolicy.removingTracking) -> [Replacement] {
        let source = text as NSString
        guard source.length <= 65536 else { return [] }
        var result: [Replacement] = []
        var end = 0
        for range in urlRanges.prefix(64).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            guard range.lowerBound >= end, range.upperBound <= source.length, !range.isEmpty else { continue }
            let nsRange = NSRange(location: range.lowerBound, length: range.count)
            guard Range(nsRange, in: text) != nil else { continue }
            end = range.upperBound
            let original = source.substring(with: nsRange)
            let cleaned = clean(original)
            if cleaned != original { result.append(Replacement(range: range, text: cleaned)) }
        }
        return Array(result.reversed())
    }
}

public enum ChatPillPolicy {
    public static let supportedIds: [Int] = [5, 6]

    public static func ids(_ raw: String) -> [Int] {
        var seen = Set<Int>()
        return raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.filter { seen.insert($0).inserted }
    }

    public static func visibleIds(active: [Int], hidden: Set<Int>, available: Set<Int>) -> [Int] {
        var seen = Set<Int>()
        return active.filter { available.contains($0) && !hidden.contains($0) && seen.insert($0).inserted }
    }

    public static func nextId(current: Int?, ids: [Int], forward: Bool, loop: Bool) -> Int? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return ids.first }
        let next = index + (forward ? 1 : -1)
        if ids.indices.contains(next) { return ids[next] }
        return loop ? ids[(next + ids.count) % ids.count] : current
    }
}
