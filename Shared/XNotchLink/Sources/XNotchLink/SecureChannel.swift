import CryptoKit
import Foundation

/// Authenticated encryption over any transport, keyed by the pairing.
///
/// Handshake, initiator I and responder R, pairing key K:
///
///     I → R  "XNL2" | id length | pairing id | nonceI (32) | ephemeral key I (32)
///     R → I  "XNL2" | nonceR (32) | ephemeral key R (32) | HMAC(K, "XNL2 responder" | transcript)
///     I → R  HMAC(K, "XNL2 initiator" | transcript)
///
/// The transcript is everything both sides sent before the tags. Only a
/// holder of K can produce a tag, so both ends are authenticated; the X25519
/// exchange gives each connection fresh keys (forward secrecy):
///
///     keys = HKDF-SHA256(X25519(I, R), salt: K, info: "XNL2 keys" | SHA256(transcript), 64 bytes)
///
/// Records are a 4-byte big-endian length, then ChaCha20-Poly1305 ciphertext
/// and tag, with a per-direction counter as the nonce. Any tampering,
/// reordering or replay fails authentication and closes the channel.
///
/// `send` isn't reentrant: callers send one record at a time (LinkSession
/// holds its send lock), so counters and stream order agree.
public final class SecureChannel: @unchecked Sendable {
    public let transport: LinkTransport
    /// The pairing this channel was opened with.
    public let pairingID: String

    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0

    static let magic = Data("XNL2".utf8)
    static let maxRecord = 8 << 20
    private static let tagSize = 32

    private init(transport: LinkTransport, pairingID: String, sendKey: SymmetricKey, receiveKey: SymmetricKey) {
        self.transport = transport
        self.pairingID = pairingID
        self.sendKey = sendKey
        self.receiveKey = receiveKey
    }

    /// The connecting side: proves it holds `pairing.key` and checks the other side does.
    public static func initiate(over transport: LinkTransport, pairing: LinkPairing,
                                timeout: TimeInterval = 10) async throws -> SecureChannel {
        try await withTimeout(timeout, closing: transport) {
            let id = Data(pairing.id.utf8)
            guard id.count <= 255 else { throw LinkError.protocolViolation("Pairing ID too long") }
            let ephemeral = Curve25519.KeyAgreement.PrivateKey()
            let nonce = randomBytes(32)
            let hello = magic + Data([UInt8(id.count)]) + id + nonce + ephemeral.publicKey.rawRepresentation
            try await writeHandshake(hello, to: transport)

            let reply = try await readHandshake(from: transport)
            guard reply.count == 4 + 32 + 32 + tagSize, reply.prefix(4) == magic else {
                throw LinkError.protocolViolation("Bad handshake reply")
            }
            let body = reply.dropFirst(4)
            let theirNonce = Data(body.prefix(32))
            let theirKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: body.dropFirst(32).prefix(32))
            let theirTag = Data(body.suffix(tagSize))
            let transcript = hello + theirNonce + theirKey.rawRepresentation
            let key = SymmetricKey(data: pairing.key)
            guard HMAC<SHA256>.isValidAuthenticationCode(theirTag, authenticating: Data("XNL2 responder".utf8) + transcript, using: key) else {
                throw LinkError.rejected("This device isn't paired with that Mac any more. Scan its code again.")
            }
            let myTag = Data(HMAC<SHA256>.authenticationCode(for: Data("XNL2 initiator".utf8) + transcript, using: key))
            try await writeHandshake(myTag, to: transport)
            let (toResponder, toInitiator) = try deriveKeys(ephemeral, theirKey, key, transcript)
            return SecureChannel(transport: transport, pairingID: pairing.id, sendKey: toResponder, receiveKey: toInitiator)
        }
    }

    /// The listening side. `key` returns the pairing key for an ID, or nil
    /// to refuse; a refusal reveals nothing to the other side.
    public static func respond(over transport: LinkTransport, timeout: TimeInterval = 10,
                               key lookup: @escaping @Sendable (String) -> Data?) async throws -> SecureChannel {
        try await withTimeout(timeout, closing: transport) {
            let hello = try await readHandshake(from: transport)
            guard hello.count > 4 + 1, hello.prefix(4) == magic else { throw LinkError.protocolViolation("Bad handshake") }
            let idLength = Int(hello[hello.startIndex + 4])
            guard hello.count == 4 + 1 + idLength + 32 + 32,
                  let id = String(data: hello.dropFirst(5).prefix(idLength), encoding: .utf8) else {
                throw LinkError.protocolViolation("Bad handshake")
            }
            guard let secret = lookup(id), secret.count == 32 else { throw LinkError.rejected("Unknown pairing") }
            let theirKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: hello.suffix(32))
            let ephemeral = Curve25519.KeyAgreement.PrivateKey()
            let nonce = randomBytes(32)
            let transcript = Data(hello) + nonce + ephemeral.publicKey.rawRepresentation
            let key = SymmetricKey(data: secret)
            let myTag = Data(HMAC<SHA256>.authenticationCode(for: Data("XNL2 responder".utf8) + transcript, using: key))
            try await writeHandshake(magic + nonce + ephemeral.publicKey.rawRepresentation + myTag, to: transport)

            let theirTag = try await readHandshake(from: transport)
            guard HMAC<SHA256>.isValidAuthenticationCode(theirTag, authenticating: Data("XNL2 initiator".utf8) + transcript, using: key) else {
                throw LinkError.rejected("Wrong pairing key")
            }
            let (toResponder, toInitiator) = try deriveKeys(ephemeral, theirKey, key, transcript)
            return SecureChannel(transport: transport, pairingID: id, sendKey: toInitiator, receiveKey: toResponder)
        }
    }

    public func send(_ plaintext: Data) async throws {
        let nonce = try ChaChaPoly.Nonce(data: Self.nonce(sendCounter))
        sendCounter += 1
        let box = try ChaChaPoly.seal(plaintext, using: sendKey, nonce: nonce)
        let sealed = box.ciphertext + box.tag
        guard sealed.count <= Self.maxRecord else { throw LinkError.protocolViolation("Record too large") }
        try await transport.send(Self.lengthPrefix(sealed.count) + sealed)
    }

    public func receive() async throws -> Data {
        let length = try Self.length(try await transport.receive(exactly: 4))
        guard length >= 16, length <= Self.maxRecord else { throw LinkError.protocolViolation("Bad record length") }
        let sealed = try await transport.receive(exactly: length)
        let nonce = try ChaChaPoly.Nonce(data: Self.nonce(receiveCounter))
        receiveCounter += 1
        do {
            let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
            return try ChaChaPoly.open(box, using: receiveKey)
        } catch {
            throw LinkError.protocolViolation("A record failed authentication")
        }
    }

    public func close() {
        transport.close()
    }

    // MARK: Plumbing

    private static func deriveKeys(_ mine: Curve25519.KeyAgreement.PrivateKey, _ theirs: Curve25519.KeyAgreement.PublicKey,
                                   _ key: SymmetricKey, _ transcript: Data) throws -> (SymmetricKey, SymmetricKey) {
        let shared = try mine.sharedSecretFromKeyAgreement(with: theirs)
        let info = Data("XNL2 keys".utf8) + Data(SHA256.hash(data: transcript))
        let material = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: key.withUnsafeBytes { Data($0) },
                                                      sharedInfo: info, outputByteCount: 64)
        let bytes = material.withUnsafeBytes { Data($0) }
        return (SymmetricKey(data: bytes.prefix(32)), SymmetricKey(data: bytes.suffix(32)))
    }

    private static func writeHandshake(_ message: Data, to transport: LinkTransport) async throws {
        try await transport.send(lengthPrefix(message.count) + message)
    }

    private static func readHandshake(from transport: LinkTransport) async throws -> Data {
        let length = try length(try await transport.receive(exactly: 4))
        guard length > 0, length <= 512 else { throw LinkError.protocolViolation("Bad handshake length") }
        return try await transport.receive(exactly: length)
    }

    private static func nonce(_ counter: UInt64) -> Data {
        var big = counter.bigEndian
        return Data(count: 4) + Data(bytes: &big, count: 8)
    }

    static func lengthPrefix(_ count: Int) -> Data {
        var big = UInt32(count).bigEndian
        return Data(bytes: &big, count: 4)
    }

    static func length(_ prefix: Data) throws -> Int {
        guard prefix.count == 4 else { throw LinkError.protocolViolation("Short length") }
        return Int(prefix.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
    }

    static func randomBytes(_ count: Int) -> Data {
        SymmetricKey(size: SymmetricKeySize(bitCount: count * 8)).withUnsafeBytes { Data($0) }
    }

    /// A stuck peer can't hold a handshake open: the transport closes, failing the pending read.
    private static func withTimeout<T: Sendable>(_ seconds: TimeInterval, closing transport: LinkTransport,
                                                 _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let watchdog = Task {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            transport.close()
        }
        defer { watchdog.cancel() }
        do {
            return try await body()
        } catch {
            transport.close()
            throw error
        }
    }
}
