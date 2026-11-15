import ExteralessCore

/// Instant View presentation only. Both TL blockquote constructors map to the
/// native .blockQuote case; pull quotes and nested page content are not filtered.
public enum ExteralessAIVisibility {
    public static var instantViewSummaryHidden: Bool { AINativeVisibilityPolicy().hideIvSummary }

    public static func shouldHideInstantViewBlock(_ block: InstantPageBlock, hideSummary: Bool) -> Bool {
        guard hideSummary, case let .blockQuote(_, caption, _) = block else { return false }
        return AINativeVisibilityPolicy.hidesInstantViewBlockquote(caption: caption.plainText, hideSummary: hideSummary)
    }
}
