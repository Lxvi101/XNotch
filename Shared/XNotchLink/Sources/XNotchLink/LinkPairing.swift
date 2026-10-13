import CryptoKit
import Foundation

/// What a phone needs to reach one Mac, shown on the Mac as a QR code. The
/// key never leaves the two devices: it authenticates and encrypts the link.
public struct LinkPairing: Codable, Hashable, Identifiable, Sendable {
    /// The Mac's link ID, advertised in its Bonjour TXT record.
    public var id: String
    /// The Mac's name, for display.
    public var name: String
    /// 32-byte pre-shared key.
    public var key: Data
    /// The Mac's relay server, for reaching it over the internet. Also
    /// learned from the Mac's hello, so it can be added after pairing.
    public var relay: URL?

    public static let scheme = "xnotchlink"

    public init(id: String, name: String, key: Data, relay: URL? = nil) {
        self.id = id
        self.name = name
        self.key = key
        self.relay = relay
    }

    public static func generateKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    /// `xnotchlink://pair?v=1&id=…&name=…&key=…`
    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "key", value: key.base64URLEncodedString())
        ]
        if let relay { components.queryItems?.append(URLQueryItem(name: "relay", value: relay.absoluteString)) }
        return components.url!
    }

    public init?(url: URL) {
        guard url.scheme == Self.scheme, url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("v") == "1",
              let id = value("id"), !id.isEmpty, id.count <= 64,
              let name = value("name"), !name.isEmpty,
              let encoded = value("key"), let key = Data(base64URLEncoded: encoded), key.count == 32 else { return nil }
        let relay = value("relay").flatMap(URL.init(string:)).flatMap { ["https", "http"].contains($0.scheme) ? $0 : nil }
        self.init(id: id, name: String(name.prefix(80)), key: key, relay: relay)
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}

extension LinkPairing {
    /// Derived from the key, so both sides compute it and only they know it.
    func tag(_ purpose: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(purpose.utf8), using: SymmetricKey(data: key)))
    }
}
