import CryptoKit
import Foundation

/// Walkie's end-to-end encryption, `XNotch Walkie v1` (see Server/docs/WALKIE.md).
/// It runs on macOS 14 and later: X-Wing and ML-DSA-65 come from BoringSSL
/// (`PostQuantum`), HPKE is `XWingHPKE`.
///
/// - Confidentiality: HPKE (RFC 9180) with the X-Wing KEM (ML-KEM-768 + X25519),
///   HKDF-SHA256 and AES-256-GCM. Breaking it needs breaking both ML-KEM and X25519.
/// - Authenticity: every sealed body is signed with both ML-DSA-65 and Ed25519;
///   both must verify. The signature covers the recipient's mailbox and the KEM
///   ciphertext, so a message can't be re-sealed to someone else under the
///   original sender's name.
enum WalkieCrypto {
    static let magic = Data("XNWK".utf8)
    static let version: UInt8 = 1
        static let hpkeInfo = Data("XNotch Walkie v1".utf8)
    static let messageContext = Data("XNotch Walkie msg v1\0".utf8)
    static let cardContext = Data("XNotch Walkie card v1\0".utf8)
    static let fingerprintContext = Data("XNotch Walkie fp v1\0".utf8)
    static let edSignatureLength = 64
    /// Our own cap on a message, above any server's: refuse before parsing.
    static let maxSealed = 1 << 30

    enum Failure: Error, Equatable {
        case malformed
        case badSignature
        case unknownSender
        case wrongRecipient
    }

    // MARK: Identity

    /// Private keys of this Mac, kept as seeds.
        struct Identity: Sendable {
        let kem: PostQuantum.XWingPrivateKey
        let mldsa: PostQuantum.MLDSAPrivateKey
        let ed: Curve25519.Signing.PrivateKey

        static func generate() throws -> Identity {
            Identity(kem: try .generate(), mldsa: try .generate(), ed: Curve25519.Signing.PrivateKey())
        }

        init(kem: PostQuantum.XWingPrivateKey, mldsa: PostQuantum.MLDSAPrivateKey, ed: Curve25519.Signing.PrivateKey) {
            self.kem = kem
            self.mldsa = mldsa
            self.ed = ed
        }

        init(seeds: Seeds) throws {
            kem = try PostQuantum.XWingPrivateKey(seed: seeds.kem)
            mldsa = try PostQuantum.MLDSAPrivateKey(seed: seeds.mldsa)
            ed = try Curve25519.Signing.PrivateKey(rawRepresentation: seeds.ed)
        }

        var seeds: Seeds {
            Seeds(kem: kem.seed, mldsa: mldsa.seed, ed: ed.rawRepresentation)
        }

        var publicKeys: PublicKeys {
            PublicKeys(kem: kem.publicKey, mldsa: mldsa.publicKey, ed: ed.publicKey.rawRepresentation)
        }

        /// Ed25519 then ML-DSA-65, over `context || message`.
        func sign(_ message: Data, context: Data) throws -> Data {
            let input = context + message
            return try ed.signature(for: input) + mldsa.signature(for: input)
        }
    }

    struct Seeds: Codable, Sendable, Equatable {
        var kem: Data
        var mldsa: Data
        var ed: Data
    }

    /// Someone's public keys, as their card carries them.
    struct PublicKeys: Codable, Sendable, Hashable {
        var kem: Data
        var mldsa: Data
        var ed: Data

                func verify(_ signature: Data, for message: Data, context: Data) -> Bool {
            guard signature.count == edSignatureLength + PostQuantum.mldsaSignatureBytes,
                  let edKey = try? Curve25519.Signing.PublicKey(rawRepresentation: ed) else { return false }
            let input = context + message
            let edPart = signature.prefix(edSignatureLength)
            let mldsaPart = signature.dropFirst(edSignatureLength)
            // Both, always: neither scheme alone is trusted to carry the identity.
            let edValid = edKey.isValidSignature(edPart, for: input)
            let mldsaValid = PostQuantum.mldsaVerify(Data(mldsaPart), for: input, publicKey: mldsa)
            return edValid && mldsaValid
        }

        /// 32 bytes that name these keys; invites carry it, people compare it.
        var fingerprint: Data {
            var hash = SHA256()
            hash.update(data: fingerprintContext)
            for part in [kem, mldsa, ed] {
                hash.update(data: UInt32(part.count).bigEndianBytes)
                hash.update(data: part)
            }
            return Data(hash.finalize())
        }
    }

    /// Twelve groups of five digits from a fingerprint, for reading aloud.
    /// Both sides compute the same code from the pair, whoever reads it.
    static func safetyNumber(_ a: Data, _ b: Data) -> String {
        let (first, second) = a.lexicographicallyPrecedes(b) ? (a, b) : (b, a)
        let digest = Data(SHA256.hash(data: Data("XNotch Walkie safety v1\0".utf8) + first + second))
        var groups: [String] = []
        var bytes = Array(digest) + Array(Data(SHA256.hash(data: digest)))
        while groups.count < 12, bytes.count >= 5 {
            let chunk = bytes.prefix(5)
            bytes.removeFirst(5)
            let value = chunk.reduce(UInt64(0)) { $0 << 8 | UInt64($1) } % 100_000
            groups.append(String(format: "%05llu", value))
        }
        return groups.joined(separator: " ")
    }

    // MARK: Cards

    /// A signed public card: who someone is and how to reach them.
    struct Card: Codable, Sendable, Equatable {
        var v: Int = 1
        var name: String
        /// Small JPEG, at most 24 KB.
        var avatar: Data?
        /// The server their mailbox is on.
        var server: String
        /// Their mailbox, 64 hex characters.
        var box: String
        var keys: PublicKeys
        var created: Date
    }

    struct SignedCard: Codable, Sendable, Equatable {
        /// The card's JSON, exactly as signed.
        var card: Data
        var sig: Data

                static func make(_ card: Card, identity: Identity) throws -> SignedCard {
            let json = try WalkieJSON.encoder.encode(card)
            return SignedCard(card: json, sig: try identity.sign(json, context: cardContext))
        }

        /// The card, when its signature holds under its own keys and, if
        /// given, those keys have the expected fingerprint.
                func open(expecting fingerprint: Data? = nil) throws -> Card {
            guard let card = try? WalkieJSON.decoder.decode(Card.self, from: self.card), card.v == 1,
                  isBoxID(card.box) else { throw Failure.malformed }
            if let fingerprint, card.keys.fingerprint != fingerprint { throw Failure.badSignature }
            guard card.keys.verify(sig, for: self.card, context: cardContext) else { throw Failure.badSignature }
            return card
        }

        var base64: String { (try? WalkieJSON.encoder.encode(self))?.base64EncodedString() ?? "" }

        init(card: Data, sig: Data) {
            self.card = card
            self.sig = sig
        }

        init?(base64: String) {
            guard let data = Data(base64Encoded: base64),
                  let decoded = try? WalkieJSON.decoder.decode(SignedCard.self, from: data) else { return nil }
            self = decoded
        }
    }

    // MARK: Envelopes

    /// Seals `body` from `sender` (whose mailbox is `senderBox`) to `recipient`.
    ///
    /// ```
    /// sealed    = "XNWK" || 0x01 || u16 len(enc) || enc || HPKE ciphertext
    /// plaintext = senderBox (32) || u16 len(sig) || sig || body
    /// sig       = Ed25519 || ML-DSA-65 over msgContext || recipientBox || SHA-256(enc) || body
    /// ```
        static func seal(_ body: Data, from sender: Identity, senderBox: String, to recipient: PublicKeys,
                     recipientBox: String) throws -> Data {
        guard let senderRaw = Data(hex: senderBox), senderRaw.count == 32,
              let recipientRaw = Data(hex: recipientBox), recipientRaw.count == 32 else { throw Failure.malformed }
        // The signature binds the KEM ciphertext, so encapsulate first, then sign, then encrypt.
        let (encapsulated, secret) = try PostQuantum.xwingEncapsulate(to: recipient.kem)
        let enc = encapsulated
        let signature = try sender.sign(recipientRaw + Data(SHA256.hash(data: enc)) + body, context: messageContext)
        let plaintext = senderRaw + UInt16(signature.count).bigEndianBytes + signature + body
        let header = magic + [version]
        let (key, nonce) = XWingHPKE.schedule(sharedSecret: secret, info: hpkeInfo + recipientRaw)
        let box = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(data: nonce), authenticating: header)
        return header + UInt16(enc.count).bigEndianBytes + enc + box.ciphertext + box.tag
    }

    struct Opened: Sendable {
        let senderBox: String
        let body: Data
        /// Checks the signature once the sender's keys are known.
        let signature: Data
        let signedPart: Data

        func verify(with keys: PublicKeys) -> Bool {
            keys.verify(signature, for: signedPart, context: messageContext)
        }
    }

    /// Decrypts a sealed message for `recipientBox`. The result is not yet
    /// authenticated: call `verify(with:)` with the claimed sender's keys.
        static func open(_ sealed: Data, as identity: Identity, recipientBox: String) throws -> Opened {
        let sealed = Data(sealed)
        guard sealed.count < maxSealed, sealed.count > 7, sealed.prefix(4) == magic, sealed[4] == version,
              let recipientRaw = Data(hex: recipientBox), recipientRaw.count == 32 else { throw Failure.malformed }
        let encLength = Int(sealed[5]) << 8 | Int(sealed[6])
        guard sealed.count > 7 + encLength else { throw Failure.malformed }
        let enc = sealed.subdata(in: 7..<(7 + encLength))
        let ciphertext = sealed.subdata(in: (7 + encLength)..<sealed.count)
        let plaintext: Data
        do {
            plaintext = try XWingHPKE.open(ciphertext, enc: enc, with: identity.kem, info: hpkeInfo + recipientRaw,
                                           aad: magic + [version])
        } catch {
            throw Failure.wrongRecipient
        }
        guard plaintext.count > 34 else { throw Failure.malformed }
        let senderRaw = plaintext.prefix(32)
        let sigLength = Int(plaintext[plaintext.startIndex + 32]) << 8 | Int(plaintext[plaintext.startIndex + 33])
        let sigStart = plaintext.startIndex + 34
        guard plaintext.endIndex >= sigStart + sigLength else { throw Failure.malformed }
        let signature = plaintext.subdata(in: sigStart..<(sigStart + sigLength))
        let body = plaintext.subdata(in: (sigStart + sigLength)..<plaintext.endIndex)
        return Opened(senderBox: senderRaw.hex, body: body, signature: signature,
                      signedPart: recipientRaw + Data(SHA256.hash(data: enc)) + body)
    }
}

/// A mailbox's private credentials. `secret` reads it; `postToken` is what
/// contacts post with. The box id is derived from the secret, as the server does.
struct MailboxKeys: Codable, Sendable, Equatable {
    var secret: Data
    var postToken: Data

    static func generate() -> MailboxKeys {
        MailboxKeys(secret: .random(32), postToken: .random(32))
    }

    var box: String {
        Data(SHA256.hash(data: Data("XNotch Walkie box v1\0".utf8) + secret)).hex
    }
}

func isBoxID(_ text: String) -> Bool {
    text.count == 64 && text.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
}

enum WalkieJSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}

extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }

    static func random(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "the system random generator failed")
        return Data(bytes)
    }

    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL: String) {
        var text = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while !text.count.isMultiple(of: 4) { text += "=" }
        self.init(base64Encoded: text)
    }
}

extension FixedWidthInteger {
    var bigEndianBytes: Data { withUnsafeBytes(of: bigEndian) { Data($0) } }
}
