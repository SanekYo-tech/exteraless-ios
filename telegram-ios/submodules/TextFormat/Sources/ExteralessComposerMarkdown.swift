import ExteralessCore
import Foundation
import TelegramCore

/// Original EntitiesHelper's ordered grammar over attributed substrings. No whole-document
/// round trip: existing entities, code, emoji and every run outside a match remain intact.
/// `respectDisableMarkdown` is false at getEntities-style boundaries (media captions, edits and
/// forwarding comments). The send-composer toggle is not a request to erase explicit formatting.
public func exteralessComposerMarkdown(_ value: NSAttributedString, settings: ClientSettings = .shared, respectDisableMarkdown: Bool = true) -> NSAttributedString {
    guard !respectDisableMarkdown || !settings.bool("chats.disableMarkdown") else { return value }
    guard settings.integer("chats.markdownParser", default: 1) == 1 else { return convertMarkdownToAttributes(value) }
    guard value.length <= 65536 else { return value }
    let result = NSMutableAttributedString(attributedString: value)
    let patterns = ["^`{3}(.*?)[\\n\\r](.*?[\\n\\r]?)`{3}", "^`{3}[\\n\\r]?(.*?)[\\n\\r]?`{3}", "`{3}([^`]+)`{3}", "`([^`]+?)`", "[*]{2}([^*\\n]+)[*]{2}", "_{2}([^_\\n]+)_{2}", "~{2}([^~\\n]+)~{2}", "[|]{2}([^|\\n]+)[|]{2}", "\\[([^]]+?)]\\((https?://[^\\s)]+|www\\.[^\\s)]+)\\)"]
    for (index, pattern) in patterns.enumerated() {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: index < 2 ? [.anchorsMatchLines, .dotMatchesLineSeparators] : (index == 3 ? [.dotMatchesLineSeparators] : [])) else { continue }
        let matches = regex.matches(in: result.string, range: NSRange(location: 0, length: result.length))
        guard matches.count <= 4096 else { return value }
        for match in matches.reversed() {
            var protected = false
            result.enumerateAttributes(in: match.range, options: []) { attributes, _, stop in
                let codeBlock: Bool
                if let block = attributes[ChatTextInputAttributes.block] as? ChatTextInputTextQuoteAttribute, case .code = block.kind { codeBlock = true } else { codeBlock = false }
                if codeBlock || attributes[ChatTextInputAttributes.monospace] != nil || attributes[ChatTextInputAttributes.collapsedBlock] != nil || attributes[ChatTextInputAttributes.customEmoji] != nil || attributes[ChatTextInputAttributes.textUrl] != nil || attributes[ChatTextInputAttributes.textMention] != nil || attributes[ChatTextInputAttributes.date] != nil {
                    protected = true; stop.pointee = true
                }
            }
            if protected { continue }
            var contentRange = match.range(at: index == 0 ? 2 : 1)
            if index == 0, contentRange.length > 0, (result.string as NSString).character(at: NSMaxRange(contentRange) - 1) == 10 { contentRange.length -= 1 }
            let content = NSMutableAttributedString(attributedString: result.attributedSubstring(from: contentRange))
            let range = NSRange(location: 0, length: content.length)
            switch index {
            case 0:
                let language = (result.string as NSString).substring(with: match.range(at: 1))
                content.addAttribute(ChatTextInputAttributes.block, value: ChatTextInputTextQuoteAttribute(kind: .code(language: language), isCollapsed: false), range: range)
            case 1 ... 3: content.addAttribute(ChatTextInputAttributes.monospace, value: true, range: range)
            case 4: content.addAttribute(ChatTextInputAttributes.bold, value: true, range: range)
            case 5: content.addAttribute(ChatTextInputAttributes.italic, value: true, range: range)
            case 6: content.addAttribute(ChatTextInputAttributes.strikethrough, value: true, range: range)
            case 7: content.addAttribute(ChatTextInputAttributes.spoiler, value: true, range: range)
            default:
                let target = (result.string as NSString).substring(with: match.range(at: 2))
                content.addAttribute(ChatTextInputAttributes.textUrl, value: ChatTextInputTextUrlAttribute(url: target.hasPrefix("www.") ? "https://" + target : target), range: range)
            }
            result.replaceCharacters(in: match.range, with: content)
        }
    }
    return result
}

/// The actual caption producer shared by native and legacy asset-picker results. Captions follow
/// the selected grammar, independently of the ordinary text-send Markdown toggle.
public func exteralessComposerCaption(_ caption: NSAttributedString?, settings: ClientSettings = .shared) -> (text: NSAttributedString, entities: [MessageTextEntity]) {
    let text = trimChatInputText(exteralessComposerMarkdown(caption ?? NSAttributedString(), settings: settings, respectDisableMarkdown: false))
    return (text, generateTextEntities(text.string, enabledTypes: .all, currentEntities: generateChatInputTextEntities(text)))
}

/// Forwarding's authored comment, before enqueue: parse once, trim, split, then compute UTF-16
/// entities per piece. Explicit attributes keep the forwarding producer's uncapped emoji semantics.
public func exteralessComposerForwardComment(_ comment: NSAttributedString, settings: ClientSettings = .shared) -> [(text: NSAttributedString, entities: [MessageTextEntity])] {
    let input = exteralessComposerMarkdown(comment, settings: settings, respectDisableMarkdown: false)
    return breakChatInputText(trimChatInputText(input)).filter { $0.length != 0 }.map { text in
        (text, generateTextEntities(text.string, enabledTypes: .all, currentEntities: generateChatInputTextEntities(text)))
    }
}
