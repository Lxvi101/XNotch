import Foundation
import Network
import XCTest
@testable import XNotchLink

/// Skips where Bonjour may be unavailable (GitHub's runners).
func skipWithoutBonjour() throws {
    if ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != nil {
        throw XCTSkip("Bonjour discovery isn't reliable on CI runners")
    }
}

let mac = LinkDevice(id: "mac", name: "Mac", kind: .mac)
let phone = LinkDevice(id: "phone", name: "iPhone", kind: .iPhone)

func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func testFile(bytes: Int) throws -> URL {
    let url = temporaryDirectory().appendingPathComponent("\(UUID().uuidString).bin")
    try Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: url)
    return url
}

/// Two ends of an in-memory pipe. `tamper` rewrites bytes in flight.
final class MemoryTransport: LinkTransport, @unchecked Sendable {
    let route: LinkRoute
    private let lock = NSLock()
    private var buffer = Data()
    private var waiter: (Int, CheckedContinuation<Data, Error>)?
    private var closed = false
    weak var other: MemoryTransport?
    var tamper: ((Data) -> Data)?

    init(route: LinkRoute = .local) {
        self.route = route
    }

    static func pair(route: LinkRoute = .local) -> (MemoryTransport, MemoryTransport) {
        let a = MemoryTransport(route: route), b = MemoryTransport(route: route)
        a.other = b
        b.other = a
        return (a, b)
    }

    func send(_ data: Data) async throws {
        guard let other, !lock.withLock({ closed }) else { throw LinkError.closed }
        other.deliver(tamper?(data) ?? data)
    }

    private func deliver(_ data: Data) {
        let resume: (CheckedContinuation<Data, Error>, Data)? = lock.withLock {
            buffer += data
            guard let (maximum, continuation) = waiter else { return nil }
            waiter = nil
            let chunk = Data(buffer.prefix(maximum))
            buffer.removeFirst(chunk.count)
            return (continuation, chunk)
        }
        if let (continuation, chunk) = resume { continuation.resume(returning: chunk) }
    }

    func receive(upTo maximum: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let ready: Result<Data, Error>? = lock.withLock {
                if !buffer.isEmpty {
                    let chunk = Data(buffer.prefix(maximum))
                    buffer.removeFirst(chunk.count)
                    return .success(chunk)
                }
                if closed { return .failure(LinkError.closed) }
                waiter = (maximum, continuation)
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }

    func close() {
        let pending = lock.withLock { () -> CheckedContinuation<Data, Error>? in
            closed = true
            defer { waiter = nil }
            return waiter?.1
        }
        pending?.resume(throwing: LinkError.closed)
        if let other, !other.lock.withLock({ other.closed }) { other.close() }
    }
}

/// A Mac-side session and a phone-side session over any transport pair.
func sessionPair(_ macEnd: LinkTransport, _ phoneEnd: LinkTransport,
                 pairing: LinkPairing) async throws -> (mac: LinkSession, phone: LinkSession) {
    let directory = temporaryDirectory()
    async let accepted = LinkClient.accept(macEnd, as: mac, incomingDirectory: directory.appendingPathComponent("mac"),
                                           relay: URL(string: "https://relay.example.com")) { id in
        id == pairing.id ? pairing.key : nil
    }
    async let opened = LinkClient.open(phoneEnd, pairing: pairing, as: phone, incomingDirectory: directory.appendingPathComponent("phone"))
    return try await (accepted, opened)
}

actor Received {
    var items: [String: Data] = [:]

    func add(_ side: String, _ item: LinkSession.Incoming) {
        switch item {
        case .file(let url, let name): items["\(side):\(name)"] = try? Data(contentsOf: url)
        case .text(let text): items["\(side):text"] = Data(text.utf8)
        }
    }
}

/// Sends a file and text each way at once, and checks they all arrive intact.
func exchange(_ macSession: LinkSession, _ phoneSession: LinkSession, bytes: Int = 1_200_000) async throws {
    let received = Received()
    Task { await macSession.run { await received.add("mac", $0) } }
    Task { await phoneSession.run { await received.add("phone", $0) } }
    let toMac = try testFile(bytes: bytes)
    let toPhone = try testFile(bytes: bytes / 2 + 7)
    async let a: Void = phoneSession.sendFile(toMac, name: "photo.heic")
    async let b: Void = macSession.sendFile(toPhone, name: "notes.pdf")
    async let c: Void = phoneSession.sendText("hello from the phone")
    _ = try await (a, b, c)
    let items = await received.items
    XCTAssertEqual(items["mac:photo.heic"], try Data(contentsOf: toMac))
    XCTAssertEqual(items["phone:notes.pdf"], try Data(contentsOf: toPhone))
    XCTAssertEqual(items["mac:text"], Data("hello from the phone".utf8))
}

/// usbmuxd's plist protocol on a Unix socket: lists one USB iPhone, and on
/// Connect forwards the socket to a loopback TCP port, as the real daemon
/// forwards it over the cable to the phone.
final class FakeUSBMux: @unchecked Sendable {
    let path = "/tmp/xnl-\(UUID().uuidString.prefix(8)).sock"
    private let server: Int32
    private let port: UInt16

    init(forwardingTo port: UInt16) throws {
        self.port = port
        unlink(path)
        server = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            _ = path.withCString { strncpy(buffer.baseAddress!.assumingMemoryBound(to: CChar.self), $0, buffer.count - 1) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(server, 8) == 0 else { throw LinkError.unavailable("Can't bind \(path)") }
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(server, nil, nil)
                guard client >= 0 else { return }
                Thread.detachNewThread { self.serve(client) }
            }
        }
    }

    func stop() {
        close(server)
        unlink(path)
    }

    private func serve(_ client: Int32) {
        guard let message = readPacket(client) else { close(client); return }
        switch message["MessageType"] as? String {
        case "Listen":
            writePacket(client, ["MessageType": "Result", "Number": 0])
            writePacket(client, ["MessageType": "Attached", "DeviceID": 7,
                                 "Properties": ["ConnectionType": "USB", "DeviceID": 7, "SerialNumber": "00008110-TEST"]])
            var byte: UInt8 = 0
            _ = read(client, &byte, 1) // Hold the listen socket open until the client goes.
            close(client)
        case "Connect":
            let requested = UInt16(truncatingIfNeeded: message["PortNumber"] as? Int ?? 0).byteSwapped
            let device = socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = requested.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(device, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard requested == port, connected == 0 else {
                writePacket(client, ["MessageType": "Result", "Number": 3])
                close(client)
                return
            }
            writePacket(client, ["MessageType": "Result", "Number": 0])
            Thread.detachNewThread { Self.pipe(from: client, to: device) }
            Self.pipe(from: device, to: client)
        default:
            close(client)
        }
    }

    private static func pipe(from source: Int32, to destination: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(source, &buffer, buffer.count)
            guard count > 0 else { break }
            var offset = 0
            while offset < count {
                let written = buffer[offset..<count].withUnsafeBytes { write(destination, $0.baseAddress, count - offset) }
                guard written > 0 else { return }
                offset += written
            }
        }
        shutdown(destination, SHUT_WR)
    }

    private func readPacket(_ socket: Int32) -> [String: Any]? {
        var header = [UInt8](repeating: 0, count: 16)
        guard readFully(socket, &header, 16) else { return nil }
        let length = Int(header[0]) | Int(header[1]) << 8 | Int(header[2]) << 16 | Int(header[3]) << 24
        var body = [UInt8](repeating: 0, count: length - 16)
        guard readFully(socket, &body, body.count) else { return nil }
        return try? PropertyListSerialization.propertyList(from: Data(body), format: nil) as? [String: Any]
    }

    private func writePacket(_ socket: Int32, _ message: [String: Any]) {
        let body = try! PropertyListSerialization.data(fromPropertyList: message, format: .xml, options: 0)
        var packet = Data()
        for value in [UInt32(16 + body.count), 1, 8, 1] {
            var little = value.littleEndian
            packet += Data(bytes: &little, count: 4)
        }
        packet += body
        _ = packet.withUnsafeBytes { write(socket, $0.baseAddress, packet.count) }
    }

    private func readFully(_ socket: Int32, _ buffer: inout [UInt8], _ count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let got = buffer.withUnsafeMutableBytes { read(socket, $0.baseAddress! + offset, count - offset) }
            guard got > 0 else { return false }
            offset += got
        }
        return true
    }
}
