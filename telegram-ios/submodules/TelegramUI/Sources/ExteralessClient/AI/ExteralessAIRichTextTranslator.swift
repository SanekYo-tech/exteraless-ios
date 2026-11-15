import BrowserUI
import ExteralessCore
import Foundation
import TelegramCore

/// Text-leaf translation preserves the actual InstantPage graph, media, button
/// actions, URLs, tables, list markers and collapse state. Code/entity payloads
/// are never replaced by a model-generated page or flattened attributed string.
enum ExteralessAIRichTextTranslator {
    @MainActor
    static func markdown(source: RichTextMessageAttribute) async throws -> String {
        let page = ExteralessAIRichSource.wholePage(source)
        guard page.isComplete else { throw AIError.incompleteStream }
        return try await markdown(page: page)
    }

    @MainActor
    static func translate(source: RichTextMessageAttribute, client: AITranslationClient, to language: String, configuration: AITranslationConfiguration) async throws -> InstantPage {
        let page = ExteralessAIRichSource.wholePage(source)
        guard page.isComplete else { throw AIError.incompleteStream }
        return try await translate(page: page, client: client, to: language, configuration: configuration)
    }

    @MainActor
    static func markdown(page: InstantPage) async throws -> String {
        let snapshot = PageSnapshot(page)
        let worker = Task.detached(priority: .userInitiated) {
            var validator = Mapper(buildOutput: false, transform: { $0 })
            _ = try validator.page(snapshot.page)
            try Task.checkCancellation()
            let text = markdownStringFromInstantPage(snapshot.page)
            guard text.utf16.count <= AILimits.inputUTF16 else { throw AIError.inputTooLarge }
            return text
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    @MainActor
    static func translate(page: InstantPage, client: AITranslationClient, to language: String, configuration: AITranslationConfiguration) async throws -> InstantPage {
        let snapshot = PageSnapshot(page)
        let collect = Task.detached(priority: .userInitiated) {
            var texts: [String] = []
            var seen = Set<String>()
            var collector = Mapper(buildOutput: false) { text in
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !seen.contains(text) {
                    guard texts.count < 512 else { throw AIError.inputTooLarge }
                    seen.insert(text)
                    texts.append(text)
                }
                return text
            }
            _ = try collector.page(snapshot.page)
            return texts
        }
        let texts = try await withTaskCancellationHandler(operation: { try await collect.value }, onCancel: { collect.cancel() })
        var translations: [String: String] = [:]
        var outputUTF16 = 0
        try await withThrowingTaskGroup(of: (String, String).self) { group in
            var next = 0
            func submit(_ text: String) {
                group.addTask {
                    let result = try await client.translate(.init(text: text), to: language, configuration: configuration)
                    return (text, result.text.text)
                }
            }
            while next < min(5, texts.count) { submit(texts[next]); next += 1 }
            while let (source, result) = try await group.next() {
                guard result.utf16.count <= 512_000 - outputUTF16 else { throw AIError.inputTooLarge }
                outputUTF16 += result.utf16.count
                translations[source] = result
                if next < texts.count { submit(texts[next]); next += 1 }
            }
        }
        try Task.checkCancellation()
        let replacements = translations
        let write = Task.detached(priority: .userInitiated) {
            var writer = Mapper(maximumUTF16: 512_000) { replacements[$0] ?? $0 }
            return PageSnapshot(try writer.page(snapshot.page))
        }
        return try await withTaskCancellationHandler(operation: { try await write.value.page }, onCancel: { write.cancel() })
    }

    // InstantPage and its graph have immutable fields. This box transfers only
    // that read-only snapshot; all mapper state remains local to the worker.
    private final class PageSnapshot: @unchecked Sendable {
        let page: InstantPage
        init(_ page: InstantPage) { self.page = page }
    }

    /// Also usable by a native fixture with a local deterministic transform.
    struct Mapper {
        let transform: (String) throws -> String
        private let buildOutput: Bool
        private let maximumUTF16: Int
        private var budget: AINativeGraphBudget
        private var textSize = 0
        private var preservingText = false
        private(set) var outputSlots = 0
        var visitedNodes: Int { budget.visited }
        init(buildOutput: Bool = true, maximumNodes: Int = 8192, maximumDepth: Int = 48, maximumUTF16: Int = 256_000, transform: @escaping (String) throws -> String) {
            self.transform = transform
            self.buildOutput = buildOutput
            self.maximumUTF16 = max(0, maximumUTF16)
            self.budget = AINativeGraphBudget(maximumNodes: maximumNodes, maximumDepth: maximumDepth)
        }

        mutating func page(_ page: InstantPage) throws -> InstantPage {
            try budget.visit(depth: 0)
            try budget.visit(depth: 0, count: page.media.count)
            let blocks = try collection(page.blocks, depth: 0) { try $0.block($1, depth: $2) }
            guard buildOutput else { return page }
            return InstantPage(blocks: blocks, media: page.media, isComplete: page.isComplete, rtl: page.rtl, url: page.url, views: page.views)
        }
        private mutating func visit(_ depth: Int) throws {
            try budget.visit(depth: depth)
        }
        private mutating func collection<T>(_ values: [T], depth: Int, map: (inout Mapper, T, Int) throws -> T) throws -> [T] {
            // Check BEFORE reserve/map; every member consumes at least one node.
            try budget.checkCollection(count: values.count, depth: depth)
            let writes = buildOutput && !preservingText
            var output: [T] = []
            if writes { output.reserveCapacity(values.count); outputSlots += values.count }
            for value in values {
                try Task.checkCancellation()
                let mapped = try map(&self, value, depth)
                if writes { output.append(mapped) }
            }
            return writes ? output : values
        }
        private mutating func unchangedText(_ value: RichText, depth: Int) throws {
            let previous = preservingText
            preservingText = true
            defer { preservingText = previous }
            _ = try text(value, depth: depth)
        }
        private mutating func text(_ value: RichText, depth: Int) throws -> RichText {
            try visit(depth)
            switch value {
            case let .plain(value):
                guard value.utf16.count <= maximumUTF16 - textSize else { throw AIError.inputTooLarge }
                let mapped = preservingText ? value : try transform(value)
                guard mapped.utf16.count <= maximumUTF16 - textSize else { throw AIError.inputTooLarge }
                textSize += mapped.utf16.count
                return .plain(mapped)
            case let .bold(value): return .bold(try text(value, depth: depth + 1))
            case let .italic(value): return .italic(try text(value, depth: depth + 1))
            case let .underline(value): return .underline(try text(value, depth: depth + 1))
            case let .strikethrough(value): return .strikethrough(try text(value, depth: depth + 1))
            case let .url(value, url, webpageId): return .url(text: try text(value, depth: depth + 1), url: url, webpageId: webpageId)
            case let .concat(values): return .concat(try collection(values, depth: depth + 1) { try $0.text($1, depth: $2) })
            case let .subscript(value): return .subscript(try text(value, depth: depth + 1))
            case let .superscript(value): return .superscript(try text(value, depth: depth + 1))
            case let .marked(value): return .marked(try text(value, depth: depth + 1))
            case let .anchor(value, name): return .anchor(text: try text(value, depth: depth + 1), name: name)
            case let .textSpoiler(value): return .textSpoiler(text: try text(value, depth: depth + 1))
            case let .textDate(value, date, format): return .textDate(text: try text(value, depth: depth + 1), date: date, format: format)
            case let .textButton(value): return .textButton(try button(value, depth: depth + 1))
            case let .fixed(child), let .email(child, _), let .phone(child, _), let .textAutoEmail(child), let .textAutoPhone(child), let .textAutoUrl(child), let .textBankCard(child), let .textTonAddress(child), let .textBotCommand(child), let .textCashtag(child), let .textHashtag(child), let .textMention(child), let .textMentionName(child, _):
                try unchangedText(child, depth: depth + 1)
                return value
            case .empty, .image, .formula, .textCustomEmoji:
                return value
            }
        }
        private mutating func caption(_ value: InstantPageCaption, depth: Int) throws -> InstantPageCaption {
            try visit(depth)
            return try InstantPageCaption(text: text(value.text, depth: depth + 1), credit: text(value.credit, depth: depth + 1))
        }
        private mutating func button(_ value: InstantPageButton, depth: Int) throws -> InstantPageButton {
            try visit(depth)
            return try InstantPageButton(text: text(value.text, depth: depth + 1), action: value.action, color: value.color, isLink: value.isLink)
        }
        private mutating func listItem(_ item: InstantPageListItem, depth: Int) throws -> InstantPageListItem {
            try visit(depth)
            switch item {
            case .unknown: return item
            case let .text(value, number, checked): return .text(try text(value, depth: depth + 1), number, checked)
            case let .blocks(values, number, checked): return .blocks(try collection(values, depth: depth + 1) { try $0.block($1, depth: $2) }, number, checked)
            }
        }
        private mutating func row(_ value: InstantPageTableRow, depth: Int) throws -> InstantPageTableRow {
            try visit(depth)
            return InstantPageTableRow(cells: try collection(value.cells, depth: depth + 1) { try $0.cell($1, depth: $2) })
        }
        private mutating func cell(_ value: InstantPageTableCell, depth: Int) throws -> InstantPageTableCell {
            try visit(depth)
            let mapped = try value.text.map { try text($0, depth: depth + 1) }
            return InstantPageTableCell(text: mapped, header: value.header, alignment: value.alignment, verticalAlignment: value.verticalAlignment, colspan: value.colspan, rowspan: value.rowspan)
        }
        private mutating func block(_ value: InstantPageBlock, depth: Int) throws -> InstantPageBlock {
            try visit(depth)
            switch value {
            case let .title(value): return .title(try text(value, depth: depth + 1))
            case let .subtitle(value): return .subtitle(try text(value, depth: depth + 1))
            case let .authorDate(author, date): return .authorDate(author: try text(author, depth: depth + 1), date: date)
            case let .header(value): return .header(try text(value, depth: depth + 1))
            case let .subheader(value): return .subheader(try text(value, depth: depth + 1))
            case let .heading(value, level): return .heading(text: try text(value, depth: depth + 1), level: level)
            case let .paragraph(value): return .paragraph(try text(value, depth: depth + 1))
            case let .footer(value): return .footer(try text(value, depth: depth + 1))
            case let .kicker(value): return .kicker(try text(value, depth: depth + 1))
            case let .thinking(value): return .thinking(try text(value, depth: depth + 1))
            case let .list(items, ordered):
                let values = try collection(items, depth: depth + 1) { try $0.listItem($1, depth: $2) }
                return .list(items: values, ordered: ordered)
            case let .blockQuote(values, value, collapsed): return .blockQuote(blocks: try collection(values, depth: depth + 1) { try $0.block($1, depth: $2) }, caption: try text(value, depth: depth + 1), collapsed: collapsed)
            case let .pullQuote(value, title): return .pullQuote(text: try text(value, depth: depth + 1), caption: try text(title, depth: depth + 1))
            case let .image(id, value, url, webpageId, spoiler): return .image(id: id, caption: try caption(value, depth: depth + 1), url: url, webpageId: webpageId, spoiler: spoiler)
            case let .video(id, value, autoplay, loop, spoiler): return .video(id: id, caption: try caption(value, depth: depth + 1), autoplay: autoplay, loop: loop, spoiler: spoiler)
            case let .audio(id, value): return .audio(id: id, caption: try caption(value, depth: depth + 1))
            case let .document(id, value): return .document(id: id, caption: try caption(value, depth: depth + 1))
            case let .buttonRow(alignment, values): return .buttonRow(alignment: alignment, buttons: try collection(values, depth: depth + 1) { try $0.button($1, depth: $2) })
            case let .cover(value): return .cover(try block(value, depth: depth + 1))
            case let .webEmbed(url, html, dimensions, value, stretch, scrolling, cover): return .webEmbed(url: url, html: html, dimensions: dimensions, caption: try caption(value, depth: depth + 1), stretchToWidth: stretch, allowScrolling: scrolling, coverId: cover)
            case let .postEmbed(url, webpageId, avatarId, author, date, values, value): return .postEmbed(url: url, webpageId: webpageId, avatarId: avatarId, author: author, date: date, blocks: try collection(values, depth: depth + 1) { try $0.block($1, depth: $2) }, caption: try caption(value, depth: depth + 1))
            case let .collage(values, value): return .collage(items: try collection(values, depth: depth + 1) { try $0.block($1, depth: $2) }, caption: try caption(value, depth: depth + 1))
            case let .slideshow(values, value): return .slideshow(items: try collection(values, depth: depth + 1) { try $0.block($1, depth: $2) }, caption: try caption(value, depth: depth + 1))
            case let .table(title, rows, bordered, striped, compact):
                let translatedRows = try collection(rows, depth: depth + 1) { try $0.row($1, depth: $2) }
                return .table(title: try text(title, depth: depth + 1), rows: translatedRows, bordered: bordered, striped: striped, compact: compact)
            case let .details(title, values, expanded): return .details(title: try text(title, depth: depth + 1), blocks: try collection(values, depth: depth + 1) { try $0.block($1, depth: $2) }, expanded: expanded)
            case let .relatedArticles(title, articles):
                try budget.visit(depth: depth + 1, count: articles.count)
                return .relatedArticles(title: try text(title, depth: depth + 1), articles: articles)
            case let .map(latitude, longitude, zoom, dimensions, value): return .map(latitude: latitude, longitude: longitude, zoom: zoom, dimensions: dimensions, caption: try caption(value, depth: depth + 1))
            case let .preformatted(text, _):
                try unchangedText(text, depth: depth + 1)
                return value
            case .unsupported, .formula, .divider, .anchor, .channelBanner: return value
            }
        }
    }
}
