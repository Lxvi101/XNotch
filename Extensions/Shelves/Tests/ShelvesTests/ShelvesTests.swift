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

    @MainActor func testMergeKeepsFilesAndSkipsDuplicates() {
        let shared = file("shared.png", .image)
        var owned = file("owned.txt", .document)
        owned.isOwned = true
        let target = Shelf(record: ShelfRecord(files: [shared]))
        XCTAssertEqual(target.merge([shared, owned]), 1)
        XCTAssertEqual(target.files.map(\.path), [shared.path, owned.path])
        XCTAssertEqual(target.files.last, owned)
        XCTAssertEqual(target.merge([owned]), 0)
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

final class DraggedImageTests: XCTestCase {
    private func bitmap() -> NSBitmapImageRep {
        NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A browser's TIFF, read at the drop, lands as a PNG of the same size.
    func testTIFFBecomesPNG() throws {
        let url = try XCTUnwrap(PasteboardReader.imageFile(from: bitmap().tiffRepresentation!, into: directory()))
        let data = try Data(contentsOf: url)
        XCTAssertTrue(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        XCTAssertEqual(NSBitmapImageRep(data: data)?.pixelsWide, 4)
    }

    func testPNGIsKeptAsIs() throws {
        let png = bitmap().representation(using: .png, properties: [:])!
        let url = try XCTUnwrap(PasteboardReader.imageFile(from: png, into: directory()))
        XCTAssertEqual(try Data(contentsOf: url), png)
    }

    func testNotAnImage() throws {
        XCTAssertNil(PasteboardReader.imageFile(from: Data("hello".utf8), into: try directory()))
    }
}

final class PageDragDataTests: XCTestCase {
    /// Firefox's layout: big-endian kind, then type and value as counted UTF-16LE.
    private func pageData(_ entries: [(String, String)]) -> Data {
        var data = Data()
        func uint32(_ value: Int) { data.append(contentsOf: withUnsafeBytes(of: UInt32(value).bigEndian, Array.init)) }
        func text(_ string: String) {
            let bytes = string.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
            uint32(bytes.count)
            data.append(contentsOf: bytes)
        }
        for (type, value) in entries {
            uint32(1)
            text(type)
            text(value)
        }
        uint32(0)
        return data
    }

    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])

    /// How ChatGPT drags a generated image.
    func testChatGPTImage() throws {
        let json = #"{"filename":"generated-image-1","src":"data:image/png;base64,\#(png.base64EncodedString())"}"#
        let data = pageData([("application/x-codex-image", json)])
        XCTAssertTrue(PageDragData.hasImage(data))
        let image = try XCTUnwrap(PageDragData.image(in: data))
        XCTAssertEqual(image.data, png)
        XCTAssertEqual(image.name, "generated-image-1.png")
    }

    func testBareDataURL() throws {
        let data = pageData([("text/plain", "hi"), ("text/x-image", "data:image/jpeg;base64,\(png.base64EncodedString())")])
        let image = try XCTUnwrap(PageDragData.image(in: data))
        XCTAssertEqual(image.name, "Image.jpeg")
    }

    func testNoImage() {
        let data = pageData([("application/x-moz-tabbrowser-tab", "tab"), ("text/uri-list", "https://example.com")])
        XCTAssertFalse(PageDragData.hasImage(data))
        XCTAssertNil(PageDragData.image(in: data))
        XCTAssertTrue(PageDragData.entries(in: data).map(\.type) == ["application/x-moz-tabbrowser-tab", "text/uri-list"])
    }

    func testTruncatedDataStops() {
        let data = pageData([("a", "b")]).dropLast(6)
        XCTAssertTrue(PageDragData.entries(in: Data(data)).isEmpty)
    }
}
