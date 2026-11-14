import Foundation

/// Source: TelegramAiReplacement.buildComposeTask. These options describe text
/// transformation, not arbitrary model tools or account operations.
public struct AIComposeTask: Sendable {
    public var proofread: Bool
    public var translateTo: String?
    public var style: String?
    public var emojify: Bool
    public var sourceLanguage: String?

    public init(proofread: Bool = false, translateTo: String? = nil, style: String? = nil, emojify: Bool = false, sourceLanguage: String? = nil) {
        self.proofread = proofread; self.translateTo = translateTo; self.style = style
        self.emojify = emojify; self.sourceLanguage = sourceLanguage
    }

    public func prompt(text: String) -> String {
        let task: String
        if let language = translateTo {
            let languageName = Locale(identifier: "en").localizedString(forIdentifier: language) ?? language
            task = "Translate the text into \(languageName). Preserve its meaning, line breaks and emojis, and keep links and @mentions exactly as written. " + (style.map { "Write the translation \($0). " } ?? "")
        } else if proofread {
            task = "Proofread the text: fix spelling, grammar and punctuation. Change as little as possible, keep its meaning, tone, line breaks and emojis, and keep links and @mentions exactly as written. "
        } else if let style {
            task = "Rewrite the whole text \(style). Rephrase every sentence in that style instead of only adding words at the start or end. Keep its meaning, and keep links and @mentions exactly as written. "
        } else { task = "Keep the text as it is. " }
        let language = translateTo ?? sourceLanguage ?? ""
        return AITextAction.wrappedPrompt(task: task + (emojify ? "Add fitting emojis to the text. " : ""), text: text, language: language)
    }
}

public enum AITextDifference {
    /// A conservative contiguous changed range, measured in the new text's UTF-16
    /// coordinates. Prefix/suffix comparison uses Characters to preserve emoji.
    public static func changedRange(original: String, updated: String) -> Range<Int>? {
        if original == updated { return nil }
        let before = Array(original)
        let after = Array(updated)
        var prefix = 0
        while prefix < min(before.count, after.count), before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(before.count - prefix, after.count - prefix), before[before.count - suffix - 1] == after[after.count - suffix - 1] { suffix += 1 }
        let start = String(after.prefix(prefix)).utf16.count
        let end = updated.utf16.count - String(after.suffix(suffix)).utf16.count
        return start ..< end
    }
}
