import Foundation

public extension Document {
    /// Rewrites destinations only, before a paste is spliced. Labels, block/run identities,
    /// tables, folds, media references, formulae and non-URL button payloads are retained.
    /// Code is literal. A pathological fragment is returned whole rather than half rewritten.
    func rewritingLinkTargets(_ transform: ((String) -> String)?) -> Document {
        guard let transform else { return self }
        var remaining = 8192
        var exceeded = false
        func enter(_ depth: Int) -> Bool {
            guard depth <= 64, remaining > 0 else { exceeded = true; return false }
            remaining -= 1
            return true
        }
        func button(_ value: ButtonRef, depth: Int) -> ButtonRef {
            guard enter(depth) else { return value }
            var result = value
            if case let .url(url) = result.action { result.action = .url(transform(url)) }
            result.label = runs(result.label, depth: depth + 1)
            return result
        }
        func runs(_ values: [TextRun], depth: Int) -> [TextRun] {
            values.map { value in
                guard enter(depth), !value.attributes.inlineCode else { return value }
                var result = value
                if let link = result.attributes.link { result.attributes.link = transform(link) }
                if let ref = result.attributes.button { result.attributes.button = button(ref, depth: depth + 1) }
                return result
            }
        }
        func blocks(_ values: [Block], depth: Int) -> [Block] {
            values.map { value in
                guard enter(depth) else { return value }
                switch value {
                case var .paragraph(p):
                    p.runs = runs(p.runs, depth: depth + 1)
                    return .paragraph(p)
                case .code:
                    return value
                case var .media(m):
                    m.caption = runs(m.caption, depth: depth + 1)
                    return .media(m)
                case var .table(t):
                    t.rows = t.rows.map { row in
                        var row = row
                        row.cells = row.cells.map { cell in
                            var cell = cell
                            cell.blocks = blocks(cell.blocks, depth: depth + 1)
                            return cell
                        }
                        return row
                    }
                    return .table(t)
                case var .pullQuote(q):
                    q.runs = runs(q.runs, depth: depth + 1)
                    q.author = runs(q.author, depth: depth + 1)
                    return .pullQuote(q)
                case var .blockQuote(q):
                    q.children = blocks(q.children, depth: depth + 1)
                    q.author = runs(q.author, depth: depth + 1)
                    return .blockQuote(q)
                case var .details(d):
                    d.title = runs(d.title, depth: depth + 1)
                    d.children = blocks(d.children, depth: depth + 1)
                    return .details(d)
                case var .buttonRow(r):
                    r.buttons = r.buttons.map { button($0, depth: depth + 1) }
                    return .buttonRow(r)
                }
            }
        }
        let result = Document(schemaVersion: schemaVersion, blocks: blocks(self.blocks, depth: 0))
        return exceeded ? self : result
    }
}
