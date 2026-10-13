import Foundation
import Network

/// What a connection attempt is doing, to show it as it happens.
public enum LinkProgress: Sendable, Equatable {
    case searching(LinkRoute)
    /// iOS is asking for Local Network access; the search waits for the answer.
    case waitingForLocalNetwork
    /// The Mac answered; the secure handshake is running.
    case securing(LinkRoute)
}

public typealias LinkProgressHandler = @Sendable (LinkProgress) -> Void

/// Opening sessions over each route, and the phone's race between them.
public enum LinkClient {
    private static let queue = DispatchQueue(label: "dev.levi.XNotchLink.browser")

    // MARK: Sessions on a transport

    /// The connecting side of any transport.
    public static func open(_ transport: LinkTransport, pairing: LinkPairing, as device: LinkDevice,
                            incomingDirectory: URL, relay: URL? = nil) async throws -> LinkSession {
        let channel = try await SecureChannel.initiate(over: transport, pairing: pairing)
        let session = LinkSession(channel: channel, incomingDirectory: incomingDirectory)
        do {
            try await session.handshake(as: device, isInitiator: true, relay: relay)
        } catch {
            await session.close()
            throw error
        }
        return session
    }

    /// The accepting side: `key` finds the pairing key for an ID, nil refuses.
    public static func accept(_ transport: LinkTransport, as device: LinkDevice, incomingDirectory: URL, relay: URL? = nil,
                              key: @escaping @Sendable (String) -> Data?) async throws -> LinkSession {
        let channel = try await SecureChannel.respond(over: transport, key: key)
        let session = LinkSession(channel: channel, incomingDirectory: incomingDirectory)
        do {
            try await session.handshake(as: device, isInitiator: false, relay: relay)
        } catch {
            await session.close()
            throw error
        }
        return session
    }

    // MARK: Routes from the phone

    /// The same network, or peer-to-peer Wi-Fi nearby: Bonjour finds the Mac.
    public static func connectLocal(to pairing: LinkPairing, as device: LinkDevice, incomingDirectory: URL,
                                    timeout: TimeInterval = 8, progress: LinkProgressHandler? = nil) async throws -> LinkSession {
        progress?(.searching(.local))
        let endpoint = try await find(pairing, timeout: timeout, progress: progress)
        let transport = NetworkTransport(NWConnection(to: endpoint, using: LinkNetwork.parameters()), route: .local)
        try await transport.start(timeout: timeout)
        progress?(.securing(.local))
        return try await open(transport, pairing: pairing, as: device, incomingDirectory: incomingDirectory)
    }

    /// Through the Mac's relay server.
    public static func connectInternet(to pairing: LinkPairing, as device: LinkDevice,
                                       incomingDirectory: URL, progress: LinkProgressHandler? = nil) async throws -> LinkSession {
        guard let relay = pairing.relay else {
            throw LinkError.unavailable("\(pairing.name) has no relay server set up for the internet.")
        }
        progress?(.searching(.internet))
        let transport = try await LinkRelay.connect(LinkRelay.room(for: pairing), server: relay, as: .phone)
        progress?(.securing(.internet))
        return try await open(transport, pairing: pairing, as: device, incomingDirectory: incomingDirectory)
    }

    public static func connectBluetooth(to pairing: LinkPairing, as device: LinkDevice,
                                        incomingDirectory: URL, progress: LinkProgressHandler? = nil) async throws -> LinkSession {
        progress?(.searching(.bluetooth))
        let transport = try await LinkBluetoothCentral.connect(to: pairing)
        progress?(.securing(.bluetooth))
        return try await open(transport, pairing: pairing, as: device, incomingDirectory: incomingDirectory)
    }

    /// Whatever connects first, with the faster routes given a head start:
    /// USB and Wi-Fi at once, the internet after a second, Bluetooth after
    /// three. For one-off sends, like the Share extension's.
    public static func connectBest(to pairing: LinkPairing, as device: LinkDevice, incomingDirectory: URL,
                                   routes: Set<LinkRoute> = Set(LinkRoute.allCases), timeout: TimeInterval = 15,
                                   progress: LinkProgressHandler? = nil) async throws -> LinkSession {
        typealias Attempt = (route: LinkRoute, delay: Double, open: @Sendable () async throws -> LinkSession)
        var attempts: [Attempt] = []
        if routes.contains(.local) {
            attempts.append((.local, 0, { try await connectLocal(to: pairing, as: device, incomingDirectory: incomingDirectory, timeout: timeout, progress: progress) }))
        }
        if routes.contains(.usb) {
            attempts.append((.usb, 0, { try await LinkUSBAcceptor.acceptOnce(pairings: [pairing], as: device, incomingDirectory: incomingDirectory, timeout: timeout) }))
        }
        if routes.contains(.internet), pairing.relay != nil {
            attempts.append((.internet, 1, { try await connectInternet(to: pairing, as: device, incomingDirectory: incomingDirectory, progress: progress) }))
        }
        if routes.contains(.bluetooth) {
            attempts.append((.bluetooth, 3, { try await connectBluetooth(to: pairing, as: device, incomingDirectory: incomingDirectory, progress: progress) }))
        }
        let race = Race(count: attempts.count)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LinkSession, Error>) in
                race.begin(continuation, fallback: LinkError.notFound(pairing.name))
                for attempt in attempts {
                    race.add(Task {
                        do {
                            if attempt.delay > 0 { try await Task.sleep(nanoseconds: UInt64(attempt.delay * 1_000_000_000)) }
                            race.won(try await attempt.open())
                        } catch {
                            race.lost(attempt.route, error)
                        }
                    })
                }
            }
        } onCancel: {
            race.cancel()
        }
    }

    // MARK: Bonjour

    /// Browses Bonjour until the Mac with this pairing's ID shows up. While
    /// iOS asks for Local Network access the search waits up to 20 seconds
    /// longer for the answer instead of timing out underneath the prompt.
    public static func find(_ pairing: LinkPairing, timeout: TimeInterval,
                            progress: LinkProgressHandler? = nil) async throws -> NWEndpoint {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: LinkService.type, domain: nil), using: parameters)
        let once = Once()
        let denied = Flag()
        let deniedNow = Flag()
        let extended = Flag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NWEndpoint, Error>) in
                browser.browseResultsChangedHandler = { results, _ in
                    let match = results.first { result in
                        if case .bonjour(let record) = result.metadata { return record[LinkService.idKey] == pairing.id }
                        return false
                    }
                    guard let match else { return }
                    once.run {
                        browser.cancel()
                        continuation.resume(returning: match.endpoint)
                    }
                }
                browser.stateUpdateHandler = { state in
                    switch state {
                    case .failed(let error):
                        once.run {
                            browser.cancel()
                            continuation.resume(throwing: LinkError.connectionFailed(error.localizedDescription))
                        }
                    case .waiting(let error):
                        // Also the state while iOS asks for Local Network access: keep waiting.
                        if case .dns(let code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
                            denied.set()
                            deniedNow.set()
                            progress?(.waitingForLocalNetwork)
                        }
                    case .ready:
                        if deniedNow.isSet {
                            deniedNow.clear()
                            progress?(.searching(.local))
                        }
                    case .cancelled:
                        once.run { continuation.resume(throwing: CancellationError()) }
                    default:
                        break
                    }
                }
                browser.start(queue: queue)
                @Sendable func expire() {
                    if deniedNow.isSet, !extended.isSet {
                        extended.set()
                        queue.asyncAfter(deadline: .now() + 20, execute: expire)
                        return
                    }
                    once.run {
                        browser.cancel()
                        continuation.resume(throwing: denied.isSet ? LinkError.localNetworkDenied : LinkError.notFound(pairing.name))
                    }
                }
                queue.asyncAfter(deadline: .now() + timeout, execute: expire)
            }
        } onCancel: {
            browser.cancel()
        }
    }
}

/// The phone's end of the USB route: the Mac connects in through usbmuxd.
public final class LinkUSBAcceptor: @unchecked Sendable {
    private let listener: NWListener
    /// Calls `onSession` for each Mac that connects and proves its pairing.
    public init(pairings: @escaping @Sendable () -> [LinkPairing], as device: @escaping @Sendable () -> LinkDevice,
                incomingDirectory: URL, onSession: @escaping @Sendable (LinkSession) -> Void,
                onFailure: (@Sendable (Error) -> Void)? = nil) throws {
        listener = try LinkUSB.listener()
        listener.newConnectionHandler = { connection in
            Task {
                let transport = NetworkTransport(connection, route: .usb)
                do {
                    try await transport.start()
                    let known = pairings()
                    let session = try await LinkClient.accept(transport, as: device(), incomingDirectory: incomingDirectory) { id in
                        known.first { $0.id == id }?.key
                    }
                    onSession(session)
                } catch {
                    transport.close()
                }
            }
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state { onFailure?(error) }
        }
        listener.start(queue: DispatchQueue(label: "dev.levi.XNotchLink.usb"))
    }

    public func cancel() {
        listener.cancel()
    }

    /// Waits for one Mac to connect over USB.
    static func acceptOnce(pairings: [LinkPairing], as device: LinkDevice, incomingDirectory: URL,
                           timeout: TimeInterval) async throws -> LinkSession {
        let waiter = AcceptWaiter()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LinkSession, Error>) in
                waiter.begin(continuation)
                do {
                    waiter.acceptor = try LinkUSBAcceptor(pairings: { pairings }, as: { device }, incomingDirectory: incomingDirectory,
                                                          onSession: { waiter.finish(.success($0)) },
                                                          onFailure: { waiter.finish(.failure(LinkError.unavailable($0.localizedDescription))) })
                } catch {
                    waiter.finish(.failure(error))
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    waiter.finish(.failure(LinkError.unavailable("No USB connection")))
                }
            }
        } onCancel: {
            waiter.finish(.failure(CancellationError()))
        }
    }
}

/// One USB acceptance: the first outcome wins, and the listener stops.
private final class AcceptWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<LinkSession, Error>?
    private var cancelled = false
    var acceptor: LinkUSBAcceptor? {
        didSet { if lock.withLock({ continuation == nil && cancelled }) { acceptor?.cancel() } }
    }

    func begin(_ continuation: CheckedContinuation<LinkSession, Error>) {
        let resumeNow = lock.withLock { () -> Bool in
            if cancelled { return true }
            self.continuation = continuation
            return false
        }
        if resumeNow { continuation.resume(throwing: CancellationError()) }
    }

    func finish(_ result: Result<LinkSession, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<LinkSession, Error>? in
            cancelled = true
            defer { self.continuation = nil }
            return self.continuation
        }
        acceptor?.cancel()
        guard let continuation else {
            if case .success(let late) = result { Task { await late.close() } }
            return
        }
        continuation.resume(with: result)
    }
}

/// The first session wins; later ones are closed. When every route
/// fails, the fastest route's error says the most.
private final class Race: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var continuation: CheckedContinuation<LinkSession, Error>?
    private var fallback: Error = LinkError.closed
    private var errors: [(LinkRoute, Error)] = []
    private var tasks: [Task<Void, Never>] = []

    init(count: Int) {
        remaining = count
    }

    func begin(_ continuation: CheckedContinuation<LinkSession, Error>, fallback: Error) {
        lock.withLock {
            self.continuation = continuation
            self.fallback = fallback
        }
        if remaining == 0 { finish(.failure(fallback)) }
    }

    func add(_ task: Task<Void, Never>) {
        lock.withLock { tasks.append(task) }
    }

    func won(_ session: LinkSession) {
        guard finish(.success(session)) else {
            Task { await session.close() }
            return
        }
    }

    func lost(_ route: LinkRoute, _ error: Error) {
        let last: Bool = lock.withLock {
            errors.append((route, error))
            remaining -= 1
            return remaining == 0
        }
        guard last else { return }
        let best: Error = lock.withLock {
            // USB's "nothing connected" says nothing useful when there's no cable.
            errors.filter { $0.0 != .usb }.min { $0.0 < $1.0 }?.1 ?? errors.first?.1 ?? fallback
        }
        finish(.failure(best))
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    /// Resumes once; the other attempts are cancelled.
    @discardableResult
    private func finish(_ result: Result<LinkSession, Error>) -> Bool {
        let (continuation, tasks) = lock.withLock { () -> (CheckedContinuation<LinkSession, Error>?, [Task<Void, Never>]) in
            defer { self.continuation = nil }
            return (self.continuation, self.tasks)
        }
        guard let continuation else { return false }
        tasks.forEach { $0.cancel() }
        continuation.resume(with: result)
        return true
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() { lock.withLock { value = true } }
    func clear() { lock.withLock { value = false } }
    var isSet: Bool { lock.withLock { value } }
}
