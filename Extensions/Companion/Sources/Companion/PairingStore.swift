import Foundation
import Security
import XNotchLink

/// This Mac's pairing: an ID in defaults, the key in the Keychain. Every
/// iPhone or iPad that scanned the code shares the key; resetting it unpairs
/// them all.
struct PairingStore {
    private let defaults: UserDefaults
    private let service: String
    private static let idKey = "linkID"
    private static let account = "link-key"

    init(defaults: UserDefaults, service: String = "dev.levi.XNotch.companion") {
        self.defaults = defaults
        self.service = service
    }

    enum Failure: LocalizedError {
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .keychain(let status):
                let reason = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
                return "The pairing key couldn't be read from the Keychain (\(reason)). Phones stay paired once it's readable again."
            }
        }
    }

    /// The saved pairing, or a new one when there is none yet. Any other
    /// Keychain trouble throws: making a new key then would quietly unpair
    /// every phone.
    func load(macName: String) throws -> LinkPairing {
        if let id = defaults.string(forKey: Self.idKey) {
            let (key, status) = readKey()
            if let key, key.count == 32 { return LinkPairing(id: id, name: macName, key: key) }
            if status != errSecSuccess, status != errSecItemNotFound { throw Failure.keychain(status) }
        }
        return try reset(macName: macName)
    }

    @discardableResult
    func reset(macName: String) throws -> LinkPairing {
        let pairing = LinkPairing(id: UUID().uuidString, name: macName, key: LinkPairing.generateKey())
        try writeKey(pairing.key)
        defaults.set(pairing.id, forKey: Self.idKey)
        return pairing
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: Self.account]
    }

    private func readKey() -> (Data?, OSStatus) {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        return (status == errSecSuccess ? result as? Data : nil, status)
    }

    private func writeKey(_ key: Data) throws {
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: key] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = key
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            item[kSecAttrLabel as String] = "XNotch iPhone & iPad pairing"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }
}
