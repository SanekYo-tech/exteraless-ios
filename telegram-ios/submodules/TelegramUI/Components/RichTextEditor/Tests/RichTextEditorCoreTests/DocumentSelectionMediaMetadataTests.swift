import XCTest
@testable import RichTextEditorCore

/// CMC-06: selected-text replacement must not reconfigure a media block outside the selection.
/// Calls the actual kernel entry the native Translate completion uses, including its complement copy.
final class DocumentSelectionMediaMetadataTests: XCTestCase {
    func testReplacingTextKeepsNeighbouringSlideshowAndAllItsPayloadAtAnyDepth() throws {
        let media = MediaBlock(id: BlockID("media"), items: [
            MediaItem(mediaID: "first", kind: .image, naturalSize: Size2D(width: 120, height: 80)),
            MediaItem(mediaID: "second", kind: .video, naturalSize: Size2D(width: 80, height: 120), isSpoiler: true)
        ], displayWidth: 240, alignment: .right, displayMode: .slideshow,
        caption: [TextRun(text: "caption", attributes: CharacterAttributes(link: "https://authored.test/"))])
        for nested in [false, true] {
            let body = Block.paragraph(ParagraphBlock(id: BlockID("body"), runs: [TextRun(text: "😀 old tail")]))
            let children: [Block] = [body, .media(media)]
            let document = Document(blocks: nested ? [
                .blockQuote(BlockQuote(id: BlockID("quote"), children: children, author: [TextRun(text: "author")]))
            ] : children)
            let start = try XCTUnwrap(PositionResolver.globalPosition(of: .paragraph(BlockID("body")), offset: 3, in: DocumentTree.build(from: document)))
            let replacement = Document(blocks: [.paragraph(ParagraphBlock(id: BlockID("replacement"), runs: [TextRun(text: "new")]))])
            let changed = document.replacingRange(globalFrom: start, globalTo: start + 3, with: replacement).document
            let result: [Block]
            if nested {
                guard changed.blocks.count == 1, case let .blockQuote(quote) = changed.blocks[0] else { return XCTFail("quote was flattened") }
                XCTAssertEqual(quote.author, [TextRun(text: "author")])
                result = quote.children
            } else {
                result = changed.blocks
            }
            guard result.count == 2, case let .paragraph(paragraph) = result[0], case let .media(kept) = result[1] else {
                return XCTFail("replacement changed the neighbouring block structure")
            }
            XCTAssertEqual(paragraph.text, "😀 new tail")
            XCTAssertEqual(kept.items, media.items)
            XCTAssertEqual(kept.displayWidth, media.displayWidth)
            XCTAssertEqual(kept.alignment, media.alignment)
            XCTAssertEqual(kept.displayMode, .slideshow)
            XCTAssertEqual(kept.caption, media.caption)
        }
    }
}
