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

    func load(macName: String) -> LinkPairing {
        if let id = defaults.string(forKey: Self.idKey), let key = readKey(), key.count == 32 {
            return LinkPairing(id: id, name: macName, key: key)
        }
        return reset(macName: macName)
    }

    @discardableResult
    func reset(macName: String) -> LinkPairing {
        let pairing = LinkPairing(id: UUID().uuidString, name: macName, key: LinkPairing.generateKey())
        writeKey(pairing.key)
        defaults.set(pairing.id, forKey: Self.idKey)
        return pairing
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: Self.account]
    }

    private func readKey() -> Data? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private func writeKey(_ key: Data) {
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = key
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrLabel as String] = "XNotch iPhone & iPad pairing"
        SecItemAdd(item as CFDictionary, nil)
    }
}
