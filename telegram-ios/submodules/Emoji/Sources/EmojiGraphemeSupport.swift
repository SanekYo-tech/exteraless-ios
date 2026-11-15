import CoreGraphics
import CoreText
import ExteralessCore
import Foundation

/// Use-time support, scoped to one immutable font face. Positive AND negative
/// decisions are cached; arbitrary text cannot grow this cache or bitmap size.
final class EmojiGraphemeSupport: @unchecked Sendable {
    private static let capacity = 256
    private let graphicsFont: CGFont
    private let lock = NSLock()
    private var decisions: [String: Bool] = [:]
    private var insertionOrder: [String] = []
    private var didReadCmap = false
    private var cmap: [UInt8]?

    init(graphicsFont: CGFont) { self.graphicsFont = graphicsFont }

    func supports(_ text: String) -> Bool {
        guard text.utf16.count <= 32, StickerReactionPolicy.isEmoji(text) else { return false }
        self.lock.lock()
        defer { self.lock.unlock() }
        if let value = self.decisions[text] { return value }
        let value = self.evaluate(text)
        if self.insertionOrder.count == Self.capacity {
            self.decisions.removeValue(forKey: self.insertionOrder.removeFirst())
        }
        self.insertionOrder.append(text)
        self.decisions[text] = value
        return value
    }

    /// The fixed-size shaping/drawing work is performed only on a cache miss.
    /// Requiring one shaped glyph for an emoji grapheme rejects partially shaped
    /// ZWJ/modifier/flag sequences (e.g. a visible base plus a blank second glyph).
    private func evaluate(_ text: String) -> Bool {
        let font = CTFontCreateWithGraphicsFont(self.graphicsFont, 32, nil, nil)
        let scalars = Array(text.unicodeScalars)
        for index in scalars.indices {
            let value = scalars[index].value
            if (0xfe00...0xfe0f).contains(value) || (0xe0100...0xe01ef).contains(value) {
                guard index > 0, self.hasVariation(base: scalars[index - 1].value, selector: value) else { return false }
            }
        }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        guard runs.count == 1, let run = runs.first, CTRunGetGlyphCount(run) == 1 else { return false }
        let attributes = CTRunGetAttributes(run) as NSDictionary
        guard let value = attributes[kCTFontAttributeName] else { return false }
        let runFont = value as! CTFont
        guard CTFontCopyPostScriptName(runFont) == CTFontCopyPostScriptName(font) else { return false }
        var glyph: CGGlyph = 0
        CTRunGetGlyphs(run, CFRange(location: 0, length: 1), &glyph)
        guard glyph != 0 else { return false }

        // A nonzero glyph can have no outline/bitmap at all. Probe THIS grapheme,
        // not a different emoji that happened to pass font installation.
        guard let context = CGContext(data: nil, width: 96, height: 96, bitsPerComponent: 8, bytesPerRow: 96 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.clear(CGRect(x: 0, y: 0, width: 96, height: 96))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.textPosition = CGPoint(x: 16, y: 32)
        CTLineDraw(line, context)
        guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
        return stride(from: 3, to: 96 * 96 * 4, by: 4).contains(where: { bytes[$0] != 0 })
    }

    /// CoreText may silently discard an unsupported variation selector. Require
    /// an explicit cmap-14 default/non-default mapping before accepting it. This
    /// is a conservative per-grapheme fallback, not a change to SFNT admission.
    private func hasVariation(base: UInt32, selector: UInt32) -> Bool {
        if !self.didReadCmap {
            self.didReadCmap = true
            // Read the installed face's raw table. CoreText's excludeSynthetic
            // option is unavailable on iOS, and fallback tables are not evidence.
            if let data = self.graphicsFont.table(for: 0x636d6170) as Data?, data.count <= 1024 * 1024 {
                self.cmap = Array(data)
            }
        }
        guard let bytes = self.cmap else { return false }
        func uint(_ offset: Int, _ length: Int, end: Int) -> Int? {
            guard offset >= 0, offset <= end, length <= end - offset, end <= bytes.count else { return nil }
            var result = 0
            for index in offset..<(offset + length) { result = result << 8 | Int(bytes[index]) }
            return result
        }
        guard let count = uint(2, 2, end: bytes.count), count <= 64, 4 + count * 8 <= bytes.count else { return false }
        for record in 0..<count {
            let at = 4 + record * 8
            guard let start = uint(at + 4, 4, end: bytes.count), uint(start, 2, end: bytes.count) == 14,
                  let length = uint(start + 2, 4, end: bytes.count), length >= 10, length <= bytes.count - start,
                  let selectors = uint(start + 6, 4, end: start + length), selectors <= 256, selectors <= (length - 10) / 11 else { continue }
            let end = start + length
            for index in 0..<selectors {
                let entry = start + 10 + index * 11
                guard uint(entry, 3, end: end) == Int(selector) else { continue }
                // Search the sorted non-default mappings or default ranges. Both
                // count/offset checks precede all accesses, including binary search.
                for nonDefault in [true, false] {
                    guard let offset = uint(entry + (nonDefault ? 7 : 3), 4, end: end), offset > 0, offset <= length - 4,
                          let count = uint(start + offset, 4, end: end), count <= 65536 else { continue }
                    let stride = nonDefault ? 5 : 4
                    guard count <= (length - offset - 4) / stride else { continue }
                    var low = 0, high = count
                    while low < high {
                        let middle = low + (high - low) / 2
                        let position = start + offset + 4 + middle * stride
                        guard let code = uint(position, 3, end: end) else { return false }
                        if code > Int(base) { high = middle; continue }
                        if nonDefault {
                            if code == Int(base) { return (uint(position + 3, 2, end: end) ?? 0) != 0 }
                        } else if let additional = uint(position + 3, 1, end: end), Int(base) <= code + additional {
                            return true
                        }
                        low = middle + 1
                    }
                }
                return false
            }
        }
        return false
    }
}
