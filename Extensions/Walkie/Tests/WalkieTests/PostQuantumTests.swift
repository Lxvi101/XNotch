import CryptoKit
import XCTest
@testable import Walkie

/// Walkie's BoringSSL X-Wing / ML-DSA-65 and its own HPKE must agree with
/// CryptoKit's, byte for byte, so Macs on Sequoia and on macOS 26 and later
/// can talk. These need CryptoKit's post-quantum types, so they run on macOS 26+.
final class PostQuantumTests: XCTestCase {
    func testXWingKeysMatchCryptoKitFromTheSameSeed() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("CryptoKit has X-Wing from macOS 26") }
        for _ in 0..<8 {
            let ours = try PostQuantum.XWingPrivateKey.generate()
            let theirs = try XWingMLKEM768X25519.PrivateKey(seedRepresentation: ours.seed, publicKey: nil)
            XCTAssertEqual(ours.publicKey, theirs.publicKey.rawRepresentation)
            XCTAssertEqual(ours.publicKey.count, 1216)
        }
    }

    func testOurHPKEOpensCryptoKitsAndTheOtherWayRound() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("CryptoKit has X-Wing HPKE from macOS 26") }
        let suite = HPKE.Ciphersuite.XWingMLKEM768X25519_SHA256_AES_GCM_256
        let recipient = try PostQuantum.XWingPrivateKey.generate()
        let theirKey = try XWingMLKEM768X25519.PrivateKey(seedRepresentation: recipient.seed, publicKey: nil)
        let info = Data("XNotch Walkie v1".utf8) + Data(repeating: 0xab, count: 32)
        let aad = Data("XNWK\u{1}".utf8)

        for size in [0, 1, 16, 1000, 70_000] {
            let message = Data((0..<size).map { UInt8($0 % 256) })

            // CryptoKit seals, we open.
            var sender = try HPKE.Sender(recipientKey: theirKey.publicKey, ciphersuite: suite, info: info)
            let sealed = try sender.seal(message, authenticating: aad)
            XCTAssertEqual(try XWingHPKE.open(sealed, enc: sender.encapsulatedKey, with: recipient, info: info, aad: aad),
                           message, "size \(size)")

            // We seal, CryptoKit opens.
            let (enc, ours) = try XWingHPKE.seal(message, to: recipient.publicKey, info: info, aad: aad)
            var opener = try HPKE.Recipient(privateKey: theirKey, ciphersuite: suite, info: info, encapsulatedKey: enc)
            XCTAssertEqual(try opener.open(ours, authenticating: aad), message, "size \(size)")
        }
    }

    func testHPKERejectsWrongInfoAadAndTampering() throws {
        let recipient = try PostQuantum.XWingPrivateKey.generate()
        let (enc, sealed) = try XWingHPKE.seal(Data("hi".utf8), to: recipient.publicKey, info: Data("a".utf8), aad: Data("x".utf8))
        XCTAssertThrowsError(try XWingHPKE.open(sealed, enc: enc, with: recipient, info: Data("b".utf8), aad: Data("x".utf8)))
        XCTAssertThrowsError(try XWingHPKE.open(sealed, enc: enc, with: recipient, info: Data("a".utf8), aad: Data("y".utf8)))
        var bent = sealed
        bent[0] ^= 1
        XCTAssertThrowsError(try XWingHPKE.open(bent, enc: enc, with: recipient, info: Data("a".utf8), aad: Data("x".utf8)))
        XCTAssertThrowsError(try XWingHPKE.open(sealed, enc: enc.prefix(100), with: recipient, info: Data("a".utf8), aad: Data("x".utf8)))
        let other = try PostQuantum.XWingPrivateKey.generate()
        XCTAssertThrowsError(try XWingHPKE.open(sealed, enc: enc, with: other, info: Data("a".utf8), aad: Data("x".utf8)))
    }

    func testMLDSAMatchesCryptoKitBothWays() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("CryptoKit has ML-DSA from macOS 26") }
        let ours = try PostQuantum.MLDSAPrivateKey.generate()
        let theirs = try MLDSA65.PrivateKey(seedRepresentation: ours.seed, publicKey: nil)
        XCTAssertEqual(ours.publicKey, theirs.publicKey.rawRepresentation)

        let message = Data("XNotch Walkie card v1\0{}".utf8)
        let ourSignature = try ours.signature(for: message)
        XCTAssertEqual(ourSignature.count, 3309)
        XCTAssertTrue(theirs.publicKey.isValidSignature(ourSignature, for: message))
        let theirSignature = try theirs.signature(for: message)
        XCTAssertTrue(PostQuantum.mldsaVerify(theirSignature, for: message, publicKey: ours.publicKey))

        var bent = ourSignature
        bent[100] ^= 1
        XCTAssertFalse(PostQuantum.mldsaVerify(bent, for: message, publicKey: ours.publicKey))
        XCTAssertFalse(PostQuantum.mldsaVerify(ourSignature, for: message + [0], publicKey: ours.publicKey))
    }

    func testRejectsMalformedKeys() {
        XCTAssertThrowsError(try PostQuantum.XWingPrivateKey(seed: Data(count: 31)))
        XCTAssertThrowsError(try PostQuantum.MLDSAPrivateKey(seed: Data(count: 33)))
        XCTAssertThrowsError(try PostQuantum.xwingEncapsulate(to: Data(count: 1215)))
        XCTAssertFalse(PostQuantum.mldsaVerify(Data(count: 3309), for: Data(), publicKey: Data(count: 10)))
    }

    /// Keys made by the earlier CryptoKit build still load: same seeds, same public keys.
    func testIdentitiesFromCryptoKitSeedsStillWork() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("needs CryptoKit's post-quantum types") }
        let kem = try XWingMLKEM768X25519.PrivateKey.generate()
        let mldsa = try MLDSA65.PrivateKey()
        let seeds = WalkieCrypto.Seeds(kem: kem.seedRepresentation, mldsa: mldsa.seedRepresentation,
                                       ed: Curve25519.Signing.PrivateKey().rawRepresentation)
        let identity = try WalkieCrypto.Identity(seeds: seeds)
        XCTAssertEqual(identity.publicKeys.kem, kem.publicKey.rawRepresentation)
        XCTAssertEqual(identity.publicKeys.mldsa, mldsa.publicKey.rawRepresentation)
    }
}
