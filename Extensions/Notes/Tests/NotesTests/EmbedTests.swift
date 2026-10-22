import AppKit
import XCTest
@testable import Notes

final class MentionTriggerTests: XCTestCase {
    private func query(_ text: String) -> String? {
        MentionTrigger.find(in: text as NSString, caret: (text as NSString).length)?.query
    }

    func testAtOpensOnlyAtTheStartOfAWord() {
        XCTAssertEqual(query("@"), "")
        XCTAssertEqual(query("see @img"), "img")
        XCTAssertEqual(query("line\n@ph"), "ph")
        XCTAssertEqual(query("(@sk"), "sk")
        XCTAssertNil(query("abc@"))
        XCTAssertNil(query("mail me at levi@example"))
        XCTAssertNil(query("@img and more"))
        let found = MentionTrigger.find(in: "go @pho" as NSString, caret: 7)
        XCTAssertEqual(found?.range, NSRange(location: 3, length: 4))
    }

    func testPicturesComeFirstThenNamesStartingWithTheQuery() {
        let folder = URL(fileURLWithPath: "/tmp/bucket")
        let files = ["notes.txt", "photo.png", "my photo.jpg"].map {
            Attachment(url: folder.appendingPathComponent($0), size: 1, added: .distantPast)
        }
        XCTAssertEqual(MentionState.matches("pho", in: files).map(\.name), ["photo.png", "my photo.jpg"])
        XCTAssertEqual(MentionState.matches("", in: files).first.map(MentionState.isImage), true)
    }
}

final class ImageDisplayTests: XCTestCase {
    func testHintsParseAndWrite() {
        XCTAssertEqual(ImageDisplay.parse("Sketch|inline").label, "Sketch")
        XCTAssertEqual(ImageDisplay.parse("Sketch|inline").display, .inline)
        XCTAssertEqual(ImageDisplay.parse("a|b|large").display, .large)
        XCTAssertEqual(ImageDisplay.parse("Sketch|300").display, .width(300))
        XCTAssertNil(ImageDisplay.parse("Sketch|whatever").display)
        XCTAssertEqual(ImageDisplay.parse("Sketch|whatever").label, "Sketch|whatever")
        XCTAssertNil(ImageDisplay.preview.hint)
        XCTAssertEqual(ImageDisplay.full.hint, "full")
    }

    func testSizesFitTheirCapAndTheText() {
        let wide = CGSize(width: 1200, height: 600)
        XCTAssertEqual(ImageDisplay.preview.size(for: wide, available: 300), CGSize(width: 160, height: 80))
        XCTAssertEqual(ImageDisplay.preview.size(for: CGSize(width: 600, height: 1200), available: 300), CGSize(width: 80, height: 160))
        XCTAssertEqual(ImageDisplay.full.size(for: wide, available: 300), CGSize(width: 300, height: 150))
        XCTAssertEqual(ImageDisplay.inline.size(for: wide, available: 300), CGSize(width: 36, height: 18))
        XCTAssertLessThanOrEqual(ImageDisplay.large.size(for: wide, available: 300).width, 300)
    }
}

@MainActor
final class ImageEmbedStylingTests: XCTestCase {
    private var bucket: URL!

    override func setUp() async throws {
        bucket = FileManager.default.temporaryDirectory.appendingPathComponent("embeds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bucket, withIntermediateDirectories: true)
        let image = NSImage(size: CGSize(width: 400, height: 200), flipped: false) { rect in
            NSColor.orange.setFill(); rect.fill(); return true
        }
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        try png.write(to: bucket.appendingPathComponent("shot.png"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: bucket)
    }

    private func styled(_ markdown: String, caret: Int? = nil) -> NSMutableAttributedString {
        let text = NSMutableAttributedString(string: markdown)
        let context = MarkdownStyler.Context(selection: caret.map { NSRange(location: $0, length: 0) }, width: 300, base: bucket)
        MarkdownStyler().style(text, in: NSRange(location: 0, length: text.length), context: context)
        return text
    }

    func testAlonePreviewsAmongWordsInline() {
        let block = styled("![shot](shot.png)\nafter")
        let image = block.attribute(.mdImage, at: 0, effectiveRange: nil) as? NoteImage
        XCTAssertEqual(image?.mode, .preview)
        XCTAssertLessThanOrEqual(image?.display.width ?? 999, ImageDisplay.previewSide)

        let inline = styled("See ![shot](shot.png) here")
        let thumb = inline.attribute(.mdInlineImage, at: 4, effectiveRange: nil) as? NoteImage
        XCTAssertEqual(thumb?.mode, .inline)
        // The "!" holds the room; the rest of the syntax takes none.
        XCTAssertNil(inline.attribute(.mdHidden, at: 4, effectiveRange: nil))
        XCTAssertNotNil(inline.attribute(.mdHidden, at: 5, effectiveRange: nil))

        XCTAssertNotNil(styled("![shot|inline](shot.png)").attribute(.mdInlineImage, at: 0, effectiveRange: nil))
        XCTAssertEqual((styled("![shot|full](shot.png)").attribute(.mdImage, at: 0, effectiveRange: nil) as? NoteImage)?.display.width, 300)
    }

    func testTypingBesideAPictureKeepsItInsideShowsTheMarkdown() {
        let markdown = "See ![shot](shot.png) here"
        XCTAssertNotNil(styled(markdown, caret: 21).attribute(.mdInlineImage, at: 4, effectiveRange: nil))
        XCTAssertNil(styled(markdown, caret: 10).attribute(.mdInlineImage, at: 4, effectiveRange: nil))
        let line = "![shot](shot.png)"
        XCTAssertNotNil(styled(line, caret: 17).attribute(.mdImage, at: 0, effectiveRange: nil))
        XCTAssertNil(styled(line, caret: 5).attribute(.mdImage, at: 0, effectiveRange: nil))
    }

    func testTheMenuRewritesTheHintAndGivesAGrownPictureItsOwnLine() {
        _ = NSApplication.shared
        let editor = MarkdownEditor()
        editor.base = bucket
        editor.load("See ![shot](shot.png) here")
        let view = editor.textView
        let markup = MarkdownStyler.imageMarkup(at: 4, in: view.string as NSString)!.range
        view.setDisplay(.large, markup: markup)
        XCTAssertEqual(view.string, "See \n![shot|large](shot.png)\n here")
        let again = MarkdownStyler.imageMarkup(at: 6, in: view.string as NSString)!.range
        view.setDisplay(.preview, markup: again)
        XCTAssertEqual(view.string, "See \n![shot](shot.png)\n here")
        view.removeImage(markup: MarkdownStyler.imageMarkup(at: 6, in: view.string as NSString)!.range)
        XCTAssertEqual(view.string, "See \n here")
    }

    func testReferencesEscapeNamesAndLinkFilesThatArentPictures() throws {
        try "x".write(to: bucket.appendingPathComponent("Plan (v2).txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(Attachments.markdown(for: bucket.appendingPathComponent("shot.png")), "![shot](shot.png)")
        XCTAssertEqual(Attachments.markdown(for: bucket.appendingPathComponent("Plan (v2).txt")), "[Plan (v2).txt](Plan%20%28v2%29.txt)")
    }
}
