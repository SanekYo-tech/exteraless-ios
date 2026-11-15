import Foundation

/// A bounded display/export projection. The full native rich attribute remains in the snapshot.
/// Unlike InstantPage.plainText (a draft-only helper), this includes headings, tables and captions.
func exteralessRetentionRichText(_ page: InstantPage) -> String {
    var pieces: [String] = []
    var remaining = 4096
    func text(_ value: RichText) { if !value.plainText.isEmpty { pieces.append(value.plainText) } }
    func caption(_ value: InstantPageCaption) { text(value.text); text(value.credit) }
    func visit(_ blocks: [InstantPageBlock], depth: Int) {
        guard depth <= 32 else { pieces.append("[Nested content]"); return }
        for block in blocks {
            guard remaining > 0 else { pieces.append("[More content]"); return }
            remaining -= 1
            switch block {
            case let .title(value), let .subtitle(value), let .header(value), let .subheader(value), let .paragraph(value), let .footer(value), let .kicker(value), let .thinking(value): text(value)
            case let .heading(value, _), let .preformatted(value, _), let .authorDate(value, _): text(value)
            case let .formula(latex): pieces.append(latex)
            case let .list(items, _):
                for item in items.prefix(4096) {
                    switch item {
                    case let .text(value, _, _): text(value)
                    case let .blocks(blocks, _, _): visit(blocks, depth: depth + 1)
                    case .unknown: pieces.append("[Unsupported list item]")
                    }
                }
            case let .blockQuote(blocks, value, _): visit(blocks, depth: depth + 1); text(value)
            case let .pullQuote(value, attribution): text(value); text(attribution)
            case let .image(_, value, _, _, _), let .video(_, value, _, _, _), let .audio(_, value), let .document(_, value), let .map(_, _, _, _, value): caption(value)
            case let .buttonRow(_, buttons): for button in buttons.prefix(128) { text(button.text) }
            case let .cover(block): visit([block], depth: depth + 1)
            case let .webEmbed(_, _, _, value, _, _, _): caption(value)
            case let .postEmbed(_, _, _, author, _, blocks, value): pieces.append(author); visit(blocks, depth: depth + 1); caption(value)
            case let .collage(blocks, value), let .slideshow(blocks, value): visit(blocks, depth: depth + 1); caption(value)
            case let .table(title, rows, _, _, _):
                text(title)
                for row in rows.prefix(4096) { for cell in row.cells.prefix(128) { if let value = cell.text { text(value) } } }
            case let .details(title, blocks, _): text(title); visit(blocks, depth: depth + 1)
            case let .relatedArticles(title, _): text(title)
            case .unsupported: pieces.append("[Unsupported block]")
            case .anchor, .divider, .channelBanner: break
            }
        }
    }
    visit(page.blocks, depth: 0)
    return String(pieces.joined(separator: "\n").prefix(131072))
}
