import Foundation

public enum LinkService {
    /// The Bonjour service a Mac advertises. Its TXT record carries the link ID under `idKey`.
    public static let type = "_xnotchlink._tcp"
    public static let idKey = "id"
    /// Longest text sent to the clipboard, in UTF-8 bytes.
    public static let maxTextBytes = 1 << 20
}

/// One end of the link.
public struct LinkDevice: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case mac, iPhone, iPad
    }

    public var id: String
    public var name: String
    public var kind: Kind

    public init(id: String, name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

/// A message frame. A `file` message is followed by `data` frames
/// carrying exactly `size` bytes.
struct LinkMessage: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case hello, file, text, ack, failure
    }

    var kind: Kind
    var id: UUID
    var name: String?
    var size: Int64?
    var text: String?
    var device: LinkDevice?
    var reason: String?
    /// In the Mac's hello: its relay server, for reaching it over the internet.
    var relay: URL?

    init(kind: Kind, id: UUID = UUID(), name: String? = nil, size: Int64? = nil, text: String? = nil,
         device: LinkDevice? = nil, reason: String? = nil, relay: URL? = nil) {
        self.kind = kind
        self.id = id
        self.name = name
        self.size = size
        self.text = text
        self.device = device
        self.reason = reason
        self.relay = relay
    }

    static let maxEncodedSize = 4 << 20
}

/// One record of a secure channel: a type byte, then the payload. A file is
/// a `file` message followed by `data` frames, so acknowledgements can travel
/// between its chunks.
enum LinkFrame {
    case message(LinkMessage)
    case data(Data)

    func encoded() throws -> Data {
        switch self {
        case .message(let message):
            let body = try JSONEncoder().encode(message)
            guard body.count <= LinkMessage.maxEncodedSize else { throw LinkError.protocolViolation("Message too large") }
            return Data([0]) + body
        case .data(let data):
            return Data([1]) + data
        }
    }

    static func decode(_ record: Data) throws -> LinkFrame {
        guard let type = record.first else { throw LinkError.protocolViolation("Empty frame") }
        let payload = record.dropFirst()
        switch type {
        case 0:
            do {
                return .message(try JSONDecoder().decode(LinkMessage.self, from: payload))
            } catch {
                throw LinkError.protocolViolation("Unreadable message")
            }
        case 1:
            return .data(Data(payload))
        default:
            throw LinkError.protocolViolation("Unknown frame")
        }
    }
}

public enum LinkError: LocalizedError, Sendable {
    case connectionFailed(String)
    case closed
    case timedOut
    case protocolViolation(String)
    case rejected(String)
    case notFound(String)
    case localNetworkDenied
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let name): "\(name) isn't on this network. Is XNotch running and on the same Wi-Fi?"
        case .localNetworkDenied: "Allow Local Network for XNotch in Settings → Privacy & Security → Local Network."
        case .unavailable(let reason): reason

        case .connectionFailed(let reason): "Couldn't connect: \(reason)"
        case .closed: "The connection closed."
        case .timedOut: "The other device didn't answer."
        case .protocolViolation(let reason): "Unexpected data: \(reason)"
        case .rejected(let reason): reason
        }
    }
}

/// Names from the other device become file names here: keep only the last
/// path component, without leading dots or path separators.
public func linkSafeFileName(_ name: String) -> String {
    let last = name.split(whereSeparator: { $0 == "/" || $0 == "\\" || $0 == ":" }).last.map(String.init) ?? ""
    // Control characters and bidi overrides go; joiners stay, so emoji and scripts that need them survive.
    let cleaned = String(String.UnicodeScalarView(last.unicodeScalars.filter { scalar in
        scalar.properties.generalCategory != .control && !(0x202A...0x202E).contains(scalar.value)
            && !(0x2066...0x2069).contains(scalar.value)
    }))
    .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
    guard !cleaned.isEmpty else { return "File" }
    return fitted(cleaned, maxBytes: 240)
}

/// Shortened to `maxBytes` of UTF-8 (the file system allows 255; the rest
/// leaves room for " 2"), cutting the name rather than the extension.
private func fitted(_ name: String, maxBytes: Int) -> String {
    guard name.utf8.count > maxBytes else { return name }
    let ext = (name as NSString).pathExtension
    let suffix = ext.isEmpty || ext.utf8.count > 16 ? "" : "." + ext
    var base = suffix.isEmpty ? name : String(name.dropLast(suffix.count))
    while base.utf8.count + suffix.utf8.count > maxBytes, !base.isEmpty { base.removeLast() }
    return base + suffix
}

/// `directory/name`, or `name 2.ext`, `name 3.ext`… when that's taken.
public func linkUniqueURL(for name: String, in directory: URL) -> URL {
    let base = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    var candidate = directory.appendingPathComponent(name)
    var counter = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
        let numbered = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
        candidate = directory.appendingPathComponent(numbered)
        counter += 1
    }
    return candidate
}
