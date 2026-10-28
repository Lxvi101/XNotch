import Foundation
import UniformTypeIdentifiers

/// Where a link rule finds the file a link stands for.
enum LinkSource: String, Codable, CaseIterable, Identifiable {
    /// The link points straight at the file.
    case link
    /// The page's preview image, from its `og:image` or `twitter:image` tag.
    case previewImage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .link: "The link itself"
        case .previewImage: "The page\u{2019}s preview image"
        }
    }
}

/// Turns a dropped link into the file it stands for: a pin into its image, a
/// link to a picture into the picture. Hosts and paths are patterns where `*`
/// stands for anything; a host pattern also covers its subdomains.
struct LinkRule: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var isEnabled = true
    var hosts: [String]
    /// Empty for any path.
    var paths: [String] = []
    var source: LinkSource
    /// A regular expression replaced in the file's address before it's
    /// downloaded, like a thumbnail's size for the original's. The address as
    /// found is the fallback.
    var find = ""
    var replace = ""

    /// Rules that come with XNotch can be turned off but not deleted.
    var isBuiltIn: Bool { Self.builtIn.contains { $0.id == id } }

    func matches(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased()), let host = url.host()?.lowercased() else { return false }
        let path = url.path(percentEncoded: false)
        return hosts.contains { Self.host(host, matches: $0) }
            && (paths.isEmpty || paths.contains { Self.glob($0, matches: path) })
    }

    /// "pinterest.*" covers pinterest.com and de.pinterest.com.
    static func host(_ host: String, matches pattern: String) -> Bool {
        if glob(pattern, matches: host) { return true }
        var rest = Substring(host)
        while let dot = rest.firstIndex(of: ".") {
            rest = rest[rest.index(after: dot)...]
            if glob(pattern, matches: String(rest)) { return true }
        }
        return false
    }

    /// Case-insensitive, with `*` for any run of characters.
    static func glob(_ pattern: String, matches text: String) -> Bool {
        let p = Array(pattern.lowercased()), t = Array(text.lowercased())
        var pi = 0, ti = 0
        var star: Int?, resume = 0
        while ti < t.count {
            if pi < p.count, p[pi] != "*", p[pi] == t[ti] {
                pi += 1
                ti += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi
                resume = ti
                pi += 1
            } else if let star {
                pi = star + 1
                resume += 1
                ti = resume
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    /// The pattern lists as they're typed: separated by commas or spaces.
    static func patterns(from text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
    }
}

extension LinkRule {
    /// The rules XNotch comes with, first match wins. Their ids never change,
    /// so saved settings keep finding them.
    static let builtIn: [LinkRule] = [
        LinkRule(id: UUID(uuidString: "5B0F3C1E-8A4D-4E57-9C61-2F7D0A9B1E01")!,
                 name: "Pinterest pins", hosts: ["pinterest.*"], paths: ["/pin/*"],
                 source: .previewImage, find: "/\\d+x/", replace: "/originals/"),
        LinkRule(id: UUID(uuidString: "5B0F3C1E-8A4D-4E57-9C61-2F7D0A9B1E02")!,
                 name: "Links to images", hosts: ["*"],
                 paths: ["*.jpg", "*.jpeg", "*.png", "*.gif", "*.webp", "*.avif", "*.heic", "*.tiff", "*.bmp"],
                 source: .link),
    ]
}

/// Rules as files, to share them or write them by hand. Only a rule's name,
/// hosts and source are required:
///
///     {"rules": [{"name": "Dribbble shots", "hosts": ["dribbble.com"],
///                 "paths": ["/shots/*"], "source": "previewImage"}]}
extension LinkRule {
    private struct File: Codable {
        var rules: [LinkRule]
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        hosts = try container.decode([String].self, forKey: .hosts)
        paths = try container.decodeIfPresent([String].self, forKey: .paths) ?? []
        source = try container.decode(LinkSource.self, forKey: .source)
        find = try container.decodeIfPresent(String.self, forKey: .find) ?? ""
        replace = try container.decodeIfPresent(String.self, forKey: .replace) ?? ""
    }

    static func export(_ rules: [LinkRule]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(File(rules: rules))
    }

    /// Reads an exported file, a list of rules or a single rule.
    static func rules(from data: Data) throws -> [LinkRule] {
        let decoder = JSONDecoder()
        if let file = try? decoder.decode(File.self, from: data) { return file.rules }
        if let rules = try? decoder.decode([LinkRule].self, from: data) { return rules }
        return [try decoder.decode(LinkRule.self, from: data)]
    }
}

/// Downloads the file a rule finds for a link.
enum LinkResolver {
    enum Failure: LocalizedError {
        case noPreviewImage, notAFile, badRewrite

        var errorDescription: String? {
            switch self {
            case .noPreviewImage: "The page has no preview image."
            case .notAFile: "The link leads to a page, not a file."
            case .badRewrite: "The rewrite isn\u{2019}t a valid regular expression."
            }
        }
    }

    /// The first rule that covers a link.
    static func rule(for url: URL, in rules: [LinkRule]) -> LinkRule? {
        rules.first { $0.isEnabled && $0.matches(url) }
    }

    /// Where the file is, best first: rewritten by the rule, then as found.
    static func addresses(for url: URL, with rule: LinkRule) async throws -> [URL] {
        let found = switch rule.source {
        case .link: url
        case .previewImage: try await previewImage(of: url)
        }
        guard !rule.find.isEmpty else { return [found] }
        guard let regex = try? NSRegularExpression(pattern: rule.find) else { throw Failure.badRewrite }
        let address = found.absoluteString
        let rewritten = regex.stringByReplacingMatches(in: address, range: NSRange(address.startIndex..., in: address),
                                                       withTemplate: rule.replace)
        guard rewritten != address, let better = URL(string: rewritten) else { return [found] }
        return [better, found]
    }

    /// Downloads the file into `folder`, trying each address in turn.
    static func download(_ url: URL, with rule: LinkRule, into folder: URL) async throws -> URL {
        var failure: Error = Failure.notAFile
        for address in try await addresses(for: url, with: rule) {
            do { return try await fetch(address, into: folder) } catch { failure = error }
        }
        throw failure
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 30
        // Sites answer a browser with the page people see.
        configuration.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"]
        return URLSession(configuration: configuration)
    }()

    private static func fetch(_ url: URL, into folder: URL) async throws -> URL {
        let (temporary, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.mimeType != "text/html" else { throw Failure.notAFile }
        var name = response.suggestedFilename ?? url.lastPathComponent
        if (name as NSString).pathExtension.isEmpty,
           let ext = http.mimeType.flatMap({ UTType(mimeType: $0) })?.preferredFilenameExtension {
            name += ".\(ext)"
        }
        let destination = folder.appendingPathComponent(name.replacingOccurrences(of: "/", with: "-"))
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    private static func previewImage(of page: URL) async throws -> URL {
        let (data, response) = try await session.data(from: page)
        let html = String(decoding: data, as: UTF8.self)
        guard let address = previewImage(in: html),
              let url = URL(string: address, relativeTo: response.url ?? page)?.absoluteURL else { throw Failure.noPreviewImage }
        return url
    }

    private static let previewTags = ["og:image:secure_url", "og:image:url", "og:image", "twitter:image", "twitter:image:src"]
    private static let metaTag = try! NSRegularExpression(pattern: "<meta\\b[^>]*>", options: .caseInsensitive)
    private static let attribute = try! NSRegularExpression(pattern: "([\\w:-]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')")

    /// The address in a page's preview image tag.
    static func previewImage(in html: String) -> String? {
        var found: [String: String] = [:]
        for tag in metaTag.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            let text = String(html[Range(tag.range, in: html)!])
            var attributes: [String: String] = [:]
            for match in attribute.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let key = String(text[Range(match.range(at: 1), in: text)!]).lowercased()
                let value = [2, 3].lazy.compactMap { Range(match.range(at: $0), in: text) }.first.map { String(text[$0]) }
                attributes[key] = value
            }
            guard let key = (attributes["property"] ?? attributes["name"])?.lowercased(),
                  previewTags.contains(key), found[key] == nil,
                  let content = attributes["content"], !content.isEmpty else { continue }
            found[key] = decodingEntities(content)
        }
        return previewTags.lazy.compactMap { found[$0] }.first
    }

    private static func decodingEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#x2F;", with: "/")
            .replacingOccurrences(of: "&#47;", with: "/")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}
