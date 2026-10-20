import XCTest
import UniformTypeIdentifiers
@testable import Converter

final class CatalogTests: XCTestCase {
    func testKinds() {
        XCTAssertEqual(FileKind(.png), .image)
        XCTAssertEqual(FileKind(.heic), .image)
        XCTAssertEqual(FileKind(.gif), .gif)
        XCTAssertEqual(FileKind(.pdf), .pdf)
        XCTAssertEqual(FileKind(.mpeg4Movie), .video)
        XCTAssertEqual(FileKind(.mp3), .audio)
        XCTAssertEqual(FileKind(.rtf), .document)
        XCTAssertEqual(FileKind(UTType("org.openxmlformats.wordprocessingml.document")!), .document)
        XCTAssertNil(FileKind(.zip))
    }

    func testOfferLeavesOutTheFilesOwnFormat() {
        let jpeg = Catalog.offer(for: .image, sourceExtensions: ["JPEG"])
        XCTAssertFalse(jpeg.formats.contains(.jpg))
        XCTAssertTrue(jpeg.formats.contains(.png))
        XCTAssertFalse(Catalog.offer(for: .video, sourceExtensions: ["mp4"]).formats.contains(.mp4))
        XCTAssertFalse(Catalog.offer(for: .document, sourceExtensions: ["htm"]).formats.contains(.html))
        // A batch keeps a format some of its files aren't in yet.
        XCTAssertTrue(Catalog.offer(for: .image, sourceExtensions: ["jpg", "png"]).formats.contains(.jpg))
    }

    func testShelfFilesMustShareAKind() {
        func urls(_ names: String...) -> [URL] { names.map { URL(fileURLWithPath: "/tmp/\($0)") } }
        XCTAssertEqual(FileKind.shared(by: urls("a.heic", "b.JPG", "c.png")), .image)
        XCTAssertEqual(FileKind.shared(by: urls("a.mkv", "b.mov")), .video)
        XCTAssertEqual(FileKind.shared(by: urls("a.opus")), .audio)
        XCTAssertNil(FileKind.shared(by: urls("a.heic", "b.pdf")))
        XCTAssertNil(FileKind.shared(by: urls("a.zip")))
        XCTAssertNil(FileKind.shared(by: []))
    }

    func testHiddenFoldersSendOutputToDownloads() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertTrue(Output.isHidden(home.appendingPathComponent("Library/Application Support/XNotch/ExtensionData/shelves")))
        XCTAssertTrue(Output.isHidden(URL(fileURLWithPath: NSTemporaryDirectory())))
        XCTAssertFalse(Output.isHidden(home.appendingPathComponent("Desktop")))
    }

    func testFFmpegIsOnlyForWhatMacOSCantDo() {
        XCTAssertFalse(Catalog.needsFFmpeg(.convert(.png), kind: .image))
        XCTAssertTrue(Catalog.needsFFmpeg(.convert(.webp), kind: .image))
        XCTAssertTrue(Catalog.needsFFmpeg(.convert(.mp4), kind: .gif))
        XCTAssertFalse(Catalog.needsFFmpeg(.convert(.png), kind: .gif))
        XCTAssertTrue(Catalog.needsFFmpeg(.tool(.compress), kind: .video))
        XCTAssertFalse(Catalog.needsFFmpeg(.tool(.compress), kind: .pdf))
    }
}

final class WheelGeometryTests: XCTestCase {
    let geometry = WheelGeometry(formatCount: 8, toolCount: 4)

    func testHub() {
        XCTAssertEqual(geometry.hit(.zero), .hub)
        XCTAssertEqual(geometry.hit(CGPoint(x: 30, y: 30)), .hub)
    }

    func testFormatsRunClockwiseFromTheTop() {
        let r = (geometry.formatRing.lowerBound + geometry.formatRing.upperBound) / 2
        XCTAssertEqual(geometry.hit(CGPoint(x: 0, y: -r)), .format(0))
        XCTAssertEqual(geometry.hit(CGPoint(x: r, y: 0)), .format(2))
        XCTAssertEqual(geometry.hit(CGPoint(x: 0, y: r)), .format(4))
        XCTAssertEqual(geometry.hit(CGPoint(x: -r, y: 0)), .format(6))
        // Just left of 12 o'clock is still the top sector.
        XCTAssertEqual(geometry.hit(CGPoint(x: -5, y: -r)), .format(0))
    }

    func testToolsAndBeyond() {
        let ring = geometry.toolRing!
        XCTAssertEqual(geometry.hit(CGPoint(x: 0, y: -(ring.lowerBound + ring.upperBound) / 2)), .tool(0))
        XCTAssertEqual(geometry.hit(CGPoint(x: ring.upperBound + 10, y: 0)), .tool(1))
        XCTAssertNil(geometry.hit(CGPoint(x: ring.upperBound + WheelGeometry.reach + 1, y: 0)))
    }

    func testWheelFitsItsWindow() {
        XCTAssertLessThan(geometry.radius * 2 + 40, WheelGeometry.panelSide)
    }
}

final class MediaTests: XCTestCase {
    let probe = """
    Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'clip.mov':
      Duration: 00:01:02.50, start: 0.000000, bitrate: 1205 kb/s
      Stream #0:0[0x1](und): Video: h264 (High) (avc1 / 0x31637661), yuv420p(tv, bt709, progressive), 1920x1080, 1067 kb/s
      Stream #0:1[0x2](und): Audio: aac (LC) (mp4a / 0x6134706D), 48000 Hz, stereo, fltp, 128 kb/s (default)
    """

    func testProbe() {
        let info = MediaInfo(ffmpegOutput: probe)
        XCTAssertEqual(info.duration, 62.5)
        XCTAssertEqual(info.videoCodec, "h264")
        XCTAssertEqual(info.audioCodec, "aac")
    }

    func testCoverArtIsntVideo() {
        let info = MediaInfo(ffmpegOutput: """
          Duration: 00:03:00.00, start: 0.025057, bitrate: 320 kb/s
          Stream #0:0: Audio: mp3 (mp3float), 44100 Hz, stereo, fltp, 320 kb/s
          Stream #0:1: Video: mjpeg (Baseline), yuvj420p(pc), 500x500, 90k tbr, 90k tbn (attached pic)
        """)
        XCTAssertNil(info.videoCodec)
        XCTAssertEqual(info.audioCodec, "mp3")
    }

    func testH264RewrapsWithoutReencoding() {
        let info = MediaInfo(ffmpegOutput: probe)
        let args = MediaRecipe.arguments(for: .convert(.mp4), kind: .video, info: info, quality: .balanced)
        XCTAssertTrue(args.contains("copy"))
        XCTAssertFalse(args.contains("libx264"))
        let vp9 = MediaInfo(duration: 3, videoCodec: "vp9", audioCodec: "opus")
        XCTAssertTrue(MediaRecipe.arguments(for: .convert(.mp4), kind: .video, info: vp9, quality: .balanced).contains("libx264"))
    }

    func testProgressAcrossChunks() {
        var parser = ProgressParser()
        XCTAssertNil(parser.feed("frame=10\nout_time_us=15"))
        XCTAssertEqual(parser.feed("00000\nprogress=continue\n"), 1.5)
        XCTAssertNil(parser.feed("out_time_us=N/A\n"))
    }

    func testEncoderFallbacks() {
        let listing = """
        Encoders:
         V..... = Video
         ------
         V....D libx264              libx264 H.264
         V..... libsvtav1            SVT-AV1
         A..X.D vorbis               Vorbis
         A....D libmp3lame           MP3
        """
        let homebrew = Encoders(listing: listing)
        XCTAssertEqual(homebrew.names, ["libx264", "libsvtav1", "vorbis", "libmp3lame"])
        XCTAssertFalse(MediaRecipe.isSupported(.convert(.webp), kind: .image, encoders: homebrew))
        XCTAssertTrue(MediaRecipe.isSupported(.convert(.avif), kind: .image, encoders: homebrew))
        let avif = MediaRecipe.arguments(for: .convert(.avif), kind: .image, info: MediaInfo(), quality: .balanced, encoders: homebrew)
        XCTAssertTrue(avif.contains("libsvtav1"))
        let ogg = MediaRecipe.arguments(for: .convert(.ogg), kind: .audio, info: MediaInfo(), quality: .balanced, encoders: homebrew)
        XCTAssertTrue(ogg.contains("vorbis") && ogg.contains("-strict"))
        XCTAssertTrue(MediaRecipe.isSupported(.convert(.webp), kind: .image, encoders: .unknown))
    }

    func testReasonNamesTheProblem() {
        let stderr = """
        [libvpx-vp9 @ 0x15c405b20] Pixel format 'gbrap' is not widely supported.
        [vost#0:0/libvpx-vp9 @ 0x15c405310] [enc:libvpx-vp9 @ 0x15c405ab0] Error while opening encoder - maybe incorrect parameters
        [out#0/webm @ 0x15c404800] Nothing was written into output file
        """
        XCTAssertEqual(MediaEngine.reason(stderr), "Error while opening encoder - maybe incorrect parameters")
    }

    func testOutputNames() {
        let source = URL(fileURLWithPath: "/tmp/Photo.heic")
        XCTAssertEqual(Output.name(for: source, suffix: nil, extension: "jpg"), "Photo.jpg")
        XCTAssertEqual(Output.name(for: source, suffix: "Compressed", extension: "heic"), "Photo (Compressed).heic")
    }
}
