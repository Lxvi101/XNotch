import Foundation
import Security
import UIKit
import XNotchLink

/// Paired Macs and the chosen one, in a Keychain group the app and its Share
/// extension both read.
struct PairingKeychain {
    struct Stored: Codable {
        var pairings: [LinkPairing] = []
        var selectedID: String?

        var selected: LinkPairing? {
            pairings.first { $0.id == selectedID } ?? pairings.first
        }
    }

    private static let service = "dev.levi.XNotch.companion"
    private static let account = "pairings"

    /// `<Team ID>.dev.levi.XNotch.companion`, from the entitlement written into Info.plist.
    private static var accessGroup: String? {
        guard let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String,
              !prefix.isEmpty, !prefix.hasPrefix("$(") else { return nil }
        return prefix + "dev.levi.XNotch.companion"
    }

    private static func query(group: String?) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        if let group { query[kSecAttrAccessGroup as String] = group }
        return query
    }

    /// The shared group first; the app's own Keychain if this build can't use it.
    private static var groups: [String?] { accessGroup.map { [$0, nil] } ?? [nil] }

    static func load() -> Stored {
        for group in groups {
            var lookup = query(group: group)
            lookup[kSecReturnData as String] = true
            lookup[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            if SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
               let stored = try? JSONDecoder().decode(Stored.self, from: data) {
                return stored
            }
        }
        return Stored()
    }

    static func save(_ stored: Stored) {
        guard let data = try? JSONEncoder().encode(stored) else { return }
        for group in groups {
            let query = query(group: group)
            var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var item = query
                item[kSecValueData as String] = data
                // The Share extension runs while the phone is unlocked; nothing needs it before first unlock.
                item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                status = SecItemAdd(item as CFDictionary, nil)
            }
            if status == errSecSuccess { return }
        }
    }
}

enum ThisDevice {
    @MainActor static var link: LinkDevice {
        let idiom = UIDevice.current.userInterfaceIdiom
        return LinkDevice(id: UIDevice.current.identifierForVendor?.uuidString ?? "unknown",
                          name: UIDevice.current.name,
                          kind: idiom == .pad ? .iPad : .iPhone)
    }

    /// Where files arrive before they're moved into place.
    static var incomingDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Incoming", isDirectory: true)
    }
}
