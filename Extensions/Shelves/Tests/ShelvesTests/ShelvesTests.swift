import XCTest
@testable import Shelves

final class ShakeRecognizerTests: XCTestCase {
    private let tuning = ShakeRecognizer.Tuning(minimumStroke: 30, reversals: 3, window: 0.8)

    /// Feeds strokes between alternating x positions, `step` seconds per point.
    private func feed(_ xs: [CGFloat], step: TimeInterval = 0.02, into recognizer: inout ShakeRecognizer) -> Bool {
        var fired = false
        var time: TimeInterval = 100
        var last = xs[0]
        for target in xs {
            let steps = 6
            for i in 1...steps {
                let x = last + (target - last) * CGFloat(i) / CGFloat(steps)
                time += step
                if recognizer.add(CGPoint(x: x, y: 300), at: time) { fired = true }
            }
            last = target
        }
        return fired
    }

    func testQuickShakeFires() {
        var recognizer = ShakeRecognizer(tuning: tuning)
        XCTAssertTrue(feed([100, 160, 100, 160, 100], into: &recognizer))
    }

    func testStraightDragDoesNot() {
        var recognizer = ShakeRecognizer(tuning: tuning)
        XCTAssertFalse(feed([100, 300, 500, 700], into: &recognizer))
    }

    func testJitterBelowStrokeDoesNot() {
        var recognizer = ShakeRecognizer(tuning: tuning)
        XCTAssertFalse(feed([100, 115, 100, 115, 100, 115, 100], into: &recognizer))
    }

    func testSlowShakeDoesNot() {
        var recognizer = ShakeRecognizer(tuning: tuning)
        // Each stroke takes 0.6 s, so three turns can't fit the 0.8 s window.
        XCTAssertFalse(feed([100, 160, 100, 160, 100], step: 0.1, into: &recognizer))
    }

    func testVerticalWiggleDoesNot() {
        var recognizer = ShakeRecognizer(tuning: tuning)
        var fired = false
        for (i, y) in [100, 200, 100, 200, 100, 200].enumerated() {
            if recognizer.add(CGPoint(x: 300, y: CGFloat(y)), at: 100 + Double(i) * 0.05) { fired = true }
        }
        XCTAssertFalse(fired)
    }

    func testStartsOverAfterFiring() {
        var recognizer = ShakeRecognizer(tuning: tuning)
        XCTAssertTrue(feed([100, 160, 100, 160, 100], into: &recognizer))
        XCTAssertFalse(feed([100, 160], into: &recognizer))
    }
}

final class ShelfSummaryTests: XCTestCase {
    private func file(_ name: String, _ kind: FileKind, size: Int64? = 1000) -> ShelfFile {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        var file = ShelfFile(url: url)!
        file.kind = kind
        file.size = size
        return file
    }

    func testNames() {
        XCTAssertEqual(ShelfSummary.name(for: []), "Empty Shelf")
        XCTAssertEqual(ShelfSummary.name(for: [file("a.png", .image)]), "a.png")
        XCTAssertEqual(ShelfSummary.name(for: [file("a.png", .image), file("b.png", .image)]), "2 Images")
        XCTAssertEqual(ShelfSummary.name(for: [file("a.png", .image), file("b.txt", .document)]), "2 Items")
    }

    func testCount() {
        XCTAssertEqual(ShelfSummary.count(for: [file("a.txt", .document)]), "1 Document")
        XCTAssertEqual(ShelfSummary.count(for: [file("a.txt", .document), file("f", .folder)]), "2 Items")
    }

    func testSizeSkipsFolders() {
        XCTAssertNil(ShelfSummary.size(for: [file("f", .folder, size: nil)]))
        XCTAssertNotNil(ShelfSummary.size(for: [file("a", .other, size: 2048), file("f", .folder, size: nil)]))
    }

    @MainActor func testTextFileName() {
        XCTAssertEqual(PasteboardReaderNames.name("  hello there: a/b  "), "hello there- a-b.txt")
        XCTAssertEqual(PasteboardReaderNames.name("   "), "Text.txt")
    }
}

final class ShelfGeometryTests: XCTestCase {
    func testFourActionsMakeTwoByTwo() {
        let frames = ShelfGeometry.actionFrames(count: 4, in: ShelfGeometry.compact)
        XCTAssertEqual(frames.count, 4)
        XCTAssertEqual(frames[0].minY, frames[1].minY)
        XCTAssertEqual(frames[0].minX, frames[2].minX)
        XCTAssertGreaterThan(frames[2].minY, frames[0].maxY)
        // Tiles stay inside the shelf.
        let bounds = CGRect(origin: .zero, size: ShelfGeometry.compact)
        XCTAssertTrue(frames.allSatisfy { bounds.contains($0) })
    }

    func testBoltIsInBottomRightCorner() {
        let bolt = ShelfGeometry.boltFrame(in: ShelfGeometry.compact)
        XCTAssertEqual(bolt.maxX, ShelfGeometry.compact.width - ShelfGeometry.boltInset)
        XCTAssertEqual(bolt.maxY, ShelfGeometry.compact.height - ShelfGeometry.boltInset)
    }
}

/// `PasteboardReader` is main-actor bound; its naming is pure.
private enum PasteboardReaderNames {
    @MainActor static func name(_ text: String) -> String { PasteboardReader.textFileName(for: text) }
}
