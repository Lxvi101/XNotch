import Foundation

// Request flow, response shapes and mapping adapted from CodexBar (MIT, Copyright 2026 Peter Steinberger),
// ClaudeOAuthUsageFetcher.swift, ClaudeUsageFetcher.swift, ClaudeScopedWeeklyLimitMapper.swift and
// ClaudeRateLimitResetCredits.swift. See THIRD_PARTY_NOTICES.md.

/// Claude subscription quotas from the OAuth usage endpoint, with Claude Code's own login.
final class ClaudeUsageProvider: UsageProvider, @unchecked Sendable {
    let id = AIProviderID.claude

    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    static let betaHeader = "oauth-2025-04-20"
    /// Claude Code's version as sent by CodexBar when it can't detect one; XNotch doesn't spawn `claude`.
    static let claudeCodeVersion = "2.1.0"

    private let transport: HTTPTransport
    private let locator: ClaudeCredentialLocator
    private let keychainAllowed: @Sendable () -> Bool

    private let lock = NSLock()
    /// Memory only: saves a Keychain read per poll. Dropped on expiry or rejection.
    private var keychainCredentials: ClaudeOAuthCredentials?
    /// Credential fingerprint → account identity from /api/oauth/profile.
    private var identities: [String: Identity] = [:]

    struct Identity: Equatable, Sendable {
        var accountKey: String
        var email: String?
    }

    init(transport: HTTPTransport, locator: ClaudeCredentialLocator = ClaudeCredentialLocator(),
         keychainAllowed: @escaping @Sendable () -> Bool) {
        self.transport = transport
        self.locator = locator
        self.keychainAllowed = keychainAllowed
    }

    func fetch(_ context: FetchContext) async throws -> ProviderUsageSnapshot {
        let (credentials, source) = try loadCredentials(context)
        let fingerprint = credentials.fingerprint
        let knownKey = lock.withLock { identities[fingerprint]?.accountKey }

        guard credentials.canReadUsage else {
            throw ProviderFailure(.notConnected, "This Claude login can't read plan usage (it's limited to inference, "
                + "like `claude setup-token`). Sign in with `claude` instead.")
        }
        guard !credentials.isExpired(at: context.now) else {
            forgetKeychainCredentials()
            throw ProviderFailure(.unauthorized, "Claude Code's login has expired. Use Claude Code once so it can "
                + "renew it, then refresh. XNotch never renews or rewrites Claude Code's login.",
                accountKey: knownKey, credentialFingerprint: fingerprint)
        }

        do {
            let usage = try await fetchUsage(token: credentials.accessToken, includeInventory: context.includeExtras,
                                             now: context.now)
            let identity = await identity(for: credentials)
            return Self.snapshot(from: usage, credentials: credentials, identity: identity, source: source,
                                 includeExtras: context.includeExtras, now: context.now)
        } catch {
            var failure = ProviderFailure.from(error, provider: .claude)
            if failure.kind == .unauthorized { forgetKeychainCredentials() }
            failure = failure.identified(accountKey: knownKey, fingerprint: fingerprint)
            throw failure
        }
    }

    private func loadCredentials(_ context: FetchContext) throws -> (ClaudeOAuthCredentials, CredentialSource) {
        if !context.isInteractive, let cached = lock.withLock({ keychainCredentials }),
           !cached.isExpired(at: context.now), keychainAllowed() {
            return (cached, .claudeKeychain)
        }
        let loaded = try locator.load(keychainAllowed: keychainAllowed(), interactive: context.isInteractive)
        lock.withLock { keychainCredentials = loaded.1 == .claudeKeychain ? loaded.0 : nil }
        return loaded
    }

    private func forgetKeychainCredentials() {
        lock.withLock { keychainCredentials = nil }
    }

    // MARK: Requests

    func fetchUsage(token: String, includeInventory: Bool, now: Date) async throws -> ClaudeUsageResponse {
        var components = URLComponents(url: Self.usageURL, resolvingAgainstBaseURL: false)!
        if includeInventory { components.queryItems = [URLQueryItem(name: "cedar_ember", value: "1")] }
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-cli/\(Self.claudeCodeVersion) (external, cli)", forHTTPHeaderField: "User-Agent")

        var response = try await transport.send(request)
        let missingProfileScope = response.statusCode == 403
            && (String(data: response.data, encoding: .utf8)?.contains("user:profile") ?? false)
        if includeInventory, response.statusCode == 400 || (response.statusCode == 403 && !missingProfileScope) {
            // Only the optional reset inventory was refused: ask again for the core quotas alone.
            try Task.checkCancellation()
            request.url = Self.usageURL
            request.setValue("claude-code/\(Self.claudeCodeVersion)", forHTTPHeaderField: "User-Agent")
            response = try await transport.send(request)
        }
        if missingProfileScope {
            throw ProviderFailure(.unauthorized, "This Claude login can't read plan usage (missing the user:profile "
                + "permission). Sign in again with `claude`.")
        }
        try ProviderFailure.check(response, provider: .claude,
                                  signInHint: "Use Claude Code once so it can renew its login, then refresh.", now: now)
        do {
            return try JSONDecoder().decode(ClaudeUsageResponse.self, from: response.data)
        } catch {
            throw ProviderFailure(.invalidResponse, "Claude sent usage in an unexpected format.")
        }
    }

    /// The account behind a credential, looked up once per login. Without it the reading is keyed to
    /// the credential itself, which still never mixes two logins.
    private func identity(for credentials: ClaudeOAuthCredentials) async -> Identity {
        let fingerprint = credentials.fingerprint
        if let known = lock.withLock({ identities[fingerprint] }) { return known }
        var request = URLRequest(url: Self.profileURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        guard let response = try? await transport.send(request), response.statusCode == 200,
              let profile = try? JSONDecoder().decode(ClaudeProfileResponse.self, from: response.data),
              profile.accountID != nil || profile.organizationID != nil else {
            return Identity(accountKey: Hashing.key("claude-login", fingerprint), email: nil)
        }
        let identity = Identity(accountKey: Hashing.key("claude-account", profile.accountID ?? "", profile.organizationID ?? ""),
                                email: profile.email)
        lock.withLock {
            if identities.count > 8 { identities.removeAll() }
            identities[fingerprint] = identity
        }
        return identity
    }

    // MARK: Mapping

    static func snapshot(from usage: ClaudeUsageResponse, credentials: ClaudeOAuthCredentials, identity: Identity,
                         source: CredentialSource, includeExtras: Bool, now: Date) -> ProviderUsageSnapshot {
        func window(_ raw: ClaudeUsageResponse.Window?, id: String, label: String, seconds: TimeInterval?,
                    core: Bool) -> QuotaWindow? {
            guard let raw, let utilization = raw.utilization, utilization.isFinite else { return nil }
            return QuotaWindow(id: "claude.\(id)", label: label, percentUsed: utilization,
                               resetsAt: ISO8601.parse(raw.resetsAt), windowSeconds: seconds, isCore: core)
        }
        let week: TimeInterval = 7 * 24 * 3600
        var windows: [QuotaWindow] = []
        // No 5-hour window means none is enforced right now; show the weekly one alone rather than a fake 0%.
        if let session = window(usage.fiveHour, id: "session", label: "Session", seconds: 5 * 3600, core: true) {
            windows.append(session)
        }
        if let weekly = window(usage.sevenDay, id: "weekly", label: "Weekly", seconds: week, core: true) {
            windows.append(weekly)
        }

        var spending: SpendingSummary?
        if let extra = usage.extraUsage, extra.isEnabled == true, let used = extra.usedCredits, let limit = extra.monthlyLimit {
            // The OAuth endpoint reports extra usage in cents.
            let line = SpendLine(id: "claude.extra-usage", label: windows.isEmpty ? "Spend limit" : "Extra usage",
                                 used: used / 100, limit: limit / 100,
                                 currencyCode: extra.currency.nonEmpty ?? "USD", resetsAt: nil)
            spending = SpendingSummary(lines: [line])
            // Spend-only accounts (some Enterprise seats) have a budget and no token windows.
            if windows.isEmpty, limit > 0 {
                let percent = extra.utilization ?? used / limit * 100
                windows.append(QuotaWindow(id: "claude.spend-limit", label: "Spend limit", percentUsed: percent,
                                           resetsAt: nil, windowSeconds: nil, detail: nil, isCore: true))
            }
        }

        if windows.isEmpty {
            // Fall back to whichever scoped weekly window exists, labelled for what it is.
            for (raw, id, label) in [(usage.sevenDaySonnet, "sonnet", "Sonnet weekly"), (usage.sevenDayOpus, "opus", "Opus weekly"),
                                     (usage.sevenDayOAuthApps, "oauth-apps", "Apps weekly")] {
                if let found = window(raw, id: id, label: label, seconds: week, core: true) {
                    windows.append(found)
                    break
                }
            }
        }

        var credits: CreditSummary?
        if includeExtras {
            let coreIDs = Set(windows.map(\.id))
            let modelWindows = [
                window(usage.sevenDaySonnet, id: "sonnet", label: "Sonnet weekly", seconds: week, core: false),
                window(usage.sevenDayOpus, id: "opus", label: "Opus weekly", seconds: week, core: false),
            ].compactMap { $0 }.filter { !coreIDs.contains($0.id) }
            windows += scopedWeeklyWindows(usage.limits ?? []) + modelWindows
            if let routines = window(usage.routines, id: "routines", label: "Routines", seconds: week, core: false) {
                windows.append(routines)
            }
            if let inventory = usage.resetInventory?.available(at: now), !inventory.isEmpty {
                credits = CreditSummary(savedResets: inventory.count,
                                        savedResetsNextExpiry: inventory.compactMap { $0 }.min())
            }
        } else {
            spending = nil
        }

        return ProviderUsageSnapshot(provider: .claude, accountKey: identity.accountKey,
                                     credentialFingerprint: credentials.fingerprint, planLabel: credentials.planLabel,
                                     accountLabel: identity.email, windows: windows, refreshedAt: now,
                                     credits: credits, spending: spending, source: source)
    }

    /// `limits[]` entries scoped to one model (`kind: weekly_scoped`, `group: weekly`). `is_active` is not a
    /// filter: enforced scoped limits have been seen reporting false.
    static func scopedWeeklyWindows(_ limits: [ClaudeUsageResponse.Limit]) -> [QuotaWindow] {
        var seen = Set<String>()
        return limits.compactMap { limit in
            guard limit.group == "weekly", limit.kind == "weekly_scoped",
                  let percent = limit.percent, percent.isFinite,
                  let name = limit.modelName.nonEmpty else { return nil }
            let identity = limit.modelID.nonEmpty ?? name
            let slug = identity.slug
            guard !slug.isEmpty, name.slug != "all-models", slug != "all-models", !slug.hasSuffix("-all-models"),
                  seen.insert(slug).inserted else { return nil }
            return QuotaWindow(id: "claude.scoped.\(slug)", label: "\(name) only", percentUsed: percent,
                               resetsAt: ISO8601.parse(limit.resetsAt), windowSeconds: 7 * 24 * 3600, isCore: false)
        }
    }
}

// MARK: Response

struct ClaudeUsageResponse: Decodable, Sendable {
    struct Window: Decodable, Sendable {
        var utilization: Double?
        var resetsAt: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            utilization = container.number("utilization")
            resetsAt = container.lenient(String.self, "resets_at")
        }
    }

    struct Limit: Decodable, Sendable {
        var kind: String?
        var group: String?
        var percent: Double?
        var resetsAt: String?
        var modelID: String?
        var modelName: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            kind = container.lenient(String.self, "kind")
            group = container.lenient(String.self, "group")
            percent = container.number("percent")
            resetsAt = container.lenient(String.self, "resets_at")
            let scope = try? container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("scope"))
            let model = try? scope?.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("model"))
            modelID = model?.lenient(String.self, "id")
            modelName = model?.lenient(String.self, "display_name")
        }
    }

    struct ExtraUsage: Decodable, Sendable {
        var isEnabled: Bool?
        var monthlyLimit: Double?
        var usedCredits: Double?
        var utilization: Double?
        var currency: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            isEnabled = container.lenient(Bool.self, "is_enabled")
            monthlyLimit = container.number("monthly_limit")
            usedCredits = container.number("used_credits")
            utilization = container.number("utilization")
            currency = container.lenient(String.self, "currency")
        }
    }

    /// `cedar_ember`: saved "reset for free" credits. Grant IDs are redemption handles and are never decoded.
    struct ResetInventory: Decodable, Sendable {
        static let maximumResets = 50
        static let maximumGrants = 200

        struct Grant: Decodable, Sendable {
            var resetsLeft: Int
            var startsAt: Date?
            var endsAt: Date?
            var paused: Bool

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: AnyCodingKey.self)
                resetsLeft = try container.decode(Int.self, forKey: AnyCodingKey("resets_left"))
                let total = try container.decodeIfPresent(Int.self, forKey: AnyCodingKey("resets_total"))
                paused = try container.decode(Bool.self, forKey: AnyCodingKey("paused"))
                startsAt = try Self.bound(container, "starts_at")
                endsAt = try Self.bound(container, "ends_at")
                guard resetsLeft >= 0, total.map({ $0 >= resetsLeft }) ?? true else {
                    throw DecodingError.dataCorruptedError(forKey: AnyCodingKey("resets_left"), in: container,
                                                           debugDescription: "resets_left out of range")
                }
            }

            /// Absent is open-ended; present but unreadable is malformed, never unbounded.
            private static func bound(_ container: KeyedDecodingContainer<AnyCodingKey>, _ key: String) throws -> Date? {
                guard let raw = try container.decodeIfPresent(String.self, forKey: AnyCodingKey(key)) else { return nil }
                guard let date = ISO8601.parse(raw) else {
                    throw DecodingError.dataCorruptedError(forKey: AnyCodingKey(key), in: container,
                                                           debugDescription: "unreadable date")
                }
                return date
            }

            func isAvailable(at date: Date) -> Bool {
                guard !paused, resetsLeft > 0 else { return false }
                if let startsAt, startsAt > date { return false }
                if let endsAt, endsAt <= date { return false }
                return true
            }
        }

        var eligible: Bool
        var grants: [Grant]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            eligible = try container.decode(Bool.self, forKey: AnyCodingKey("eligible"))
            let records = try container.decode([Lossy<Grant>].self, forKey: AnyCodingKey("grants"))
            guard records.count <= Self.maximumGrants else {
                throw DecodingError.dataCorruptedError(forKey: AnyCodingKey("grants"), in: container,
                                                       debugDescription: "too many grants")
            }
            grants = records.compactMap(\.value)
        }

        /// The expiry of each saved reset usable at `date` (nil = no expiry). Empty when ineligible or implausible.
        func available(at date: Date) -> [Date?] {
            guard eligible else { return [] }
            var expirations: [Date?] = []
            for grant in grants where grant.isAvailable(at: date) {
                guard grant.resetsLeft <= Self.maximumResets - expirations.count else { return [] }
                expirations += Array(repeating: grant.endsAt, count: grant.resetsLeft)
            }
            return expirations
        }
    }

    var fiveHour: Window?
    var sevenDay: Window?
    var sevenDayOAuthApps: Window?
    var sevenDayOpus: Window?
    var sevenDaySonnet: Window?
    var routines: Window?
    var extraUsage: ExtraUsage?
    var limits: [Limit]?
    var resetInventory: ResetInventory?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        fiveHour = container.lenient(Window.self, "five_hour")
        sevenDay = container.lenient(Window.self, "seven_day")
        sevenDayOAuthApps = container.lenient(Window.self, "seven_day_oauth_apps")
        sevenDayOpus = container.lenient(Window.self, "seven_day_opus")
        sevenDaySonnet = container.lenient(Window.self, "seven_day_sonnet")
        routines = container.lenient(Window.self, "seven_day_routines", "seven_day_claude_routines", "claude_routines",
                                     "routines", "routine", "seven_day_cowork", "cowork")
        extraUsage = container.lenient(ExtraUsage.self, "extra_usage")
        limits = container.lenient([Lossy<Limit>].self, "limits")?.compactMap(\.value)
        resetInventory = container.lenient(ResetInventory.self, "cedar_ember")
    }
}

struct ClaudeProfileResponse: Decodable {
    var accountID: String?
    var email: String?
    var organizationID: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        let account = try? container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("account"))
        let organization = try? container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("organization"))
        accountID = (account?.lenient(String.self, "uuid") ?? container.lenient(String.self, "accountUuid", "account_uuid")).nonEmpty
        email = (account?.lenient(String.self, "email_address", "emailAddress", "email")
            ?? container.lenient(String.self, "email_address", "emailAddress", "email")).nonEmpty
        organizationID = (organization?.lenient(String.self, "uuid")
            ?? container.lenient(String.self, "organizationUuid", "organization_uuid")).nonEmpty
    }
}
