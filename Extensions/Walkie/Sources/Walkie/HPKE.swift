import CryptoKit
import Foundation

/// HPKE (RFC 9180), base mode, single-shot, with the X-Wing KEM
/// (draft-connolly-cfrg-xwing-kem, KEM id 0x647A), HKDF-SHA256 and
/// AES-256-GCM: the suite CryptoKit calls
/// `XWingMLKEM768X25519_SHA256_AES_GCM_256`. Built from CryptoKit's HKDF and
/// AES-GCM so it runs on every macOS XNotch supports. `PostQuantumTests`
/// seals with CryptoKit and opens with this, and the other way round.
enum XWingHPKE {
    static let kemID: UInt16 = 0x647A
    static let kdfID: UInt16 = 0x0001
    static let aeadID: UInt16 = 0x0002

    private static let suiteID = Data("HPKE".utf8) + kemID.bigEndianBytes + kdfID.bigEndianBytes + aeadID.bigEndianBytes
    private static let version = Data("HPKE-v1".utf8)

    /// Seals one message: the encapsulated key and the ciphertext with its tag.
    static func seal(_ plaintext: Data, to publicKey: Data, info: Data, aad: Data) throws -> (enc: Data, ciphertext: Data) {
        let (enc, secret) = try PostQuantum.xwingEncapsulate(to: publicKey)
        let (key, nonce) = schedule(sharedSecret: secret, info: info)
        let box = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(data: nonce), authenticating: aad)
        // Zero-based: `box.ciphertext` is a slice of the combined box.
        return (enc, Data(box.ciphertext) + box.tag)
    }

    static func open(_ ciphertext: Data, enc: Data, with privateKey: PostQuantum.XWingPrivateKey, info: Data,
                     aad: Data) throws -> Data {
        guard ciphertext.count >= 16 else { throw PostQuantum.Failure.failed }
        let secret = try privateKey.decapsulate(enc)
        let (key, nonce) = schedule(sharedSecret: secret, info: info)
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext.dropLast(16),
                                        tag: ciphertext.suffix(16))
        return try AES.GCM.open(box, using: key, authenticating: aad)
    }

    /// RFC 9180 §5.1 KeySchedule for mode_base (no PSK). X-Wing's output is
    /// already a uniform 32-byte secret, so it is used as `shared_secret` directly.
    /// The first message's nonce is `base_nonce` itself (sequence number 0).
    static func schedule(sharedSecret: Data, info: Data) -> (key: SymmetricKey, nonce: Data) {
        let pskIDHash = labeledExtract(salt: Data(), label: "psk_id_hash", ikm: Data())
        let infoHash = labeledExtract(salt: Data(), label: "info_hash", ikm: info)
        let context = Data([0x00]) + pskIDHash + infoHash
        let secret = labeledExtract(salt: sharedSecret, label: "secret", ikm: Data())
        let key = labeledExpand(prk: secret, label: "key", info: context, length: 32)
        let nonce = labeledExpand(prk: secret, label: "base_nonce", info: context, length: 12)
        return (SymmetricKey(data: key), nonce)
    }

    private static func labeledExtract(salt: Data, label: String, ikm: Data) -> Data {
        let prk = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: version + suiteID + Data(label.utf8) + ikm),
                                       salt: salt)
        return prk.withUnsafeBytes { Data($0) }
    }

    private static func labeledExpand(prk: Data, label: String, info: Data, length: Int) -> Data {
        let labeled = UInt16(length).bigEndianBytes + version + suiteID + Data(label.utf8) + info
        let key = HKDF<SHA256>.expand(pseudoRandomKey: SymmetricKey(data: prk), info: labeled, outputByteCount: length)
        return key.withUnsafeBytes { Data($0) }
    }
}
