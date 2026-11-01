import AppKit
import XCTest
@testable import Notes

@MainActor
final class CodeCopyTests: XCTestCase {
    private func block(in text: String) -> NSRange {
        MarkdownStyler.codeBlocks(in: text as NSString)[0]
    }

    func testBlockCopiesItsCodeWithoutFences() {
        let text = "before\n```swift\nlet a = 1\n\nlet b = 2\n```\nafter"
        XCTAssertEqual(MarkdownStyler.code(of: block(in: text), in: text as NSString), "let a = 1\n\nlet b = 2")
    }

    func testBlockAtTheEndOfTheNoteWithNoBreakAfterItsFence() {
        let text = "```\ncode\n```"
        XCTAssertEqual(MarkdownStyler.code(of: block(in: text), in: text as NSString), "code")
    }

    func testBlockStillOpenCopiesToTheEndOfTheNote() {
        let text = "```js\none\ntwo"
        XCTAssertEqual(MarkdownStyler.code(of: block(in: text), in: text as NSString), "one\ntwo")
    }

    func testEmptyBlockHasNothingToCopy() {
        for text in ["```\n```\n", "```\n", "```"] {
            XCTAssertEqual(MarkdownStyler.code(of: block(in: text), in: text as NSString), "", text)
        }
    }

    func testSpanCopiesWithoutItsBackticks() {
        let text = "run `make test` or ``make all``" as NSString
        XCTAssertEqual(MarkdownStyler.code(ofSpan: text.range(of: "`make test`"), in: text), "make test")
        XCTAssertEqual(MarkdownStyler.code(ofSpan: text.range(of: "``make all``"), in: text), "make all")
    }

    private func makeEditor(_ text: String) -> (MarkdownEditor, NSWindow) {
        _ = NSApplication.shared
        let editor = MarkdownEditor()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 340, height: 380), styleMask: [.titled],
                              backing: .buffered, defer: false)
        editor.scrollView.frame = window.contentView!.bounds
        window.contentView!.addSubview(editor.scrollView)
        editor.textView.assumesFocus = true
        editor.load(text)
        window.makeFirstResponder(editor.textView)
        return (editor, window)
    }

    /// The middle of a run of text, in container coordinates.
    private func center(of range: NSRange, in editor: MarkdownEditor) -> CGPoint {
        let layout = editor.textView.markdownLayout!
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: editor.textView.textContainer!)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    func testInlineCodeIsFoundWhetherOrNotItsBackticksShow() {
        let text = "run `make test` now\n\nlast line"
        let (editor, window) = makeEditor(text)
        withExtendedLifetime(window) {
            let view = editor.textView
            let layout = view.markdownLayout!
            let word = (text as NSString).range(of: "make")
            let span = (text as NSString).range(of: "`make test`")

            view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            XCTAssertEqual(layout.codeSpan(at: center(of: word, in: editor)), span)
            XCTAssertNil(layout.codeSpan(at: center(of: (text as NSString).range(of: "last"), in: editor)))

            view.setSelectedRange(NSRange(location: word.location, length: 0))
            XCTAssertEqual(layout.codeSpan(at: center(of: word, in: editor)), span)
        }
    }

    func testInlineCodeAnswersThePointerOnlyWithCommandHeld() {
        let text = "run `make test` now\n\nlast line"
        let (editor, window) = makeEditor(text)
        withExtendedLifetime(window) {
            let view = editor.textView
            view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            let word = center(of: (text as NSString).range(of: "make"), in: editor)
            XCTAssertFalse(view.codeCopy.pointerMoved(to: word))
            view.codeCopy.isCommandHeld = true
            XCTAssertTrue(view.codeCopy.pointerMoved(to: word))
            view.codeCopy.isCommandHeld = false
            XCTAssertFalse(view.codeCopy.pointerMoved(to: word))
        }
    }

    func testCardIsFoundAcrossItsWidthAndNotBelowIt() {
        let text = "intro\n\n```\ncode\n```\n\noutro"
        let (editor, window) = makeEditor(text)
        withExtendedLifetime(window) {
            let view = editor.textView
            let layout = view.markdownLayout!
            view.setSelectedRange(NSRange(location: 0, length: 0))
            let block = block(in: text)
            let code = (text as NSString).range(of: "code")
            let card = layout.cardRect(for: block)!
            XCTAssertEqual(layout.codeBlock(at: center(of: code, in: editor)), block)
            XCTAssertEqual(layout.codeBlock(at: CGPoint(x: card.maxX - 4, y: card.minY + 4)), block)
            XCTAssertNil(layout.codeBlock(at: center(of: (text as NSString).range(of: "outro"), in: editor)))
        }
    }

    func testButtonFollowsTheBlockAndLeavesWithThePointer() {
        let text = "```\ncode\n```\n\nempty:\n\n```\n```\n\nplain"
        let (editor, window) = makeEditor(text)
        withExtendedLifetime(window) {
            let view = editor.textView
            view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            let layout = view.markdownLayout!
            let blocks = MarkdownStyler.codeBlocks(in: text as NSString)
            let card = layout.cardRect(for: blocks[0])!

            // The corner of a card with code in it is the button.
            XCTAssertTrue(view.codeCopy.pointerMoved(to: CGPoint(x: card.maxX - 14, y: card.minY + 12)))
            // Elsewhere on the card isn't, and neither is any of an empty one.
            XCTAssertFalse(view.codeCopy.pointerMoved(to: center(of: (text as NSString).range(of: "code"), in: editor)))
            let empty = layout.cardRect(for: blocks[1])!
            XCTAssertFalse(view.codeCopy.pointerMoved(to: CGPoint(x: empty.maxX - 14, y: empty.minY + 12)))
            XCTAssertFalse(view.codeCopy.pointerMoved(to: nil))
        }
    }

    // MARK: In a note window

    private lazy var pasteboard = NSPasteboard.withUniqueName()

    /// A real note, off screen, on a library of its own, copying to a private
    /// pasteboard. Events go in through the panel, as the window server's do.
    private func makeNote(_ text: String, run: (NoteController) -> Void) throws {
        _ = NSApplication.shared
        notePasteboard = pasteboard
        defer {
            notePasteboard = .general
            pasteboard.releaseGlobally()
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("code-copy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = NoteLibrary(root: root, preferences: NotesPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        library.load()
        let frame = CGRect(x: -3000, y: 100, width: 330, height: 360)
        let note = Note(record: NoteRecord(id: UUID(), spaceID: library.activeSpaceID, created: Date(), modified: Date(),
                                           isPinned: false, isOpen: true, frame: frame), text: text)
        let controller = NoteController(note: note, library: library)
        controller.panel.setFrame(NoteGeometry.windowFrame(forNote: frame), display: true)
        controller.panel.orderFrontRegardless()
        controller.panel.makeFirstResponder(controller.editor.textView)
        controller.editor.textView.assumesFocus = true
        controller.editor.textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        run(controller)
        controller.dismiss()
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in controller: NoteController,
                       modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        let view = controller.editor.textView
        let origin = view.textContainerOrigin
        return NSEvent.mouseEvent(with: type, location: view.convert(CGPoint(x: point.x + origin.x, y: point.y + origin.y), to: nil),
                                  modifierFlags: modifiers, timestamp: 0, windowNumber: controller.panel.windowNumber, context: nil,
                                  eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func click(at point: CGPoint, in controller: NoteController, modifiers: NSEvent.ModifierFlags = []) {
        controller.panel.postEvent(mouse(.leftMouseUp, at: point, in: controller, modifiers: modifiers), atStart: false)
        controller.panel.sendEvent(mouse(.leftMouseDown, at: point, in: controller, modifiers: modifiers))
        // A press handled on the way down leaves its release for the window, which isn't running here.
        while NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) != nil {}
    }

    func testCommandClickingInlineCodeCopiesItAndLeavesTheCaret() throws {
        let text = "run `make test` now\n\nlast line"
        try makeNote(text) { controller in
            let view = controller.editor.textView
            click(at: center(of: (text as NSString).range(of: "make"), in: controller.editor), in: controller, modifiers: .command)
            XCTAssertEqual(pasteboard.string(forType: .string), "make test")
            XCTAssertEqual(view.selectedRange(), NSRange(location: (text as NSString).length, length: 0))
        }
    }

    func testCommandClickCopiesInlineCodeWithItsBackticksShowing() throws {
        let text = "run `make test` now"
        try makeNote(text) { controller in
            let view = controller.editor.textView
            let word = (text as NSString).range(of: "make")
            view.setSelectedRange(NSRange(location: word.location, length: 0))
            click(at: center(of: word, in: controller.editor), in: controller, modifiers: .command)
            XCTAssertEqual(pasteboard.string(forType: .string), "make test")
        }
    }

    func testClickingInlineCodePlacesTheCaretInIt() throws {
        let text = "run `make test` now\n\nlast line"
        try makeNote(text) { controller in
            let word = (text as NSString).range(of: "make test")
            click(at: center(of: word, in: controller.editor), in: controller)
            XCTAssertNil(pasteboard.string(forType: .string))
            XCTAssertTrue(NSLocationInRange(controller.editor.textView.selectedRange().location, word))
        }
    }

    func testCommandClickOpensALinkAndAClickEditsIt() throws {
        let text = "see [the docs](https://example.com) and https://apple.com here\n\nlast line"
        try makeNote(text) { controller in
            let view = controller.editor.textView
            var opened: [String] = []
            view.openLink = { opened.append($0) }

            let label = (text as NSString).range(of: "docs")
            click(at: center(of: label, in: controller.editor), in: controller)
            XCTAssertEqual(opened, [])
            XCTAssertTrue(NSLocationInRange(view.selectedRange().location, (text as NSString).range(of: "the docs")))

            // With its syntax showing, from that click, ⌘ still opens it.
            RunLoop.main.run(until: Date())
            click(at: center(of: label, in: controller.editor), in: controller, modifiers: .command)
            XCTAssertEqual(opened, ["https://example.com"])

            click(at: center(of: (text as NSString).range(of: "apple"), in: controller.editor), in: controller, modifiers: .command)
            XCTAssertEqual(opened, ["https://example.com", "https://apple.com"])
        }
    }

    func testCopyButtonCopiesTheCodeAndLeavesTheCaret() throws {
        let text = "intro\n\n```swift\nlet a = 1\nlet b = 2\n```\n\noutro"
        try makeNote(text) { controller in
            let view = controller.editor.textView
            let card = view.markdownLayout!.cardRect(for: block(in: text))!
            let corner = CGPoint(x: card.maxX - 14, y: card.minY + 12)
            view.mouseMoved(with: mouse(.mouseMoved, at: corner, in: controller))
            click(at: corner, in: controller)
            XCTAssertEqual(pasteboard.string(forType: .string), "let a = 1\nlet b = 2")
            XCTAssertEqual(view.selectedRange(), NSRange(location: (text as NSString).length, length: 0))
        }
    }

    func testPressLeavingTheButtonDoesNotCopy() throws {
        let text = "```\ncode\n```\n\nend"
        try makeNote(text) { controller in
            let view = controller.editor.textView
            let card = view.markdownLayout!.cardRect(for: block(in: text))!
            let corner = CGPoint(x: card.maxX - 14, y: card.minY + 12)
            view.mouseMoved(with: mouse(.mouseMoved, at: corner, in: controller))
            controller.panel.postEvent(mouse(.leftMouseUp, at: CGPoint(x: corner.x - 60, y: corner.y), in: controller), atStart: false)
            controller.panel.sendEvent(mouse(.leftMouseDown, at: corner, in: controller))
            XCTAssertNil(pasteboard.string(forType: .string))
        }
    }

    private func shiftCommandC(in controller: NoteController) {
        controller.panel.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
                                                    windowNumber: controller.panel.windowNumber, context: nil, characters: "C",
                                                    charactersIgnoringModifiers: "C", isARepeat: false, keyCode: 8)!)
    }

    func testShiftCommandCCopiesTheWholeNoteAsMarkdown() throws {
        let text = "# Title\n\n- [ ] a task with `code`\n\n```\nblock\n```\n"
        try makeNote(text) { controller in
            controller.editor.textView.setSelectedRange(NSRange(location: 2, length: 3))
            shiftCommandC(in: controller)
            XCTAssertEqual(pasteboard.string(forType: .string), text)
            XCTAssertEqual(controller.state.flashLabel, "Markdown copied")
        }
    }

    func testShiftCommandCOnAnEmptyNoteKeepsTheClipboard() throws {
        try makeNote("") { controller in
            pasteboard.clearContents()
            pasteboard.setString("kept", forType: .string)
            shiftCommandC(in: controller)
            XCTAssertEqual(pasteboard.string(forType: .string), "kept")
            XCTAssertNil(controller.state.flashLabel)
        }
    }
}
