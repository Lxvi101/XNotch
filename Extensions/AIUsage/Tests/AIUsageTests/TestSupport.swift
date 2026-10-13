import Foundation
import XCTest
@testable import AIUsage

/// Answers requests from a closure and records them. All fixtures are synthetic.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    var handler: @Sendable (URLRequest) async throws -> HTTPResponse

    init(_ handler: @escaping @Sendable (URLRequest) async throws -> HTTPResponse) {
        self.handler = handler
    }

    var requests: [URLRequest] { lock.withLock { recorded } }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        lock.withLock { recorded.append(request) }
        return try await handler(request)
    }

    static func json(_ status: Int = 200, _ body: String, headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: headers, data: Data(body.utf8))
    }

    static func fixture(_ name: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: [:], data: Fixture.data(name))
    }
}

enum Fixture {
    static func data(_ name: String) -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try! Data(contentsOf: url)
    }
}

/// A Keychain stand-in that records whether each read was allowed to prompt.
final class FakeKeychain: KeychainReading, SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    var foreign: [String: Data] = [:]
    var own: [String: Data] = [:]
    /// What a non-interactive read returns for a present item (simulates an ACL that wants a prompt).
    var backgroundResult: KeychainRead?
    var interactiveResult: KeychainRead?
    private(set) var reads: [(name: String, interactive: Bool)] = []

    func exists(service: String) -> Bool { foreign[service] != nil }

    func read(service: String, interactive: Bool) -> KeychainRead {
        lock.withLock { reads.append((service, interactive)) }
        guard let data = foreign[service] else { return .notFound }
        if interactive, let interactiveResult { return interactiveResult }
        if !interactive, let backgroundResult { return backgroundResult }
        return .found(data)
    }

    func read(_ name: String, interactive: Bool) -> KeychainRead {
        lock.withLock { reads.append((name, interactive)) }
        guard let data = own[name] else { return .notFound }
        if !interactive, let backgroundResult { return backgroundResult }
        return .found(data)
    }

    func write(_ name: String, value: Data) -> OSStatus { own[name] = value; return errSecSuccess }
    func delete(_ name: String) -> OSStatus { own[name] = nil; return errSecSuccess }
    func exists(_ name: String) -> Bool { own[name] != nil }
}

enum TestJWT {
    static func make(_ claims: [String: Any]) -> String {
        func encode(_ object: Any) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        return "\(encode(["alg": "none", "typ": "JWT"])).\(encode(claims)).c2lnbmF0dXJl"
    }
}

func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("AIUsageTests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func assertFailure(_ error: Error, _ kind: ProviderFailure.Kind, file: StaticString = #filePath, line: UInt = #line) {
    guard let failure = error as? ProviderFailure else {
        return XCTFail("Expected ProviderFailure, got \(error)", file: file, line: line)
    }
    XCTAssertEqual(failure.kind, kind, failure.message, file: file, line: line)
}

let referenceDate = Date(timeIntervalSince1970: 1_790_000_000)  // 2026-09-21
