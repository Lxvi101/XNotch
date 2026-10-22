import AppKit
import XCTest
@testable import Notes

final class MarkdownStylerTests: XCTestCase {
    private func styled(_ markdown: String, caret: Int? = nil, base: URL? = nil) -> NSMutableAttributedString {
        let text = NSMutableAttributedString(string: markdown)
        let context = MarkdownStyler.Context(selection: caret.map { NSRange(location: $0, length: 0) }, width: 300, base: base)
        MarkdownStyler().style(text, in: NSRange(location: 0, length: text.length), context: context)
        return text
    }

    /// The characters carrying `key`, as a string.
    private func characters(with key: NSAttributedString.Key, in text: NSAttributedString) -> String {
        var result = ""
        text.enumerateAttribute(key, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if value != nil { result += (text.string as NSString).substring(with: range) }
        }
        return result
    }

    func testHeadingHidesItsHashesUntilTheCaretIsOnIt() {
        XCTAssertEqual(characters(with: .mdHidden, in: styled("# Launch checklist\nThings")), "# ")
        XCTAssertEqual(characters(with: .mdHidden, in: styled("# Launch checklist\nThings", caret: 5)), "")
        let font = styled("# Launch").attribute(.font, at: 3, effectiveRange: nil) as? NSFont
        XCTAssertGreaterThan(font?.pointSize ?? 0, 20)
    }

    func testEmphasisRevealsOnlyWhereTheCaretTouches() {
        let line = "Before **Friday** and *soon*."
        XCTAssertEqual(characters(with: .mdHidden, in: styled(line)), "*****" + "*")
        // Inside the bold: its stars show, the italic's stay hidden.
        XCTAssertEqual(characters(with: .mdHidden, in: styled(line, caret: 10)), "**")
        // Right after the bold, edges count as touching.
        XCTAssertEqual(characters(with: .mdHidden, in: styled(line, caret: 17)), "**")
        let font = styled(line).attribute(.font, at: 9, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false)
    }

    func testTaskBecomesACheckbox() {
        let text = styled("- [ ] Write copy\n- [x] Ship it", caret: 3)
        XCTAssertEqual(characters(with: .mdHidden, in: text), "- - ")
        var range = NSRange()
        let open = text.attribute(.mdCheckbox, at: 2, longestEffectiveRange: &range, in: NSRange(location: 0, length: text.length)) as? Bool
        XCTAssertEqual(open, false)
        XCTAssertEqual(range, NSRange(location: 2, length: 3))
        XCTAssertEqual(text.attribute(.mdCheckbox, at: 19, effectiveRange: nil) as? Bool, true)
    }

    func testCodeSpanKeepsMarkdownInsideLiteral() {
        let text = styled("Ship with `**not bold**` now")
        XCTAssertEqual(characters(with: .mdHidden, in: text), "``")
        XCTAssertEqual(characters(with: .mdCodeSpan, in: text), "`**not bold**`")
    }

    func testLinkIsClickableOnlyWhileItsSyntaxIsHidden() {
        let line = "See [the docs](https://example.com) and https://apple.com."
        let text = styled(line)
        XCTAssertEqual(characters(with: .mdHidden, in: text), "[](https://example.com)")
        XCTAssertEqual(text.attribute(.mdLink, at: 6, effectiveRange: nil) as? String, "https://example.com")
        let bare = (line as NSString).range(of: "https://apple.com")
        XCTAssertEqual(text.attribute(.mdLink, at: bare.location, effectiveRange: nil) as? String, "https://apple.com")
        let editing = styled(line, caret: 8)
        XCTAssertNil(editing.attribute(.mdLink, at: 6, effectiveRange: nil))
        XCTAssertEqual(characters(with: .mdHidden, in: editing), "")
    }

    func testCodeBlockCollapsesItsFencesUntilTheCaretIsInside() {
        let markdown = "```swift\nlet x = 1\n```\n# heading"
        let text = styled(markdown)
        XCTAssertEqual(characters(with: .mdHidden, in: text), "```swift\n```\n# ")
        XCTAssertEqual(text.attribute(.mdCodeLanguage, at: 0, effectiveRange: nil) as? String, "swift")
        XCTAssertNotNil(text.attribute(.mdCodeBlock, at: 10, effectiveRange: nil))
        // The caret in any line of the block shows both fences.
        XCTAssertEqual(characters(with: .mdHidden, in: styled(markdown, caret: 12)), "# ")
        XCTAssertEqual(MarkdownStyler.codeBlocks(in: markdown as NSString), [NSRange(location: 0, length: 23)])
    }

    func testRestylingOneParagraphKnowsItIsInsideAFence() {
        let text = NSMutableAttributedString(string: "```\n**x**\n```")
        MarkdownStyler().style(text, in: NSRange(location: 5, length: 1))
        XCTAssertNotNil(text.attribute(.mdCodeBlock, at: 5, effectiveRange: nil))
        XCTAssertNil(text.attribute(.mdHidden, at: 4, effectiveRange: nil))
    }

    func testRuleAndQuote() {
        let text = styled("---\n> quoted")
        XCTAssertNotNil(text.attribute(.mdRule, at: 0, effectiveRange: nil))
        XCTAssertNotNil(text.attribute(.mdQuote, at: 6, effectiveRange: nil))
        XCTAssertNil(styled("---\n> quoted", caret: 1).attribute(.mdRule, at: 0, effectiveRange: nil))
    }

    func testSnakeCaseIsNotItalic() {
        XCTAssertEqual(characters(with: .mdHidden, in: styled("call some_function_name now")), "")
    }

    func testImageFromTheBucketShowsInPlaceOfItsLine() throws {
        let bucket = FileManager.default.temporaryDirectory.appendingPathComponent("bucket-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bucket, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bucket) }
        let image = NSImage(size: CGSize(width: 40, height: 20), flipped: false) { rect in
            NSColor.orange.setFill(); rect.fill(); return true
        }
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        try png.write(to: bucket.appendingPathComponent("Sketch 1.png"))

        let markdown = "Look:\n![Sketch](Sketch%201.png)\nafter"
        let text = styled(markdown, base: bucket)
        XCTAssertTrue(text.attribute(.mdImage, at: 7, effectiveRange: nil) is NoteImage)
        XCTAssertEqual(characters(with: .mdHidden, in: text), "![Sketch](Sketch%201.png)\n")
        // With the caret on it, it's markdown again.
        XCTAssertNil(styled(markdown, caret: 8, base: bucket).attribute(.mdImage, at: 7, effectiveRange: nil))
    }
}

final class MarkdownTextTests: XCTestCase {
    func testTitleSkipsMarkdownAndBlankLines() {
        XCTAssertEqual(MarkdownText.title(of: "\n\n# Launch **checklist**\nbody"), "Launch checklist")
        XCTAssertEqual(MarkdownText.title(of: "- [ ] [Buy milk](https://x.y)"), "Buy milk")
        XCTAssertEqual(MarkdownText.title(of: "   \n"), "")
    }

    func testPreviewIsWhatFollowsTheTitle() {
        XCTAssertEqual(MarkdownText.preview(of: "# Title\nThings to close\n- [ ] Pricing"), "Things to close Pricing")
    }
}

@MainActor
final class NoteLibraryTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("NotesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testFirstLoadMakesASpace() {
        let library = NoteLibrary(root: root, preferences: NotesPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        library.load()
        XCTAssertEqual(library.spaces.count, 1)
        XCTAssertEqual(library.activeSpaceID, library.spaces[0].id)
    }

    func testNotesSurviveAReload() throws {
        let preferences = NotesPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let library = NoteLibrary(root: root, preferences: preferences)
        library.load()
        let work = library.addSpace(named: "Work")
        let record = NoteRecord(id: UUID(), spaceID: work.id, created: Date(), modified: Date(), isPinned: true,
                                isOpen: false, frame: CGRect(x: 10, y: 20, width: 300, height: 320))
        try "# Plan\nbody".write(to: library.notesFolder.appendingPathComponent("\(record.id.uuidString).md"),
                                  atomically: true, encoding: .utf8)
        // Written the way the library writes its index, then read back cold.
        let index = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("library.json"))) as! [String: Any]
        var notes = index["notes"] as! [[String: Any]]
        notes.append(try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any])
        var updated = index
        updated["notes"] = notes
        try JSONSerialization.data(withJSONObject: updated).write(to: root.appendingPathComponent("library.json"))

        let reloaded = NoteLibrary(root: root, preferences: preferences)
        reloaded.load()
        XCTAssertEqual(reloaded.spaces.map(\.name), ["Personal", "Work"])
        let note = try XCTUnwrap(reloaded.notes.first)
        XCTAssertEqual(note.title, "Plan")
        XCTAssertEqual(note.spaceID, work.id)
        XCTAssertTrue(note.isPinned)
        XCTAssertEqual(note.frame, record.frame)
    }

    func testUpdateOnlyTouchesWhatChanged() {
        let note = Note(record: NoteRecord(id: UUID(), spaceID: UUID(), created: Date(), modified: .distantPast,
                                           isPinned: false, isOpen: true, frame: nil), text: "# A")
        note.update(text: "# A\nmore")
        XCTAssertEqual(note.title, "A")
        XCTAssertEqual(note.characterCount, 8)
        XCTAssertGreaterThan(note.modified, .distantPast)
    }

    func testUnreadableIndexIsKeptAndNotesComeBack() throws {
        let preferences = NotesPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let notes = root.appendingPathComponent("Notes")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let id = UUID()
        try "# Kept\nbody".write(to: notes.appendingPathComponent("\(id.uuidString).md"), atomically: true, encoding: .utf8)
        try Data("{ not json".utf8).write(to: root.appendingPathComponent("library.json"))

        let library = NoteLibrary(root: root, preferences: preferences)
        library.load()
        XCTAssertEqual(library.notes.map(\.id), [id])
        XCTAssertEqual(library.notes.first?.title, "Kept")
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("library-unreadable-") })
    }

    func testBlankNoteGoesUnlessItsBucketHoldsFiles() throws {
        let preferences = NotesPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let first = NoteLibrary(root: root, preferences: preferences)
        first.load()
        let space = first.spaces[0]
        let blank = UUID(), withFile = UUID()
        let notes = root.appendingPathComponent("Notes")
        for id in [blank, withFile] {
            try "".write(to: notes.appendingPathComponent("\(id.uuidString).md"), atomically: true, encoding: .utf8)
        }
        let bucket = root.appendingPathComponent("Buckets/\(withFile.uuidString)")
        try FileManager.default.createDirectory(at: bucket, withIntermediateDirectories: true)
        try "x".write(to: bucket.appendingPathComponent("added in Finder.txt"), atomically: true, encoding: .utf8)
        let records = [blank, withFile].map {
            NoteRecord(id: $0, spaceID: space.id, created: Date(), modified: Date(), isPinned: false, isOpen: false, frame: nil)
        }
        var index = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("library.json"))) as! [String: Any]
        index["notes"] = try records.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
        try JSONSerialization.data(withJSONObject: index).write(to: root.appendingPathComponent("library.json"))

        let library = NoteLibrary(root: root, preferences: preferences)
        library.load()
        XCTAssertEqual(library.notes.map(\.id), [withFile])
    }
}

final class KeyShortcutTests: XCTestCase {
    func testShortcutsNeedACommandKeyAndReadLikeMenus() {
        XCTAssertTrue(KeyShortcut.toggleDefault.display.hasPrefix("⌃⌥"))
        let space = KeyShortcut(keyCode: 49, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue)
        XCTAssertEqual(space.display, "⇧⌘Space")
        let plain = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0, windowNumber: 0,
                                     context: nil, characters: "A", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        XCTAssertNil(KeyShortcut(event: plain))
    }
}

final class CodeHighlighterTests: XCTestCase {
    private func kinds(_ code: String, _ language: String) -> [String: CodeHighlighter.Kind] {
        let text = code as NSString
        var result: [String: CodeHighlighter.Kind] = [:]
        for token in CodeHighlighter.tokens(in: text, range: NSRange(location: 0, length: text.length),
                                            language: CodeHighlighter.language(named: language)) {
            result[text.substring(with: token.range)] = token.kind
        }
        return result
    }

    func testJavaScript() {
        let k = kinds("const answer = await fetch(`x ${y}\n`) // go\nconsole.log(42, true, \"hi\")", "js")
        XCTAssertEqual(k["const"], .keyword)
        XCTAssertEqual(k["await"], .keyword)
        XCTAssertEqual(k["fetch"], .function)
        XCTAssertEqual(k["`x ${y}\n`"], .string)
        XCTAssertEqual(k["// go"], .comment)
        XCTAssertEqual(k["log"], .function)
        XCTAssertEqual(k["42"], .number)
        XCTAssertEqual(k["true"], .constant)
        XCTAssertEqual(k["\"hi\""], .string)
        XCTAssertNil(k["console"])
    }

    func testSwiftAndPython() {
        let swift = kinds("@MainActor struct Note { let id: UUID; /* note */ }", "swift")
        XCTAssertEqual(swift["@MainActor"], .attribute)
        XCTAssertEqual(swift["struct"], .keyword)
        XCTAssertEqual(swift["UUID"], .type)
        XCTAssertEqual(swift["/* note */"], .comment)
        let python = kinds("def go(x):\n    return \"\"\"a\nb\"\"\" # done", "python")
        XCTAssertEqual(python["def"], .keyword)
        XCTAssertEqual(python["go"], .function)
        XCTAssertEqual(python["\"\"\"a\nb\"\"\""], .string)
        XCTAssertEqual(python["# done"], .comment)
    }

    func testJSONKeysAndCodeBlockStyling() {
        let json = kinds("{\"name\": \"Mote\", \"count\": 3}", "json")
        XCTAssertEqual(json["\"name\""], .property)
        XCTAssertEqual(json["\"Mote\""], .string)
        XCTAssertEqual(json["3"], .number)

        let text = NSMutableAttributedString(string: "```js\nconsole.log(\"hi\")\n```")
        MarkdownStyler().style(text, in: NSRange(location: 0, length: text.length))
        let call = (text.string as NSString).range(of: "log")
        XCTAssertEqual(text.attribute(.foregroundColor, at: call.location, effectiveRange: nil) as? NSColor,
                       CodeHighlighter.color(for: .function))
    }
}

final class TaskTextTests: XCTestCase {
    private let note = "# Plan\n- [x] done\n  - [ ] sub of done\n- [ ] open\n- [x] also done\n\nafter"

    func testClearingCompletedTakesNestedLinesWithIt() {
        XCTAssertEqual(TaskText.clearingCompleted(note), "# Plan\n- [ ] open\n\nafter")
    }

    func testSortingKeepsOrderWithinOpenAndDone() {
        XCTAssertEqual(TaskText.sortingCompleted(note),
                       "# Plan\n- [ ] open\n- [x] done\n  - [ ] sub of done\n- [x] also done\n\nafter")
    }

    func testUncheckAllAndPlainText() {
        XCTAssertEqual(TaskText.uncheckingAll("- [x] a\n  * [X] b\n[x] not a task"), "- [ ] a\n  * [ ] b\n[x] not a task")
        XCTAssertEqual(TaskText.plain("# Title\n**bold** and [link](x)\n```\nlet **x**\n```"), "Title\nbold and link\nlet **x**")
    }
}

@MainActor
final class CommandBarTests: XCTestCase {
    func testGreaterThanFiltersActionsByEveryWordTitleMatchesFirst() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CommandBar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = NoteLibrary(root: root, preferences: NotesPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        library.load()
        let model = SwitcherModel(library: library)
        let make = { (id: String, title: String, section: String) in
            NoteCommand(id: id, title: title, symbol: "circle", section: section) {}
        }
        model.commandSource = {
            [make("copy", "Copy as Markdown", "Note"), make("clear", "Clear Completed Tasks", "Tasks"),
             make("trash", "Move Note to Trash", "Note"), make("move", "Move to “Work”", "Spaces")]
        }
        let note = Note(record: NoteRecord(id: UUID(), spaceID: library.activeSpaceID, created: Date(), modified: Date(),
                                           isPinned: false, isOpen: true, frame: nil), text: "x")
        model.prepare(current: note)
        XCTAssertFalse(model.isCommandMode)
        model.query = "> mo"
        XCTAssertTrue(model.isCommandMode)
        XCTAssertEqual(model.commands.map(\.id), ["trash", "move"])
        model.query = "> tasks"
        XCTAssertEqual(model.commands.map(\.id), ["clear"])
        model.query = ">"
        XCTAssertEqual(model.commands.count, 4)
    }
}
