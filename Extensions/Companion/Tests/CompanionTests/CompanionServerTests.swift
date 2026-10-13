import Security
import XCTest
import XNotchLink
import os
@testable import Companion

/// The Mac's listener with a phone-side client, as the iOS app connects.
@MainActor
final class CompanionServerTests: XCTestCase {
    private let service = "dev.levi.XNotch.companion.tests"
    private var server: CompanionServer!
    private var root: URL!

    override func setUp() async throws {
        if ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != nil {
            throw XCTSkip("Bonjour discovery isn't reliable on CI runners")
        }
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let defaults = UserDefaults(suiteName: "CompanionServerTests-\(UUID().uuidString)")!
        server = CompanionServer(defaults: defaults, directory: root.appendingPathComponent("data"),
                                 log: Logger(subsystem: "tests", category: "companion"), keychainService: service)
        server.destination = root.appendingPathComponent("Received", isDirectory: true)
        server.start()
        for _ in 0..<50 where server.state != .listening { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(server.state, .listening)
    }

    override func tearDown() async throws {
        server.stop()
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }

    private func connectPhone(_ pairing: LinkPairing) async throws -> LinkSession {
        try await LinkClient.connectLocal(to: pairing, as: LinkDevice(id: "phone", name: "Test iPhone", kind: .iPhone),
                                     incomingDirectory: root.appendingPathComponent("phone"), timeout: 10)
    }

    func testFilesFromThePhoneLandInTheFolderAndOnTheShelf() async throws {
        var shelved: [URL] = []
        server.onFiles = { shelved += $0 }
        let phone = try await connectPhone(server.pairing)
        Task { await phone.run { _ in } }
        for _ in 0..<30 where server.devices.isEmpty { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(server.devices.first?.info.name, "Test iPhone")

        let photo = root.appendingPathComponent("IMG_0001.heic")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 800_000).write(to: photo)
        try await phone.sendFile(photo)
        try await phone.sendFile(photo) // same name again: kept side by side

        XCTAssertEqual(shelved.map(\.lastPathComponent), ["IMG_0001.heic", "IMG_0001 2.heic"])
        XCTAssertEqual(try Data(contentsOf: shelved[0]), try Data(contentsOf: photo))
        XCTAssertTrue(shelved.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL == server.destination.standardizedFileURL })
        XCTAssertEqual(server.recent.count, 2)
        await phone.close()
    }

    func testTheMacSendsBackToAConnectedPhone() async throws {
        let phone = try await connectPhone(server.pairing)
        let inbox = Inbox()
        Task { await phone.run { item in if case .file(let url, let name) = item { await inbox.add(name, try Data(contentsOf: url)) } } }
        for _ in 0..<30 where server.devices.isEmpty { try await Task.sleep(nanoseconds: 100_000_000) }

        let folder = root.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        server.send([folder], to: try XCTUnwrap(server.devices.first))
        for _ in 0..<50 where server.transfer != .sent { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(server.transfer, .sent)
        let names = await inbox.names
        XCTAssertEqual(names, ["Project.zip"], "Folders travel zipped")
        await phone.close()
    }

    /// RELAY_TEST_URL=http://127.0.0.1:8787 RELAY_TEST_TOKEN=… swift test
    func testOnePhoneOnTwoRoutesUsesTheFasterOne() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let relay = environment["RELAY_TEST_URL"], let token = environment["RELAY_TEST_TOKEN"] else {
            throw XCTSkip("Set RELAY_TEST_URL and RELAY_TEST_TOKEN to run against a server")
        }
        server.relayServer = relay
        server.relayToken = token
        server.applyRelaySettings()
        for _ in 0..<50 where server.relayState != .ready { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(server.relayState, .ready)
        XCTAssertEqual(server.pairing.relay?.absoluteString, relay)

        let phoneDevice = LinkDevice(id: "phone", name: "Test iPhone", kind: .iPhone)
        try await Task.sleep(nanoseconds: 300_000_000)
        let overInternet = try await LinkClient.connectInternet(to: server.pairing, as: phoneDevice, incomingDirectory: root)
        Task { await overInternet.run { _ in } }
        for _ in 0..<30 where server.devices.first?.route != .internet { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(server.devices.first?.route, .internet)

        let overWiFi = try await connectPhone(server.pairing)
        Task { await overWiFi.run { _ in } }
        for _ in 0..<30 where server.devices.first?.route != .local { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(server.devices.count, 1, "Both routes belong to one device")
        XCTAssertEqual(server.devices.first?.route, .local, "Wi-Fi beats the internet")
        XCTAssertEqual(Set(server.devices.first?.sessions.keys.map { $0 } ?? []), [.local, .internet])

        await overWiFi.close()
        for _ in 0..<30 where server.devices.first?.route != .internet { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(server.devices.first?.route, .internet, "Back to the internet when Wi-Fi goes")
        await overInternet.close()
    }

    func testResetPairingLocksOutOldPhones() async throws {
        let old = server.pairing
        server.resetPairing()
        XCTAssertNotEqual(server.pairing.key, old.key)
        for _ in 0..<50 where server.state != .listening { try await Task.sleep(nanoseconds: 100_000_000) }
        do {
            // The old ID no longer advertises, so the phone can't even find it.
            _ = try await connectPhone(old)
            XCTFail("An old pairing must not connect")
        } catch {}
        let fresh = try await connectPhone(server.pairing)
        await fresh.close()
    }
}

private actor Inbox {
    var names: [String] = []
    func add(_ name: String, _ data: Data) { names.append(name) }
}
