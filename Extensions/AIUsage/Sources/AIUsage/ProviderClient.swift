import Foundation

// MARK: Transport

struct HTTPResponse: Sendable {
    var statusCode: Int
    var headers: [String: String]
    var data: Data

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// The only way providers reach the network, so tests can swap it out.
protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

enum TransportError: Error, Equatable {
    /// The request's host isn't one this extension may send credentials to.
    case hostNotAllowed(String)
}

/// Ephemeral URLSession: no cookie jar, no URL cache, no credential store, and no redirects, so a
/// bearer token or cookie only ever goes to the host it was written for.
final class URLSessionTransport: NSObject, HTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
    static let allowedHosts: Set<String> = ["api.anthropic.com", "cursor.com", "api2.cursor.sh", "chatgpt.com", "chat.openai.com"]

    private let session: URLSession
    private let extraHosts: @Sendable () -> Set<String>

    /// `extraHosts` admits a host the user configured themselves, like Codex's `chatgpt_base_url`.
    init(extraHosts: @escaping @Sendable () -> Set<String> = { [] }) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.extraHosts = extraHosts
        session = URLSession(configuration: configuration)
        super.init()
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        guard let url = request.url, url.scheme == "https", let host = url.host?.lowercased(),
              Self.allowedHosts.contains(host) || extraHosts().contains(host) else {
            throw TransportError.hostNotAllowed(request.url?.host ?? "?")
        }
        let (data, response) = try await session.data(for: request, delegate: self)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        return HTTPResponse(statusCode: http.statusCode, headers: headers, data: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

// MARK: Providers

struct FetchContext: Sendable {
    /// True only for a click (Refresh, Allow Access). Nothing else may show a Keychain prompt.
    var isInteractive = false
    /// Optional extras (saved resets, model limits, spend, Grok Bot) on top of the core quotas.
    var includeExtras = true
    var now = Date()
}

protocol UsageProvider: AnyObject, Sendable {
    var id: AIProviderID { get }
    func fetch(_ context: FetchContext) async throws -> ProviderUsageSnapshot
}

/// A failed fetch, with what the provider could tell about the account without the network, so a
/// stale reading is only kept when it belongs to the same login.
struct ProviderFailure: Error, Sendable {
    enum Kind: Equatable, Sendable {
        case notConnected
        case needsKeychainAccess
        case unauthorized
        case rateLimited(retryAfter: Date?)
        /// Network trouble, timeouts, 5xx: worth retrying later.
        case unavailable
        case invalidResponse
    }

    var kind: Kind
    var message: String
    var accountKey: String?
    var credentialFingerprint: String?

    init(_ kind: Kind, _ message: String, accountKey: String? = nil, credentialFingerprint: String? = nil) {
        self.kind = kind
        self.message = message
        self.accountKey = accountKey
        self.credentialFingerprint = credentialFingerprint
    }

    func identified(accountKey: String?, fingerprint: String?) -> ProviderFailure {
        var copy = self
        copy.accountKey = copy.accountKey ?? accountKey
        copy.credentialFingerprint = copy.credentialFingerprint ?? fingerprint
        return copy
    }

    /// Maps transport errors without ever including response bodies, which can carry identifiers.
    static func from(_ error: Error, provider: AIProviderID) -> ProviderFailure {
        if let failure = error as? ProviderFailure { return failure }
        if let transport = error as? TransportError, case let .hostNotAllowed(host) = transport {
            return ProviderFailure(.invalidResponse, "Refused to send \(provider.displayName) credentials to \(host).")
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return ProviderFailure(.unavailable, "\(provider.displayName) didn't answer in time.")
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                 .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .secureConnectionFailed:
                return ProviderFailure(.unavailable, "Offline: couldn't reach \(provider.displayName).")
            default:
                return ProviderFailure(.unavailable, "Network error reaching \(provider.displayName) (\(urlError.code.rawValue)).")
            }
        }
        if error is DecodingError {
            return ProviderFailure(.invalidResponse, "\(provider.displayName) sent usage in an unexpected format.")
        }
        return ProviderFailure(.unavailable, "Couldn't reach \(provider.displayName).")
    }

    /// Shared status handling for usage endpoints.
    static func check(_ response: HTTPResponse, provider: AIProviderID, signInHint: String, now: Date) throws {
        switch response.statusCode {
        case 200...299:
            return
        case 401, 403:
            throw ProviderFailure(.unauthorized, "\(provider.displayName) rejected the saved login. \(signInHint)")
        case 429:
            throw ProviderFailure(.rateLimited(retryAfter: RetryAfter.date(from: response, now: now)),
                                  "\(provider.displayName) is rate limiting usage requests. XNotch will wait before asking again.")
        case 500...599:
            throw ProviderFailure(.unavailable, "\(provider.displayName) is having trouble (HTTP \(response.statusCode)).")
        default:
            throw ProviderFailure(.invalidResponse, "\(provider.displayName) usage request failed (HTTP \(response.statusCode)).")
        }
    }
}

// MARK: Parsing helpers

enum RetryAfter {
    /// Seconds or an HTTP date.
    static func date(from response: HTTPResponse, now: Date) -> Date? {
        guard let raw = response.header("Retry-After")?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return nil
        }
        if let seconds = TimeInterval(raw), seconds >= 0, seconds.isFinite {
            return now.addingTimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return formatter.date(from: raw)
    }
}

enum ISO8601 {
    static func parse(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}

enum JWT {
    /// The payload claims, without verifying the signature: only used to read expiry and identity of a
    /// token the provider's own app already trusts.
    static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, !parts[1].isEmpty else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func expiry(_ token: String) -> Date? {
        guard let exp = claims(token)?["exp"] as? NSNumber else { return nil }
        let seconds = exp.doubleValue
        guard seconds.isFinite, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Lowercased alphanumerics joined by dashes, for stable window IDs.
    var slug: String {
        var result = ""
        var lastWasDash = false
        for scalar in lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                result.append("-")
                lastWasDash = true
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

extension Optional where Wrapped == String {
    var nonEmpty: String? { self?.nonEmpty }
}

/// Decodes a value without failing its container, so one odd field can't sink a whole response.
struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension KeyedDecodingContainer where Key == AnyCodingKey {
    /// The first key that decodes, ignoring type mismatches.
    func lenient<T: Decodable>(_ type: T.Type, _ keys: String...) -> T? {
        for key in keys {
            if let value = try? decodeIfPresent(T.self, forKey: AnyCodingKey(key)) { return value }
        }
        return nil
    }

    /// A number that may arrive as a JSON number or a numeric string.
    func number(_ keys: String...) -> Double? {
        for key in keys {
            let codingKey = AnyCodingKey(key)
            if let value = try? decodeIfPresent(Double.self, forKey: codingKey), value.isFinite { return value }
            if let string = try? decodeIfPresent(String.self, forKey: codingKey),
               let value = Double(string.trimmingCharacters(in: .whitespaces)), value.isFinite {
                return value
            }
        }
        return nil
    }
}
