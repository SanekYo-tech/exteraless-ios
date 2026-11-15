import Foundation

public struct RetentionQuotePrefix: Equatable, Sendable {
    public let text: String
    public let bodyOffset: Int
    public let quoteLength: Int
    public let authorLength: Int
}

/// Android entities use UTF-16 offsets. Keep that contract for emoji/combining characters and
/// never mutate the caller's existing entity objects while constructing an album quote.
public enum RetentionPolicyQuote {
    public static func prefix(author: String, quote: String, body: String, maximumLength: Int) throws -> RetentionQuotePrefix {
        let author = clipped(author.replacingOccurrences(of: "\n", with: " "), units: 256)
        guard !author.isEmpty, maximumLength > 0, maximumLength <= 1_048_576 else { throw RetentionArchiveError.invalidData }
        let separator = body.isEmpty ? 0 : 1
        let available = maximumLength - body.utf16.count - separator - author.utf16.count - 1
        guard available >= 1 else { throw RetentionArchiveError.limitExceeded }
        let truncated = quote.utf16.count > available
        let quoted = clipped(quote, units: max(0, available - (truncated ? 1 : 0))) + (truncated ? "…" : "")
        let prefix = author + "\n" + quoted
        let offset = prefix.utf16.count + separator
        return RetentionQuotePrefix(text: prefix + (body.isEmpty ? "" : "\n") + body, bodyOffset: offset, quoteLength: prefix.utf16.count, authorLength: author.utf16.count)
    }

    public static func clipped(_ value: String, units: Int) -> String {
        guard units > 0 else { return "" }
        guard value.utf16.count > units else { return value }
        var end = value.utf16.index(value.utf16.startIndex, offsetBy: units)
        while String.Index(end, within: value) == nil { end = value.utf16.index(before: end) }
        return String(value[..<String.Index(end, within: value)!])
    }
}
