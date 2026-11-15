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
        projection(text, enabled: enabled)?.text ?? text
    }

    /// Project UTF-16 attributes after entity formatting. Mutating a String-backed
    /// Foundation substring inside a combining cluster can consume the base letter
    /// on some runtimes, so build the final text before assigning its attributes.
    public static func displayedText(_ text: NSAttributedString, enabled: Bool) -> NSAttributedString {
        guard let projection = projection(text.string, enabled: enabled) else { return text }
        let result = NSMutableAttributedString(string: projection.text)
        var outputOffset = 0
        while outputOffset < projection.sourceOffsets.count {
            var effectiveRange = NSRange()
            let attributes = text.attributes(at: projection.sourceOffsets[outputOffset], effectiveRange: &effectiveRange)
            var end = outputOffset + 1
            while end < projection.sourceOffsets.count, projection.sourceOffsets[end] < NSMaxRange(effectiveRange) {
                end += 1
            }
            result.setAttributes(attributes, range: NSRange(location: outputOffset, length: end - outputOffset))
            outputOffset = end
        }
        return result
    }

    private static func projection(_ text: String, enabled: Bool) -> (text: String, sourceOffsets: [Int])? {
        let ranges = removedMarkRanges(in: text, enabled: enabled)
        guard !ranges.isEmpty else { return nil }
        var rangeIndex = 0
        var units: [UInt16] = []
        var sourceOffsets: [Int] = []
        for (offset, unit) in text.utf16.enumerated() {
            while rangeIndex < ranges.count, offset >= NSMaxRange(ranges[rangeIndex]) { rangeIndex += 1 }
            if rangeIndex < ranges.count, offset >= ranges[rangeIndex].location { continue }
            units.append(unit)
            sourceOffsets.append(offset)
        }
        return (String(decoding: units, as: UTF16.self), sourceOffsets)
    }
}
