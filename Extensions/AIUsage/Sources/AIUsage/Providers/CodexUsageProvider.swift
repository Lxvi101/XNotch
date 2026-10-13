import Foundation

// Endpoints, response shapes and window rules adapted from CodexBar (MIT, Copyright 2026 Peter Steinberger),
// CodexOAuthCredentials.swift, CodexOAuthUsageFetcher.swift, CodexAdditionalRateLimitMapper.swift and
// CodexRateWindowNormalizer.swift. See THIRD_PARTY_NOTICES.md.

/// ChatGPT plan limits for Codex, with the Codex CLI's own login.
final class CodexUsageProvider: UsageProvider, @unchecked Sendable {
    let id = AIProviderID.codex

    static let defaultBaseURL = "https://chatgpt.com/backend-api"

    private let transport: HTTPTransport
    private let codexHome: CodexHome
    private let lock = NSLock()
    private var resetGuard = WeeklyResetGuard()

    init(transport: HTTPTransport, codexHome: CodexHome = CodexHome()) {
        self.transport = transport
        self.codexHome = codexHome
    }

    /// The host of a user-configured `chatgpt_base_url`, which may receive Codex's token like Codex itself sends it.
    static func configuredHost(_ home: CodexHome) -> String? {
        guard let configured = home.configuredBaseURL() else { return nil }
        let url = URL(string: normalizedBaseURL(configured))
        return url?.scheme == "https" ? url?.host?.lowercased() : nil
    }

    func fetch(_ context: FetchContext) async throws -> ProviderUsageSnapshot {
        let credentials = try codexHome.loadCredentials()
        let accountKey = credentials.accountKey
        let fingerprint = credentials.fingerprint

        if let expiresAt = credentials.expiresAt, expiresAt <= context.now {
            throw ProviderFailure(.unauthorized, "Codex's login has expired. Run `codex` (or `codex login`) so it can "
                + "renew it; XNotch never rewrites Codex's auth.json.", accountKey: accountKey, credentialFingerprint: fingerprint)
        }

        do {
            let base = baseURL()
            async let usageResponse = send(base.usage, credentials: credentials, timeout: 30)
            async let inventoryResponse = context.includeExtras ? try? sendResetCredits(base.resetCredits, credentials: credentials) : nil

            let response = try await usageResponse
            try ProviderFailure.check(response, provider: .codex,
                                      signInHint: "Run `codex login` to sign in again.", now: context.now)
            let usage: CodexUsageResponse
            do {
                usage = try JSONDecoder().decode(CodexUsageResponse.self, from: response.data)
            } catch {
                throw ProviderFailure(.invalidResponse, "Codex sent usage in an unexpected format.")
            }
            // Saved resets are optional: their failure never hides the plan limits.
            let inventory = await inventoryResponse.flatMap { $0.statusCode == 200 ? $0.data : nil }
                .flatMap { try? CodexResetCredits.decode($0) }
            try Task.checkCancellation()

            var snapshot = Self.snapshot(from: usage, credentials: credentials, inventory: inventory,
                                         includeExtras: context.includeExtras, now: context.now)
            lock.withLock {
                snapshot.windows = snapshot.windows.map {
                    $0.id == "codex.weekly"
                        ? resetGuard.review($0, accountKey: accountKey, savedResets: snapshot.credits?.savedResets, now: context.now)
                        : $0
                }
            }
            return snapshot
        } catch {
            throw ProviderFailure.from(error, provider: .codex).identified(accountKey: accountKey, fingerprint: fingerprint)
        }
    }

    // MARK: Requests

    struct Endpoints {
        var usage: URL
        var resetCredits: URL
    }

    func baseURL() -> Endpoints {
        var base = Self.normalizedBaseURL(codexHome.configuredBaseURL() ?? Self.defaultBaseURL)
        if URL(string: base)?.scheme != "https" { base = Self.defaultBaseURL }
        // A compatible server without ChatGPT's /backend-api prefix serves the same data at /api/codex/usage.
        let usagePath = base.contains("/backend-api") ? "/wham/usage" : "/api/codex/usage"
        return Endpoints(usage: URL(string: base + usagePath) ?? URL(string: Self.defaultBaseURL + "/wham/usage")!,
                         resetCredits: URL(string: base + "/wham/rate-limit-reset-credits")
                             ?? URL(string: Self.defaultBaseURL + "/wham/rate-limit-reset-credits")!)
    }

    static func normalizedBaseURL(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { trimmed = defaultBaseURL }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed.hasPrefix("https://chatgpt.com") || trimmed.hasPrefix("https://chat.openai.com"),
           !trimmed.contains("/backend-api") {
            trimmed += "/backend-api"
        }
        return trimmed
    }

    private func send(_ url: URL, credentials: CodexCredentials, timeout: TimeInterval) async throws -> HTTPResponse {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("XNotch", forHTTPHeaderField: "User-Agent")
        if let account = credentials.accountID {
            request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        return try await transport.send(request)
    }

    private func sendResetCredits(_ url: URL, credentials: CodexCredentials) async throws -> HTTPResponse {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("XNotch", forHTTPHeaderField: "User-Agent")
        request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        if let account = credentials.accountID {
            request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        return try await transport.send(request)
    }

    // MARK: Mapping

    static func snapshot(from usage: CodexUsageResponse, credentials: CodexCredentials, inventory: CodexResetCredits?,
                         includeExtras: Bool, now: Date) -> ProviderUsageSnapshot {
        var windows: [QuotaWindow] = []
        let (session, weekly) = normalized(primary: usage.rateLimit?.primary, secondary: usage.rateLimit?.secondary)
        if let session { windows.append(window(session, id: "codex.session", label: "Session")) }
        if let weekly { windows.append(window(weekly, id: "codex.weekly", label: "Weekly")) }

        var credits: CreditSummary?
        if includeExtras {
            windows += additionalWindows(usage.additionalRateLimits ?? [])
            if let review = usage.codeReviewRateLimit?.primary ?? usage.codeReviewRateLimit?.secondary {
                windows.append(window(review, id: "codex.code-review", label: "Code review", core: false))
            }
            var summary = CreditSummary()
            if let reported = usage.credits, reported.hasCredits || reported.unlimited {
                summary.isUnlimited = reported.unlimited
                summary.balance = reported.unlimited ? nil : reported.balance
                summary.balanceUnit = "credits"
            }
            if let inventory {
                let available = inventory.available(at: now)
                summary.savedResets = available.count
                summary.savedResetsNextExpiry = available.compactMap(\.self).min()
            } else {
                // The inventory request failed or was skipped: the usage response's own count, without expiries.
                summary.savedResets = usage.savedResetCount
            }
            credits = summary.isEmpty ? nil : summary
        }

        return ProviderUsageSnapshot(provider: .codex, accountKey: credentials.accountKey,
                                     credentialFingerprint: credentials.fingerprint,
                                     planLabel: planLabel(usage.planType ?? credentials.planType),
                                     accountLabel: credentials.email, windows: windows, refreshedAt: now,
                                     credits: credits, spending: nil, source: .codexAuthFile)
    }

    static func planLabel(_ raw: String?) -> String? {
        guard let raw = raw.nonEmpty?.lowercased() else { return nil }
        switch raw {
        case "pro": return "Pro 20x"
        case "prolite", "pro_lite", "pro-lite", "pro lite": return "Pro 5x"
        case "free_workspace": return "Free workspace"
        case "k12", "edu", "education": return "Edu"
        default: return raw.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").capitalized
        }
    }

    /// Codex usually sends the 5-hour window as primary and the weekly as secondary, but not always.
    static func normalized(primary: CodexUsageResponse.Window?, secondary: CodexUsageResponse.Window?)
        -> (session: CodexUsageResponse.Window?, weekly: CodexUsageResponse.Window?) {
        func role(_ window: CodexUsageResponse.Window) -> Int {  // 0 session, 1 weekly, 2 unknown
            switch window.windowSeconds.map({ Int($0 / 60) }) {
            case 300: 0
            case 10080: 1
            default: 2
            }
        }
        switch (primary, secondary) {
        case let (primary?, secondary?):
            return (role(primary), role(secondary)) == (1, 0) || (role(primary), role(secondary)) == (1, 2)
                ? (secondary, primary) : (primary, secondary)
        case let (primary?, nil):
            return role(primary) == 1 ? (nil, primary) : (primary, nil)
        case let (nil, secondary?):
            return role(secondary) == 1 ? (nil, secondary) : (secondary, nil)
        case (nil, nil):
            return (nil, nil)
        }
    }

    static func window(_ raw: CodexUsageResponse.Window, id: String, label: String, core: Bool = true) -> QuotaWindow {
        QuotaWindow(id: id, label: label, percentUsed: raw.usedPercent, resetsAt: raw.resetsAt,
                    windowSeconds: raw.windowSeconds, isCore: core)
    }

    /// Model-specific limits (e.g. GPT-5.3-Codex-Spark) beside the plan's own windows.
    static func additionalWindows(_ limits: [CodexUsageResponse.AdditionalLimit]) -> [QuotaWindow] {
        var used = Set<String>()
        var windows: [QuotaWindow] = []
        for limit in limits {
            let name = limit.limitName.nonEmpty ?? limit.meteredFeature.nonEmpty
            let isSpark = [limit.limitName, limit.meteredFeature].compactMap { $0?.lowercased() }.contains { $0.contains("spark") }
            if isSpark {
                for (raw, fallbackWeekly) in [(limit.rateLimit?.primary, false), (limit.rateLimit?.secondary, true)] {
                    guard let raw else { continue }
                    let minutes = raw.windowSeconds.map { Int($0 / 60) } ?? 0
                    let weekly = minutes >= 6 * 24 * 60 ? true : (minutes > 0 && minutes <= 360 ? false : fallbackWeekly)
                    let id = weekly ? "codex.spark-weekly" : "codex.spark"
                    guard used.insert(id).inserted else { continue }
                    windows.append(window(raw, id: id, label: weekly ? "Spark weekly" : "Spark 5-hour", core: false))
                }
                continue
            }
            // Model limits report in the primary window; the secondary only stands in when it's missing.
            guard let raw = limit.rateLimit?.primary ?? limit.rateLimit?.secondary,
                  let source = limit.meteredFeature.nonEmpty ?? limit.limitName.nonEmpty else { continue }
            let id = "codex.extra.\(source.slug)"
            guard !source.slug.isEmpty, used.insert(id).inserted else { continue }
            windows.append(window(raw, id: id, label: name ?? "Extra limit", core: false))
        }
        return windows
    }
}

/// Holds back an apparent early weekly reset until a second reading agrees, so a transient server
/// glitch can't flash an empty week. A redeemed saved reset explains an early reset, so it passes at once.
struct WeeklyResetGuard: Sendable {
    private struct Reading {
        var resetsAt: Date
        var percentUsed: Double?
    }

    private var published: [String: Reading] = [:]
    private var pending: [String: Reading] = [:]
    private var savedResets: [String: Int] = [:]

    mutating func review(_ window: QuotaWindow, accountKey: String, savedResets currentSaved: Int?, now: Date) -> QuotaWindow {
        defer { if let currentSaved { savedResets[accountKey] = currentSaved } }
        guard let newReset = window.resetsAt else { return window }
        let reading = Reading(resetsAt: newReset, percentUsed: window.percentUsed)
        guard let previous = published[accountKey] else {
            published[accountKey] = reading
            return window
        }
        let previousWindowRunning = previous.resetsAt > now.addingTimeInterval(60)
        let jumpedAhead = newReset > previous.resetsAt.addingTimeInterval(24 * 3600)
        let redeemed = currentSaved.map { $0 < (savedResets[accountKey] ?? 0) } ?? false
        guard previousWindowRunning, jumpedAhead, !redeemed else {
            published[accountKey] = reading
            pending[accountKey] = nil
            return window
        }
        if let candidate = pending[accountKey], abs(candidate.resetsAt.timeIntervalSince(newReset)) < 3600 {
            published[accountKey] = reading
            pending[accountKey] = nil
            return window
        }
        pending[accountKey] = reading
        var held = window
        held.resetsAt = previous.resetsAt
        held.percentUsed = previous.percentUsed
        held.detail = "Checking an early reset"
        return held
    }
}

// MARK: Responses

struct CodexUsageResponse: Decodable, Sendable {
    struct Window: Decodable, Sendable {
        var usedPercent: Double?
        var resetsAt: Date?
        var windowSeconds: TimeInterval?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            usedPercent = container.number("used_percent")
            // reset_at is Unix seconds; limit_window_seconds is a duration.
            resetsAt = container.number("reset_at").flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            windowSeconds = container.number("limit_window_seconds").flatMap { $0 > 0 ? $0 : nil }
        }
    }

    struct RateLimit: Decodable, Sendable {
        var primary: Window?
        var secondary: Window?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            primary = container.lenient(Window.self, "primary_window")
            secondary = container.lenient(Window.self, "secondary_window")
        }
    }

    struct AdditionalLimit: Decodable, Sendable {
        var limitName: String?
        var meteredFeature: String?
        var rateLimit: RateLimit?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            limitName = container.lenient(String.self, "limit_name")
            meteredFeature = container.lenient(String.self, "metered_feature")
            rateLimit = container.lenient(RateLimit.self, "rate_limit")
        }
    }

    struct Credits: Decodable, Sendable {
        var hasCredits: Bool
        var unlimited: Bool
        var balance: Double?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            hasCredits = container.lenient(Bool.self, "has_credits") ?? false
            unlimited = container.lenient(Bool.self, "unlimited") ?? false
            balance = container.number("balance")
        }
    }

    var planType: String?
    var rateLimit: RateLimit?
    var codeReviewRateLimit: RateLimit?
    var credits: Credits?
    var additionalRateLimits: [AdditionalLimit]?
    /// The saved-reset count the usage response carries itself, without expiries.
    var savedResetCount: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        planType = container.lenient(String.self, "plan_type")
        rateLimit = container.lenient(RateLimit.self, "rate_limit")
        codeReviewRateLimit = container.lenient(RateLimit.self, "code_review_rate_limit")
        let resets = try? container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("rate_limit_reset_credits"))
        savedResetCount = resets?.lenient(Int.self, "available_count").flatMap { $0 >= 0 ? $0 : nil }
        credits = container.lenient(Credits.self, "credits")
        // One malformed entry must not discard its siblings.
        additionalRateLimits = container.lenient([Lossy<AdditionalLimit>].self, "additional_rate_limits")?.compactMap(\.value)
    }
}

/// `wham/rate-limit-reset-credits`: saved, redeemable resets. Display only; never redeemed.
struct CodexResetCredits: Sendable {
    struct Credit: Sendable {
        var status: String
        var expiresAt: Date?
    }

    var credits: [Credit]

    static func decode(_ data: Data) throws -> CodexResetCredits {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let records = root["credits"] as? [[String: Any]],
              let count = (root["available_count"] as? NSNumber)?.intValue, count >= 0 else {
            throw ProviderFailure(.invalidResponse, "Unexpected saved-reset inventory.")
        }
        return CodexResetCredits(credits: records.compactMap { record in
            guard let status = record["status"] as? String else { return nil }
            return Credit(status: status, expiresAt: ISO8601.parse(record["expires_at"] as? String))
        })
    }

    /// The expiry of each credit still redeemable at `date` (nil = no expiry).
    func available(at date: Date) -> [Date?] {
        credits.filter { $0.status == "available" && ($0.expiresAt.map { $0 > date } ?? true) }.map(\.expiresAt)
    }
}
