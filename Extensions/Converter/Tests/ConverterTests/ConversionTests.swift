import AppKit
import XCTest
@testable import Converter

/// Real conversions, end to end through the runner, on files made here.
/// Media tests run when ffmpeg is on the Mac.
@MainActor
final class ConversionTests: XCTestCase {
    private var folder: URL!
    private var runner: ConversionRunner!
    private var ffmpeg: FFmpeg!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("converter-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "converter-tests-\(UUID().uuidString)")!
        let preferences = ConverterPreferences(defaults: defaults)
        ffmpeg = FFmpeg(directory: folder.appendingPathComponent("support"), customPath: nil)
        runner = ConversionRunner(ffmpeg: ffmpeg, preferences: preferences)
        runner.directory = { $0.deletingLastPathComponent() }
    }

    override func tearDown() async throws {
        if ProcessInfo.processInfo.environment["KEEP_OUTPUT"] == nil { try? FileManager.default.removeItem(at: folder) }
    }

    private func run(_ operation: Action, _ kind: FileKind, _ source: URL, file: StaticString = #filePath, line: UInt = #line) async -> ConversionJob {
        let job = ConversionJob(operation: operation, kind: kind, sources: [source])
        let done = expectation(description: "\(operation)")
        runner.onFinish = { finished in if finished === job { done.fulfill() } }
        runner.start(job)
        await fulfillment(of: [done], timeout: 120)
        if case .failed(let message) = job.phase { XCTFail("\(operation) on \(source.lastPathComponent): \(message)", file: file, line: line) }
        for output in job.outputs {
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.path), "\(output.lastPathComponent) missing", file: file, line: line)
        }
        return job
    }

    private func makePNG(alpha: Bool) throws -> URL {
        let size = 64
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if !alpha { context.setFillColor(.white); context.fill(CGRect(x: 0, y: 0, width: size, height: size)) }
        context.setFillColor(CGColor(red: 1, green: 0.4, blue: 0.1, alpha: 1))
        context.fillEllipse(in: CGRect(x: 8, y: 8, width: 48, height: 48))
        let url = folder.appendingPathComponent(alpha ? "Dot.png" : "Square.png")
        try ImageEngine.write(context.makeImage()!, type: .png, to: url, quality: 1)
        return url
    }

    private func makeDocument() throws -> URL {
        let url = folder.appendingPathComponent("Notes.rtf")
        let text = NSAttributedString(string: String(repeating: "Hello from the converter wheel. ", count: 400),
                                      attributes: [.font: NSFont.systemFont(ofSize: 14)])
        try DocumentEngine.write(text, as: .rtf, to: url)
        return url
    }

    func testImages() async throws {
        let png = try makePNG(alpha: true)
        for format in [Format.jpg, .heic, .tiff, .gif, .pdf] {
            let job = await run(.convert(format), .image, png)
            XCTAssertEqual(job.outputs.first?.pathExtension, format.fileExtension)
        }
        let flattened = try ImageEngine.loadImage(folder.appendingPathComponent("Dot.jpg"))
        XCTAssertFalse(ImageEngine.hasAlpha(flattened))
        let half = await run(.tool(.halfSize), .image, png)
        XCTAssertEqual(try ImageEngine.loadImage(half.outputs[0]).width, 32)
        _ = await run(.tool(.stripMetadata), .image, png)
        // A lossless image with transparency compresses to HEIC.
        let big = try makePNG(alpha: false)
        let compressed = ConversionJob(operation: .tool(.compress), kind: .image, sources: [big])
        let done = expectation(description: "compress")
        runner.onFinish = { _ in done.fulfill() }
        runner.start(compressed)
        await fulfillment(of: [done], timeout: 30)
        XCTAssertTrue(compressed.phase == .done || compressed.phase == .failed("It's already as small as it gets."))
    }

    func testBatchSkipsFilesAlreadyInTheFormat() async throws {
        let png = try makePNG(alpha: true)
        let jpg = folder.appendingPathComponent("Already.jpg")
        try ImageEngine.write(ImageEngine.flatten(ImageEngine.loadImage(png)), type: .jpeg, to: jpg, quality: 0.9)
        let job = ConversionJob(operation: .convert(.jpg), kind: .image, sources: [png, jpg])
        var delivered: [URL] = []
        job.deliver = { delivered = $0 }
        let done = expectation(description: "batch")
        runner.onFinish = { _ in done.fulfill() }
        runner.start(job)
        await fulfillment(of: [done], timeout: 30)
        XCTAssertEqual(job.phase, .done)
        XCTAssertEqual(job.outputs.map(\.lastPathComponent), ["Dot.jpg"])
        XCTAssertEqual(job.completed, 2)
        XCTAssertEqual(delivered, job.outputs)
    }

    func testDocumentsAndPDFs() async throws {
        let rtf = try makeDocument()
        for format in [Format.pdf, .docx, .txt, .html, .odt] {
            _ = await run(.convert(format), .document, rtf)
        }
        let pdf = folder.appendingPathComponent("Notes.pdf")
        XCTAssertGreaterThan(PDFDocumentPageCount(pdf), 1)
        let txt = await run(.convert(.txt), .pdf, pdf)
        XCTAssertTrue(try String(contentsOf: txt.outputs[0], encoding: .utf8).contains("converter wheel"))
        _ = await run(.convert(.docx), .pdf, pdf)
        let pages = await run(.convert(.png), .pdf, pdf)
        var isFolder: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: pages.outputs[0].path, isDirectory: &isFolder) && isFolder.boolValue)
        let copied = await run(.tool(.copyText), .pdf, pdf)
        XCTAssertNotNil(copied.note)
    }

    func testMedia() async throws {
        guard let system = FFmpeg.searchDirectories.map({ "\($0)/ffmpeg" }).first(where: FileManager.default.isExecutableFile) else {
            throw XCTSkip("No ffmpeg on this Mac")
        }
        let clip = folder.appendingPathComponent("Clip.mov")
        let make = Process()
        make.executableURL = URL(fileURLWithPath: system)
        make.arguments = ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=25:duration=2",
                          "-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                          "-c:a", "aac", "-shortest", clip.path]
        try make.run()
        make.waitUntilExit()
        XCTAssertEqual(make.terminationStatus, 0)
        for format in [Format.mp4, .webm, .gif, .mp3, .m4a] {
            _ = await run(.convert(format), .video, clip)
        }
        for tool in [Tool.halfSize, .mute, .stripMetadata] {
            _ = await run(.tool(tool), .video, clip)
        }
        let mp3 = folder.appendingPathComponent("Clip.mp3")
        for format in [Format.wav, .flac, .ogg, .opus, .aiff] {
            _ = await run(.convert(format), .audio, mp3)
        }
        let gif = folder.appendingPathComponent("Clip.gif")
        for format in [Format.mp4, .webm, .png] {
            _ = await run(.convert(format), .gif, gif)
        }
        let png = try makePNG(alpha: true)
        _ = await run(.convert(.avif), .image, png)
        let encoders = try await ffmpeg.resolve().encoders
        if MediaRecipe.isSupported(.convert(.webp), kind: .image, encoders: encoders) {
            _ = await run(.convert(.webp), .image, png)
        }
    }

    func testCancellingStopsFFmpeg() async throws {
        guard let system = FFmpeg.searchDirectories.map({ "\($0)/ffmpeg" }).first(where: FileManager.default.isExecutableFile) else {
            throw XCTSkip("No ffmpeg on this Mac")
        }
        let clip = folder.appendingPathComponent("Long.mov")
        let make = Process()
        make.executableURL = URL(fileURLWithPath: system)
        make.arguments = ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=size=1280x720:rate=30:duration=60",
                          "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", clip.path]
        try make.run()
        make.waitUntilExit()
        let job = ConversionJob(operation: .convert(.webm), kind: .video, sources: [clip])
        let done = expectation(description: "cancelled")
        runner.onFinish = { _ in done.fulfill() }
        runner.start(job)
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertGreaterThan(job.progress ?? 0, 0, "progress should be moving")
        job.cancel()
        await fulfillment(of: [done], timeout: 10)
        XCTAssertEqual(job.phase, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Long.webm").path))
    }
}

import PDFKit
private func PDFDocumentPageCount(_ url: URL) -> Int { PDFDocument(url: url)?.pageCount ?? 0 }
