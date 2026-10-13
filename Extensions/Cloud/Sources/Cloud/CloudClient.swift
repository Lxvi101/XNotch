import Foundation

/// The XNotch Cloud server's API (see Server/README.md).
struct CloudClient: Sendable {
    struct Info: Decodable, Sendable {
        let name: String
        let version: String
        let maxFileSize: UInt64
        let defaultExpirySeconds: UInt64
        let maxExpirySeconds: UInt64
    }

    struct Drop: Decodable, Sendable {
        let id: String
        let url: URL
        let expiresAt: Date
    }

    enum Failure: LocalizedError {
        case notConfigured
        case server(Int, String)
        case unreadable

        var errorDescription: String? {
            switch self {
            case .notConfigured: "Add your server in Settings → Cloud Links."
            case .server(401, _): "The server didn't accept the access token."
            case .server(413, _): "The file is larger than the server allows."
            case .server(let status, let message): message.isEmpty ? "The server answered \(status)." : message
            case .unreadable: "The server's answer wasn't readable. Is the URL right?"
            }
        }
    }

    let baseURL: URL
    let token: String
    var session: URLSession = .shared

    /// `nil` unless the URL is http(s) and there's a token.
    init?(server: String, token: String) {
        let trimmed = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, let url = URL(string: trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil else { return nil }
        baseURL = url
        self.token = token
    }

    func info() async throws -> Info {
        try await decode(Info.self, from: request("GET", "api/info"))
    }

    func createDrop(expiresIn: TimeInterval, title: String?) async throws -> Drop {
        var body: [String: Any] = ["expires_in": Int(expiresIn)]
        if let title { body["title"] = title }
        var request = request("POST", "api/drops")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await decode(Drop.self, from: request)
    }

    /// Streams the file from disk; `progress` gets the fraction sent.
    func upload(_ file: URL, name: String, to drop: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        // The server stores names as sent; NFC keeps "é" one name whichever way it was typed.
        let name = name.precomposedStringWithCanonicalMapping
        var request = request("PUT", "api/drops/\(Self.pathComponent(drop))/files/\(Self.pathComponent(name))")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        let (data, response) = try await session.upload(for: request, fromFile: file,
                                                        delegate: UploadProgress(progress))
        try Self.check(data, response)
    }

    func delete(drop: String) async throws {
        let (data, response) = try await session.data(for: request("DELETE", "api/drops/\(Self.pathComponent(drop))"))
        if (response as? HTTPURLResponse)?.statusCode == 404 { return }
        try Self.check(data, response)
    }

    // MARK: Plumbing

    private func request(_ method: String, _ path: String) -> URLRequest {
        var request = URLRequest(url: URL(string: baseURL.absoluteString + "/" + path)!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func decode<T: Decodable>(_ type: T.Type, from request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        try Self.check(data, response)
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw Failure.unreadable
        }
    }

    private static func check(_ data: Data, _ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw Failure.unreadable }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? ""
            throw Failure.server(http.statusCode, message)
        }
    }

    static func pathComponent(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? text
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(text)"))
        }
        return decoder
    }()
}

private final class UploadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Double) -> Void

    init(_ report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
