import XCTest
@testable import Cloud

final class CloudClientTests: XCTestCase {
    func testConfigurationNeedsHTTPAndToken() {
        XCTAssertNil(CloudClient(server: "https://drop.example.com", token: ""))
        XCTAssertNil(CloudClient(server: "ftp://drop.example.com", token: "t"))
        XCTAssertEqual(CloudClient(server: " https://drop.example.com/ ", token: "t")?.baseURL.absoluteString,
                       "https://drop.example.com")
        XCTAssertNotNil(CloudClient(server: "http://192.168.1.20:8080", token: "t"))
    }

    func testFileNamesArePercentEncodedAsOnePathComponent() {
        XCTAssertEqual(CloudClient.pathComponent("My Report/v2 (final).pdf"), "My%20Report%2Fv2%20%28final%29.pdf")
        XCTAssertEqual(CloudClient.pathComponent("Ünïcode.txt"), "%C3%9Cn%C3%AFcode.txt")
    }

    func testDecodesServerResponses() throws {
        let drop = try CloudClient.decoder.decode(CloudClient.Drop.self, from: Data("""
        {"id":"a1B2c3D4","url":"https://drop.example.com/a1B2c3D4","expires_at":"2026-10-14T18:00:00Z"}
        """.utf8))
        XCTAssertEqual(drop.id, "a1B2c3D4")
        XCTAssertEqual(drop.expiresAt.timeIntervalSince1970, 1_792_000_800)
        let info = try CloudClient.decoder.decode(CloudClient.Info.self, from: Data("""
        {"name":"XNotch Cloud","version":"0.1.0","max_file_size":5368709120,"default_expiry_seconds":86400,"max_expiry_seconds":2592000}
        """.utf8))
        XCTAssertEqual(info.maxExpirySeconds, 2_592_000)
    }
}

final class CloudRulesTests: XCTestCase {
    func testHostsWithoutSchemeMeanHTTPS() {
        XCTAssertEqual(CloudClient(server: "xnotch.levidan.com", token: "t")?.baseURL.absoluteString, "https://xnotch.levidan.com")
    }

    func testPlainHTTPOnlyOnTheLocalNetwork() {
        XCTAssertNil(CloudClient(server: "http://drop.example.com", token: "t"))
        XCTAssertNotNil(CloudClient(server: "http://192.168.1.20:8080", token: "t"))
        XCTAssertNotNil(CloudClient(server: "http://raspberrypi.local", token: "t"))
        XCTAssertNotNil(CloudClient(server: "http://localhost:8080", token: "t"))
        XCTAssertNil(CloudClient(server: "http://8.8.8.8", token: "t"))
    }
}
