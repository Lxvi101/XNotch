import XCTest
@testable import Cloud

/// Against a running server: CLOUD_TEST_URL=http://127.0.0.1:8787 CLOUD_TEST_TOKEN=… swift test
final class CloudServerTests: XCTestCase {
    private var client: CloudClient!

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["CLOUD_TEST_URL"], let token = environment["CLOUD_TEST_TOKEN"] else {
            throw XCTSkip("Set CLOUD_TEST_URL and CLOUD_TEST_TOKEN to run against a server")
        }
        client = CloudClient(server: url, token: token)
    }

    func testUploadDownloadAndRevoke() async throws {
        let info = try await client.info()
        XCTAssertGreaterThan(info.maxFileSize, 0)

        let drop = try await client.createDrop(expiresIn: 3600, title: "Résumé.pdf")
        XCTAssertEqual(drop.url.absoluteString, client.baseURL.absoluteString + "/" + drop.id)
        XCTAssertEqual(drop.expiresAt.timeIntervalSinceNow, 3600, accuracy: 30)

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString).bin")
        let bytes = Data((0..<1_500_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        try bytes.write(to: file)
        let fractions = Fractions()
        // A decomposed "é" and a space: one path component, stored as NFC.
        try await client.upload(file, name: "Re\u{301}sume\u{301} final.pdf", to: drop.id) { fractions.add($0) }
        XCTAssertEqual(fractions.last, 1, accuracy: 0.001)

        let downloadURL = drop.url.appendingPathComponent("Résumé final.pdf")
        let (downloaded, response) = try await URLSession.shared.data(from: downloadURL)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(downloaded, bytes)

        let (page, _) = try await URLSession.shared.data(from: drop.url)
        XCTAssertTrue(String(decoding: page, as: UTF8.self).contains("Résumé final.pdf"))

        try await client.delete(drop: drop.id)
        let (_, gone) = try await URLSession.shared.data(from: downloadURL)
        XCTAssertEqual((gone as? HTTPURLResponse)?.statusCode, 404)
        try await client.delete(drop: drop.id) // already gone: not an error
    }

    func testPasswordLocksThePageAndFiles() async throws {
        let info = try await client.info()
        guard info.passwords == true else { throw XCTSkip("The server predates drop passwords") }
        let drop = try await client.createDrop(expiresIn: 3600, title: "Locked", password: "open sesame")
        XCTAssertEqual(drop.protected, true)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("locked-\(UUID().uuidString).txt")
        try Data("secret".utf8).write(to: file)
        try await client.upload(file, name: "secret.txt", to: drop.id) { _ in }

        let (page, _) = try await URLSession.shared.data(from: drop.url)
        let html = String(decoding: page, as: UTF8.self)
        XCTAssertTrue(html.contains("Password required"))
        XCTAssertFalse(html.contains("secret.txt"))
        try await client.delete(drop: drop.id)
    }

    /// Uploads like the app does, then reads back what the server stores and serves.
    /// With XNE_SWIFT_DROP=path it also writes the link for Server/tests/e2ee/browser.mjs,
    /// which then decrypts this Swift-made drop in a real browser.
    func testEncryptedUploadIsOpaqueToTheServer() async throws {
        let info = try await client.info()
        guard info.supportsEncryption else { throw XCTSkip("The server predates end-to-end encryption") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("e2ee-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let small = folder.appendingPathComponent("Re\u{301}sume\u{301} secret.txt")
        try Data("Top secret résumé".utf8).write(to: small)
        let big = folder.appendingPathComponent("big secret.bin")
        let bigBytes = Data((0..<(2 * DropCrypto.segmentSize + 999)).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        try bigBytes.write(to: big)

        let uploader = DropUploader(client: client, info: info, encrypt: true)
        let result = try await uploader.upload([small, big], title: "Secret title", expiresIn: 3600, password: nil) { _ in }
        let id = result.drop.id
        let key = try XCTUnwrap(DropCrypto.Key(fragment: try XCTUnwrap(result.link.fragment)))

        let (page, _) = try await URLSession.shared.data(from: result.drop.url)
        let html = String(decoding: page, as: UTF8.self)
        XCTAssertTrue(html.contains("data-drop=\"\(id)\""))
        for secret in ["Secret title", "secret.txt", "big secret", "Top secret"] { XCTAssertFalse(html.contains(secret), secret) }

        let (sealedManifest, _) = try await URLSession.shared.data(from: result.drop.url.appendingPathComponent("-/manifest"))
        let manifest = try DropCrypto.openManifest(sealedManifest, key: key, dropID: id)
        XCTAssertEqual(manifest.title, "Secret title")
        XCTAssertEqual(manifest.files.map(\.name), ["Résumé secret.txt", "big secret.bin"])
        for (entry, expected) in zip(manifest.files, [Data("Top secret résumé".utf8), bigBytes]) {
            let (sealed, response) = try await URLSession.shared.data(from: result.drop.url.appendingPathComponent(entry.id))
            XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
            XCTAssertEqual(UInt64(sealed.count), DropCrypto.ciphertextSize(plaintextSize: UInt64(expected.count)))
            XCTAssertNil(sealed.range(of: expected.prefix(16)))
            XCTAssertEqual(try DropCrypto.open(sealed, kind: .file, key: key, dropID: id, objectID: entry.id), expected)
        }

        if let out = ProcessInfo.processInfo.environment["XNE_SWIFT_DROP"] {
            let record: [String: Any] = [
                "link": result.link.absoluteString, "title": "Secret title",
                "files": manifest.files.map { ["name": $0.name, "size": $0.size] },
                "sha256": [Data("Top secret résumé".utf8), bigBytes].map(DropCryptoTests.sha256)
            ]
            try JSONSerialization.data(withJSONObject: record).write(to: URL(fileURLWithPath: out))
        } else {
            try await client.delete(drop: id)
        }
    }

    func testWrongTokenIsExplained() async throws {
        let wrong = CloudClient(server: client.baseURL.absoluteString, token: "wrong-token-000000")!
        do {
            _ = try await wrong.info()
            XCTFail("Expected 401")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The server didn't accept the access token.")
        }
    }
}

private final class Fractions: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func add(_ value: Double) { lock.withLock { values.append(value) } }
    var last: Double { lock.withLock { values.last ?? 0 } }
}
