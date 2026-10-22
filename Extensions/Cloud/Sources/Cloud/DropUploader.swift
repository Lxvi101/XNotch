import Foundation

/// Uploads files into one new drop, end-to-end encrypted unless told otherwise.
///
/// Encryption fails closed: if the server doesn't advertise and then confirm
/// the encrypted format, or browsers couldn't decrypt the link, nothing is
/// uploaded and the half-made drop is deleted. Plaintext is never the fallback.
struct DropUploader: Sendable {
    struct Result: Sendable {
        let drop: CloudClient.Drop
        /// The link to hand out: for an encrypted drop it carries the key after `#`.
        let link: URL
    }

    let client: CloudClient
    let info: CloudClient.Info
    let encrypt: Bool

    /// Checks the server can take this upload before anything is sent.
    func preflight(sizes: [(name: String, size: UInt64)], password: String?) throws {
        if encrypt {
            guard info.supportsEncryption else { throw EncryptionUnsupported() }
            guard client.canServeEncryptedLinks else { throw EncryptionNeedsHTTPS() }
        }
        if let tooBig = sizes.first(where: { uploadSize($0.size) > info.maxFileSize }) {
            throw TooLarge(name: tooBig.name, limit: info.maxFileSize)
        }
        if password.map({ !$0.isEmpty }) == true, info.passwords != true { throw PasswordsUnsupported() }
    }

    func uploadSize(_ plaintextSize: UInt64) -> UInt64 {
        encrypt ? DropCrypto.ciphertextSize(plaintextSize: plaintextSize) : plaintextSize
    }

    /// `progress` gets the fraction of all bytes sent.
    func upload(_ urls: [URL], title: String, expiresIn: TimeInterval, password: String?,
                progress: @escaping @Sendable (Double) -> Void) async throws -> Result {
        let sizes = urls.map(Self.size(of:))
        try preflight(sizes: zip(urls, sizes).map { ($0.lastPathComponent, UInt64($1)) }, password: password)
        let protect = password.map { !$0.isEmpty } ?? false
        let total = max(1, sizes.reduce(0, +))

        let drop = try await client.createDrop(expiresIn: expiresIn, title: title, password: password, encrypted: encrypt)
        do {
            // Never hand out an open link that was meant to be locked, or a
            // server-readable one that was meant to be encrypted.
            if protect, drop.protected != true { throw PasswordsUnsupported() }
            if encrypt, drop.e2ee != Int(DropCrypto.version) { throw EncryptionUnsupported() }
            let key = DropCrypto.Key.random()
            var entries: [DropCrypto.Manifest.File] = []
            var done: Int64 = 0
            for (url, size) in zip(urls, sizes) {
                let prepared = try await PreparedFile.make(for: url)
                defer { prepared.cleanUp() }
                let report: @Sendable (Double) -> Void = { [done] fraction in
                    progress(Double(done + Int64(Double(size) * fraction)) / Double(total))
                }
                if encrypt {
                    entries.append(try await uploadEncrypted(prepared, key: key, drop: drop.id, progress: report))
                } else {
                    try await uploadPlain(prepared, drop: drop.id, progress: report)
                }
                done += size
            }
            guard encrypt else { return Result(drop: drop, link: drop.url) }
            let manifest = DropCrypto.Manifest(title: title, files: entries)
            try await client.uploadManifest(try DropCrypto.sealManifest(manifest, key: key, dropID: drop.id), to: drop.id)
            return Result(drop: drop, link: Self.link(drop.url, key: key))
        } catch {
            // Don't leave a half-filled link behind that nobody can see or revoke.
            try? await client.delete(drop: drop.id)
            throw error
        }
    }

    static func link(_ url: URL, key: DropCrypto.Key) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.percentEncodedFragment = key.fragment // base64url needs no escaping
        return components.url!
    }

    private func uploadPlain(_ prepared: PreparedFile, drop: String,
                             progress: @escaping @Sendable (Double) -> Void) async throws {
        // A folder's size is only known once zipped.
        if Self.fileSize(prepared.url) > info.maxFileSize { throw TooLarge(name: prepared.name, limit: info.maxFileSize) }
        try await client.upload(prepared.url, name: prepared.name, to: drop, progress: progress)
    }

    /// Encrypts to a temporary file (ciphertext only), uploads it under a random
    /// object name and returns its manifest entry.
    private func uploadEncrypted(_ prepared: PreparedFile, key: DropCrypto.Key, drop: String,
                                 progress: @escaping @Sendable (Double) -> Void) async throws -> DropCrypto.Manifest.File {
        let objectID = DropCrypto.objectID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("XNotchCloud-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sealed = directory.appendingPathComponent(objectID)
        let source = prepared.url
        let size = try await Task.detached(priority: .userInitiated) {
            try DropCrypto.encryptFile(source, to: sealed, key: key, dropID: drop, objectID: objectID)
        }.value
        if uploadSize(size) > info.maxFileSize { throw TooLarge(name: prepared.name, limit: info.maxFileSize) }
        try await client.upload(sealed, name: objectID, to: drop, progress: progress)
        return DropCrypto.Manifest.File(id: objectID, name: prepared.name.precomposedStringWithCanonicalMapping, size: size)
    }

    static func size(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if values?.isDirectory == true { return 1 }
        return Int64(values?.fileSize ?? 1)
    }

    private static func fileSize(_ url: URL) -> UInt64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
    }
}

struct EncryptionUnsupported: LocalizedError {
    var errorDescription: String? {
        "Your server can't store encrypted links yet. Update it from the Server folder, or turn off encryption in Settings → Cloud Links."
    }
}

struct EncryptionNeedsHTTPS: LocalizedError {
    var errorDescription: String? {
        "Browsers only decrypt encrypted links over https. Use an https server, or turn off encryption in Settings → Cloud Links."
    }
}
