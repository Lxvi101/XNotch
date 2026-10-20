import XCTest
@testable import Converter

/// Downloads the real static build; opt in with CONVERTER_INSTALL_TEST=1.
@MainActor
final class InstallTests: XCTestCase {
    func testInstallDownloadsAndVerifies() async throws {
        guard ProcessInfo.processInfo.environment["CONVERTER_INSTALL_TEST"] != nil else { throw XCTSkip("Network test") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("converter-install-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let ffmpeg = FFmpeg(directory: folder, customPath: nil)
        var states: [FFmpeg.InstallState] = []
        let binary = try await ffmpeg.install { states.append($0) }
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary.path))
        XCTAssertTrue(FFmpeg.isSigned(binary, team: FFmpeg.signingTeam))
        XCTAssertTrue(states.contains { if case .downloading(let f) = $0 { return (f ?? 0) > 0.5 } else { return false } })
        XCTAssertTrue(states.contains(.verifying))
        // Someone else's signature is refused.
        XCTAssertFalse(FFmpeg.isSigned(URL(fileURLWithPath: "/bin/ls"), team: FFmpeg.signingTeam))
    }
}
