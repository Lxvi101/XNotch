import CCryptoBoringSSL
import Foundation

/// X-Wing and ML-DSA-65 from BoringSSL (vendored by Apple's swift-crypto), so
/// Walkie runs on every macOS XNotch supports, not only where CryptoKit has
/// them (macOS 26). The formats match CryptoKit's: 32-byte seeds, 1216-byte
/// X-Wing public keys, 1120-byte ciphertexts, 1952-byte ML-DSA-65 public keys
/// and 3309-byte signatures. `PostQuantumTests` checks both agree.
enum PostQuantum {
    enum Failure: Error, Equatable {
        case badKey
        case failed
    }

    static let xwingPublicKeyBytes = Int(XWING_PUBLIC_KEY_BYTES)
    static let xwingCiphertextBytes = Int(XWING_CIPHERTEXT_BYTES)
    static let mldsaPublicKeyBytes = Int(MLDSA65_PUBLIC_KEY_BYTES)
    static let mldsaSignatureBytes = Int(MLDSA65_SIGNATURE_BYTES)

    // MARK: X-Wing (ML-KEM-768 + X25519)

    /// An X-Wing private key, kept off the stack and wiped when released.
    final class XWingPrivateKey: @unchecked Sendable {
        private let key: UnsafeMutablePointer<XWING_private_key>
        let publicKey: Data
        let seed: Data

        static func generate() throws -> XWingPrivateKey {
            try XWingPrivateKey(seed: .random(Int(XWING_PRIVATE_KEY_BYTES)))
        }

        init(seed: Data) throws {
            guard seed.count == Int(XWING_PRIVATE_KEY_BYTES) else { throw Failure.badKey }
            let key = UnsafeMutablePointer<XWING_private_key>.allocate(capacity: 1)
            let parsed = seed.withUnsafeBytes { raw -> Int32 in
                var cbs = CBS()
                CCryptoBoringSSL_CBS_init(&cbs, raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
                return CCryptoBoringSSL_XWING_parse_private_key(key, &cbs)
            }
            var encoded = [UInt8](repeating: 0, count: Int(XWING_PUBLIC_KEY_BYTES))
            guard parsed == 1, CCryptoBoringSSL_XWING_public_from_private(&encoded, key) == 1 else {
                CCryptoBoringSSL_OPENSSL_cleanse(key, MemoryLayout<XWING_private_key>.size)
                key.deallocate()
                throw Failure.badKey
            }
            self.key = key
            self.seed = seed
            publicKey = Data(encoded)
        }

        deinit {
            CCryptoBoringSSL_OPENSSL_cleanse(key, MemoryLayout<XWING_private_key>.size)
            key.deallocate()
        }

        func decapsulate(_ ciphertext: Data) throws -> Data {
            guard ciphertext.count == Int(XWING_CIPHERTEXT_BYTES) else { throw Failure.failed }
            var secret = [UInt8](repeating: 0, count: Int(XWING_SHARED_SECRET_BYTES))
            let ok = ciphertext.withUnsafeBytes { raw in
                CCryptoBoringSSL_XWING_decap(&secret, raw.bindMemory(to: UInt8.self).baseAddress, key)
            }
            guard ok == 1 else { throw Failure.failed }
            return Data(secret)
        }
    }

    /// A fresh shared secret for `publicKey`, and the ciphertext that carries it.
    static func xwingEncapsulate(to publicKey: Data) throws -> (ciphertext: Data, secret: Data) {
        guard publicKey.count == Int(XWING_PUBLIC_KEY_BYTES) else { throw Failure.badKey }
        var ciphertext = [UInt8](repeating: 0, count: Int(XWING_CIPHERTEXT_BYTES))
        var secret = [UInt8](repeating: 0, count: Int(XWING_SHARED_SECRET_BYTES))
        let ok = publicKey.withUnsafeBytes { raw in
            CCryptoBoringSSL_XWING_encap(&ciphertext, &secret, raw.bindMemory(to: UInt8.self).baseAddress)
        }
        guard ok == 1 else { throw Failure.badKey }
        return (Data(ciphertext), Data(secret))
    }

    // MARK: ML-DSA-65

    final class MLDSAPrivateKey: @unchecked Sendable {
        private let key: UnsafeMutablePointer<MLDSA65_private_key>
        let publicKey: Data
        let seed: Data

        static func generate() throws -> MLDSAPrivateKey {
            try MLDSAPrivateKey(seed: .random(Int(MLDSA_SEED_BYTES)))
        }

        init(seed: Data) throws {
            let key = UnsafeMutablePointer<MLDSA65_private_key>.allocate(capacity: 1)
            let made = seed.count == Int(MLDSA_SEED_BYTES) && seed.withUnsafeBytes { raw in
                CCryptoBoringSSL_MLDSA65_private_key_from_seed(key, raw.bindMemory(to: UInt8.self).baseAddress, raw.count) == 1
            }
            let publicKey = made ? Self.encodedPublicKey(of: key) : nil
            guard let publicKey else {
                CCryptoBoringSSL_OPENSSL_cleanse(key, MemoryLayout<MLDSA65_private_key>.size)
                key.deallocate()
                throw Failure.badKey
            }
            self.key = key
            self.seed = seed
            self.publicKey = publicKey
        }

        deinit {
            CCryptoBoringSSL_OPENSSL_cleanse(key, MemoryLayout<MLDSA65_private_key>.size)
            key.deallocate()
        }

        /// FIPS 204 ML-DSA-65, hedged (randomized), with an empty context, as
        /// CryptoKit's `signature(for:)` does.
        func signature(for message: Data) throws -> Data {
            var signature = [UInt8](repeating: 0, count: Int(MLDSA65_SIGNATURE_BYTES))
            let ok = message.withUnsafeBytes { raw in
                CCryptoBoringSSL_MLDSA65_sign(&signature, key, raw.bindMemory(to: UInt8.self).baseAddress, raw.count, nil, 0)
            }
            guard ok == 1 else { throw Failure.failed }
            return Data(signature)
        }

        private static func encodedPublicKey(of key: UnsafePointer<MLDSA65_private_key>) -> Data? {
            let publicKey = UnsafeMutablePointer<MLDSA65_public_key>.allocate(capacity: 1)
            defer { publicKey.deallocate() }
            guard CCryptoBoringSSL_MLDSA65_public_from_private(publicKey, key) == 1 else { return nil }
            var cbb = CBB()
            guard CCryptoBoringSSL_CBB_init(&cbb, Int(MLDSA65_PUBLIC_KEY_BYTES)) == 1 else { return nil }
            defer { CCryptoBoringSSL_CBB_cleanup(&cbb) }
            guard CCryptoBoringSSL_MLDSA65_marshal_public_key(&cbb, publicKey) == 1,
                  let bytes = CCryptoBoringSSL_CBB_data(&cbb) else { return nil }
            return Data(bytes: bytes, count: CCryptoBoringSSL_CBB_len(&cbb))
        }
    }

    static func mldsaVerify(_ signature: Data, for message: Data, publicKey: Data) -> Bool {
        guard publicKey.count == Int(MLDSA65_PUBLIC_KEY_BYTES), signature.count == Int(MLDSA65_SIGNATURE_BYTES) else {
            return false
        }
        let key = UnsafeMutablePointer<MLDSA65_public_key>.allocate(capacity: 1)
        defer { key.deallocate() }
        let parsed = publicKey.withUnsafeBytes { raw -> Bool in
            var cbs = CBS()
            CCryptoBoringSSL_CBS_init(&cbs, raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
            return CCryptoBoringSSL_MLDSA65_parse_public_key(key, &cbs) == 1 && CCryptoBoringSSL_CBS_len(&cbs) == 0
        }
        guard parsed else { return false }
        return signature.withUnsafeBytes { sig in
            message.withUnsafeBytes { msg in
                CCryptoBoringSSL_MLDSA65_verify(key, sig.bindMemory(to: UInt8.self).baseAddress, sig.count,
                                                msg.bindMemory(to: UInt8.self).baseAddress, msg.count, nil, 0) == 1
            }
        }
    }
}
