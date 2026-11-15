import ExteralessCore
import Foundation
import ChatRichTextEditorComposer
import RichTextEditorCore
import TelegramCore
import TextFormat
import UIKit

private let exteralessURLDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

/// Clipboard-only adaptation of LinkCleaner.cleanText/cleanSpannedUrls. URL labels and unrelated
/// attributes stay intact; literal code/collapsed structural ranges do not undergo text rewriting.
public func exteralessCleanPastedText(_ value: NSAttributedString, settings: ClientSettings = .shared) -> NSAttributedString {
    guard settings.bool("chats.stripTrackingOnPaste", default: true), value.length <= 65536 else { return value }
    let result = NSMutableAttributedString(attributedString: value)
    var changed = false
    var protectedRanges: [NSRange] = []
    let fullRange = NSRange(location: 0, length: value.length)
    value.enumerateAttributes(in: fullRange, options: []) { attributes, range, _ in
        if [ChatTextInputAttributes.textUrl, .link, ChatTextInputAttributes.monospace, ChatTextInputAttributes.block, ChatTextInputAttributes.collapsedBlock].contains(where: { attributes[$0] != nil }) {
            protectedRanges.append(range)
        }
        // Code can carry a link-looking attribute from an external importer; it is still literal.
        guard attributes[ChatTextInputAttributes.monospace] == nil,
              attributes[ChatTextInputAttributes.block] == nil,
              attributes[ChatTextInputAttributes.collapsedBlock] == nil else { return }
        for key in [ChatTextInputAttributes.textUrl, NSAttributedString.Key.link] {
            let url: String?
            if let attribute = attributes[key] as? ChatTextInputTextUrlAttribute { url = attribute.url }
            else if let attribute = attributes[key] as? URL { url = attribute.absoluteString }
            else { url = attributes[key] as? String }
            guard let url else { continue }
            let cleaned = ChatLinkPolicy.removingTracking(from: url)
            if cleaned != url {
                let attribute: Any = key == ChatTextInputAttributes.textUrl ? ChatTextInputTextUrlAttribute(url: cleaned) : cleaned
                result.addAttribute(key, value: attribute, range: range)
                changed = true
            }
        }
    }
    let matches = exteralessURLDetector?.matches(in: value.string, options: [], range: fullRange) ?? []
    let ranges = matches.prefix(64).compactMap { match -> Range<Int>? in
        guard match.resultType == .link, !protectedRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { return nil }
        return match.range.location ..< (match.range.location + match.range.length)
    }
    for replacement in ChatLinkPolicy.replacements(in: value.string, urlRanges: ranges) {
        result.replaceCharacters(in: NSRange(location: replacement.range.lowerBound, length: replacement.range.count), with: replacement.text)
        changed = true
    }
    return changed ? result : value
}

/// Plain source is still source when Markdown rendering is disabled. Recognise literal fence / code
/// spans and authored link labels before the URL detector runs; these temporary marks never leave
/// this function. Rendering-enabled paste instead parses the ORIGINAL source first, below.
public func exteralessCleanPastedPlainText(_ text: String, settings: ClientSettings = .shared) -> String {
    guard settings.bool("chats.stripTrackingOnPaste", default: true), text.utf16.count <= 65536 else { return text }
    let units = Array(text.utf16)
    let value = NSMutableAttributedString(string: text)
    var protected = [Bool](repeating: false, count: units.count)
    func protect(_ range: Range<Int>) {
        guard !range.isEmpty else { return }
        for i in range { protected[i] = true }
        value.addAttribute(ChatTextInputAttributes.monospace, value: true, range: NSRange(location: range.lowerBound, length: range.count))
    }
    func isSpace(_ unit: UInt16) -> Bool { unit == 32 || unit == 9 }
    var fence: (marker: UInt16, count: Int, start: Int)?
    var line = 0
    while line < units.count {
        var end = line
        while end < units.count, units[end] != 10, units[end] != 13 { end += 1 }
        var next = end
        if next < units.count, units[next] == 13 { next += 1 }
        if next < units.count, units[next] == 10 { next += 1 }
        var start = line
        while start < end, isSpace(units[start]) || units[start] == 62 { start += 1 }
        var markerEnd = start
        if start < end, units[start] == 96 || units[start] == 126 {
            while markerEnd < end, units[markerEnd] == units[start] { markerEnd += 1 }
        }
        if let open = fence {
            if start < end, units[start] == open.marker, markerEnd - start >= open.count,
               units[markerEnd ..< end].allSatisfy(isSpace) {
                protect(open.start ..< next)
                fence = nil
            }
        } else if markerEnd - start >= 3 {
            fence = (units[start], markerEnd - start, line)
        } else if start - line >= 4 || (line < end && units[line] == 9) {
            protect(line ..< next)
        }
        line = next
    }
    if let fence { protect(fence.start ..< units.count) }

    // Pair equal-length backtick runs in linear time. A shorter run inside a code span is content,
    // and an unmatched opener protects nothing. Fenced spans were claimed before this scan.
    var ticks: [Range<Int>] = []
    var mayOpen: [Bool] = []
    var i = 0
    var backslashes = 0
    while i < units.count {
        if units[i] == 96, !protected[i] {
            var end = i + 1
            while end < units.count, units[end] == 96 { end += 1 }
            ticks.append(i ..< end)
            mayOpen.append(backslashes % 2 == 0)
            i = end
            backslashes = 0
        } else {
            backslashes = units[i] == 92 ? backslashes + 1 : 0
            i += 1
        }
    }
    var nextTickByLength: [Int: Int] = [:]
    var closing: [Int: Int] = [:]
    for index in ticks.indices.reversed() {
        closing[index] = nextTickByLength[ticks[index].count]
        nextTickByLength[ticks[index].count] = index
    }
    var coveredEnd = 0
    for index in ticks.indices where ticks[index].lowerBound >= coveredEnd && mayOpen[index] {
        if let end = closing[index] {
            coveredEnd = ticks[end].upperBound
            protect(ticks[index].lowerBound ..< coveredEnd)
        }
    }
    if let labels = try? NSRegularExpression(pattern: #"\[(?:\\.|[^\]\\])*\](?=\(|\[)"#) {
        for match in labels.matches(in: text, range: NSRange(location: 0, length: value.length)) {
            protect(match.range.location ..< NSMaxRange(match.range))
        }
    }
    return exteralessCleanPastedText(value, settings: settings).string
}

/// The plain-paste producer installed on BOTH native editor backends. Parse structure first, so code
/// never reaches a plain URL cleaner. Hrefs are rewritten by the editor's destination-only seam.
public func exteralessComposerPasteFragment(_ text: String, settings: ClientSettings = .shared, parseMarkdown: (String) -> ChatInputContent?) -> Document? {
    if !settings.bool("chats.disableMarkdown"), let content = parseMarkdown(text) {
        let document = pasteFragmentDocument(fromChatInputContent: content)
        guard settings.bool("chats.stripTrackingOnPaste", default: true) else { return document }
        return exteralessCleanPastedProse(document, settings: settings)
    }
    let cleaned = exteralessCleanPastedPlainText(text, settings: settings)
    guard cleaned != text else { return nil }
    return pasteFragmentDocument(fromChatInputContent: chatInputContent(from: NSAttributedString(string: cleaned)))
}

private func exteralessCleanPastedProse(_ document: Document, settings: ClientSettings) -> Document {
    func runs(_ source: [TextRun]) -> [TextRun] {
        // Carry the ORIGINAL CharacterAttributes by index, including non-chat fields. The temporary
        // attributed string is only a URL-span editor, never a Document conversion or draft rebuild.
        let indexKey = NSAttributedString.Key("ExteralessPasteRunIndex")
        let value = NSMutableAttributedString()
        for (index, run) in source.enumerated() {
            var attributes: [NSAttributedString.Key: Any] = [indexKey: index]
            let a = run.attributes
            if a.inlineCode || a.link != nil || a.emoji != nil || a.formula != nil || a.button != nil {
                attributes[ChatTextInputAttributes.monospace] = true
            }
            value.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        let cleaned = exteralessCleanPastedText(value, settings: settings)
        guard cleaned.string != value.string else { return source }
        var result: [TextRun] = []
        cleaned.enumerateAttribute(indexKey, in: NSRange(location: 0, length: cleaned.length), options: []) { index, range, _ in
            guard let index = index as? Int, source.indices.contains(index) else { return }
            result.append(TextRun(text: (cleaned.string as NSString).substring(with: range), attributes: source[index].attributes))
        }
        return result
    }
    func blocks(_ source: [Block]) -> [Block] {
        source.map { block in
            switch block {
            case var .paragraph(p): p.runs = runs(p.runs); return .paragraph(p)
            case .code, .buttonRow: return block
            case var .pullQuote(q): q.runs = runs(q.runs); q.author = runs(q.author); return .pullQuote(q)
            case var .blockQuote(q): q.children = blocks(q.children); q.author = runs(q.author); return .blockQuote(q)
            case var .details(d): d.title = runs(d.title); d.children = blocks(d.children); return .details(d)
            case var .media(m): m.caption = runs(m.caption); return .media(m)
            case var .table(t):
                t.rows = t.rows.map { row in
                    var row = row
                    row.cells = row.cells.map { cell in
                        var cell = cell
                        cell.blocks = blocks(cell.blocks)
                        return cell
                    }
                    return row
                }
                return .table(t)
            }
        }
    }
    var result = document
    result.blocks = blocks(document.blocks)
    return result
}

/// The native rich editor is a container; its first responder is a descendant UITextInput.
/// A bounded walk avoids treating that container's lack of markedTextRange as "no composition".
func exteralessInputHasMarkedText(in root: UIView) -> Bool {
    var pending: [UIView] = [root]
    var visited = 0
    while let view = pending.popLast() {
        visited += 1
        if visited > 128 { return true }
        if view.isFirstResponder, let input = view as? UITextInput, input.markedTextRange != nil { return true }
        pending.append(contentsOf: view.subviews)
    }
    return false
}

func exteralessOrderedFormatActions(_ actions: [UIAction]) -> [UIAction] {
    let prefix = "exteraless.format."
    var byId: [String: UIAction] = [:]
    var available: [String] = []
    for action in actions {
        let raw = action.identifier.rawValue
        let id = raw.hasPrefix(prefix) ? String(raw.dropFirst(prefix.count)) : raw
        byId[id] = action
        available.append(id)
    }
    var hidden = Set(ChatFormattingPolicy.actions.filter {
        !ChatFormattingPolicy.isVisible($0)
    }.map(\.id))
    if hidden.contains("quote") { hidden.insert("pullquote") }
    let order = ChatFormattingPolicy.ordered(available, order: ClientSettings.shared.string("chats.textStyleOrder", default: ChatFormattingPolicy.defaultOrder), hidden: hidden)
    return order.compactMap { byId[$0] }
}
