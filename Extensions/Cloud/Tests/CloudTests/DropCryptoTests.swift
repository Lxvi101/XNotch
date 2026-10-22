import CryptoKit
import XCTest
@testable import Cloud

final class DropCryptoTests: XCTestCase {
    private let key = DropCrypto.Key(raw: SymmetricKey(data: Data((0..<32).map { UInt8($0) })))
    private let drop = "a1B2c3D4"
    private let object = "00112233445566778899aabbccddeeff"
    private var segment: Int { DropCrypto.segmentSize }

    // MARK: Round trips and sizes

    func testFilesRoundTripAtSegmentBoundaries() throws {
        for size in [0, 1, 4095, segment - 1, segment, segment + 1, 2 * segment, 3 * segment + 17] {
            let plaintext = Self.pattern(size)
            let source = try temporaryFile(plaintext)
            let sealed = source.appendingPathExtension("xne")
            let count = try DropCrypto.encryptFile(source, to: sealed, key: key, dropID: drop, objectID: object)
            let ciphertext = try Data(contentsOf: sealed)
            XCTAssertEqual(count, UInt64(size))
            XCTAssertEqual(UInt64(ciphertext.count), DropCrypto.ciphertextSize(plaintextSize: UInt64(size)), "size \(size)")
            XCTAssertEqual(try DropCrypto.open(ciphertext, kind: .file, key: key, dropID: drop, objectID: object), plaintext,
                           "size \(size)")
            // The streaming and in-memory encoders agree byte for byte.
            let salt = ciphertext.subdata(in: 6..<38)
            XCTAssertEqual(try DropCrypto.seal(plaintext, kind: .file, key: key, dropID: drop, objectID: object, salt: salt),
                           ciphertext, "size \(size)")
        }
    }

    func testEveryObjectGetsAFreshSaltAndKey() throws {
        let plaintext = Data("same bytes".utf8)
        let a = try DropCrypto.seal(plaintext, kind: .file, key: key, dropID: drop, objectID: object)
        let b = try DropCrypto.seal(plaintext, kind: .file, key: key, dropID: drop, objectID: object)
        XCTAssertNotEqual(a.subdata(in: 6..<38), b.subdata(in: 6..<38))
        XCTAssertNotEqual(a.suffix(from: 38), b.suffix(from: 38))
    }

    func testNoncesAreTheSTREAMCounterAndLastFlag() {
        XCTAssertEqual(Data(DropCrypto.nonce(index: 0, last: false)), Data(repeating: 0, count: 12))
        XCTAssertEqual(Array(DropCrypto.nonce(index: 0x0102, last: true)), [0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 1])
        XCTAssertEqual(Array(DropCrypto.nonce(index: UInt64.max, last: false)), [0, 0, 0] + Array(repeating: 0xFF, count: 8) + [0])
    }

    // MARK: Keys

    func testKeysTravelAsCanonicalBase64URLFragments() throws {
        XCTAssertEqual(key.fragment, "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
        let random = DropCrypto.Key.random()
        XCTAssertEqual(random.fragment.count, 43)
        let parsed = try XCTUnwrap(DropCrypto.Key(fragment: "#" + random.fragment))
        XCTAssertEqual(parsed.fragment, random.fragment)
        for bad in ["", "#", String(key.fragment.dropLast()), key.fragment + "A", key.fragment.replacingOccurrences(of: "A", with: "+"),
                    // Same bytes, but the two spare bits set: not canonical.
                    String(key.fragment.dropLast()) + "9"] {
            XCTAssertNil(DropCrypto.Key(fragment: bad), bad)
        }
        let link = DropUploader.link(URL(string: "https://drop.example.com/a1B2c3D4")!, key: key)
        XCTAssertEqual(link.absoluteString, "https://drop.example.com/a1B2c3D4#AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
    }

    // MARK: Tampering, truncation and wrong context

    func testAnyChangedByteFailsAuthentication() throws {
        let plaintext = Self.pattern(segment + 100)
        let sealed = try DropCrypto.seal(plaintext, kind: .file, key: key, dropID: drop, objectID: object)
        // Header (magic, version, kind, salt), first segment body and tag, second segment.
        for offset in [0, 4, 5, 6, 37, 38, 38 + segment / 2, 38 + segment + 15, 38 + segment + 16, sealed.count - 1] {
            var changed = sealed
            changed[offset] ^= 0x01
            XCTAssertThrowsError(try DropCrypto.open(changed, kind: .file, key: key, dropID: drop, objectID: object),
                                 "offset \(offset)")
        }
    }

    func testTruncationReorderingAndExtraDataFail() throws {
        let plaintext = Self.pattern(2 * segment + 5)
        let sealed = try DropCrypto.seal(plaintext, kind: .file, key: key, dropID: drop, objectID: object)
        let full = segment + 16
        let header = sealed.prefix(38)
        let first = sealed.subdata(in: 38..<38 + full)
        let second = sealed.subdata(in: 38 + full..<38 + 2 * full)
        let last = sealed.suffix(from: 38 + 2 * full)

        let attacks: [String: Data] = [
            "dropped last segment": header + first + second,
            "dropped middle segment": header + first + last,
            "swapped segments": header + second + first + last,
            "cut inside last tag": sealed.dropLast(1),
            "one extra byte": sealed + Data([0]),
            "duplicated segment": header + first + first + second + last,
            "header only": header,
            "empty": Data()
        ]
        for (name, data) in attacks {
            XCTAssertThrowsError(try DropCrypto.open(data, kind: .file, key: key, dropID: drop, objectID: object), name)
        }
    }

    func testCiphertextOnlyOpensInItsOwnContext() throws {
        let sealed = try DropCrypto.seal(Data("hello".utf8), kind: .file, key: key, dropID: drop, objectID: object)
        func open(key: DropCrypto.Key? = nil, kind: DropCrypto.Kind = .file, drop: String? = nil, object: String? = nil) throws {
            _ = try DropCrypto.open(sealed, kind: kind, key: key ?? self.key, dropID: drop ?? self.drop, objectID: object ?? self.object)
        }
        XCTAssertNoThrow(try open())
        XCTAssertThrowsError(try open(key: .random())) { XCTAssertEqual($0 as? DropCrypto.Failure, .authentication) }
        XCTAssertThrowsError(try open(drop: "a1B2c3D5")) { XCTAssertEqual($0 as? DropCrypto.Failure, .authentication) }
        XCTAssertThrowsError(try open(object: "ffeeddccbbaa99887766554433221100")) {
            XCTAssertEqual($0 as? DropCrypto.Failure, .authentication)
        }
        XCTAssertThrowsError(try open(kind: .manifest)) { XCTAssertEqual($0 as? DropCrypto.Failure, .badFormat) }

        var newer = sealed
        newer[4] = 2
        XCTAssertThrowsError(try DropCrypto.open(newer, kind: .file, key: key, dropID: drop, objectID: object)) {
            XCTAssertEqual($0 as? DropCrypto.Failure, .unsupportedVersion)
        }
    }

    func testManifestRoundTripsAndIsBounded() throws {
        let manifest = DropCrypto.Manifest(title: "Résumé & notes", files: [.init(id: object, name: "Résumé.pdf", size: 12)])
        let sealed = try DropCrypto.sealManifest(manifest, key: key, dropID: drop)
        XCTAssertEqual(try DropCrypto.openManifest(sealed, key: key, dropID: drop), manifest)
        XCTAssertThrowsError(try DropCrypto.openManifest(sealed, key: key, dropID: "zzzzzzzz"))

        let huge = DropCrypto.Manifest(title: nil, files: (0..<3000).map {
            .init(id: String(format: "%032x", $0), name: String(repeating: "n", count: 60), size: 1)
        })
        XCTAssertThrowsError(try DropCrypto.sealManifest(huge, key: key, dropID: drop)) {
            XCTAssertEqual($0 as? DropCrypto.Failure, .manifestTooLarge)
        }
    }

    // MARK: Shared test vectors (also checked by Server/tests/e2ee/crypto.test.mjs)

    /// XNE_WRITE_VECTORS=1 swift test --filter testVectors rewrites the file.
    func testVectors() throws {
        let url = Self.vectorsURL
        if ProcessInfo.processInfo.environment["XNE_WRITE_VECTORS"] == "1" {
            try writeVectors(to: url)
        }
        let file = try JSONDecoder().decode(VectorFile.self, from: Data(contentsOf: url))
        XCTAssertGreaterThanOrEqual(file.vectors.count, 6)
        for vector in file.vectors {
            let key = try XCTUnwrap(DropCrypto.Key(fragment: vector.keyFragment))
            XCTAssertEqual(key.raw.withUnsafeBytes { Data($0) }, Data(hex: vector.key))
            let kind: DropCrypto.Kind = vector.kind == "manifest" ? .manifest : .file
            let plaintext = vector.plaintext(pattern: Self.pattern)
            let sealed = try DropCrypto.seal(plaintext, kind: kind, key: key, dropID: vector.dropId,
                                             objectID: vector.objectId, salt: Data(hex: vector.salt))
            XCTAssertEqual(Self.sha256(sealed), vector.ciphertextSha256, vector.name)
            XCTAssertEqual(sealed.count, vector.ciphertextSize, vector.name)
            if let hex = vector.ciphertextHex { XCTAssertEqual(sealed, Data(hex: hex), vector.name) }
            XCTAssertEqual(try DropCrypto.open(sealed, kind: kind, key: key, dropID: vector.dropId, objectID: vector.objectId),
                           plaintext, vector.name)
        }
    }

    private func writeVectors(to url: URL) throws {
        let salt = { (seed: UInt8) in Data((0..<32).map { UInt8(truncatingIfNeeded: Int(seed) &+ $0 &* 3) }) }
        let manifestJSON = #"{"files":[{"id":"00112233445566778899aabbccddeeff","name":"Résumé final.pdf","size":13}],"title":"Résumé final.pdf","v":1}"#
        var specs: [(String, String, Int?, String?, String?, UInt8)] = [
            ("empty file", "file", 0, nil, object, 1),
            ("short file", "file", nil, "Hello, XNotch", object, 2),
            ("manifest", "manifest", nil, manifestJSON, nil, 3),
            ("one full segment", "file", segment, nil, object, 4),
            ("two segments and a bit", "file", 2 * segment + 1234, nil, "ffeeddccbbaa99887766554433221100", 5)
        ]
        specs.append(("one byte", "file", 1, nil, object, 6))
        let vectors: [Vector] = try specs.map { name, kind, size, text, objectID, seed in
            let plaintext = text.map { Data($0.utf8) } ?? Self.pattern(size!)
            let sealed = try DropCrypto.seal(plaintext, kind: kind == "manifest" ? .manifest : .file, key: key,
                                             dropID: drop, objectID: objectID, salt: salt(seed))
            return Vector(name: name, kind: kind, key: Data((0..<32).map { UInt8($0) }).hex, keyFragment: key.fragment,
                          dropId: drop, objectId: objectID, salt: salt(seed).hex,
                          plaintextUtf8: text, plaintextPatternSize: text == nil ? size : nil,
                          ciphertextSize: sealed.count, ciphertextSha256: Self.sha256(sealed),
                          ciphertextHex: sealed.count <= 512 ? sealed.hex : nil)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let file = VectorFile(format: "XNotch Cloud E2EE v1",
                              pattern: "plaintext_pattern_size n means bytes (i * 31 + 7) mod 256 for i in 0..<n",
                              vectors: vectors)
        try (encoder.encode(file) + Data("\n".utf8)).write(to: url)
    }

    // MARK: Helpers

    static let vectorsURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Server/tests/e2ee/vectors.json")

    static func pattern(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    }

    static func sha256(_ data: Data) -> String { Data(SHA256.hash(data: data)).hex }

    private func temporaryFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xne-\(UUID().uuidString)")
        try data.write(to: url)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("xne"))
        }
        return url
    }
}

private struct VectorFile: Codable {
    let format: String
    let pattern: String
    let vectors: [Vector]
}

private struct Vector: Codable {
    let name: String
    let kind: String
    let key: String
    let keyFragment: String
    let dropId: String
    let objectId: String?
    let salt: String
    let plaintextUtf8: String?
    let plaintextPatternSize: Int?
    let ciphertextSize: Int
    let ciphertextSha256: String
    let ciphertextHex: String?

    enum CodingKeys: String, CodingKey {
        case name, kind, key, salt
        case keyFragment = "key_fragment", dropId = "drop_id", objectId = "object_id"
        case plaintextUtf8 = "plaintext_utf8", plaintextPatternSize = "plaintext_pattern_size"
        case ciphertextSize = "ciphertext_size", ciphertextSha256 = "ciphertext_sha256", ciphertextHex = "ciphertext_hex"
    }

    func plaintext(pattern: (Int) -> Data) -> Data {
        plaintextUtf8.map { Data($0.utf8) } ?? pattern(plaintextPatternSize ?? 0)
    }
}

private extension Data {
    init(hex: String) {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
