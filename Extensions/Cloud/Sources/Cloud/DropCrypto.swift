import CryptoKit
import Foundation

/// End-to-end encryption of Cloud drops, format "XNotch Cloud E2EE v1"
/// (spec: Server/docs/E2EE.md). The browser decrypts with the same format in
/// Server/src/assets/e2ee-core.js.
///
/// Each object (a file, or the drop's manifest) is a 38-byte header — "XNCE",
/// version, kind, 32-byte random salt — followed by AES-256-GCM segments of
/// 1 MiB plaintext. Its key is HKDF-SHA256 of the drop key with that salt and
/// an info string naming the drop and object. Nonces follow the STREAM
/// construction (as in age): an 11-byte segment counter and a last-segment
/// flag. Every segment authenticates the header.
enum DropCrypto {
    static let version: UInt8 = 1
    static let segmentSize = 1 << 20
    static let tagSize = 16
    static let saltSize = 32
    static let headerSize = 4 + 1 + 1 + saltSize
    static let magic: [UInt8] = [0x58, 0x4E, 0x43, 0x45] // "XNCE"
    /// The manifest is one segment; the browser refuses anything larger.
    static let maxManifestPlaintext = 256 * 1024

    enum Kind: UInt8 {
        case file = 1
        case manifest = 2
    }

    enum Failure: Error, Equatable {
        case badFormat
        case unsupportedVersion
        case authentication
        case truncated
        case manifestTooLarge
    }

    /// The drop's 256-bit key. It travels only in the link's fragment (after
    /// `#`), which browsers never send to the server.
    struct Key: Sendable {
        let raw: SymmetricKey

        static func random() -> Key { Key(raw: SymmetricKey(size: .bits256)) }

        init(raw: SymmetricKey) {
            precondition(raw.bitCount == 256)
            self.raw = raw
        }

        /// Parses the unpadded base64url fragment, with or without `#`.
        init?(fragment: String) {
            var text = Substring(fragment)
            if text.first == "#" { text = text.dropFirst() }
            guard text.count == 43, text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
            else { return nil }
            let base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="
            guard let data = Data(base64Encoded: base64), data.count == 32 else { return nil }
            self.init(raw: SymmetricKey(data: data))
            // The spare two bits must be zero, so every key has exactly one spelling.
            guard self.fragment == String(text) else { return nil }
        }

        var fragment: String {
            raw.withUnsafeBytes { Data($0) }.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
    }

    /// The decrypted manifest: everything the server must not see.
    struct Manifest: Codable, Equatable {
        struct File: Codable, Equatable {
            /// The random object name the ciphertext is stored under.
            let id: String
            let name: String
            let size: UInt64
        }

        var v = 1
        var title: String?
        var files: [File]
    }

    /// A random object name: 32 lowercase hex characters.
    static func objectID() -> String {
        SymmetricKey(size: .bits128).withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
    }

    static func segmentCount(plaintextSize: UInt64) -> UInt64 {
        plaintextSize == 0 ? 1 : (plaintextSize + UInt64(segmentSize) - 1) / UInt64(segmentSize)
    }

    static func ciphertextSize(plaintextSize: UInt64) -> UInt64 {
        UInt64(headerSize) + plaintextSize + segmentCount(plaintextSize: plaintextSize) * UInt64(tagSize)
    }

    /// Domain-separates every object: a file's ciphertext only opens under its
    /// own drop and object name, and never as a manifest.
    static func info(kind: Kind, dropID: String, objectID: String?) -> Data {
        var text = "XNotch Cloud E2EE v1\u{0}" + (kind == .manifest ? "manifest" : "file") + "\u{0}" + dropID
        if kind == .file { text += "\u{0}" + (objectID ?? "") }
        return Data(text.utf8)
    }

    static func nonce(index: UInt64, last: Bool) -> AES.GCM.Nonce {
        var bytes = [UInt8](repeating: 0, count: 12)
        var n = index
        for i in stride(from: 10, through: 3, by: -1) { // a UInt64 fills the low 8 of the 11 counter bytes
            bytes[i] = UInt8(truncatingIfNeeded: n)
            n >>= 8
        }
        bytes[11] = last ? 1 : 0
        return try! AES.GCM.Nonce(data: bytes) // 12 bytes is always valid
    }

    // MARK: Encrypting

    /// Seals one object segment by segment. `salt` is only for test vectors;
    /// leave it out so every object gets a fresh random salt (and so a fresh key).
    struct Sealer {
        let header: Data
        private let key: SymmetricKey
        private var index: UInt64 = 0
        private var finished = false

        init(key: Key, kind: Kind, dropID: String, objectID: String?, salt: Data? = nil) {
            let salt = salt ?? SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            precondition(salt.count == DropCrypto.saltSize)
            header = Data(DropCrypto.magic + [DropCrypto.version, kind.rawValue]) + salt
            self.key = HKDF<SHA256>.deriveKey(inputKeyMaterial: key.raw, salt: salt,
                                              info: DropCrypto.info(kind: kind, dropID: dropID, objectID: objectID),
                                              outputByteCount: 32)
        }

        /// Every segment but the last must be exactly `segmentSize` bytes.
        mutating func seal(_ plaintext: Data, last: Bool) throws -> Data {
            precondition(!finished && plaintext.count <= DropCrypto.segmentSize && (last || plaintext.count == DropCrypto.segmentSize))
            let box = try AES.GCM.seal(plaintext, using: key, nonce: DropCrypto.nonce(index: index, last: last),
                                       authenticating: header)
            index += 1
            finished = last
            return box.ciphertext + box.tag
        }
    }

    static func seal(_ plaintext: Data, kind: Kind, key: Key, dropID: String, objectID: String? = nil,
                     salt: Data? = nil) throws -> Data {
        var sealer = Sealer(key: key, kind: kind, dropID: dropID, objectID: objectID, salt: salt)
        var out = sealer.header
        var offset = plaintext.startIndex
        repeat {
            let end = plaintext.index(offset, offsetBy: segmentSize, limitedBy: plaintext.endIndex) ?? plaintext.endIndex
            out += try sealer.seal(plaintext[offset..<end], last: end == plaintext.endIndex)
            offset = end
        } while offset < plaintext.endIndex
        return out
    }

    /// Encrypts a file to `destination`, holding about two segments in memory
    /// whatever its size. Returns the number of plaintext bytes encrypted.
    @discardableResult
    static func encryptFile(_ source: URL, to destination: URL, key: Key, dropID: String, objectID: String,
                            salt: Data? = nil) throws -> UInt64 {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        var sealer = Sealer(key: key, kind: .file, dropID: dropID, objectID: objectID, salt: salt)
        try output.write(contentsOf: sealer.header)
        var total: UInt64 = 0
        var current = try read(input)
        // Read one segment ahead: the last segment is only known when the next read is empty.
        while true {
            let next = current.count == segmentSize ? try read(input) : Data()
            let last = next.isEmpty
            try autoreleasepool { try output.write(contentsOf: sealer.seal(current, last: last)) }
            total += UInt64(current.count)
            if last { break }
            current = next
        }
        try output.synchronize()
        return total
    }

    /// Reads up to a full segment; less only at the end of the file.
    private static func read(_ handle: FileHandle) throws -> Data {
        var data = Data()
        while data.count < segmentSize {
            guard let chunk = try handle.read(upToCount: segmentSize - data.count), !chunk.isEmpty else { break }
            data += chunk
        }
        return data
    }

    static func sealManifest(_ manifest: Manifest, key: Key, dropID: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = try encoder.encode(manifest)
        guard json.count <= maxManifestPlaintext else { throw Failure.manifestTooLarge }
        return try seal(json, kind: .manifest, key: key, dropID: dropID)
    }

    // MARK: Decrypting (used to verify uploads and in tests; recipients use the browser)

    static func open(_ ciphertext: Data, kind: Kind, key: Key, dropID: String, objectID: String? = nil) throws -> Data {
        let bytes = Data(ciphertext) // zero-based indices
        guard bytes.count >= headerSize + tagSize else { throw Failure.truncated }
        let header = bytes.prefix(headerSize)
        guard Array(header.prefix(4)) == magic else { throw Failure.badFormat }
        guard header[4] == version else { throw Failure.unsupportedVersion }
        guard header[5] == kind.rawValue else { throw Failure.badFormat }
        let salt = header.suffix(saltSize)
        let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: key.raw, salt: salt,
                                             info: info(kind: kind, dropID: dropID, objectID: objectID),
                                             outputByteCount: 32)
        let body = bytes.count - headerSize
        let segments = (body + segmentSize + tagSize - 1) / (segmentSize + tagSize)
        let size = body - segments * tagSize
        guard size >= 0, ciphertextSize(plaintextSize: UInt64(size)) == UInt64(bytes.count) else { throw Failure.truncated }

        var plaintext = Data(capacity: size)
        var offset = headerSize
        for index in 0..<segments {
            let last = index == segments - 1
            let length = (last ? size - segmentSize * (segments - 1) : segmentSize) + tagSize
            let segment = bytes[offset..<offset + length]
            do {
                let box = try AES.GCM.SealedBox(nonce: nonce(index: UInt64(index), last: last),
                                                ciphertext: segment.dropLast(tagSize), tag: segment.suffix(tagSize))
                plaintext += try AES.GCM.open(box, using: derived, authenticating: header)
            } catch {
                throw Failure.authentication
            }
            offset += length
        }
        return plaintext
    }

    static func openManifest(_ ciphertext: Data, key: Key, dropID: String) throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: open(ciphertext, kind: .manifest, key: key, dropID: dropID))
    }
}
