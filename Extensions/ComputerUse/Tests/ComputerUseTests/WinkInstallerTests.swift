import XCTest
@testable import ComputerUse

@MainActor
final class WinkInstallerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wink-installer-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A Wink.app whose server answers `permissions` with Accessibility on and Screen Recording off.
    private func makeBundledApp() throws -> URL {
        let app = root.appendingPathComponent("bundle/Wink.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let server = macOS.appendingPathComponent("wink-cua")
        try Data("#!/bin/sh\necho '{\"accessibility\":true,\"screenRecording\":false}'\n".utf8).write(to: server)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path)
        return app
    }

    func testInstallReadsGrantsAndRemoveCleansUp() async throws {
        let directory = root.appendingPathComponent("Wink")
        let installer = WinkInstaller(bundled: try makeBundledApp(), directory: directory, clients: [])
        await installer.install(guide: nil)

        XCTAssertTrue(installer.isInstalled)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installer.command.path))
        XCTAssertEqual(installer.grants, .init(accessibility: true, screenRecording: false))
        XCTAssertEqual(installer.missingPermissions, [.screenRecording])

        await installer.uninstall()
        XCTAssertFalse(installer.isInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.destination.path))
        XCTAssertTrue(installer.missingPermissions.isEmpty)
    }

    func testMovesTheBareServerIntoTheApp() async throws {
        let directory = root.appendingPathComponent("Wink")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = directory.appendingPathComponent("wink-cua")
        try Data("old".utf8).write(to: legacy)

        let installer = WinkInstaller(bundled: try makeBundledApp(), directory: directory, clients: [])
        await installer.refresh()
        XCTAssertTrue(installer.isInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testUpdatesAnOlderInstall() async throws {
        let directory = root.appendingPathComponent("Wink")
        let installer = WinkInstaller(bundled: try makeBundledApp(), directory: directory, clients: [])
        await installer.install(guide: nil)
        try Data("#!/bin/sh\necho old\n".utf8).write(to: installer.command)

        await installer.refresh()
        let server = try String(contentsOf: installer.command, encoding: .utf8)
        XCTAssertTrue(server.contains("accessibility"))
    }
}
