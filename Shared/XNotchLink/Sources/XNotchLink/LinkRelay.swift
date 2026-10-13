import Foundation

/// The internet route: both devices connect out to the XNotch Cloud server,
/// which pairs a phone with a waiting Mac and passes bytes between them. The
/// bytes are `SecureChannel` records, so the server can't read them.
public enum LinkRelay {
    public enum Role: String, Sendable {
        case mac, phone
    }

    /// 64 hex characters derived from the pairing key. Knowing it is what lets
    /// a device into the room, so only paired devices can.
    public static func room(for pairing: LinkPairing) -> String {
        pairing.tag("xnotch-link relay room").map { String(format: "%02x", $0) }.joined()
    }

    /// The Mac registers its room with the API token; phones need no token.
    public static func register(_ room: String, server: URL, token: String) async throws {
        var request = URLRequest(url: server.appendingPathComponent("api/relay/rooms/\(room)"))
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw LinkError.unavailable(status == 401 ? "The relay server didn't accept the access token."
                                                      : status == 404 ? "This server has the relay switched off."
                                                                      : "The relay server answered \(status).")
        }
    }

    public static func unregister(_ room: String, server: URL, token: String) async {
        var request = URLRequest(url: server.appendingPathComponent("api/relay/rooms/\(room)"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Opens a socket into the room. A Mac's socket returns once a phone has
    /// joined and spoken; a phone's returns as soon as it's open. A Mac's
    /// waiting socket gives up after `refreshAfter` with `LinkError.timedOut`,
    /// so a connection that died quietly never sits in the relay's pool long.
    public static func connect(_ room: String, server: URL, as role: Role,
                               refreshAfter: TimeInterval = 240) async throws -> WebSocketTransport {
        guard var components = URLComponents(url: server.appendingPathComponent("api/relay/rooms/\(room)/connect"),
                                             resolvingAgainstBaseURL: false) else { throw LinkError.unavailable("Bad relay URL") }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.queryItems = [URLQueryItem(name: "role", value: role.rawValue)]
        let transport = WebSocketTransport(url: components.url!)
        guard role == .mac else { return transport }
        let timer = Task {
            try await Task.sleep(nanoseconds: UInt64(refreshAfter * 1_000_000_000))
            transport.expire()
        }
        defer { timer.cancel() }
        try await transport.waitForFirstMessage()
        return transport
    }
}

/// A WebSocket as a byte stream.
public final class WebSocketTransport: LinkTransport, @unchecked Sendable {
    public let route = LinkRoute.internet
    private let task: URLSessionWebSocketTask
    private let lock = NSLock()
    private var buffer = Data()
    private var expired = false

    init(url: URL) {
        task = URLSession.shared.webSocketTask(with: url)
        task.maximumMessageSize = 9 << 20
        task.resume()
        keepAlive()
    }

    /// A ping every 20 seconds: a network that died quietly closes the
    /// socket instead of leaving a transfer waiting forever.
    private func keepAlive() {
        let task = self.task
        Task { [weak self] in
            while self != nil, task.state == .running {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard task.state == .running else { return }
                let answered = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    let once = Once()
                    task.sendPing { error in once.run { continuation.resume(returning: error == nil) } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 10) { once.run { continuation.resume(returning: false) } }
                }
                if !answered { task.cancel(with: .goingAway, reason: nil) }
            }
        }
    }

    /// Parks until the other side's first message, which proves it's there.
    func waitForFirstMessage() async throws {
        let first = try await nextMessage()
        lock.withLock { buffer += first }
    }

    public func send(_ data: Data) async throws {
        do {
            try await task.send(.data(data))
        } catch {
            throw failure(error)
        }
    }

    public func receive(upTo maximum: Int) async throws -> Data {
        if let buffered = take(maximum) { return buffered }
        let message = try await nextMessage()
        lock.withLock { buffer += message }
        return take(maximum) ?? Data()
    }

    public func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }

    /// Ends a wait that went on too long.
    func expire() {
        lock.withLock { expired = true }
        close()
    }

    private func take(_ maximum: Int) -> Data? {
        lock.withLock {
            guard !buffer.isEmpty else { return nil }
            let chunk = Data(buffer.prefix(maximum))
            buffer.removeFirst(chunk.count)
            return chunk
        }
    }

    private func nextMessage() async throws -> Data {
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                // A Mac's socket can wait for hours; cancelling closes it.
                message = try await withTaskCancellationHandler { try await task.receive() } onCancel: { [task] in
                    task.cancel(with: .goingAway, reason: nil)
                }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw failure(error)
            }
            switch message {
            case .data(let data) where !data.isEmpty: return data
            case .string(let text) where !text.isEmpty: return Data(text.utf8)
            default: continue
            }
        }
    }

    /// The server's close codes say why.
    private func failure(_ error: Error) -> LinkError {
        if lock.withLock({ expired }) { return .timedOut }
        switch task.closeCode.rawValue {
        case 4404: return .unavailable("The Mac isn't connected to the relay. Is XNotch running?")
        case 4503: return .unavailable("The relay is busy. Try again in a moment.")
        case 4409: return .closed
        default:
            if let response = task.response as? HTTPURLResponse, response.statusCode == 404 {
                return .unavailable("The relay doesn't know this Mac. Open XNotch on the Mac to set it up.")
            }
            return task.closeCode == .invalid ? .connectionFailed(error.localizedDescription) : .closed
        }
    }
}
