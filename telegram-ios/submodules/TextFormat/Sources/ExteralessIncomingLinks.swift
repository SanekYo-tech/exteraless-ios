import ExteralessCore
import Foundation

private let incomingLinkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

/// Plain share/import text only. Rich fragments use the kernel's destination-only rewrite.
public func exteralessCleanIncomingLinkText(_ text: String) -> String {
    guard ClientSettings.shared.bool("chats.stripTrackingOnPaste", default: true), text.utf16.count <= 65536 else { return text }
    let ranges = (incomingLinkDetector?.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)) ?? []).map { $0.range.location ..< NSMaxRange($0.range) }
    let result = NSMutableString(string: text)
    for edit in ChatLinkPolicy.replacements(in: text, urlRanges: ranges) {
        result.replaceCharacters(in: NSRange(location: edit.range.lowerBound, length: edit.range.count), with: edit.text)
    }
    return result as String
}
