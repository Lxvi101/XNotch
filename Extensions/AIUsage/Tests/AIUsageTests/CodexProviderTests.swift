import XCTest
@testable import AIUsage

final class CodexProviderTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = temporaryDirectory()
    }

    private func accessToken(expires: Date = referenceDate.addingTimeInterval(86400), user: String = "user-synthetic-1") -> String {
        TestJWT.make(["exp": Int(expires.timeIntervalSince1970), "sub": user,
                      "https://api.openai.com/auth": ["chatgpt_account_id": "acct-synthetic-1", "chatgpt_user_id": user]])
    }

    @discardableResult
    private func writeAuth(in directory: URL, tokens: [String: Any]? = nil, apiKey: String? = nil) -> URL {
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var object: [String: Any] = ["last_refresh": "2026-09-20T00:00:00Z"]
        if let tokens { object["tokens"] = tokens }
        if let apiKey { object["OPENAI_API_KEY"] = apiKey }
        let url = directory.appendingPathComponent("auth.json")
        try! JSONSerialization.data(withJSONObject: object).write(to: url)
        return url
    }

    private func standardTokens(access: String? = nil) -> [String: Any] {
        ["access_token": access ?? accessToken(), "refresh_token": "rt-synthetic",
         "id_token": TestJWT.make(["email": "dev@example.com", "sub": "user-synthetic-1"]), "account_id": "acct-synthetic-1"]
    }

    private func provider(_ transport: MockTransport, codexHome: URL? = nil) -> CodexUsageProvider {
        CodexUsageProvider(transport: transport,
                           codexHome: CodexHome(environment: ["CODEX_HOME": (codexHome ?? root.appendingPathComponent(".codex")).path], home: root))
    }

    private static let standardTransport = MockTransport { request in
        request.url?.path.hasSuffix("rate-limit-reset-credits") == true
            ? MockTransport.fixture("codex_reset_credits") : MockTransport.fixture("codex_usage")
    }

    func testReadsOnlyTheConfiguredCodexHome() throws {
        writeAuth(in: root.appendingPathComponent(".codex"), tokens: standardTokens())
        let other = root.appendingPathComponent("other-home")
        writeAuth(in: other, apiKey: "sk-synthetic")
        let home = CodexHome(environment: ["CODEX_HOME": other.path], home: root)
        XCTAssertEqual(home.authFile.path, other.appendingPathComponent("auth.json").path)
        XCTAssertThrowsError(try home.loadCredentials()) { assertFailure($0, .notConnected) }
        XCTAssertNoThrow(try CodexHome(environment: [:], home: root).loadCredentials())
    }

    func testAPIKeyIsNotASubscription() {
        writeAuth(in: root.appendingPathComponent(".codex"), apiKey: "sk-synthetic")
        XCTAssertThrowsError(try CodexHome(environment: [:], home: root).loadCredentials()) { error in
            assertFailure(error, .notConnected)
            XCTAssertTrue((error as! ProviderFailure).message.contains("API key"))
            XCTAssertFalse((error as! ProviderFailure).message.contains("sk-synthetic"))
        }
    }

    func testAccountIDRecoveredFromJWTWhenMissing() throws {
        var tokens = standardTokens()
        tokens["account_id"] = nil
        tokens["id_token"] = nil
        writeAuth(in: root.appendingPathComponent(".codex"), tokens: tokens)
        let credentials = try CodexHome(environment: [:], home: root).loadCredentials()
        XCTAssertEqual(credentials.accountID, "acct-synthetic-1")
        XCTAssertEqual(credentials.expiresAt, referenceDate.addingTimeInterval(86400))
    }

    func testRequestAndMapping() async throws {
        writeAuth(in: root.appendingPathComponent(".codex"), tokens: standardTokens())
        let transport = Self.standardTransport
        let snapshot = try await provider(transport).fetch(FetchContext(now: referenceDate))

        let usage = try XCTUnwrap(transport.requests.first { $0.url?.path == "/backend-api/wham/usage" })
        XCTAssertEqual(usage.url?.host, "chatgpt.com")
        XCTAssertEqual(usage.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "acct-synthetic-1")
        XCTAssertEqual(usage.value(forHTTPHeaderField: "Authorization"), "Bearer \(accessToken())")

        XCTAssertEqual(snapshot.planLabel, "Pro 20x")
        XCTAssertEqual(snapshot.accountLabel, "dev@example.com")
        XCTAssertEqual(snapshot.coreWindows.map(\.label), ["Session", "Weekly"])
        XCTAssertEqual(snapshot.coreWindows[0].percentUsed, 42)
        XCTAssertEqual(snapshot.coreWindows[0].resetsAt, Date(timeIntervalSince1970: 1_790_010_000), "reset_at is Unix seconds")
        XCTAssertEqual(snapshot.coreWindows[1].windowSeconds, 604_800)
        XCTAssertEqual(snapshot.extraWindows.map(\.label), ["Spark 5-hour", "Spark weekly", "Research Preview", "Code review"])
        XCTAssertEqual(snapshot.credits?.balance, 125.5)
        XCTAssertEqual(snapshot.credits?.savedResets, 2)
        XCTAssertEqual(snapshot.credits?.savedResetsNextExpiry, ISO8601.parse("2026-10-10T00:00:00Z"))
    }

    func testSwappedWindowsAreNormalized() async throws {
        writeAuth(in: root.appendingPathComponent(".codex"), tokens: standardTokens())
        let snapshot = try await provider(MockTransport { _ in MockTransport.fixture("codex_usage_swapped") })
            .fetch(FetchContext(includeExtras: false, now: referenceDate))
        XCTAssertEqual(snapshot.coreWindows.map(\.label), ["Session", "Weekly"])
        XCTAssertEqual(snapshot.coreWindows.map(\.percentUsed), [8, 55])
    }

    func testResetCreditFailureDoesNotHideQuota() async throws {
        writeAuth(in: root.appendingPathComponent(".codex"), tokens: standardTokens())
        let transport = MockTransport { request in
            request.url?.path.hasSuffix("rate-limit-reset-credits") == true
                ? MockTransport.json(500, "{}") : MockTransport.fixture("codex_usage")
        }
        let snapshot = try await provider(transport).fetch(FetchContext(now: referenceDate))
        XCTAssertEqual(snapshot.coreWindows.count, 2)
        XCTAssertEqual(snapshot.credits?.savedResets, 1, "Falls back to the usage response's own count")
        XCTAssertNil(snapshot.credits?.savedResetsNextExpiry)
        XCTAssertEqual(snapshot.credits?.balance, 125.5)
    }

    func testExpiredLoginNeverTouchesNetworkOrAuthFile() async throws {
        let url = writeAuth(in: root.appendingPathComponent(".codex"),
                            tokens: standardTokens(access: accessToken(expires: referenceDate.addingTimeInterval(-60))))
        let before = try Data(contentsOf: url)
        let modified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        let transport = Self.standardTransport
        do {
            _ = try await provider(transport).fetch(FetchContext(now: referenceDate))
            XCTFail("Expected failure")
        } catch {
            assertFailure(error, .unauthorized)
            XCTAssertTrue((error as! ProviderFailure).message.contains("codex login"))
            XCTAssertNotNil((error as? ProviderFailure)?.accountKey)
        }
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, modified)
    }

    func testUnauthorizedAndRateLimited() async {
        writeAuth(in: root.appendingPathComponent(".codex"), tokens: standardTokens())
        for (status, kind) in [(401, ProviderFailure.Kind.unauthorized),
                               (429, .rateLimited(retryAfter: referenceDate.addingTimeInterval(30)))] {
            let transport = MockTransport { _ in MockTransport.json(status, "{}", headers: ["retry-after": "30"]) }
            do {
                _ = try await provider(transport).fetch(FetchContext(includeExtras: false, now: referenceDate))
                XCTFail("Expected failure")
            } catch {
                assertFailure(error, kind)
            }
        }
    }

    func testConfiguredBaseURL() throws {
        let home = root.appendingPathComponent(".codex")
        writeAuth(in: home, tokens: standardTokens())
        try "model = \"o3\"\nchatgpt_base_url = \"https://chatgpt.com/\"  # comment\n".write(
            to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(provider(Self.standardTransport).baseURL().usage.absoluteString, "https://chatgpt.com/backend-api/wham/usage")

        try "chatgpt_base_url = 'https://codex.example.com/'\n".write(to: home.appendingPathComponent("config.toml"),
                                                                     atomically: true, encoding: .utf8)
        XCTAssertEqual(provider(Self.standardTransport).baseURL().usage.absoluteString, "https://codex.example.com/api/codex/usage")
        XCTAssertEqual(CodexUsageProvider.configuredHost(CodexHome(environment: ["CODEX_HOME": home.path], home: root)), "codex.example.com")

        try "chatgpt_base_url = \"http://insecure.example.com\"\n".write(to: home.appendingPathComponent("config.toml"),
                                                                       atomically: true, encoding: .utf8)
        XCTAssertEqual(provider(Self.standardTransport).baseURL().usage.host, "chatgpt.com", "Tokens never go over plain HTTP")
    }

    func testDifferentUsersInOneWorkspaceStayApart() throws {
        writeAuth(in: root.appendingPathComponent(".codex"), tokens: standardTokens(access: accessToken(user: "user-a")))
        let a = try CodexHome(environment: [:], home: root).loadCredentials()
        writeAuth(in: root.appendingPathComponent(".codex"), tokens: standardTokens(access: accessToken(user: "user-b")))
        let b = try CodexHome(environment: [:], home: root).loadCredentials()
        XCTAssertEqual(a.accountID, b.accountID)
        XCTAssertNotEqual(a.accountKey, b.accountKey)
    }

    // MARK: Weekly reset guard

    private func weekly(_ percent: Double, resets: Date) -> QuotaWindow {
        QuotaWindow(id: "codex.weekly", label: "Weekly", percentUsed: percent, resetsAt: resets, windowSeconds: 604_800)
    }

    func testApparentEarlyWeeklyResetIsHeldUntilConfirmed() {
        var guardrail = WeeklyResetGuard()
        let firstReset = referenceDate.addingTimeInterval(3 * 86400)
        let earlyReset = referenceDate.addingTimeInterval(7 * 86400)
        _ = guardrail.review(weekly(70, resets: firstReset), accountKey: "a", savedResets: nil, now: referenceDate)

        let held = guardrail.review(weekly(0, resets: earlyReset), accountKey: "a", savedResets: nil, now: referenceDate)
        XCTAssertEqual(held.percentUsed, 70)
        XCTAssertEqual(held.resetsAt, firstReset)

        let confirmed = guardrail.review(weekly(1, resets: earlyReset), accountKey: "a", savedResets: nil, now: referenceDate)
        XCTAssertEqual(confirmed.percentUsed, 1)
        XCTAssertEqual(confirmed.resetsAt, earlyReset)
    }

    func testRedeemedResetOrNaturalResetPassesImmediately() {
        var guardrail = WeeklyResetGuard()
        let firstReset = referenceDate.addingTimeInterval(3 * 86400)
        let nextWeek = referenceDate.addingTimeInterval(7 * 86400)
        _ = guardrail.review(weekly(70, resets: firstReset), accountKey: "a", savedResets: 2, now: referenceDate)
        XCTAssertEqual(guardrail.review(weekly(0, resets: nextWeek), accountKey: "a", savedResets: 1, now: referenceDate).percentUsed, 0)

        var natural = WeeklyResetGuard()
        _ = natural.review(weekly(70, resets: referenceDate), accountKey: "a", savedResets: nil, now: referenceDate.addingTimeInterval(-3600))
        XCTAssertEqual(natural.review(weekly(0, resets: nextWeek), accountKey: "a", savedResets: nil, now: referenceDate).percentUsed, 0)

        var accounts = WeeklyResetGuard()
        _ = accounts.review(weekly(70, resets: firstReset), accountKey: "a", savedResets: nil, now: referenceDate)
        XCTAssertEqual(accounts.review(weekly(5, resets: nextWeek), accountKey: "b", savedResets: nil, now: referenceDate).percentUsed, 5,
                       "Another account's reading is never compared with, or replaced by, this one's")
    }
}
