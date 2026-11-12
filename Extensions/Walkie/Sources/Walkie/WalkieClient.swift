import Foundation

/// The XNotch Cloud server's Walkie API (Server/docs/WALKIE.md).
struct WalkieClient: Sendable {
    enum Failure: LocalizedError {
        case server(Int, String)
        case unreadable
        case badURL

        var errorDescription: String? {
            switch self {
            case .server(401, _): "The server didn't accept the credentials."
            case .server(404, _): "This server has no Walkie. Update it from the Server folder."
            case .server(413, _): "That's more than the server takes in one message."
            case .server(429, _): "Their mailbox is full. Try again in a minute."
            case .server(let status, let message): message.isEmpty ? "The server answered \(status)." : message
            case .unreadable: "The server's answer wasn't readable."
            case .badURL: "That server address doesn't look right."
            }
        }
    }

    let baseURL: URL
    var session: URLSession = .shared

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// "drop.example.com" means https; plain http only for your own network.
    init?(server: String) {
        var trimmed = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if !trimmed.isEmpty, !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard let url = URL(string: trimmed), let host = url.host, let scheme = url.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && Self.isLocal(host)) else { return nil }
        baseURL = url
    }

    static func isLocal(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") || !host.contains(".") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || parts[0] == 127 || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 100 && (64...127).contains(parts[1]))
    }

    // MARK: Owner (API token)

    struct Info: Decodable {
        let walkie: Bool?
        let walkieMaxMessage: Int?
    }

    func info(apiToken: String) async throws -> Info {
        var request = request("GET", "api/info")
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        return try await decode(Info.self, request)
    }

    func register(_ mailbox: MailboxKeys, card: String, listed: Bool, apiToken: String) async throws {
        var request = request("PUT", "api/walkie/boxes/\(mailbox.box)")
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue(mailbox.secret.hex, forHTTPHeaderField: "X-Walkie-Secret")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "post_token": mailbox.postToken.hex, "card": card, "listed": listed
        ] as [String: Any])
        try await send(request)
    }

    func unregister(_ mailbox: MailboxKeys, apiToken: String) async throws {
        var request = request("DELETE", "api/walkie/boxes/\(mailbox.box)")
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue(mailbox.secret.hex, forHTTPHeaderField: "X-Walkie-Secret")
        try await send(request)
    }

    struct Listed: Decodable, Sendable {
        let box: String
        let card: String
        let postToken: String
    }

    func directory(apiToken: String) async throws -> [Listed] {
        var request = request("GET", "api/walkie/directory")
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        return try await decode([Listed].self, request)
    }

    // MARK: Contacts (send token)

    func card(box: String, postToken: Data) async throws -> String {
        var request = request("GET", "api/walkie/boxes/\(box)/card")
        request.setValue("Bearer \(postToken.hex)", forHTTPHeaderField: "Authorization")
        struct Answer: Decodable { let card: String }
        return try await decode(Answer.self, request).card
    }

    /// Returns whether they were listening when it arrived.
    @discardableResult
    func post(_ sealed: Data, to box: String, postToken: Data,
              progress: (@Sendable (Double) -> Void)? = nil) async throws -> Bool {
        var request = request("POST", "api/walkie/boxes/\(box)/messages")
        request.setValue("Bearer \(postToken.hex)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        let (data, response) = try await session.upload(for: request, from: sealed,
                                                        delegate: progress.map(UploadProgress.init))
        try Self.check(data, response)
        struct Answer: Decodable { let delivered: Bool }
        return (try? JSONDecoder().decode(Answer.self, from: data))?.delivered ?? false
    }

    func signal(_ sealed: Data, to box: String, postToken: Data) async throws {
        var request = request("POST", "api/walkie/boxes/\(box)/signals")
        request.setValue("Bearer \(postToken.hex)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = sealed
        request.timeoutInterval = 10
        try await send(request)
    }

    struct Presence: Decodable, Sendable {
        let box: String
        let online: Bool
        let lastSeen: String?
    }

    func presence(of boxes: [(box: String, postToken: Data)]) async throws -> [Presence] {
        var request = request("POST", "api/walkie/presence")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "boxes": boxes.prefix(64).map { ["box": $0.box, "token": $0.postToken.hex] }
        ])
        struct Answer: Decodable { let boxes: [Presence] }
        return try await decode(Answer.self, request).boxes
    }

    // MARK: Inbox (mailbox secret)

    struct Waiting: Decodable, Sendable {
        let id: String
        let size: Int
    }

    func waiting(_ mailbox: MailboxKeys) async throws -> [Waiting] {
        var request = request("GET", "api/walkie/boxes/\(mailbox.box)/messages")
        request.setValue("Bearer \(mailbox.secret.hex)", forHTTPHeaderField: "Authorization")
        struct Answer: Decodable { let messages: [Waiting] }
        return try await decode(Answer.self, request).messages
    }

    func fetch(_ id: String, from mailbox: MailboxKeys) async throws -> Data {
        var request = request("GET", "api/walkie/boxes/\(mailbox.box)/messages/\(id)")
        request.setValue("Bearer \(mailbox.secret.hex)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120
        let (data, response) = try await session.data(for: request)
        try Self.check(data, response)
        return data
    }

    func delete(_ id: String, from mailbox: MailboxKeys) async throws {
        var request = request("DELETE", "api/walkie/boxes/\(mailbox.box)/messages/\(id)")
        request.setValue("Bearer \(mailbox.secret.hex)", forHTTPHeaderField: "Authorization")
        do {
            try await send(request)
        } catch Failure.server(404, _) {}
    }

    /// The listening socket's request; the secret goes in a header, never the URL.
    func listenRequest(_ mailbox: MailboxKeys) -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path += "/api/walkie/boxes/\(mailbox.box)/listen"
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(mailbox.secret.hex)", forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: Plumbing

    private func request(_ method: String, _ path: String) -> URLRequest {
        var request = URLRequest(url: URL(string: baseURL.absoluteString + "/" + path)!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        return request
    }

    private func send(_ request: URLRequest) async throws {
        let (data, response) = try await session.data(for: request)
        try Self.check(data, response)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        try Self.check(data, response)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(T.self, from: data)
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

/// Keeps a listening socket open, reconnecting with backoff, and reports what
/// arrives. Delivered on the main actor.
@MainActor
final class MailboxListener {
    enum Event {
        case message(id: String)
        case resync
        case signal(Data)
        case connected(Bool)
    }

    private let client: WalkieClient
    private let mailbox: MailboxKeys
    private let onEvent: @MainActor (Event) -> Void
    private var task: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?

    init(client: WalkieClient, mailbox: MailboxKeys, onEvent: @escaping @MainActor (Event) -> Void) {
        self.client = client
        self.mailbox = mailbox
        self.onEvent = onEvent
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            var backoff: UInt64 = 1
            while !Task.isCancelled {
                guard let self else { return }
                let connectedAt = Date()
                await self.runOnce()
                self.onEvent(.connected(false))
                // A socket that lived a while resets the backoff.
                backoff = Date().timeIntervalSince(connectedAt) > 30 ? 1 : min(backoff * 2, 60)
                try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func runOnce() async {
        let task = client.session.webSocketTask(with: client.listenRequest(mailbox))
        self.task = task
        task.resume()
        // A ping answered means the upgrade went through and the socket is live.
        let alive = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            task.sendPing { error in done.resume(returning: error == nil) }
        }
        guard alive, !Task.isCancelled else {
            task.cancel(with: .goingAway, reason: nil)
            return
        }
        onEvent(.connected(true))
        // Anything that came in while we were away.
        onEvent(.resync)
        while !Task.isCancelled {
            guard let message = try? await task.receive() else { break }
            switch message {
            case .string(let text):
                guard let data = text.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                switch json["type"] as? String {
                case "message": if let id = json["id"] as? String { onEvent(.message(id: id)) }
                default: onEvent(.resync)
                }
            case .data(let data):
                onEvent(.signal(data))
            @unknown default:
                break
            }
        }
        task.cancel(with: .goingAway, reason: nil)
    }
}
