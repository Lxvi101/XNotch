import Foundation
import Security

/// Someone in the notch.
struct Contact: Codable, Identifiable, Equatable, Sendable {
    /// Their mailbox.
    var box: String
    var server: String
    var postToken: Data
    var name: String
    var avatar: Data?
    var keys: WalkieCrypto.PublicKeys
    /// Their keys came with a fingerprint we trust (an invite), or the two of
    /// you compared safety numbers.
    var verified: Bool
    /// False while they wrote first and you haven't said yes.
    var accepted: Bool
    /// They have our card and send token, so we stop sending them along.
    var knowsUs: Bool
    var addedAt: Date
    var lastActivity: Date

    var id: String { box }
    var firstName: String { name.split(separator: " ").first.map(String.init) ?? name }
}

/// A line in a conversation.
struct ChatItem: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case voice, files, text, todo }
    enum Delivery: String, Codable, Sendable { case sending, sent, heard, failed }

    struct StoredFile: Codable, Equatable, Sendable, Identifiable {
        var name: String
        var size: Int
        /// Relative to the extension's media directory.
        var path: String
        var id: String { path }
    }

    var id: String
    var fromMe: Bool
    var at: Date
    var kind: Kind
    var text: String?
    var duration: Double?
    var levels: [UInt8]?
    /// Voice: the audio, relative to the media directory.
    var audio: String?
    var files: [StoredFile]?
    var remindAt: Date?
    var done: Bool?
    var delivery: Delivery?
    /// Incoming voice notes: played at least once.
    var heard: Bool?
}

/// The Mac's own Walkie secrets, in the login Keychain as one item.
struct OwnSecrets: Codable, Sendable {
    var seeds: Data
    var mailbox: MailboxKeys
}

enum WalkieKeychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "dev.levi.XNotch.walkie",
        kSecAttrAccount as String: "identity"
    ]

    enum ReadError: LocalizedError {
        case unavailable(OSStatus)

        var errorDescription: String? {
            "Walkie couldn't read its keys from the Keychain (\(Self.code(self))). Unlock the Keychain and switch Walkie off and on."
        }

        private static func code(_ error: ReadError) -> OSStatus {
            switch error { case .unavailable(let status): status }
        }
    }

    /// `nil` only when there are no keys yet. Any other failure throws, so a
    /// locked or busy Keychain never leads to new keys replacing the old ones.
    static func read() throws -> OwnSecrets? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let secrets = try? JSONDecoder().decode(OwnSecrets.self, from: data) else {
            throw ReadError.unavailable(status)
        }
        return secrets
    }

    /// Walkie's own access token, when it doesn't share Cloud Links'.
    static func ownToken() -> String {
        var lookup = tokenQuery
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func writeOwnToken(_ token: String) {
        SecItemDelete(tokenQuery as CFDictionary)
        guard !token.isEmpty else { return }
        var item = tokenQuery
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrLabel as String] = "XNotch Walkie server token"
        SecItemAdd(item as CFDictionary, nil)
    }

    private static let tokenQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "dev.levi.XNotch.walkie",
        kSecAttrAccount as String: "api-token"
    ]

    @discardableResult
    static func write(_ secrets: OwnSecrets) -> Bool {
        guard let data = try? JSONEncoder().encode(secrets) else { return false }
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "XNotch Walkie keys"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }

    /// Cloud Links' token, so Walkie works with the same server out of the box.
    static func cloudToken() -> String? {
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.levi.XNotch.cloud",
            kSecAttrAccount as String: "api-token",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Plain JSON files in the extension's directory.
struct WalkieDisk {
    let root: URL

    var media: URL { root.appendingPathComponent("Media", isDirectory: true) }
    private var contactsURL: URL { root.appendingPathComponent("contacts.json") }
    private func chatURL(_ box: String) -> URL {
        root.appendingPathComponent("Chats", isDirectory: true).appendingPathComponent("\(box).json")
    }

    func loadContacts() -> [Contact] {
        guard let data = try? Data(contentsOf: contactsURL) else { return [] }
        return (try? WalkieJSON.decoder.decode([Contact].self, from: data)) ?? []
    }

    func save(_ contacts: [Contact]) {
        write(try? WalkieJSON.encoder.encode(contacts), to: contactsURL)
    }

    func loadChat(_ box: String) -> [ChatItem] {
        guard let data = try? Data(contentsOf: chatURL(box)) else { return [] }
        return (try? WalkieJSON.decoder.decode([ChatItem].self, from: data)) ?? []
    }

    func save(_ chat: [ChatItem], for box: String) {
        write(try? WalkieJSON.encoder.encode(chat), to: chatURL(box))
    }

    func removeChat(_ box: String) {
        try? FileManager.default.removeItem(at: chatURL(box))
        try? FileManager.default.removeItem(at: media.appendingPathComponent(box, isDirectory: true))
    }

    func url(forMedia path: String) -> URL {
        media.appendingPathComponent(path)
    }

    /// Writes `data` under the contact's media folder and returns its relative path.
    func store(_ data: Data, box: String, folder: String, name: String) throws -> String {
        let safe = Self.safeName(name)
        let relative = "\(box)/\(folder)/\(safe)"
        let url = media.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
        return relative
    }

    /// Keeps a name to one path component, whatever a sender put in it.
    static func safeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let limited = String(cleaned.prefix(120))
        return limited.isEmpty ? "file" : limited
    }

    private func write(_ data: Data?, to url: URL) {
        guard let data else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }
}
