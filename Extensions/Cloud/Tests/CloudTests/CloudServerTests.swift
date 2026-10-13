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
