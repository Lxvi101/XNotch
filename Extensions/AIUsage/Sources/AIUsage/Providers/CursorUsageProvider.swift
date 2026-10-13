import Foundation
import CryptoKit
import SQLite3

// Session handling, endpoints and unit rules adapted from CodexBar (MIT, Copyright 2026 Peter Steinberger),
// CursorAppAuth.swift, CursorStatusProbe.swift, CursorStatusProbe+UsageSummary.swift and CursorSandUsage.swift.
// See THIRD_PARTY_NOTICES.md.

enum CursorSourcePreference: String, Codable, CaseIterable, Sendable {
    /// The Cursor app's session, then a saved cookie.
    case automatic
    case desktop
    case manualCookie

    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .desktop: "Cursor app only"
        case .manualCookie: "Saved cookie only"
        }
    }
}

/// The Cursor app's signed-in session, as a cursor.com cookie.
struct CursorSession: Equatable, Sendable {
    var accessToken: String

    /// The user ID from the JWT subject ("auth0|user_123" → "user_123").
    var userID: String? {
        guard let subject = (JWT.claims(accessToken)?["sub"] as? String).nonEmpty,
              let id = subject.split(separator: "|").last.map(String.init), !id.isEmpty else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return id.unicodeScalars.allSatisfy(allowed.contains) ? id : nil
    }

    var expiresAt: Date? { JWT.expiry(accessToken) }

    /// Usable while the JWT has a user and more than a minute left.
    func isUsable(at date: Date) -> Bool {
        guard userID != nil, let expiresAt else { return false }
        return expiresAt.timeIntervalSince(date) > 60
    }

    /// The session cookie cursor.com's dashboard uses. Never logged or written anywhere.
    var cookieHeader: String? {
        userID.map { "WorkosCursorSessionToken=\($0)%3A%3A\(accessToken)" }
    }

    /// The user ID inside a pasted cookie header, if it has a WorkOS session.
    static func userID(fromCookieHeader header: String) -> String? {
        for component in header.split(separator: ";") {
            let pair = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces) == "WorkosCursorSessionToken" else { continue }
            let encoded = pair[1].trimmingCharacters(in: .whitespaces)
            let parts = (encoded.removingPercentEncoding ?? encoded).components(separatedBy: "::")
            guard parts.count >= 2 else { continue }
            if let id = CursorSession(accessToken: parts.last ?? "").userID { return id }
            if let id = parts.first.nonEmpty { return id }
        }
        return nil
    }
}

protocol CursorSessionLoading: Sendable {
    func loadSession() throws -> CursorSession?
}

/// Reads `cursorAuth/accessToken` from Cursor's global state database, strictly read-only.
struct CursorDesktopAuth: CursorSessionLoading {
    static var defaultPath: String {
        NSHomeDirectory() + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    }

    var dbPath: String = Self.defaultPath

    struct SQLiteFailure: Error {
        var code: Int32
        var message: String
    }

    func loadSession() throws -> CursorSession? {
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }
        guard let token = try value(for: "cursorAuth/accessToken").nonEmpty else { return nil }
        return CursorSession(accessToken: token)
    }

    func value(for key: String) throws -> String? {
        do {
            return try value(for: key, immutable: false)
        } catch let failure as SQLiteFailure {
            // An idle WAL database keeps WAL mode in its header after both sidecars are gone, and a read-only
            // open then fails because it can't create them. Immutable mode reads the main file without
            // creating anything. Never use it while a WAL exists: it would ignore live, uncheckpointed state.
            guard failure.code == SQLITE_CANTOPEN,
                  !FileManager.default.fileExists(atPath: dbPath + "-wal"),
                  !FileManager.default.fileExists(atPath: dbPath + "-shm") else { throw failure }
            return try value(for: key, immutable: true)
        }
    }

    private func value(for key: String, immutable: Bool) throws -> String? {
        var db: OpaquePointer?
        let filename = immutable ? URL(fileURLWithPath: dbPath).absoluteString + "?immutable=1" : dbPath
        let flags = immutable ? SQLITE_OPEN_READONLY | SQLITE_OPEN_URI : SQLITE_OPEN_READONLY
        let opened = sqlite3_open_v2(filename, &db, flags, nil)
        defer { sqlite3_close(db) }
        guard opened == SQLITE_OK else { throw Self.failure(db, opened) }
        sqlite3_busy_timeout(db, 250)

        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ? LIMIT 1;", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        guard prepared == SQLITE_OK else { throw Self.failure(db, prepared) }
        sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else { throw Self.failure(db, step) }
        return Self.decode(statement, column: 0)
    }

    static func decode(_ statement: OpaquePointer?, column: Int32) -> String? {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_TEXT:
            return sqlite3_column_text(statement, column).map { String(cString: $0) }
        case SQLITE_BLOB:
            guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
            return decodeBlob(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column))))
        default:
            return nil
        }
    }

    /// BOM-less ASCII UTF-16LE is also "valid" UTF-8 full of NULs, so recognise it first.
    static func decodeBlob(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        if bytes.count.isMultiple(of: 2), !bytes.isEmpty,
           stride(from: 0, to: bytes.count, by: 2).allSatisfy({ (1..<128).contains(bytes[$0]) && bytes[$0 + 1] == 0 }),
           let decoded = String(data: data, encoding: .utf16LittleEndian), decoded.nonEmpty != nil {
            return decoded
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16LittleEndian)
    }

    private static func failure(_ db: OpaquePointer?, _ code: Int32) -> SQLiteFailure {
        SQLiteFailure(code: db.map(sqlite3_errcode) ?? code,
                      message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error")
    }
}

final class CursorUsageProvider: UsageProvider, @unchecked Sendable {
    let id = AIProviderID.cursor

    static let baseURL = URL(string: "https://cursor.com")!
    static let manualCookieName = "cursor.cookie"

    private let transport: HTTPTransport
    private let desktop: CursorSessionLoading
    private let secrets: SecretStore
    private let preference: @Sendable () -> CursorSourcePreference

    init(transport: HTTPTransport, desktop: CursorSessionLoading = CursorDesktopAuth(), secrets: SecretStore,
         preference: @escaping @Sendable () -> CursorSourcePreference) {
        self.transport = transport
        self.desktop = desktop
        self.secrets = secrets
        self.preference = preference
    }

    private struct Login {
        var cookie: String
        var userID: String?
        var source: CredentialSource

        var accountKey: String? { userID.map { Hashing.key("cursor-account", $0.lowercased()) } }
        var fingerprint: String { Hashing.key("cursor-credential", cookie) }
    }

    func fetch(_ context: FetchContext) async throws -> ProviderUsageSnapshot {
        let logins = try resolveLogins(context)
        var lastFailure: ProviderFailure?
        for login in logins {
            do {
                return try await fetch(with: login, context: context)
            } catch {
                let failure = ProviderFailure.from(error, provider: .cursor)
                    .identified(accountKey: login.accountKey, fingerprint: login.fingerprint)
                // Only a rejected session moves on to the next login; anything else is about Cursor, not the login.
                guard failure.kind == .unauthorized else { throw failure }
                lastFailure = failure
            }
        }
        throw lastFailure ?? ProviderFailure(.notConnected, AIProviderID.cursor.signInHint)
    }

    private func resolveLogins(_ context: FetchContext) throws -> [Login] {
        var logins: [Login] = []
        var desktopProblem: String?
        let preference = preference()

        if preference != .manualCookie {
            do {
                if let session = try desktop.loadSession() {
                    if session.isUsable(at: context.now), let cookie = session.cookieHeader {
                        logins.append(Login(cookie: cookie, userID: session.userID, source: .cursorDesktop))
                    } else {
                        desktopProblem = "The Cursor app's session has expired. Open Cursor to renew it."
                    }
                }
            } catch {
                desktopProblem = "Couldn't read the Cursor app's session database."
            }
        }

        if preference != .desktop {
            switch secrets.read(Self.manualCookieName, interactive: context.isInteractive) {
            case let .found(data):
                if let cookie = String(data: data, encoding: .utf8).nonEmpty {
                    logins.append(Login(cookie: cookie, userID: CursorSession.userID(fromCookieHeader: cookie),
                                        source: .cursorManualCookie))
                }
            case .interactionRequired, .denied:
                if logins.isEmpty {
                    throw ProviderFailure(.needsKeychainAccess,
                                          "macOS needs your OK before XNotch reads its saved Cursor sign-in. Sign in again in Settings → AI Usage.")
                }
            case .notFound, .failed:
                break
            }
        }

        guard !logins.isEmpty else {
            throw ProviderFailure(.notConnected, desktopProblem ?? AIProviderID.cursor.signInHint)
        }
        return logins
    }

    // MARK: Requests

    private func fetch(with login: Login, context: FetchContext) async throws -> ProviderUsageSnapshot {
        async let summaryResponse = get("/api/usage-summary", cookie: login.cookie)
        async let meResponse = try? get("/api/auth/me", cookie: login.cookie)
        async let sandResponse = context.includeExtras ? try? sand(cookie: login.cookie) : nil

        let summaryHTTP = try await summaryResponse
        try ProviderFailure.check(summaryHTTP, provider: .cursor, signInHint: AIProviderID.cursor.signInHint, now: context.now)
        let summary: CursorUsageSummary
        do {
            summary = try JSONDecoder().decode(CursorUsageSummary.self, from: summaryHTTP.data)
        } catch {
            throw ProviderFailure(.invalidResponse, "Cursor sent usage in an unexpected format.")
        }

        let me = await meResponse.flatMap { $0.statusCode == 200 ? try? JSONDecoder().decode(CursorUser.self, from: $0.data) : nil }
        let sand = await sandResponse.flatMap {
            $0.statusCode == 200 ? try? JSONDecoder().decode(CursorSandUsage.self, from: $0.data) : nil
        }
        let userID = me?.userID ?? login.userID

        // Legacy request-count plans. Not every plan has this endpoint, so failure is fine.
        var requests: CursorRequestUsage?
        if let userID {
            var components = URLComponents(url: Self.baseURL.appendingPathComponent("/api/usage"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "user", value: userID)]
            if let response = try? await send(URLRequest(url: components.url!), cookie: login.cookie),
               response.statusCode == 200 {
                requests = try? JSONDecoder().decode(CursorRequestUsage.self, from: response.data)
            }
        }
        try Task.checkCancellation()

        guard let accountKey = userID.map({ Hashing.key("cursor-account", $0.lowercased()) }) else {
            throw ProviderFailure(.invalidResponse, "Cursor didn't say which account this usage belongs to.")
        }
        return Self.snapshot(summary: summary, requests: requests, sand: sand, accountKey: accountKey,
                             fingerprint: login.fingerprint, email: me?.email, source: login.source,
                             includeExtras: context.includeExtras, now: context.now)
    }

    private func get(_ path: String, cookie: String) async throws -> HTTPResponse {
        try await send(URLRequest(url: Self.baseURL.appendingPathComponent(path)), cookie: cookie)
    }

    /// Grok Bot's allowance. Best-effort: its failure never hides the monthly quotas.
    private func sand(cookie: String) async throws -> HTTPResponse {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("/api/dashboard/get-sand-usage-status"))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.httpBody = Data("{}".utf8)
        return try await send(request, cookie: cookie)
    }

    private func send(_ request: URLRequest, cookie: String) async throws -> HTTPResponse {
        var request = request
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if request.timeoutInterval > 15 { request.timeoutInterval = 15 }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        return try await transport.send(request)
    }

    // MARK: Mapping

    static func snapshot(summary: CursorUsageSummary, requests: CursorRequestUsage?, sand: CursorSandUsage?,
                         accountKey: String, fingerprint: String?, email: String?, source: CredentialSource,
                         includeExtras: Bool, now: Date) -> ProviderUsageSnapshot {
        let cycleStart = ISO8601.parse(summary.billingCycleStart)
        let cycleEnd = ISO8601.parse(summary.billingCycleEnd)
        let cycleSeconds = cycleStart.flatMap { start in cycleEnd.map { $0.timeIntervalSince(start) } }.flatMap { $0 > 0 ? $0 : nil }
        let plan = summary.individualUsage?.plan
        let overall = summary.individualUsage?.overall
        let pooled = summary.teamUsage?.pooled

        var windows: [QuotaWindow] = []
        if let requests, let used = requests.used, let limit = requests.limit, limit > 0 {
            // A request-count plan: token percentages from usage-based pricing would mislead next to it.
            windows.append(QuotaWindow(id: "cursor.requests", label: "Requests", percentUsed: Double(used) / Double(limit) * 100,
                                       resetsAt: cycleEnd, windowSeconds: cycleSeconds, detail: "\(used) / \(limit) requests"))
        } else {
            // Percent fields are already percentages, even below 1: 0.36 means 0.36%, not 36%.
            let auto = plan?.autoPercentUsed
            let api = plan?.apiPercentUsed
            var percent: Double?
            var detail: String?
            if let total = plan?.totalPercentUsed {
                percent = total
            } else if let auto, let api {
                percent = (auto + api) / 2
            } else if let single = api ?? auto {
                percent = single
            }
            // Dollar amounts are cents. Prefer the block the headline came from.
            for (used, limit) in [(plan?.used, plan?.limit), (overall?.used, overall?.limit), (pooled?.used, pooled?.limit)] {
                guard let used, let limit, limit > 0 else { continue }
                if percent == nil { percent = Double(used) / Double(limit) * 100 }
                detail = "\(Money.format(Double(used) / 100, "USD")) of \(Money.format(Double(limit) / 100, "USD"))"
                break
            }
            // Unknown stays unknown: no plan data is not 0% used.
            windows.append(QuotaWindow(id: "cursor.plan", label: "Plan", percentUsed: percent, resetsAt: cycleEnd,
                                       windowSeconds: cycleSeconds, detail: detail))
            // Pinned beside the plan: third-party models run out on their own.
            if let api {
                windows.append(QuotaWindow(id: "cursor.api", label: "Third-party models", percentUsed: api, resetsAt: cycleEnd,
                                           windowSeconds: cycleSeconds, shortLabel: "Third party"))
            }
            if includeExtras {
                if let auto {
                    windows.append(QuotaWindow(id: "cursor.auto", label: "Cursor models", percentUsed: auto, resetsAt: cycleEnd,
                                               windowSeconds: cycleSeconds, isCore: false))
                }
                if let grok = sand?.window(now: now) { windows.append(grok) }
            }
        }

        var spending: SpendingSummary?
        if includeExtras {
            // A personal on-demand cap first; team members without one see the shared pool.
            let personal = summary.individualUsage?.onDemand
            let team = summary.teamUsage?.onDemand
            var lines: [SpendLine] = []
            if let limit = personal?.limit, limit > 0 {
                lines.append(SpendLine(id: "cursor.on-demand", label: "On-demand", used: Double(personal?.used ?? 0) / 100,
                                       limit: Double(limit) / 100, currencyCode: "USD", resetsAt: cycleEnd))
            } else if let limit = team?.limit, limit > 0 {
                lines.append(SpendLine(id: "cursor.team-on-demand", label: "Team on-demand", used: Double(team?.used ?? 0) / 100,
                                       limit: Double(limit) / 100, currencyCode: "USD", resetsAt: cycleEnd))
                if let mine = personal?.used, mine > 0 {
                    lines.append(SpendLine(id: "cursor.my-on-demand", label: "Your on-demand", used: Double(mine) / 100,
                                           limit: nil, currencyCode: "USD", resetsAt: cycleEnd))
                }
            } else if let used = personal?.used, used > 0 {
                lines.append(SpendLine(id: "cursor.on-demand", label: "On-demand", used: Double(used) / 100, limit: nil,
                                       currencyCode: "USD", resetsAt: cycleEnd))
            }
            spending = lines.isEmpty ? nil : SpendingSummary(lines: lines)
        }

        return ProviderUsageSnapshot(provider: .cursor, accountKey: accountKey, credentialFingerprint: fingerprint,
                                     planLabel: summary.planLabel, accountLabel: email, windows: windows, refreshedAt: now,
                                     credits: nil, spending: spending, source: source)
    }
}

// MARK: Responses

struct CursorUsageSummary: Decodable, Sendable {
    struct Amount: Decodable, Sendable {
        var used: Int?
        var limit: Int?
        var totalPercentUsed: Double?
        var autoPercentUsed: Double?
        var apiPercentUsed: Double?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            used = container.number("used").map { Int($0.rounded()) }
            limit = container.number("limit").map { Int($0.rounded()) }
            totalPercentUsed = container.number("totalPercentUsed")
            autoPercentUsed = container.number("autoPercentUsed")
            apiPercentUsed = container.number("apiPercentUsed")
        }
    }

    struct Individual: Decodable, Sendable {
        var plan: Amount?
        var onDemand: Amount?
        var overall: Amount?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            plan = container.lenient(Amount.self, "plan")
            onDemand = container.lenient(Amount.self, "onDemand")
            overall = container.lenient(Amount.self, "overall")
        }
    }

    struct Team: Decodable, Sendable {
        var onDemand: Amount?
        var pooled: Amount?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            onDemand = container.lenient(Amount.self, "onDemand")
            pooled = container.lenient(Amount.self, "pooled")
        }
    }

    var billingCycleStart: String?
    var billingCycleEnd: String?
    var membershipType: String?
    var individualUsage: Individual?
    var teamUsage: Team?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        billingCycleStart = container.lenient(String.self, "billingCycleStart")
        billingCycleEnd = container.lenient(String.self, "billingCycleEnd")
        membershipType = container.lenient(String.self, "membershipType")
        individualUsage = container.lenient(Individual.self, "individualUsage")
        teamUsage = container.lenient(Team.self, "teamUsage")
    }

    var planLabel: String? {
        membershipType.nonEmpty.map { $0.replacingOccurrences(of: "_", with: " ").capitalized }
    }
}

struct CursorUser: Decodable, Sendable {
    var sub: String?
    var email: String?

    var userID: String? {
        sub.nonEmpty.flatMap { $0.split(separator: "|").last.map(String.init) }
    }
}

/// `/api/usage?user=` for legacy request-count plans.
struct CursorRequestUsage: Decodable, Sendable {
    var used: Int?
    var limit: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        let gpt4 = try? container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("gpt-4"))
        used = gpt4?.lenient(Int.self, "numRequestsTotal") ?? gpt4?.lenient(Int.self, "numRequests")
        limit = gpt4?.lenient(Int.self, "maxRequestUsage")
    }
}

/// Grok Bot ("Sand") weekly allowance.
struct CursorSandUsage: Decodable, Sendable {
    var nextResetTimestampUtc: String?
    var usagePercent: Double?
    var hasNonZeroIncludedLimit: Bool?
    var includedLimitZero: Bool?
    var sandTrialExpiresAt: String?

    /// An included allowance resets weekly. A trial's expiry is not a recurring reset, so it gets none.
    func window(now: Date) -> QuotaWindow? {
        let hasLimit = includedLimitZero.map { !$0 } ?? hasNonZeroIncludedLimit
        let hasTrial = hasLimit != true && (ISO8601.parse(sandTrialExpiresAt).map { $0 > now } ?? false)
        guard hasLimit == true || hasTrial, let usagePercent, usagePercent.isFinite else { return nil }
        let resetsAt = hasTrial ? nil : ISO8601.parse(nextResetTimestampUtc)
        return QuotaWindow(id: "cursor.grok-bot", label: hasTrial ? "Grok Bot trial" : "Grok Bot", percentUsed: usagePercent,
                           resetsAt: resetsAt, windowSeconds: resetsAt == nil ? nil : 7 * 24 * 3600, isCore: false)
    }
}

// MARK: Browser sign-in

/// Cursor's own browser login, the one the Cursor app uses: the user signs in on cursor.com in their
/// own browser (with their password manager), and XNotch collects the session by polling with a
/// one-time verifier whose hash went into the login link.
struct CursorBrowserLogin: Sendable {
    static let pollInterval: UInt64 = 2_000_000_000
    static let timeout: TimeInterval = 10 * 60

    let uuid: String
    let verifier: String

    init(uuid: String = UUID().uuidString.lowercased(), verifier: String? = nil) {
        self.uuid = uuid
        if let verifier {
            self.verifier = verifier
        } else {
            var bytes = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            self.verifier = Self.base64URL(Data(bytes))
        }
    }

    var challenge: String { Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    /// Opened in the user's default browser.
    var loginURL: URL {
        var components = URLComponents(string: "https://cursor.com/loginDeepControl")!
        components.queryItems = [URLQueryItem(name: "challenge", value: challenge),
                                 URLQueryItem(name: "uuid", value: uuid),
                                 URLQueryItem(name: "mode", value: "login")]
        return components.url!
    }

    /// The signed-in session, or nil while the user hasn't finished.
    func poll(_ transport: HTTPTransport) async throws -> CursorSession? {
        var components = URLComponents(string: "https://api2.cursor.sh/auth/poll")!
        components.queryItems = [URLQueryItem(name: "uuid", value: uuid), URLQueryItem(name: "verifier", value: verifier)]
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await transport.send(request)
        if response.statusCode == 404 { return nil }
        try ProviderFailure.check(response, provider: .cursor, signInHint: "Try signing in again.", now: Date())
        guard let root = (try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any],
              let token = (root["accessToken"] as? String).nonEmpty else { return nil }
        let session = CursorSession(accessToken: token)
        guard session.userID != nil else {
            throw ProviderFailure(.invalidResponse, "Cursor's sign-in didn't include an account.")
        }
        return session
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
