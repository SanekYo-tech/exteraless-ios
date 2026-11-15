import XCTest
import RichTextEditorCore

final class DocumentLinkTargetsTests: XCTestCase {
    private let url = "https://example.test/?utm_source=x"
    private var linked: TextRun { TextRun(text: "😀 label", attributes: CharacterAttributes(bold: true, link: url)) }

    func testNestedPrivateFragmentRewritesTargetsWithoutFlatteningAnything() throws {
        let media = MediaBlock(id: BlockID("media"), mediaID: "original-reference", naturalSize: Size2D(width: 400, height: 300), caption: [linked])
        let code = CodeBlock(id: BlockID("code"), language: "swift", runs: [linked])
        let opaque = ButtonRef(label: [linked], action: .unsupported(kind: "callback", payload: url))
        let row = ButtonRowBlock(id: BlockID("buttons"), buttons: [ButtonRef(label: [linked], action: .url(url)), opaque, ButtonRef(label: [], action: .copyText(url))])
        let cell = Cell(id: BlockID("cell"), blocks: [.paragraph(ParagraphBlock(id: BlockID("p"), runs: [linked]))])
        let table = TableBlock(id: BlockID("table"), columns: [ColumnSpec(width: 120)], rows: [Row(id: BlockID("row"), cells: [cell])])
        let doc = Document(blocks: [.details(DetailsBlock(id: BlockID("details"), title: [linked], children: [.blockQuote(BlockQuote(id: BlockID("q"), children: [.media(media), .code(code), .table(table), .buttonRow(row)], collapsed: true, author: [linked]))], expanded: false))])
        let cleaned = doc.rewritingLinkTargets { _ in "https://example.test/" }
        guard case let .details(details) = cleaned.blocks[0], case let .blockQuote(quote) = details.children[0], case let .media(updatedMedia) = quote.children[0], case let .code(updatedCode) = quote.children[1], case let .table(updatedTable) = quote.children[2], case let .buttonRow(updatedRow) = quote.children[3] else { return XCTFail("structure was flattened") }
        XCTAssertFalse(details.expanded)
        XCTAssertTrue(quote.collapsed)
        XCTAssertEqual(updatedMedia.items, media.items)
        XCTAssertEqual(updatedMedia.caption[0].text, linked.text)
        XCTAssertTrue(updatedMedia.caption[0].attributes.bold)
        XCTAssertEqual(updatedCode, code)
        XCTAssertEqual(updatedTable.id, table.id)
        XCTAssertEqual(updatedRow.buttons[0].action, .url("https://example.test/"))
        XCTAssertEqual(updatedRow.buttons[1].action, opaque.action)
        XCTAssertEqual(updatedRow.buttons[2].action, .copyText(url))
        XCTAssertEqual(try DocumentCodec.decode(DocumentCodec.encode(cleaned)), cleaned)
    }

    func testInlineCodeAndOverdeepFragmentRemainLiteral() {
        var literal = linked
        literal.attributes.inlineCode = true
        let leaf = Block.paragraph(ParagraphBlock(id: BlockID("literal"), runs: [literal]))
        XCTAssertEqual(Document(blocks: [leaf]).rewritingLinkTargets { _ in "changed" }, Document(blocks: [leaf]))
        var deep = Block.paragraph(ParagraphBlock(id: BlockID("p"), runs: [linked]))
        for i in 0 ..< 66 { deep = .blockQuote(BlockQuote(id: BlockID("q\(i)"), children: [deep])) }
        let doc = Document(blocks: [deep])
        XCTAssertEqual(doc.rewritingLinkTargets { _ in "changed" }, doc)
    }
}
