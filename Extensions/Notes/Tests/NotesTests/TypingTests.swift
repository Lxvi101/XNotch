import AppKit
import XCTest
@testable import Notes

/// Typing with the caret's line tracked, as in a key note window.
@MainActor
final class TypingTests: XCTestCase {
    private func type(_ text: String, into view: NSTextView, window: NSWindow) {
        for ch in text {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil, characters: String(ch),
                                         charactersIgnoringModifiers: String(ch), isARepeat: false, keyCode: 0)!
            view.keyDown(with: event)
            // Lets the deferred caret-line update run, as the run loop would between keys.
            RunLoop.main.run(until: Date())
        }
    }

    func testTypingMidTextStaysWhereTheCaretIs() throws {
        _ = NSApplication.shared
        let editor = MarkdownEditor()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 340, height: 380), styleMask: [.titled],
                              backing: .buffered, defer: false)
        editor.scrollView.frame = window.contentView!.bounds
        window.contentView!.addSubview(editor.scrollView)
        editor.textView.assumesFocus = true
        editor.load("Hello world\n\nHello **world**")
        window.makeFirstResponder(editor.textView)
        editor.textView.setSelectedRange(NSRange(location: 11, length: 0))
        type("Hey there", into: editor.textView, window: window)
        XCTAssertEqual(editor.textView.string, "Hello worldHey there\n\nHello **world**")
        XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 20, length: 0))
        editor.textView.setSelectedRange(NSRange(location: (editor.textView.string as NSString).length - 2, length: 0))
        type("ly", into: editor.textView, window: window)
        XCTAssertEqual(editor.textView.string, "Hello worldHey there\n\nHello **worldly**")
    }

    func testDeletingAndBreakingLinesMidTextKeepTheCaret() throws {
        _ = NSApplication.shared
        let editor = MarkdownEditor()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 340, height: 380), styleMask: [.titled],
                              backing: .buffered, defer: false)
        editor.scrollView.frame = window.contentView!.bounds
        window.contentView!.addSubview(editor.scrollView)
        editor.textView.assumesFocus = true
        editor.load("# Title\nsome words here\n- [ ] task one\nend")
        window.makeFirstResponder(editor.textView)
        let view = editor.textView

        view.setSelectedRange(NSRange(location: 13, length: 0)) // after "some "
        view.deleteBackward(nil)
        RunLoop.main.run(until: Date())
        XCTAssertEqual(view.selectedRange(), NSRange(location: 12, length: 0))
        type("!", into: view, window: window)
        XCTAssertTrue(view.string.hasPrefix("# Title\nsome!words here\n"), view.string.debugDescription)

        view.insertNewline(nil)
        RunLoop.main.run(until: Date())
        type("x", into: view, window: window)
        XCTAssertTrue(view.string.hasPrefix("# Title\nsome!\nxwords here\n"))

        let task = (view.string as NSString).range(of: "task one")
        view.setSelectedRange(NSRange(location: task.location + 4, length: 0))
        type("ed", into: view, window: window)
        XCTAssertTrue(view.string.contains("- [ ] tasked one\nend"))
        XCTAssertEqual(view.selectedRange(), NSRange(location: task.location + 6, length: 0))
    }
}

@MainActor
final class EditorOptionTests: XCTestCase {
    private func makeEditor(_ text: String, options: EditorOptions) -> (MarkdownEditor, NSWindow) {
        _ = NSApplication.shared
        let editor = MarkdownEditor()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 340, height: 380), styleMask: [.titled],
                              backing: .buffered, defer: false)
        editor.scrollView.frame = window.contentView!.bounds
        window.contentView!.addSubview(editor.scrollView)
        editor.textView.assumesFocus = true
        editor.apply(options)
        editor.load(text)
        window.makeFirstResponder(editor.textView)
        return (editor, window)
    }

    func testCheckedTaskMovesBelowItsListAndBackUp() {
        var options = EditorOptions()
        options.moveCompletedTasks = true
        let (editor, _) = makeEditor("# Plan\n- [ ] one\n- [ ] two\n- [ ] three\nafter", options: options)
        let view = editor.textView
        let one = (view.string as NSString).range(of: "[ ] one")
        view.replace(NSRange(location: one.location, length: 3), with: "[x]")
        view.tidier.taskToggled(at: one.location, options: options)
        XCTAssertEqual(view.string, "# Plan\n- [ ] two\n- [ ] three\n- [x] one\nafter")
        let done = (view.string as NSString).range(of: "[x] one")
        view.replace(NSRange(location: done.location, length: 3), with: "[ ]")
        view.tidier.taskToggled(at: done.location, options: options)
        XCTAssertEqual(view.string, "# Plan\n- [ ] two\n- [ ] three\n- [ ] one\nafter")
    }

    func testClearedTaskGoesAfterItsFadeUnlessUnchecked() {
        var options = EditorOptions()
        options.clearCompletedTasks = true
        let (editor, _) = makeEditor("- [ ] keep\n- [ ] go\n- [ ] stay", options: options)
        let view = editor.textView
        let go = (view.string as NSString).range(of: "[ ] go")
        view.replace(NSRange(location: go.location, length: 3), with: "[x]")
        view.tidier.taskToggled(at: go.location, options: options)
        // Typing above it during the fade doesn't change which line goes.
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertText("Top\n", replacementRange: NSRange(location: 0, length: 0))
        RunLoop.main.run(until: Date().addingTimeInterval(1.3))
        XCTAssertEqual(view.string, "Top\n- [ ] keep\n- [ ] stay")
        view.undoManager?.undo()
        XCTAssertTrue(view.string.contains("- [x] go"))
    }

    func testGlideCaretFollowsTheSelection() {
        let (editor, _) = makeEditor("Hello **world**\nsecond line", options: EditorOptions())
        let view = editor.textView
        view.setSelectedRange(NSRange(location: 5, length: 0))
        let caret = view.subviews.first { !($0 is NSScrollView) && $0.frame.width == 2 }
        XCTAssertNotNil(caret)
        XCTAssertEqual(view.insertionPointColor, .clear)
        let first = caret!.frame
        view.setSelectedRange(NSRange(location: 20, length: 0))
        XCTAssertGreaterThan(caret!.frame.minY, first.minY)
        view.setSelectedRange(NSRange(location: 2, length: 4))
        XCTAssertTrue(caret!.isHidden)
    }

    func testSubtasksMoveWithTheirTaskAndIdenticalTasksAreToldApart() {
        var options = EditorOptions()
        options.moveCompletedTasks = true
        let (editor, _) = makeEditor("- [ ] A\n- [ ] milk\n  - [ ] b1\n- [x] milk\n- [ ] C", options: options)
        let view = editor.textView
        let a = (view.string as NSString).range(of: "[ ] A")
        view.replace(NSRange(location: a.location, length: 3), with: "[x]")
        view.tidier.taskToggled(at: a.location, options: options)
        XCTAssertEqual(view.string, "- [ ] milk\n  - [ ] b1\n- [x] milk\n- [ ] C\n- [x] A")
        // The unchecked "milk" is the one checked here, not the done one with the same text.
        view.replace(NSRange(location: 2, length: 3), with: "[x]")
        view.tidier.taskToggled(at: 2, options: options)
        XCTAssertEqual(view.string, "- [x] milk\n- [ ] C\n- [x] A\n- [x] milk\n  - [ ] b1")
    }

    func testTheCaretStaysOnItsLineWhenATaskAboveMoves() {
        var options = EditorOptions()
        options.moveCompletedTasks = true
        let (editor, _) = makeEditor("- [ ] one\n- [ ] two\n- [ ] three", options: options)
        let view = editor.textView
        let two = (view.string as NSString).range(of: "two")
        view.setSelectedRange(NSRange(location: two.location + 1, length: 0))
        view.replace(NSRange(location: 2, length: 3), with: "[x]", keepingSelection: true)
        view.tidier.taskToggled(at: 2, options: options)
        let moved = (view.string as NSString).range(of: "two")
        XCTAssertEqual(view.selectedRange(), NSRange(location: moved.location + 1, length: 0))
    }

    func testAFadeDoesNotCarryIntoTheNextNote() {
        var options = EditorOptions()
        options.clearCompletedTasks = true
        let (editor, _) = makeEditor("- [ ] go\n- [ ] keep", options: options)
        let view = editor.textView
        view.replace(NSRange(location: 2, length: 3), with: "[x]")
        view.tidier.taskToggled(at: 2, options: options)
        editor.load("- [x] go\n- [ ] keep")
        RunLoop.main.run(until: Date().addingTimeInterval(1.3))
        XCTAssertEqual(view.string, "- [x] go\n- [ ] keep")
    }
}
