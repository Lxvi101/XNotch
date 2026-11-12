import CryptoKit
import XCTest
@testable import Walkie

final class WalkieCryptoTests: XCTestCase {
    private struct Party {
        let identity: WalkieCrypto.Identity
        let mailbox: MailboxKeys
        var box: String { mailbox.box }
        var keys: WalkieCrypto.PublicKeys { identity.publicKeys }

        static func make() throws -> Party {
            Party(identity: try .generate(), mailbox: .generate())
        }
    }

    func testSealsAndOpensBetweenTwoParties() throws {
        let (alice, bob) = (try Party.make(), try Party.make())
        let body = Data("hello over the notch".utf8)
        let sealed = try WalkieCrypto.seal(body, from: alice.identity, senderBox: alice.box, to: bob.keys,
                                           recipientBox: bob.box)
        XCTAssertNil(sealed.range(of: body), "the body is not readable in the envelope")
        let opened = try WalkieCrypto.open(sealed, as: bob.identity, recipientBox: bob.box)
        XCTAssertEqual(opened.senderBox, alice.box)
        XCTAssertEqual(opened.body, body)
        XCTAssertTrue(opened.verify(with: alice.keys))
        XCTAssertFalse(opened.verify(with: bob.keys), "someone else's keys don't vouch for it")
    }

    func testOnlyTheRecipientCanOpen() throws {
        let (alice, bob, eve) = (try Party.make(), try Party.make(), try Party.make())
        let sealed = try WalkieCrypto.seal(Data("x".utf8), from: alice.identity, senderBox: alice.box, to: bob.keys,
                                           recipientBox: bob.box)
        XCTAssertThrowsError(try WalkieCrypto.open(sealed, as: eve.identity, recipientBox: eve.box))
        XCTAssertThrowsError(try WalkieCrypto.open(sealed, as: bob.identity, recipientBox: eve.box),
                             "bound to the mailbox it was sealed for")
    }

    func testTamperingIsDetected() throws {
        let (alice, bob) = (try Party.make(), try Party.make())
        let sealed = try WalkieCrypto.seal(Data(repeating: 7, count: 300), from: alice.identity, senderBox: alice.box,
                                           to: bob.keys, recipientBox: bob.box)
        for index in [0, 4, 6, 100, sealed.count - 1] {
            var bent = sealed
            bent[index] ^= 0x01
            XCTAssertThrowsError(try WalkieCrypto.open(bent, as: bob.identity, recipientBox: bob.box), "byte \(index)")
        }
        XCTAssertThrowsError(try WalkieCrypto.open(sealed.prefix(sealed.count - 1), as: bob.identity, recipientBox: bob.box))
    }

    /// Bob can't take Alice's signed message and pass it to Carol as if Alice
    /// had written to her: the signature names Bob's mailbox and the KEM ciphertext.
    func testSignaturesDontTransferToAnotherRecipient() throws {
        let (alice, bob, carol) = (try Party.make(), try Party.make(), try Party.make())
        let sealed = try WalkieCrypto.seal(Data("for bob".utf8), from: alice.identity, senderBox: alice.box,
                                           to: bob.keys, recipientBox: bob.box)
        let opened = try WalkieCrypto.open(sealed, as: bob.identity, recipientBox: bob.box)

        // Re-seal the same signed plaintext to Carol by hand.
        let plaintext = Data(hex: alice.box)! + UInt16(opened.signature.count).bigEndianBytes + opened.signature + opened.body
        let header = WalkieCrypto.magic + [WalkieCrypto.version]
        let (enc, ciphertext) = try XWingHPKE.seal(plaintext, to: carol.keys.kem,
                                                   info: WalkieCrypto.hpkeInfo + Data(hex: carol.box)!, aad: header)
        let forged = header + UInt16(enc.count).bigEndianBytes + enc + ciphertext
        let atCarol = try WalkieCrypto.open(forged, as: carol.identity, recipientBox: carol.box)
        XCTAssertEqual(atCarol.senderBox, alice.box)
        XCTAssertFalse(atCarol.verify(with: alice.keys))
    }

    func testHybridSignatureNeedsBothHalves() throws {
        let alice = try Party.make()
        let message = Data("card".utf8)
        let signature = try alice.identity.sign(message, context: WalkieCrypto.cardContext)
        XCTAssertTrue(alice.keys.verify(signature, for: message, context: WalkieCrypto.cardContext))
        var badEd = signature
        badEd[3] ^= 1
        XCTAssertFalse(alice.keys.verify(badEd, for: message, context: WalkieCrypto.cardContext))
        var badML = signature
        badML[badML.count - 5] ^= 1
        XCTAssertFalse(alice.keys.verify(badML, for: message, context: WalkieCrypto.cardContext))
        XCTAssertFalse(alice.keys.verify(signature.prefix(64), for: message, context: WalkieCrypto.cardContext))
        XCTAssertFalse(alice.keys.verify(signature, for: message, context: WalkieCrypto.messageContext),
                       "contexts keep cards and messages apart")
    }

    func testCardsCheckTheirSignatureAndFingerprint() throws {
        let (alice, mallory) = (try Party.make(), try Party.make())
        let card = WalkieCrypto.Card(name: "Alice", avatar: nil, server: "https://drop.example.com", box: alice.box,
                                     keys: alice.keys, created: Date(timeIntervalSince1970: 1_800_000_000))
        let signed = try WalkieCrypto.SignedCard.make(card, identity: alice.identity)
        let roundTripped = try XCTUnwrap(WalkieCrypto.SignedCard(base64: signed.base64))
        XCTAssertEqual(try roundTripped.open(expecting: alice.keys.fingerprint), card)

        // A server swapping in its own keys under Alice's name is caught by the invite's fingerprint.
        var swapped = card
        swapped.keys = mallory.keys
        let forged = try WalkieCrypto.SignedCard.make(swapped, identity: mallory.identity)
        XCTAssertNoThrow(try forged.open())
        XCTAssertThrowsError(try forged.open(expecting: alice.keys.fingerprint))

        var bent = signed
        bent.card[10] ^= 1
        XCTAssertThrowsError(try bent.open())
    }

    func testIdentitySurvivesItsSeeds() throws {
        let identity = try WalkieCrypto.Identity.generate()
        let restored = try WalkieCrypto.Identity(seeds: identity.seeds)
        XCTAssertEqual(restored.publicKeys, identity.publicKeys)
    }

    func testMailboxIdsMatchTheServer() {
        // The same derivation as Server/src/walkie.rs `box_for_secret`.
        let keys = MailboxKeys(secret: Data(repeating: 0xab, count: 32), postToken: Data(repeating: 1, count: 32))
        let expected = Data(SHA256.hash(data: Data("XNotch Walkie box v1\0".utf8) + keys.secret)).hex
        XCTAssertEqual(keys.box, expected)
        XCTAssertTrue(isBoxID(keys.box))
    }

    func testSafetyNumbersAgreeOnBothSides() throws {
        let (a, b) = (try Party.make().keys.fingerprint, try Party.make().keys.fingerprint)
        let code = WalkieCrypto.safetyNumber(a, b)
        XCTAssertEqual(code, WalkieCrypto.safetyNumber(b, a))
        XCTAssertEqual(code.split(separator: " ").count, 12)
    }
}

final class WalkieWireTests: XCTestCase {
    func testRoundTripsFilesAndVoice() throws {
        var files = WireMessage(kind: .files)
        files.files = [.init(name: "a.txt", size: 3), .init(name: "b.bin", size: 0), .init(name: "c", size: 2)]
        let body = try WireCodec.encode(files, attachments: [Data("abc".utf8), Data(), Data("hi".utf8)])
        let (decoded, attachments) = try WireCodec.decode(body)
        XCTAssertEqual(decoded, files)
        XCTAssertEqual(attachments, [Data("abc".utf8), Data(), Data("hi".utf8)])

        var voice = WireMessage(kind: .voice)
        voice.duration = 1.5
        voice.levels = [0, 128, 255]
        voice.text = "Morning!"
        let (decodedVoice, audio) = try WireCodec.decode(try WireCodec.encode(voice, attachments: [Data(repeating: 9, count: 50)]))
        XCTAssertEqual(decodedVoice, voice)
        XCTAssertEqual(audio.first?.count, 50)
    }

    func testRejectsSizesThatDontAddUp() throws {
        var files = WireMessage(kind: .files)
        files.files = [.init(name: "a", size: 10)]
        let short = try WireCodec.encode(files, attachments: [Data(count: 9)])
        XCTAssertThrowsError(try WireCodec.decode(short))
        let long = try WireCodec.encode(files, attachments: [Data(count: 11)])
        XCTAssertThrowsError(try WireCodec.decode(long))
        XCTAssertThrowsError(try WireCodec.decode(Data([0, 0])))
        XCTAssertThrowsError(try WireCodec.decode(Data([0xff, 0xff, 0xff, 0xff, 1])))
    }

    func testInvitesRoundTripAndSurviveChatText() {
        let invite = WalkieInvite(server: "https://drop.example.com", box: String(repeating: "ab", count: 32),
                                  postToken: Data(repeating: 3, count: 32), fingerprint: Data(repeating: 4, count: 32))
        XCTAssertTrue(invite.text.hasPrefix("xnotch-walkie:"))
        XCTAssertEqual(WalkieInvite(text: invite.text), invite)
        XCTAssertEqual(WalkieInvite(text: "Talk to me: \(invite.text). See you!"), invite)
        XCTAssertNil(WalkieInvite(text: "xnotch-walkie:not-an-invite"))
        XCTAssertNil(WalkieInvite(text: "https://example.com"))
    }
}
