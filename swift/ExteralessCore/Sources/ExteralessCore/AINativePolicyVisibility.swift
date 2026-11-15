import Foundation

/// Visibility of Telegram's stock AI affordances, independent of the provider
/// replacement policy. Resetting any key restores the original false default.
public struct AINativeVisibilityPolicy: Sendable {
    public static let editorKey = "appearance.hideAiEditor"
    public static let instantViewKey = "appearance.hideIvSummary"
    public static let messageSummaryKey = "appearance.hideMessageSummary"
    public static let keys: Set<String> = [editorKey, instantViewKey, messageSummaryKey]
    public static let instantViewSummaryCaption = "Cocoon AI Summary"

    public static let definitions: [ClientSettingDefinition] = [
        .init(key: editorKey, title: "Hide Telegram AI editor button", section: "AI · Visibility", defaultValue: .bool(false),
              explanation: "Hides the stock AI button in chat input, attachments and media captions. Translation and provider settings are independent.",
              androidSymbols: ["AppearanceConfig.hideAiEditor", "AiFeaturesHelper.isAiEditorHidden"]),
        .init(key: instantViewKey, title: "Hide Instant View AI summary", section: "AI · Visibility", defaultValue: .bool(false),
              explanation: "Hides the Instant View blockquote captioned Cocoon AI Summary. The stored page and ordinary quotes are retained.",
              androidSymbols: ["AppearanceConfig.hideIvSummary", "AiFeaturesHelper.shouldHideIvBlock"]),
        .init(key: messageSummaryKey, title: "Hide message summary button", section: "AI · Visibility", defaultValue: .bool(false),
              explanation: "Hides the stock summary affordance on messages. It does not select or replace a summary provider.",
              androidSymbols: ["AppearanceConfig.hideMessageSummary", "AiFeaturesHelper.isMessageSummaryHidden"])
    ]

    public let hideAiEditor: Bool
    public let hideIvSummary: Bool
    public let hideMessageSummary: Bool

    public init(store: ClientSettings = .shared) {
        hideAiEditor = store.bool(Self.editorKey, default: false)
        hideIvSummary = store.bool(Self.instantViewKey, default: false)
        hideMessageSummary = store.bool(Self.messageSummaryKey, default: false)
    }

    public static func hidesInstantViewBlockquote(caption: String, hideSummary: Bool) -> Bool {
        hideSummary && caption == instantViewSummaryCaption
    }
}
