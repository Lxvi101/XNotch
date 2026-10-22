import AppKit
import XCTest
@testable import Notes

@MainActor
/// The text behind the bucket keeps its place: nothing re-hosts the text view.
final class NoteWindowTests: XCTestCase {
    func testBucketRoundTripKeepsScroll() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = NoteLibrary(root: root, preferences: NotesPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        library.load()
        let text = (1...80).map { "## Line \($0)\nsome **text** here" }.joined(separator: "\n")
        let note = Note(record: NoteRecord(id: UUID(), spaceID: library.activeSpaceID, created: Date(), modified: Date(),
                                           isPinned: false, isOpen: true, frame: CGRect(x: -3000, y: 100, width: 330, height: 360)),
                        text: text)
        let controller = NoteController(note: note, library: library)
        controller.panel.setFrame(CGRect(x: -3000, y: 100, width: 382, height: 412), display: true)
        controller.panel.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let clip = controller.editor.scrollView.contentView
        clip.scroll(to: CGPoint(x: 0, y: 700))
        controller.editor.scrollView.reflectScrolledClipView(clip)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let before = clip.bounds.origin.y
        controller.toggleBucket()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let open = clip.bounds.origin.y
        controller.toggleBucket()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(open, before)
        XCTAssertEqual(clip.bounds.origin.y, before)
        controller.dismiss()
    }
}
