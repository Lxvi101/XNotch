import Foundation
import Network
import os

/// How two devices reach each other, fastest first. When several are up,
/// the lowest `rawValue` wins.
public enum LinkRoute: Int, Comparable, CaseIterable, Codable, Sendable {
    /// A cable: the Mac reaches the phone through usbmuxd.
    case usb
    /// The same Wi-Fi network, or peer-to-peer Wi-Fi when the devices are near.
    case local
    /// Both connect out to the XNotch Cloud server, which relays encrypted bytes.
    case internet
    /// Bluetooth LE: slow, but needs no Wi-Fi at all.
    case bluetooth

    public static func < (lhs: LinkRoute, rhs: LinkRoute) -> Bool { lhs.rawValue < rhs.rawValue }

    public var title: String {
        switch self {
        case .usb: "USB"
        case .local: "Wi-Fi"
        case .internet: "Internet"
        case .bluetooth: "Bluetooth"
        }
    }

    public var symbol: String {
        switch self {
        case .usb: "cable.connector"
        case .local: "wifi"
        case .internet: "globe"
        case .bluetooth: "dot.radiowaves.left.and.right"
        }
    }
}

/// An ordered, reliable byte stream between two devices. `send` must keep
/// the order of its calls; `SecureChannel` calls it one at a time.
public protocol LinkTransport: AnyObject, Sendable {
    var route: LinkRoute { get }
    /// "Nearby" for peer-to-peer Wi-Fi, for display.
    var detail: String? { get }
    func send(_ data: Data) async throws
    /// Up to `maximum` bytes, at least one.
    func receive(upTo maximum: Int) async throws -> Data
    func close()
}

extension LinkTransport {
    public var detail: String? { nil }

    func receive(exactly count: Int) async throws -> Data {
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            data += try await receive(upTo: count - data.count)
        }
        return data
    }
}

public enum LinkNetwork {
    /// Plain TCP: `SecureChannel` encrypts. Peer-to-peer Wi-Fi is allowed,
    /// so devices near each other connect even without a shared network.
    public static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 8
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }
}

/// A TCP connection (or a Unix socket, for usbmuxd) through Network.framework.
public final class NetworkTransport: LinkTransport, @unchecked Sendable {
    public let connection: NWConnection
    public let route: LinkRoute
    private let queue = DispatchQueue(label: "dev.levi.XNotchLink.network")

    public init(_ connection: NWConnection, route: LinkRoute) {
        self.connection = connection
        self.route = route
    }

    public var detail: String? {
        guard route == .local, let path = connection.currentPath else { return nil }
        // awdl0 is the peer-to-peer Wi-Fi AirDrop uses.
        return path.availableInterfaces.first { path.usesInterfaceType($0.type) }?.name.hasPrefix("awdl") == true ? "Nearby" : nil
    }

    /// Starts the connection and waits until it's up.
    public func start(timeout: TimeInterval = 8) async throws {
        let once = Once()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let connection = self.connection
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        once.run { continuation.resume() }
                    case .failed(let error), .waiting(let error):
                        // Waiting means unreachable or refused: Network would retry forever, so stop it.
                        once.run {
                            connection.cancel()
                            continuation.resume(throwing: LinkError.connectionFailed(error.localizedDescription))
                        }
                    case .cancelled:
                        once.run { continuation.resume(throwing: LinkError.closed) }
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) {
                    once.run {
                        connection.cancel()
                        continuation.resume(throwing: LinkError.timedOut)
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    public func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: LinkError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func receive(upTo maximum: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: LinkError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume(throwing: isComplete ? LinkError.closed : LinkError.protocolViolation("Empty read"))
                }
            }
        }
    }

    public func close() {
        connection.cancel()
    }
}

/// Runs its block once, from any thread.
final class Once: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)

    func run(_ body: () -> Void) {
        let first = lock.withLock { done -> Bool in
            defer { done = true }
            return !done
        }
        if first { body() }
    }
}
