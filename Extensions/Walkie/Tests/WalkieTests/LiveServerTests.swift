import XCTest
@testable import Walkie

/// Two Macs talking through a real XNotch Cloud server. Runs only when
/// `WALKIE_TEST_SERVER` and `WALKIE_TEST_TOKEN` point at one, e.g.
///
///     PUBLIC_URL=http://localhost:18787 API_TOKEN=test-token-0123456789 PORT=18787 \
///       DATA_DIR=$(mktemp -d) cargo run --manifest-path Server/Cargo.toml
///     WALKIE_TEST_SERVER=http://localhost:18787 WALKIE_TEST_TOKEN=test-token-0123456789 swift test
final class LiveServerTests: XCTestCase {
    private var server: String!
    private var token: String!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["WALKIE_TEST_SERVER"], let token = env["WALKIE_TEST_TOKEN"] else {
            throw XCTSkip("set WALKIE_TEST_SERVER and WALKIE_TEST_TOKEN to run against a live server")
        }
        self.server = server
        self.token = token
    }

    private struct Mac {
        let name: String
        let identity: WalkieCrypto.Identity
        let mailbox: MailboxKeys
        let card: WalkieCrypto.SignedCard

        init(name: String, server: String) throws {
            self.name = name
            identity = try .generate()
            mailbox = .generate()
            card = try .make(WalkieCrypto.Card(name: name, avatar: nil, server: server, box: mailbox.box,
                                               keys: identity.publicKeys, created: Date()), identity: identity)
        }

        var invite: WalkieInvite {
            WalkieInvite(server: card.serverURL, box: mailbox.box, postToken: mailbox.postToken,
                         fingerprint: identity.publicKeys.fingerprint)
        }
    }

    @MainActor
    func testVoiceNoteTravelsSealedAndArrivesLive() async throws {
        let client = try XCTUnwrap(WalkieClient(server: server))
        let alice = try Mac(name: "Alice", server: server)
        let bob = try Mac(name: "Bob", server: server)
        try await client.register(alice.mailbox, card: alice.card.base64, listed: false, apiToken: token)
        try await client.register(bob.mailbox, card: bob.card.base64, listed: true, apiToken: token)

        // Bob listens.
        let arrived = expectation(description: "message notice")
        let talking = expectation(description: "talking signal")
        var noticeID: String?
        var signal: Data?
        let listener = MailboxListener(client: client, mailbox: bob.mailbox) { event in
            switch event {
            case .message(let id): noticeID = id; arrived.fulfill()
            case .signal(let data): signal = data; talking.fulfill()
            default: break
            }
        }
        listener.start()
        defer { listener.stop() }
        try await waitUntilOnline(client, bob)

        // Alice adds Bob from his invite: the fetched card must match its fingerprint.
        let invite = try XCTUnwrap(WalkieInvite(text: "here: \(bob.invite.text)"))
        let encodedCard = try await client.card(box: invite.box, postToken: invite.postToken)
        let fetched = try XCTUnwrap(WalkieCrypto.SignedCard(base64: encodedCard))
        let bobCard = try fetched.open(expecting: invite.fingerprint)
        XCTAssertEqual(bobCard.name, "Bob")

        // The directory lists Bob (he opted in) but not Alice.
        let listed = try await client.directory(apiToken: token)
        XCTAssertTrue(listed.contains { $0.box == bob.mailbox.box })
        XCTAssertFalse(listed.contains { $0.box == alice.mailbox.box })

        // "Alice is talking…", then the note itself.
        var hold = WireMessage(kind: .talking)
        hold.active = true
        try await client.signal(try WalkieCrypto.seal(try WireCodec.encode(hold), from: alice.identity,
                                                      senderBox: alice.mailbox.box, to: bobCard.keys,
                                                      recipientBox: bobCard.box),
                                to: bobCard.box, postToken: invite.postToken)
        await fulfillment(of: [talking], timeout: 5)
        let openedSignal = try WalkieCrypto.open(try XCTUnwrap(signal), as: bob.identity, recipientBox: bob.mailbox.box)
        XCTAssertTrue(openedSignal.verify(with: alice.identity.publicKeys))

        var note = WireMessage(kind: .voice)
        note.duration = 2.4
        note.levels = [10, 200, 90]
        note.text = "Lunch at one?"
        note.intro = .init(card: alice.card.base64, postToken: alice.mailbox.postToken.hex)
        let audio = Data((0..<40_000).map { UInt8($0 % 251) })
        let sealed = try WalkieCrypto.seal(try WireCodec.encode(note, attachments: [audio]), from: alice.identity,
                                           senderBox: alice.mailbox.box, to: bobCard.keys, recipientBox: bobCard.box)
        let delivered = try await client.post(sealed, to: bobCard.box, postToken: invite.postToken)
        XCTAssertTrue(delivered, "Bob was listening")
        await fulfillment(of: [arrived], timeout: 5)

        // Bob fetches, opens, learns who Alice is from her signed intro, and checks it's really her.
        let waiting = try await client.waiting(bob.mailbox)
        XCTAssertEqual(waiting.map(\.id), [try XCTUnwrap(noticeID)])
        let bytes = try await client.fetch(waiting[0].id, from: bob.mailbox)
        XCTAssertEqual(bytes, sealed, "the server stored exactly the sealed bytes")
        let opened = try WalkieCrypto.open(bytes, as: bob.identity, recipientBox: bob.mailbox.box)
        let (message, attachments) = try WireCodec.decode(opened.body)
        let introCard = try XCTUnwrap(WalkieCrypto.SignedCard(base64: try XCTUnwrap(message.intro?.card))).open()
        XCTAssertEqual(introCard.box, opened.senderBox)
        XCTAssertTrue(opened.verify(with: introCard.keys))
        XCTAssertEqual(message.text, "Lunch at one?")
        XCTAssertEqual(attachments, [audio])
        try await client.delete(waiting[0].id, from: bob.mailbox)
        let afterDelete = try await client.waiting(bob.mailbox)
        XCTAssertTrue(afterDelete.isEmpty)

        // Bob can now reply with the token Alice introduced, and nobody else's token works.
        let replyToken = try XCTUnwrap(Data(hex: try XCTUnwrap(message.intro?.postToken)))
        let reply = try WalkieCrypto.seal(try WireCodec.encode(WireMessage(kind: .text)), from: bob.identity,
                                          senderBox: bob.mailbox.box, to: introCard.keys, recipientBox: introCard.box)
        try await client.post(reply, to: alice.mailbox.box, postToken: replyToken)
        do {
            try await client.post(reply, to: alice.mailbox.box, postToken: bob.mailbox.postToken)
            XCTFail("a wrong send token must be refused")
        } catch WalkieClient.Failure.server(let status, _) {
            XCTAssertEqual(status, 401)
        }

        try await client.unregister(alice.mailbox, apiToken: token)
        try await client.unregister(bob.mailbox, apiToken: token)
    }

    @MainActor
    private func waitUntilOnline(_ client: WalkieClient, _ mac: Mac) async throws {
        for _ in 0..<50 {
            let presence = try await client.presence(of: [(mac.mailbox.box, mac.mailbox.postToken)])
            if presence.first?.online == true { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("\(mac.name) never came online")
    }
}

private extension WalkieCrypto.SignedCard {
    var serverURL: String { ((try? open())?.server) ?? "" }
}
