import XCTest
@testable import Cloud

/// Encryption must fail closed: whatever an old or misbehaving server answers,
/// no file bytes may reach it unencrypted.
final class DropUploaderTests: XCTestCase {
    private var file: URL!

    override func setUpWithError() throws {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("Secret plans \(UUID().uuidString).txt")
        try Data("attack at dawn".utf8).write(to: file)
        FakeServer.reset()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: file)
    }

    private func uploader(server: String = "https://drop.example.com", info: String, encrypt: Bool = true) throws -> DropUploader {
        var client = try XCTUnwrap(CloudClient(server: server, token: "token"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeServer.self]
        client.session = URLSession(configuration: configuration)
        let decoded = try CloudClient.decoder.decode(CloudClient.Info.self, from: Data(info.utf8))
        return DropUploader(client: client, info: decoded, encrypt: encrypt)
    }

    private let oldInfo = #"{"name":"X","version":"0.1.0","max_file_size":1000000,"default_expiry_seconds":86400,"max_expiry_seconds":2592000,"passwords":true}"#
    private let newInfo = #"{"name":"X","version":"0.2.0","max_file_size":1000000,"default_expiry_seconds":86400,"max_expiry_seconds":2592000,"passwords":true,"e2ee":[1]}"#

    func testRefusesAServerThatDoesNotAdvertiseEncryption() async throws {
        let uploader = try uploader(info: oldInfo)
        await XCTAssertThrowsAsync(try await uploader.upload([file], title: "t", expiresIn: 3600, password: nil) { _ in }) {
            XCTAssertTrue($0 is EncryptionUnsupported, "\($0)")
        }
        XCTAssertEqual(FakeServer.requests, [], "nothing at all is sent")
    }

    func testRefusesAServerThatIgnoresTheEncryptionRequest() async throws {
        // Advertises e2ee, but creates a plain drop (say, a proxy rewrote the body).
        FakeServer.createResponse = #"{"id":"a1B2c3D4","url":"https://drop.example.com/a1B2c3D4","expires_at":"2026-10-14T18:00:00Z","protected":false}"#
        let uploader = try uploader(info: newInfo)
        await XCTAssertThrowsAsync(try await uploader.upload([file], title: "t", expiresIn: 3600, password: nil) { _ in }) {
            XCTAssertTrue($0 is EncryptionUnsupported, "\($0)")
        }
        XCTAssertEqual(FakeServer.requests, ["POST /api/drops", "DELETE /api/drops/a1B2c3D4"], "the drop is removed, no file sent")
    }

    func testRefusesPlainHTTPWhereBrowsersCannotDecrypt() async throws {
        let uploader = try uploader(server: "http://192.168.1.20:8080", info: newInfo)
        await XCTAssertThrowsAsync(try await uploader.upload([file], title: "t", expiresIn: 3600, password: nil) { _ in }) {
            XCTAssertTrue($0 is EncryptionNeedsHTTPS, "\($0)")
        }
        XCTAssertEqual(FakeServer.requests, [])
        XCTAssertTrue(try XCTUnwrap(CloudClient(server: "http://localhost:8080", token: "t")).canServeEncryptedLinks)
        XCTAssertTrue(try XCTUnwrap(CloudClient(server: "http://127.0.0.1:8791", token: "t")).canServeEncryptedLinks)
    }

    func testEncryptedUploadSendsOnlyCiphertextAndOpaqueNames() async throws {
        FakeServer.createResponse = #"{"id":"a1B2c3D4","url":"https://drop.example.com/a1B2c3D4","expires_at":"2026-10-14T18:00:00Z","protected":false,"e2ee":1}"#
        let result = try await uploader(info: newInfo).upload([file], title: "Secret plans.txt", expiresIn: 3600, password: nil) { _ in }

        let key = try XCTUnwrap(DropCrypto.Key(fragment: try XCTUnwrap(result.link.fragment)))
        XCTAssertEqual(result.link.absoluteString, "https://drop.example.com/a1B2c3D4#" + key.fragment)
        XCTAssertEqual(FakeServer.requests.count, 3)
        XCTAssertEqual(FakeServer.requests[0], "POST /api/drops")
        let create = try XCTUnwrap(FakeServer.bodies["POST /api/drops"])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: create) as? [String: Any])
        XCTAssertEqual(json["e2ee"] as? Int, 1)
        XCTAssertNil(json["title"], "the title stays in the manifest")

        let put = FakeServer.requests[1]
        let objectID = String(put.split(separator: "/").last!)
        XCTAssertTrue(put.hasPrefix("PUT /api/drops/a1B2c3D4/files/") && objectID.count == 32, put)
        XCTAssertEqual(FakeServer.requests[2], "PUT /api/drops/a1B2c3D4/manifest")

        for body in FakeServer.bodies.values {
            XCTAssertNil(body.range(of: Data("attack at dawn".utf8)))
            XCTAssertNil(body.range(of: Data("Secret plans".utf8)))
            XCTAssertNil(body.range(of: Data(key.fragment.utf8)), "the key never leaves the Mac")
        }
        let sealedFile = try XCTUnwrap(FakeServer.bodies[put])
        XCTAssertEqual(try DropCrypto.open(sealedFile, kind: .file, key: key, dropID: "a1B2c3D4", objectID: objectID),
                       Data("attack at dawn".utf8))
        let manifest = try DropCrypto.openManifest(try XCTUnwrap(FakeServer.bodies["PUT /api/drops/a1B2c3D4/manifest"]),
                                                   key: key, dropID: "a1B2c3D4")
        XCTAssertEqual(manifest, .init(title: "Secret plans.txt",
                                       files: [.init(id: objectID, name: file.lastPathComponent, size: 14)]))
    }

    func testHTTPSAPIRefusesHTTPPublicLinkBeforeUploading() async throws {
        try setPublicURL("http://drop.example.com/a1B2c3D4")
        let uploader = try uploader(info: newInfo)
        await XCTAssertThrowsAsync(try await uploader.upload([file], title: "t", expiresIn: 3600, password: nil) { _ in }) {
            XCTAssertTrue($0 is EncryptionNeedsHTTPS, "\($0)")
        }
        XCTAssertEqual(FakeServer.requests, ["POST /api/drops", "DELETE /api/drops/a1B2c3D4"],
                       "reject the public URL before any file or manifest is uploaded")
    }

    func testRefusesMalformedOrUnsafeEncryptedPublicLinksAndCleansUp() async throws {
        let uploader = try uploader(info: newInfo)
        for publicURL in [
            "http://192.168.1.20/a1B2c3D4", "http://localhost.evil.example/a1B2c3D4",
            "ftp://localhost/a1B2c3D4", "file:///a1B2c3D4", "/a1B2c3D4", "//drop.example.com/a1B2c3D4",
            "https:/a1B2c3D4", "https:///a1B2c3D4", "https:a1B2c3D4",
            "https://user:password@drop.example.com/a1B2c3D4", "https://@drop.example.com/a1B2c3D4",
            "https://drop.example.com:99999/a1B2c3D4", "https://drop.example.com:0/a1B2c3D4",
            "https://%0Adrop.example.com/a1B2c3D4", "https://drop.example.com%2Fevil/a1B2c3D4",
            "https://drop.example.com/a1B2c3D4#server-fragment"
        ] {
            FakeServer.reset()
            try setPublicURL(publicURL)
            await XCTAssertThrowsAsync(try await uploader.upload([file], title: "t", expiresIn: 3600, password: nil) { _ in }) {
                XCTAssertTrue($0 is EncryptionNeedsHTTPS, "\(publicURL): \($0)")
            }
            XCTAssertEqual(FakeServer.requests, ["POST /api/drops", "DELETE /api/drops/a1B2c3D4"], publicURL)
        }
    }

    func testAcceptsHTTPSPublicLinkOnADifferentHost() async throws {
        let publicURL = "https://public.example.com/a1B2c3D4"
        try setPublicURL(publicURL)
        let result = try await uploader(info: newInfo).upload([file], title: "t", expiresIn: 3600, password: nil) { _ in }
        let key = try XCTUnwrap(result.link.fragment)
        XCTAssertNotNil(DropCrypto.Key(fragment: key))
        XCTAssertEqual(result.link.absoluteString, publicURL + "#" + key)
        XCTAssertEqual(FakeServer.requests.count, 3)
        XCTAssertEqual(FakeServer.requests.last, "PUT /api/drops/a1B2c3D4/manifest")
    }

    func testAcceptsOnlyTheIntendedLoopbackHTTPPublicLinks() async throws {
        for host in ["localhost", "127.0.0.1", "[::1]"] {
            FakeServer.reset()
            let publicURL = "http://\(host):8080/a1B2c3D4"
            try setPublicURL(publicURL)
            let result = try await uploader(server: "http://\(host):8080", info: newInfo)
                .upload([file], title: "t", expiresIn: 3600, password: nil) { _ in }
            let key = try XCTUnwrap(result.link.fragment)
            XCTAssertNotNil(DropCrypto.Key(fragment: key))
            XCTAssertEqual(result.link.absoluteString, publicURL + "#" + key)
            XCTAssertEqual(FakeServer.requests.count, 3)
            XCTAssertEqual(FakeServer.requests.last, "PUT /api/drops/a1B2c3D4/manifest")
        }
    }

    private func setPublicURL(_ url: String) throws {
        let response: [String: Any] = ["id": "a1B2c3D4", "url": url, "expires_at": "2026-10-14T18:00:00Z",
                                       "protected": false, "e2ee": 1]
        FakeServer.createResponse = String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
    }

    func testPlainUploadsStillWorkWhenEncryptionIsOff() async throws {
        FakeServer.createResponse = #"{"id":"a1B2c3D4","url":"https://drop.example.com/a1B2c3D4","expires_at":"2026-10-14T18:00:00Z"}"#
        let result = try await uploader(info: oldInfo, encrypt: false).upload([file], title: "t", expiresIn: 3600, password: nil) { _ in }
        XCTAssertEqual(result.link.absoluteString, "https://drop.example.com/a1B2c3D4")
        XCTAssertEqual(FakeServer.requests.count, 2)
        XCTAssertEqual(FakeServer.bodies[FakeServer.requests[1]], Data("attack at dawn".utf8))
    }

    func testPlainUploadsKeepSupportingLANHTTPPublicLinks() async throws {
        let publicURL = "http://192.168.1.20:8080/a1B2c3D4"
        FakeServer.createResponse = #"{"id":"a1B2c3D4","url":"http://192.168.1.20:8080/a1B2c3D4","expires_at":"2026-10-14T18:00:00Z"}"#
        let result = try await uploader(server: "http://192.168.1.20:8080", info: oldInfo, encrypt: false)
            .upload([file], title: "t", expiresIn: 3600, password: nil) { _ in }
        XCTAssertEqual(result.link.absoluteString, publicURL)
        XCTAssertNil(result.link.fragment)
        XCTAssertEqual(FakeServer.requests.count, 2)
        XCTAssertEqual(FakeServer.bodies[FakeServer.requests[1]], Data("attack at dawn".utf8))
    }

    func testSizeLimitAppliesToTheCiphertext() throws {
        let info = newInfo.replacingOccurrences(of: "1000000", with: "100")
        let uploader = try uploader(info: info)
        XCTAssertNoThrow(try uploader.preflight(sizes: [("a", 100 - 38 - 16)], password: nil))
        XCTAssertThrowsError(try uploader.preflight(sizes: [("a", 100 - 38 - 15)], password: nil)) { XCTAssertTrue($0 is TooLarge) }
    }
}

/// Answers like a Cloud server and records what it was sent.
final class FakeServer: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _requests: [String] = []
    nonisolated(unsafe) private static var _bodies: [String: Data] = [:]
    nonisolated(unsafe) private static var _createResponse = ""

    static var requests: [String] { lock.withLock { _requests } }
    static var bodies: [String: Data] { lock.withLock { _bodies } }
    static var createResponse: String {
        get { lock.withLock { _createResponse } }
        set { lock.withLock { _createResponse = newValue } }
    }

    static func reset() {
        lock.withLock { _requests = []; _bodies = [:]; _createResponse = "" }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let line = "\(request.httpMethod ?? "GET") \(request.url!.path)"
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        Self.lock.withLock {
            Self._requests.append(line)
            Self._bodies[line] = body
        }
        let (status, answer): (Int, String) = switch request.httpMethod {
        case "POST": (201, Self.createResponse)
        case "DELETE": (204, "")
        default: (201, #"{"name":"x","size":1,"url":"https://drop.example.com/x"}"#)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

func XCTAssertThrowsAsync<T>(_ expression: @autoclosure () async throws -> T, file: StaticString = #filePath,
                             line: UInt = #line, _ handler: (Error) -> Void = { _ in }) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        handler(error)
    }
}
