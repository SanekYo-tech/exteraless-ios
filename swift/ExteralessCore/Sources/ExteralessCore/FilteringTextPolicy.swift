import Foundation

/// Android MessageHelper.zalgoFilter: only 4...2048 UTF-16 units, only after four
/// consecutive Unicode marks, then remove ALL marks. No normalization of storage.
public enum FilteringTextPolicy {
    public static func removedMarkRanges(in text: String, enabled: Bool) -> [NSRange] {
        guard enabled else { return [] }
        let length = text.utf16.prefix(2_049).count
        guard (4 ... 2_048).contains(length) else { return [] }
        var run = 0
        var triggered = false
        var offset = 0
        var ranges: [NSRange] = []
        for scalar in text.unicodeScalars {
            let width = scalar.value > 0xffff ? 2 : 1
            let mark: Bool
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: mark = true
            default: mark = false
            }
            if mark {
                run += 1
                triggered = triggered || run >= 4
                if let last = ranges.last, last.location + last.length == offset {
                    ranges[ranges.count - 1] = NSRange(location: last.location, length: last.length + width)
                } else { ranges.append(NSRange(location: offset, length: width)) }
            } else { run = 0 }
            offset += width
        }
        return triggered ? ranges : []
    }

    public static func displayedText(_ text: String, enabled: Bool) -> String {
        let ranges = removedMarkRanges(in: text, enabled: enabled)
        guard !ranges.isEmpty else { return text }
        let result = NSMutableString(string: text)
        for range in ranges.reversed() { result.deleteCharacters(in: range) }
        return result as String
    }

    /// Delete from the final attributed display string, after entity formatting;
    /// Foundation remaps link/spoiler/emoji spans, including astral UTF-16 offsets.
    public static func displayedText(_ text: NSAttributedString, enabled: Bool) -> NSAttributedString {
        let ranges = removedMarkRanges(in: text.string, enabled: enabled)
        guard !ranges.isEmpty else { return text }
        let result = NSMutableAttributedString(attributedString: text)
        for range in ranges.reversed() { result.deleteCharacters(in: range) }
        return result
    }
}
