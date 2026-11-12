import Foundation

/// What travels inside a sealed envelope.
///
/// ```
/// body = u32 len(header) || header JSON || attachment_0 || attachment_1 || …
/// ```
/// The header names each attachment's size, in order.
struct WireMessage: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        /// A voice note: one `audio/mp4` attachment.
        case voice
        /// Files, one attachment each.
        case files
        case text
        case todo
        /// A to-do the recipient sent was ticked off (or unticked).
        case todoDone
        /// Not stored: the sender started or stopped holding the recipient's face.
        case talking
    }

    struct File: Codable, Sendable, Equatable {
        var name: String
        var size: Int
    }

    /// How to reply: sent until the other side has written back once.
    struct Introduction: Codable, Sendable, Equatable {
        /// `WalkieCrypto.SignedCard`, base64.
        var card: String
        /// Our send token, hex: lets them post to our mailbox.
        var postToken: String
    }

    var kind: Kind
    var id: String
    var at: Date
    var text: String?
    /// Voice: seconds.
    var duration: Double?
    /// Voice: loudness over time, 0…255, about 24 per second.
    var levels: [UInt8]?
    var files: [File]?
    var remindAt: Date?
    /// todoDone: which to-do. talking: nil.
    var ref: String?
    var done: Bool?
    /// talking: whether they are holding the face now.
    var active: Bool?
    var intro: Introduction?

    init(kind: Kind, id: String = UUID().uuidString, at: Date = Date()) {
        self.kind = kind
        self.id = id
        // Whole milliseconds, as the wire carries them.
        self.at = Date(timeIntervalSince1970: (at.timeIntervalSince1970 * 1000).rounded() / 1000)
    }
}

enum WireCodec {
    static let maxHeader = 512 * 1024

    enum Failure: Error { case malformed }

    static func encode(_ message: WireMessage, attachments: [Data] = []) throws -> Data {
        let header = try WalkieJSON.encoder.encode(message)
        var body = UInt32(header.count).bigEndianBytes + header
        for attachment in attachments { body.append(attachment) }
        return body
    }

    /// The header and the attachments, split by the sizes the header names.
    static func decode(_ body: Data) throws -> (WireMessage, [Data]) {
        let body = Data(body)
        guard body.count >= 4 else { throw Failure.malformed }
        let length = Int(body.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        guard length <= maxHeader, body.count >= 4 + length else { throw Failure.malformed }
        let message = try WalkieJSON.decoder.decode(WireMessage.self, from: body.subdata(in: 4..<(4 + length)))
        var offset = 4 + length
        var attachments: [Data] = []
        let sizes: [Int] = switch message.kind {
        case .files: (message.files ?? []).map(\.size)
        case .voice: [body.count - offset]
        default: []
        }
        for size in sizes {
            guard size >= 0, offset + size <= body.count else { throw Failure.malformed }
            attachments.append(body.subdata(in: offset..<(offset + size)))
            offset += size
        }
        guard offset == body.count else { throw Failure.malformed }
        return (message, attachments)
    }
}

/// An invite: everything needed to reach someone and check their card.
///
/// `xnotch-walkie:` + base64url(JSON {s, b, t, f}), where `f` is the full
/// fingerprint of their keys, so the server can't swap the card it serves.
struct WalkieInvite: Equatable, Sendable {
    static let scheme = "xnotch-walkie:"

    var server: String
    var box: String
    var postToken: Data
    var fingerprint: Data

    private struct Payload: Codable {
        var s: String
        var b: String
        var t: String
        var f: String
    }

    var text: String {
        let payload = Payload(s: server, b: box, t: postToken.hex, f: fingerprint.hex)
        let json = (try? WalkieJSON.encoder.encode(payload)) ?? Data()
        return Self.scheme + json.base64URL
    }

    init(server: String, box: String, postToken: Data, fingerprint: Data) {
        self.server = server
        self.box = box
        self.postToken = postToken
        self.fingerprint = fingerprint
    }

    /// Accepts the invite with surrounding text, as pasted from a chat.
    init?(text: String) {
        guard let range = text.range(of: Self.scheme) else { return nil }
        let encoded = text[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard let data = Data(base64URL: String(encoded)),
              let payload = try? WalkieJSON.decoder.decode(Payload.self, from: data),
              isBoxID(payload.b), let token = Data(hex: payload.t), token.count == 32,
              let fingerprint = Data(hex: payload.f), fingerprint.count == 32,
              let url = URL(string: payload.s), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        self.init(server: payload.s, box: payload.b, postToken: token, fingerprint: fingerprint)
    }
}
