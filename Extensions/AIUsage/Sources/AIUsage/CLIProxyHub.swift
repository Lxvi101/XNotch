import Foundation
import Security

/// A CLIProxyAPI hub that Claude Code or Codex sends its requests to instead of the provider. The
/// subscription logins then live on the hub, so their limits are read there, through the hub's management
/// `api-call` relay: the hub puts in each login's own token, which never reaches this Mac.
struct CLIProxyHub: Equatable, Sendable {
    /// Stands in for the subscription token in relayed requests; the hub swaps in the login's own.
    static let tokenPlaceholder = "$TOKEN$"

    /// The hub's origin, e.g. `https://hub.example.ts.net:8317`.
    var baseURL: URL
    var managementKey: String

    var host: String { baseURL.host?.lowercased() ?? "" }

    struct Account: Equatable, Sendable {
        var authIndex: String
        /// The hub's auth file name: stable across token refreshes, so it orders and keys the login.
        var id: String
        var email: String?
    }

    /// The hub's logins for one provider (`codex`, `claude`), in a stable order. Cooling-down logins stay
    /// in: their limits are exactly what's worth seeing.
    func accounts(provider: AIProviderID, transport: HTTPTransport) async throws -> [Account] {
        try await allAccounts(transport: transport).filter { $0.provider == provider }.map(\.account)
    }

    /// How many logins the hub holds per provider XNotch shows, for the Connect sheet to confirm.
    func inventory(transport: HTTPTransport) async throws -> [AIProviderID: Int] {
        try await allAccounts(transport: transport).reduce(into: [:]) { $0[$1.provider, default: 0] += 1 }
    }

    private func allAccounts(transport: HTTPTransport) async throws -> [(provider: AIProviderID, account: Account)] {
        var request = URLRequest(url: baseURL.appendingPathComponent("v0/management/auth-files"),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await send(request, transport)
        guard let root = (try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any],
              let files = root["files"] as? [[String: Any]] else {
            throw ProviderFailure(.invalidResponse, "Your CLIProxyAPI hub at \(host) listed its logins in an unexpected format.")
        }
        return files.compactMap { file -> (AIProviderID, Account)? in
            let kind = ((file["provider"] as? String).nonEmpty ?? (file["type"] as? String).nonEmpty)?.lowercased()
            guard let provider = kind.flatMap(AIProviderID.init(rawValue:)), (file["disabled"] as? Bool) != true,
                  (file["status"] as? String)?.lowercased() != "disabled",
                  let index = (file["auth_index"] as? String).nonEmpty else { return nil }
            let id = (file["id"] as? String).nonEmpty ?? (file["name"] as? String).nonEmpty ?? index
            return (provider, Account(authIndex: index, id: id,
                                      email: (file["email"] as? String).nonEmpty ?? (file["account"] as? String).nonEmpty))
        }
        .sorted { $0.1.id < $1.1.id }
    }

    /// Sends a provider request as `account`, through the hub.
    func relay(for account: Account, transport: HTTPTransport) -> HTTPTransport {
        CLIProxyRelayTransport(hub: self, authIndex: account.authIndex, transport: transport)
    }

    func send(_ request: URLRequest, _ transport: HTTPTransport) async throws -> HTTPResponse {
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch let error as URLError {
            throw ProviderFailure(.unavailable, error.code == .timedOut
                ? "Your CLIProxyAPI hub at \(host) didn't answer in time."
                : "Couldn't reach your CLIProxyAPI hub at \(host). Is it running, and is this Mac on its network?")
        }
        switch response.statusCode {
        case 200...299:
            return response
        case 403 where String(decoding: response.data, as: UTF8.self).lowercased().contains("banned"):
            // Too many wrong keys from this Mac. Asking again only extends the lockout, so wait it out.
            let wait = Self.lockout(in: response)
            throw ProviderFailure(.rateLimited(retryAfter: wait.map { Date().addingTimeInterval($0) }),
                                  "Your CLIProxyAPI hub at \(host) locked this Mac out after too many wrong management keys. "
                                  + (wait.map { "It lets XNotch in again in \(Int(($0 / 60).rounded(.up))) min." } ?? "Try again later."))
        case 401, 403:
            throw ProviderFailure(.unauthorized, "Your CLIProxyAPI hub at \(host) rejected the management key. It's the "
                + "`remote-management.secret-key` from the hub's config.")
        case 404:
            throw ProviderFailure(.unavailable, "Your CLIProxyAPI hub at \(host) has remote management off. "
                + CLIProxyHub.managementHint(host: host))
        case 429:
            throw ProviderFailure(.rateLimited(retryAfter: RetryAfter.date(from: response, now: Date())),
                                  "Your CLIProxyAPI hub at \(host) is limiting requests. XNotch will wait before asking again.")
        default:
            throw ProviderFailure(.unavailable, "Your CLIProxyAPI hub at \(host) answered HTTP \(response.statusCode).")
        }
    }

    /// "Try again in 25m37s" from the hub's lockout answer, in seconds.
    static func lockout(in response: HTTPResponse) -> TimeInterval? {
        let text = String(decoding: response.data, as: UTF8.self).lowercased()
        guard let range = text.range(of: "try again in ") else { return nil }
        var total: TimeInterval = 0
        var number = ""
        for character in text[range.upperBound...] {
            if character.isNumber || character == "." {
                number.append(character)
            } else if let value = Double(number), let unit = ["h": 3600.0, "m": 60, "s": 1][String(character)] {
                total += value * unit
                number = ""
            } else {
                break
            }
        }
        return total > 0 ? total : nil
    }

    /// What to change in the hub's config so XNotch may read it.
    static func managementHint(host: String) -> String {
        CLIProxyHubLocator.isLoopback(host)
            ? "Set `remote-management.secret-key` in its config and restart it."
            : "Set `remote-management.allow-remote: true` and a `secret-key` in its config, then restart it."
    }

    // MARK: Several logins

    /// One reading for all of a provider's hub logins. With several, each login keeps its main window as a
    /// glance tile ("Account 1", "Account 2", in the order the account label lists them) and the rest move
    /// behind the details. A login that couldn't be read keeps its place with an unknown value.
    func merge(_ readings: [Result<ProviderUsageSnapshot, Error>], provider: AIProviderID, now: Date) throws -> ProviderUsageSnapshot {
        let snapshots = readings.compactMap { try? $0.get() }
        guard !snapshots.isEmpty else {
            throw readings.lazy.compactMap { result -> Error? in
                if case let .failure(error) = result { return error } else { return nil }
            }.first.map { ProviderFailure.from($0, provider: provider) }
                ?? ProviderFailure(.notConnected, "Your CLIProxyAPI hub at \(host) has no \(provider.displayName) login.")
        }
        if readings.count == 1, var only = snapshots.first {
            only.source = .cliProxyHub
            return only
        }

        var core: [QuotaWindow] = []
        var extra: [QuotaWindow] = []
        var accountKeys: [String] = []
        var spendLines: [SpendLine] = []
        var savedResets = 0
        var nextExpiry: Date?
        for (offset, result) in readings.enumerated() {
            let ordinal = "Account \(offset + 1)"
            switch result {
            case let .success(reading):
                accountKeys.append(reading.accountKey)
                let main = reading.coreWindows.first { $0.windowSeconds == TodayPace.week } ?? reading.coreWindows.first
                for window in reading.windows {
                    var copy = window
                    copy.id = "\(provider.rawValue).hub.\(reading.accountKey).\(window.id)"
                    copy.label = "\(window.label) · \(ordinal)"
                    copy.isCore = window.id == main?.id
                    copy.shortLabel = copy.isCore ? ordinal : nil
                    if copy.isCore { core.append(copy) } else { extra.append(copy) }
                }
                spendLines += (reading.spending?.lines ?? []).map {
                    var line = $0
                    line.id = "\(reading.accountKey).\(line.id)"
                    line.label = "\(line.label) · \(ordinal)"
                    return line
                }
                savedResets += reading.credits?.savedResets ?? 0
                if let expiry = reading.credits?.savedResetsNextExpiry { nextExpiry = min(nextExpiry ?? expiry, expiry) }
            case let .failure(error):
                accountKeys.append("unread-\(offset)")
                core.append(QuotaWindow(id: "\(provider.rawValue).hub.unread-\(offset)", label: ordinal, percentUsed: nil,
                                        resetsAt: nil, windowSeconds: nil,
                                        detail: ProviderFailure.from(error, provider: provider).message, isCore: true,
                                        shortLabel: ordinal))
            }
        }

        let plans = snapshots.compactMap(\.planLabel)
        let planLabel: String? = Set(plans).count == 1 && plans.count == readings.count
            ? "\(readings.count)× \(plans[0])"
            : (plans.isEmpty ? nil : plans.joined(separator: " + "))
        let accountLabel = snapshots.compactMap(\.accountLabel)
        let credits = CreditSummary(savedResets: savedResets, savedResetsNextExpiry: nextExpiry)
        return ProviderUsageSnapshot(
            provider: provider,
            accountKey: Hashing.key("\(provider.rawValue)-hub", accountKeys.joined(separator: ",")),
            credentialFingerprint: Hashing.key("\(provider.rawValue)-hub-credential", host, accountKeys.joined(separator: ",")),
            planLabel: planLabel,
            accountLabel: accountLabel.isEmpty ? nil : accountLabel.joined(separator: " · "),
            windows: core + extra, refreshedAt: now,
            credits: credits.isEmpty ? nil : credits,
            spending: spendLines.isEmpty ? nil : SpendingSummary(lines: spendLines),
            source: .cliProxyHub)
    }
}

/// Wraps a provider request into the hub's `POST /v0/management/api-call` and unwraps the answer, so the
/// providers' own request and mapping code runs unchanged. Only the providers' official hosts are relayed.
struct CLIProxyRelayTransport: HTTPTransport {
    let hub: CLIProxyHub
    let authIndex: String
    let transport: HTTPTransport

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        guard let url = request.url, url.scheme == "https", let host = url.host?.lowercased(),
              URLSessionTransport.allowedHosts.contains(host) else {
            throw TransportError.hostNotAllowed(request.url?.host ?? "?")
        }
        var headers = (request.allHTTPHeaderFields ?? [:]).filter { $0.key.caseInsensitiveCompare("Authorization") != .orderedSame }
        headers["Authorization"] = "Bearer \(CLIProxyHub.tokenPlaceholder)"
        var call: [String: Any] = ["auth_index": authIndex, "method": request.httpMethod ?? "GET",
                                   "url": url.absoluteString, "header": headers]
        if let body = request.httpBody, let text = String(data: body, encoding: .utf8) { call["data"] = text }

        var relay = URLRequest(url: hub.baseURL.appendingPathComponent("v0/management/api-call"),
                               cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: request.timeoutInterval + 5)
        relay.httpMethod = "POST"
        relay.setValue("Bearer \(hub.managementKey)", forHTTPHeaderField: "Authorization")
        relay.setValue("application/json", forHTTPHeaderField: "Content-Type")
        relay.setValue("application/json", forHTTPHeaderField: "Accept")
        relay.httpBody = try JSONSerialization.data(withJSONObject: call)

        let response = try await hub.send(relay, transport)
        guard let root = (try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any],
              let status = (root["status_code"] as? NSNumber)?.intValue else {
            throw ProviderFailure(.invalidResponse, "Your CLIProxyAPI hub at \(hub.host) relayed an unexpected answer.")
        }
        var unwrapped: [String: String] = [:]
        for (name, value) in root["header"] as? [String: Any] ?? [:] {
            if let text = value as? String { unwrapped[name] = text }
            else if let list = value as? [String] { unwrapped[name] = list.joined(separator: ", ") }
        }
        let data: Data
        switch root["body"] {
        case let text as String:
            data = Data(text.utf8)
        case let object? where JSONSerialization.isValidJSONObject(object):
            data = try JSONSerialization.data(withJSONObject: object)
        default:
            data = Data()
        }
        return HTTPResponse(statusCode: status, headers: unwrapped, data: data)
    }
}

/// What a provider's own tool sends its requests to, as far as XNotch can tell.
enum ProxyRoute: Equatable, Sendable {
    /// The provider's own API.
    case direct
    /// A CLIProxyAPI hub XNotch reads limits from. `removable` is false when the key comes from the keys file.
    case connected(host: String, removable: Bool)
    /// A CLIProxyAPI hub XNotch has no key for. With management off, no key would help yet.
    case cliProxy(origin: URL, managementEnabled: Bool)
    /// Some other proxy, which can't report subscription limits.
    case otherProxy(host: String)
    /// A proxy that didn't answer, so XNotch couldn't tell.
    case unreachable(origin: URL)
}

/// Tells a CLIProxyAPI hub from other proxies without a key, and whether it takes management requests.
enum CLIProxyProbe {
    static func probe(_ origin: URL, transport: HTTPTransport) async -> ProxyRoute {
        @Sendable func get(_ path: String) async -> HTTPResponse? {
            var request = URLRequest(url: path.isEmpty ? origin : origin.appendingPathComponent(path),
                                     cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            return try? await transport.send(request)
        }
        async let rootResponse = get("")
        async let managementResponse = get("v0/management/config")
        let (root, management) = await (rootResponse, managementResponse)
        guard root != nil || management != nil else { return .unreachable(origin: origin) }

        let banner = root.map { String(decoding: $0.data, as: UTF8.self).lowercased() } ?? ""
        let refusal = management.map { String(decoding: $0.data, as: UTF8.self).lowercased() } ?? ""
        let askedForKey = [401, 403].contains(management?.statusCode ?? 0) && refusal.contains("management key")
        guard banner.contains("cli proxy api") || banner.contains("cliproxyapi") || askedForKey else {
            return .otherProxy(host: origin.host ?? "?")
        }
        return .cliProxy(origin: origin, managementEnabled: management.map { $0.statusCode != 404 } ?? false)
    }
}

/// Finds the hub a provider's own tool is pointed at, and XNotch's management key for it.
///
/// The key is the one the user entered in Settings, kept in XNotch's own Keychain item. For scripted setups,
/// `~/.config/cliproxyapi/hub-keys.json` (`{"url": "https://…:8317", "management_key": "…"}`) works too. A
/// provider goes through the hub only when its tool sends requests to that same host and port: Claude Code's
/// `ANTHROPIC_BASE_URL` (its settings.json `env`, or the environment), Codex's `openai_base_url` or its
/// selected `model_provider`'s `base_url`.
struct CLIProxyHubLocator: Sendable {
    static let keysFileDisplayPath = "~/.config/cliproxyapi/hub-keys.json"
    static let keychainName = "cliproxy.hub"
    /// Hosts that are the providers themselves, never a proxy.
    static let officialHosts: Set<String> = ["api.anthropic.com", "api.openai.com", "chatgpt.com", "chat.openai.com"]

    enum KeySource: Equatable, Sendable {
        case keychain
        case keysFile
    }

    var environment: [String: String] = ProcessInfo.processInfo.environment
    var home: URL = FileManager.default.homeDirectoryForCurrentUser
    var codexHome = CodexHome()
    var secrets: SecretStore?

    var keysFile: URL {
        if let custom = environment["CLIPROXY_HUB_KEYS"].nonEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent(".config/cliproxyapi/hub-keys.json")
    }

    /// The hub `provider`'s tool sends its requests to. Nil when the tool talks to the provider directly,
    /// or to a proxy XNotch has no management key for.
    func hub(for provider: AIProviderID) -> CLIProxyHub? {
        guard let routed = routedOrigin(for: provider), let saved = savedHub(), Self.sameOrigin(routed, saved.hub.baseURL) else {
            return nil
        }
        return saved.hub
    }

    /// What the tool goes through, when XNotch needs no network to tell.
    func knownRoute(for provider: AIProviderID) -> ProxyRoute? {
        guard routedOrigin(for: provider) != nil else { return .direct }
        guard let hub = hub(for: provider) else { return nil }
        return .connected(host: hub.host, removable: savedHub()?.source == .keychain)
    }

    /// Hosts the transport may send the management key to.
    var hosts: Set<String> {
        savedHub().map { [$0.hub.host] } ?? []
    }

    /// Proxy hosts the tools point at, which the probe may ask (without any key).
    var routedHosts: Set<String> {
        Set([AIProviderID.claude, .codex].compactMap { routedOrigin(for: $0)?.host?.lowercased() })
    }

    func savedHub() -> (hub: CLIProxyHub, source: KeySource)? {
        if case let .found(data) = secrets?.read(Self.keychainName, interactive: false), let hub = Self.decode(data) {
            return (hub, .keychain)
        }
        if let data = try? Data(contentsOf: keysFile), let hub = Self.decode(data) {
            return (hub, .keysFile)
        }
        return nil
    }

    /// Keeps a hub the user connected in Settings.
    func save(_ hub: CLIProxyHub) -> Bool {
        let object = ["url": hub.baseURL.absoluteString, "management_key": hub.managementKey]
        guard let secrets, let data = try? JSONSerialization.data(withJSONObject: object) else { return false }
        return secrets.write(Self.keychainName, value: data) == errSecSuccess
    }

    func forget() {
        _ = secrets?.delete(Self.keychainName)
    }

    private static func decode(_ data: Data) -> CLIProxyHub? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let url = (root["url"] as? String).nonEmpty.flatMap(origin),
              let key = (root["management_key"] as? String).nonEmpty else { return nil }
        return CLIProxyHub(baseURL: url, managementKey: key)
    }

    /// Where the tool sends requests, reduced to an origin; nil for the providers' own APIs.
    func routedOrigin(for provider: AIProviderID) -> URL? {
        let raw: String?
        switch provider {
        case .claude: raw = environment["ANTHROPIC_BASE_URL"].nonEmpty ?? claudeSettingsEnvironment()["ANTHROPIC_BASE_URL"].nonEmpty
        case .codex: raw = codexHome.routedBaseURL()
        case .cursor: raw = nil
        }
        guard let origin = raw.flatMap(Self.origin), let host = origin.host?.lowercased(),
              !Self.officialHosts.contains(host) else { return nil }
        return origin
    }

    private func claudeSettingsEnvironment() -> [String: String] {
        let directory = environment["CLAUDE_CONFIG_DIR"].nonEmpty.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? home.appendingPathComponent(".claude")
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("settings.json")),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return root["env"] as? [String: String] ?? [:]
    }

    /// `scheme://host:port` of an address the user or a tool gave. HTTPS, or plain HTTP to this Mac only,
    /// so the management key never crosses a network unencrypted. A bare host means HTTPS.
    static func origin(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              let host = url.host, !host.isEmpty,
              scheme == "https" || (scheme == "http" && isLoopback(host)) else { return nil }
        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host
        origin.port = url.port
        return origin.url
    }

    static func isLoopback(_ host: String) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
    }

    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        func port(_ url: URL) -> Int { url.port ?? (url.scheme == "http" ? 80 : 443) }
        return a.scheme == b.scheme && a.host?.lowercased() == b.host?.lowercased() && port(a) == port(b)
    }
}
