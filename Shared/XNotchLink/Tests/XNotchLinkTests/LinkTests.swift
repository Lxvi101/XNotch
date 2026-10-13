import Network
import XCTest
@testable import XNotchLink

final class LinkPairingTests: XCTestCase {
    func testPairingURLRoundTrips() throws {
        var pairing = LinkPairing(id: "mac-1", name: "Levi’s MacBook Pro", key: LinkPairing.generateKey())
        XCTAssertEqual(LinkPairing(url: pairing.url), pairing)
        pairing.relay = URL(string: "https://drop.example.com")
        XCTAssertEqual(LinkPairing(url: pairing.url)?.relay, pairing.relay)
    }

    func testPairingRejectsBadKeysAndSchemes() {
        XCTAssertNil(LinkPairing(url: URL(string: "xnotchlink://pair?v=1&id=a&name=b&key=c2hvcnQ")!))
        XCTAssertNil(LinkPairing(url: URL(string: "https://pair?v=1&id=a&name=b")!))
    }

    func testRelayRoomsAreSecretAndStable() {
        let pairing = LinkPairing(id: "a", name: "b", key: LinkPairing.generateKey())
        let room = LinkRelay.room(for: pairing)
        XCTAssertEqual(room.count, 64)
        XCTAssertEqual(room, LinkRelay.room(for: pairing))
        XCTAssertNotEqual(room, LinkRelay.room(for: LinkPairing(id: "a", name: "b", key: LinkPairing.generateKey())))
    }

    func testSafeFileNames() {
        XCTAssertEqual(linkSafeFileName("../../etc/passwd"), "passwd")
        XCTAssertEqual(linkSafeFileName(".hidden"), "hidden")
        XCTAssertEqual(linkSafeFileName("a\u{0}b.pdf"), "ab.pdf")
        XCTAssertEqual(linkSafeFileName(".."), "File")
    }

    func testUniqueURLNumbersTakenNames() throws {
        let directory = temporaryDirectory()
        FileManager.default.createFile(atPath: directory.appendingPathComponent("a.txt").path, contents: Data())
        XCTAssertEqual(linkUniqueURL(for: "a.txt", in: directory).lastPathComponent, "a 2.txt")
    }
}

final class SecureChannelTests: XCTestCase {
    func testSessionsRunOverTheSecureChannel() async throws {
        let pairing = LinkPairing(id: "mac-1", name: "Mac", key: LinkPairing.generateKey())
        let (a, b) = MemoryTransport.pair()
        let (macSession, phoneSession) = try await sessionPair(a, b, pairing: pairing)
        let relay = await phoneSession.peerRelay
        XCTAssertEqual(relay?.host, "relay.example.com", "The Mac's hello names its relay")
        try await exchange(macSession, phoneSession)
    }

    func testWrongKeyIsRefusedOnBothSides() async throws {
        let macPairing = LinkPairing(id: "mac-1", name: "Mac", key: LinkPairing.generateKey())
        let stale = LinkPairing(id: macPairing.id, name: macPairing.name, key: LinkPairing.generateKey())
        let (a, b) = MemoryTransport.pair()
        async let responder = SecureChannel.respond(over: a) { $0 == macPairing.id ? macPairing.key : nil }
        async let initiator = SecureChannel.initiate(over: b, pairing: stale)
        do {
            _ = try await initiator
            XCTFail("A stale key must not get through")
        } catch LinkError.rejected {}
        do {
            _ = try await responder
            XCTFail("The responder must not accept it either")
        } catch {}
    }

    func testUnknownPairingIDIsRefused() async throws {
        let pairing = LinkPairing(id: "mac-1", name: "Mac", key: LinkPairing.generateKey())
        let (a, b) = MemoryTransport.pair()
        async let responder = SecureChannel.respond(over: a) { _ in nil }
        async let initiator = SecureChannel.initiate(over: b, pairing: pairing)
        let outcomes = await (try? responder, try? initiator)
        XCTAssertNil(outcomes.0)
        XCTAssertNil(outcomes.1)
    }

    func testTamperedRecordsFailAuthentication() async throws {
        let pairing = LinkPairing(id: "mac-1", name: "Mac", key: LinkPairing.generateKey())
        let (a, b) = MemoryTransport.pair()
        async let responder = SecureChannel.respond(over: a) { _ in pairing.key }
        async let initiator = SecureChannel.initiate(over: b, pairing: pairing)
        let (macChannel, phoneChannel) = try await (responder, initiator)
        try await phoneChannel.send(Data("intact".utf8))
        let first = try await macChannel.receive()
        XCTAssertEqual(first, Data("intact".utf8))
        b.tamper = { data in
            var flipped = data
            flipped[flipped.count - 1] ^= 0x01
            return flipped
        }
        try await phoneChannel.send(Data("changed".utf8))
        do {
            _ = try await macChannel.receive()
            XCTFail("A flipped bit must fail authentication")
        } catch LinkError.protocolViolation {}
    }

    func testEachConnectionGetsFreshKeys() async throws {
        let pairing = LinkPairing(id: "mac-1", name: "Mac", key: LinkPairing.generateKey())
        var wire: [Data] = []
        for _ in 0..<2 {
            let (a, b) = MemoryTransport.pair()
            let captured = Capture()
            b.tamper = { data in captured.add(data); return data }
            async let responder = SecureChannel.respond(over: a) { _ in pairing.key }
            async let initiator = SecureChannel.initiate(over: b, pairing: pairing)
            let (_, phoneChannel) = try await (responder, initiator)
            let before = captured.data.count
            try await phoneChannel.send(Data("same plaintext".utf8))
            wire.append(captured.data.suffix(from: before))
        }
        XCTAssertNotEqual(wire[0], wire[1], "The same message under the same pairing must encrypt differently")
    }
}

final class TransportTests: XCTestCase {
    func testTCPWithBothDirectionsAtOnce() async throws {
        let pairing = LinkPairing(id: "mac-1", name: "Mac", key: LinkPairing.generateKey())
        let listener = try NWListener(using: LinkNetwork.parameters(), on: .any)
        let accepted = AsyncStream<NWConnection>.makeStream()
        listener.newConnectionHandler = { accepted.continuation.yield($0) }
        let ready = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .global())
        await fulfillment(of: [ready], timeout: 5)
        defer { listener.cancel() }

        let client = NetworkTransport(NWConnection(host: "127.0.0.1", port: listener.port!, using: LinkNetwork.parameters()), route: .local)
        async let started: Void = client.start()
        var iterator = accepted.stream.makeAsyncIterator()
        let server = NetworkTransport(await iterator.next()!, route: .local)
        async let serverStarted: Void = server.start()
        _ = try await (started, serverStarted)
        let (macSession, phoneSession) = try await sessionPair(server, client, pairing: pairing)
        try await exchange(macSession, phoneSession, bytes: 3_000_000)
    }

    /// Bluetooth's L2CAP channel hands over a stream pair; bound streams stand in for it.
    func testFoundationStreams() async throws {
        let pairing = LinkPairing(id: "mac-1", name: "Mac", key: LinkPairing.generateKey())
        var macIn: InputStream?, phoneOut: OutputStream?, phoneIn: InputStream?, macOut: OutputStream?
        Stream.getBoundStreams(withBufferSize: 64 * 1024, inputStream: &macIn, outputStream: &phoneOut)
        Stream.getBoundStreams(withBufferSize: 64 * 1024, inputStream: &phoneIn, outputStream: &macOut)
        let macEnd = StreamTransport(input: macIn!, output: macOut!, route: .bluetooth)
        let phoneEnd = StreamTransport(input: phoneIn!, output: phoneOut!, route: .bluetooth)
        let (macSession, phoneSession) = try await sessionPair(macEnd, phoneEnd, pairing: pairing)
        XCTAssertEqual(macSession.route, .bluetooth)
        try await exchange(macSession, phoneSession, bytes: 600_000)
        await macSession.close()
    }

    func testUSBMuxConnectsThroughTheDaemonProtocol() async throws {
        let pairing = LinkPairing(id: "mac-1", name: "Mac", key: LinkPairing.generateKey())
        // The phone's side, on loopback like on the device.
        let phoneSessions = AsyncStream<LinkSession>.makeStream()
        let acceptor = try LinkUSBAcceptor(pairings: { [pairing] }, as: { phone }, incomingDirectory: temporaryDirectory(),
                                           onSession: { phoneSessions.continuation.yield($0) })
        defer { acceptor.cancel() }
        // usbmuxd, faked: lists one USB device and forwards Connect to the loopback port.
        let fake = try FakeUSBMux(forwardingTo: LinkUSB.port)
        defer { fake.stop() }
        let mux = USBMux(socketPath: fake.path)

        var events = mux.devices().makeAsyncIterator()
        let event = try await events.next()
        XCTAssertEqual(event?.0.serial, "00008110-TEST")
        XCTAssertEqual(event?.attached, true)

        let transport = try await mux.connect(to: event!.0, port: LinkUSB.port)
        let macSession = try await LinkClient.open(transport, pairing: pairing, as: mac, incomingDirectory: temporaryDirectory())
        var iterator = phoneSessions.stream.makeAsyncIterator()
        let phoneSession = try await iterator.next()!
        XCTAssertEqual(macSession.route, .usb)
        try await exchange(phoneSession, macSession)
    }
}

final class LinkClientTests: XCTestCase {
    override func setUpWithError() throws {
        try skipWithoutBonjour()
    }

    /// A Mac advertising on Bonjour, accepting with the pairing key.
    private func advertise(_ pairing: LinkPairing) throws -> NWListener {
        let listener = try NWListener(using: LinkNetwork.parameters())
        listener.service = NWListener.Service(name: "XNotchLink Test \(pairing.id.prefix(6))", type: LinkService.type,
                                              txtRecord: NWTXTRecord([LinkService.idKey: pairing.id]))
        listener.newConnectionHandler = { connection in
            Task {
                let transport = NetworkTransport(connection, route: .local)
                try await transport.start()
                let session = try await LinkClient.accept(transport, as: mac, incomingDirectory: temporaryDirectory()) { _ in pairing.key }
                await session.run { _ in }
            }
        }
        listener.start(queue: .global())
        return listener
    }

    func testFindsAndConnectsToTheAdvertisedMac() async throws {
        let pairing = LinkPairing(id: UUID().uuidString, name: "Test Mac", key: LinkPairing.generateKey())
        let listener = try advertise(pairing)
        defer { listener.cancel() }
        let session = try await LinkClient.connectLocal(to: pairing, as: phone, incomingDirectory: temporaryDirectory(), timeout: 10)
        let peer = await session.peer
        XCTAssertEqual(peer?.name, "Mac")
        Task { await session.run { _ in } }
        try await session.sendText("found you")
        await session.close()
    }

    func testTheRacePicksWhatConnects() async throws {
        let pairing = LinkPairing(id: UUID().uuidString, name: "Test Mac", key: LinkPairing.generateKey(),
                                  relay: URL(string: "http://127.0.0.1:9"))
        let listener = try advertise(pairing)
        defer { listener.cancel() }
        let session = try await LinkClient.connectBest(to: pairing, as: phone, incomingDirectory: temporaryDirectory(),
                                                       routes: [.usb, .local, .internet], timeout: 10)
        XCTAssertEqual(session.route, .local)
        await session.close()
    }

    func testMissingMacTimesOut() async {
        let pairing = LinkPairing(id: UUID().uuidString, name: "Nowhere", key: LinkPairing.generateKey())
        do {
            _ = try await LinkClient.find(pairing, timeout: 1.5)
            XCTFail("Nothing advertises this ID")
        } catch LinkError.notFound(let name) {
            XCTAssertEqual(name, "Nowhere")
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }
}

/// Through a running XNotch Cloud server with the relay:
/// RELAY_TEST_URL=http://127.0.0.1:8787 RELAY_TEST_TOKEN=… swift test
final class RelayTests: XCTestCase {
    private var server: URL!
    private var token: String!

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["RELAY_TEST_URL"].flatMap(URL.init(string:)), let token = environment["RELAY_TEST_TOKEN"] else {
            throw XCTSkip("Set RELAY_TEST_URL and RELAY_TEST_TOKEN to run against a server")
        }
        self.server = server
        self.token = token
    }

    func testPhoneAndMacMeetThroughTheRelay() async throws {
        let pairing = LinkPairing(id: UUID().uuidString, name: "Relay Mac", key: LinkPairing.generateKey(), relay: server)
        let room = LinkRelay.room(for: pairing)
        try await LinkRelay.register(room, server: server, token: token)
        let server = self.server!
        let macSide = Task {
            let transport = try await LinkRelay.connect(room, server: server, as: .mac)
            return try await LinkClient.accept(transport, as: mac, incomingDirectory: temporaryDirectory()) { _ in pairing.key }
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let phoneSession = try await LinkClient.connectInternet(to: pairing, as: phone, incomingDirectory: temporaryDirectory())
        let macSession = try await macSide.value
        XCTAssertEqual(phoneSession.route, .internet)
        try await exchange(macSession, phoneSession, bytes: 2_000_000)
        await LinkRelay.unregister(room, server: server, token: token)
    }

    func testTheMacRefreshesItsWaitingSocket() async throws {
        let pairing = LinkPairing(id: UUID().uuidString, name: "Idle Mac", key: LinkPairing.generateKey(), relay: server)
        let room = LinkRelay.room(for: pairing)
        try await LinkRelay.register(room, server: server, token: token)
        do {
            _ = try await LinkRelay.connect(room, server: server, as: .mac, refreshAfter: 1)
            XCTFail("No phone came, so the wait must end")
        } catch LinkError.timedOut {}
        await LinkRelay.unregister(room, server: server, token: token)
    }

    func testPhoneWithoutAMacIsToldSo() async throws {
        let pairing = LinkPairing(id: UUID().uuidString, name: "Away Mac", key: LinkPairing.generateKey(), relay: server)
        try await LinkRelay.register(LinkRelay.room(for: pairing), server: server, token: token)
        do {
            _ = try await LinkClient.connectInternet(to: pairing, as: phone, incomingDirectory: temporaryDirectory())
            XCTFail("No Mac is waiting")
        } catch LinkError.unavailable(let reason) {
            XCTAssertTrue(reason.contains("isn't connected"), reason)
        }
    }
}

private final class Capture: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func add(_ data: Data) { lock.withLock { bytes += data } }
    var data: Data { lock.withLock { bytes } }
}
