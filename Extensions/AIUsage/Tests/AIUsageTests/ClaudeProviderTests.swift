import XCTest
@testable import AIUsage

final class ClaudeProviderTests: XCTestCase {
    private let token = "sk-ant-oat01-SYNTHETIC-access"
    private var home: URL!

    override func setUp() {
        home = temporaryDirectory()
    }

    private func credentialsJSON(expiresAt: Date = referenceDate.addingTimeInterval(3600), scopes: [String] = ["user:inference", "user:profile"],
                                 accessToken: String? = nil) -> Data {
        let object: [String: Any] = ["claudeAiOauth": [
            "accessToken": accessToken ?? token, "refreshToken": "sk-ant-ort01-SYNTHETIC-refresh",
            "expiresAt": expiresAt.timeIntervalSince1970 * 1000, "scopes": scopes,
            "subscriptionType": "max", "rateLimitTier": "default_claude_max_20x",
        ]]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func writeCredentialsFile(_ data: Data) {
        let dir = home.appendingPathComponent(".claude", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try! data.write(to: dir.appendingPathComponent(".credentials.json"))
    }

    private func provider(_ transport: MockTransport, keychain: FakeKeychain = FakeKeychain(), consent: Bool = false,
                          environment: [String: String] = [:]) -> ClaudeUsageProvider {
        ClaudeUsageProvider(transport: transport,
                            locator: ClaudeCredentialLocator(environment: environment, home: home, keychain: keychain),
                            keychainAllowed: { consent })
    }

    private static func usageAndProfile(_ usage: String = "claude_usage_full") -> MockTransport {
        MockTransport { request in
            request.url?.path == "/api/oauth/profile" ? MockTransport.fixture("claude_profile") : MockTransport.fixture(usage)
        }
    }

    // MARK: Credentials

    func testParsesCredentialsWithMillisecondExpiryAndPlan() throws {
        let credentials = try ClaudeOAuthCredentials.parse(credentialsJSON(expiresAt: Date(timeIntervalSince1970: 1_790_003_600)))
        XCTAssertEqual(credentials.expiresAt, Date(timeIntervalSince1970: 1_790_003_600))
        XCTAssertEqual(credentials.planLabel, "Max 20x")
        XCTAssertTrue(credentials.canReadUsage)
        XCTAssertFalse(credentials.isExpired(at: referenceDate))
    }

    func testRejectsMCPOnlyPayload() {
        let data = Data(#"{"mcpOAuth": {"server": {"accessToken": "x"}}}"#.utf8)
        XCTAssertThrowsError(try ClaudeOAuthCredentials.parse(data)) {
            XCTAssertEqual($0 as? ClaudeOAuthCredentials.ParseError, .mcpOnly)
        }
    }

    func testInferenceOnlyTokenNeverQueriesUsage() async {
        writeCredentialsFile(credentialsJSON(scopes: ["user:inference"]))
        let transport = Self.usageAndProfile()
        do {
            _ = try await provider(transport).fetch(FetchContext(now: referenceDate))
            XCTFail("Expected failure")
        } catch {
            assertFailure(error, .notConnected)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testExpiredTokenSkipsNetworkAndKeepsFingerprint() async {
        writeCredentialsFile(credentialsJSON(expiresAt: referenceDate.addingTimeInterval(-10)))
        let transport = Self.usageAndProfile()
        do {
            _ = try await provider(transport).fetch(FetchContext(now: referenceDate))
            XCTFail("Expected failure")
        } catch {
            assertFailure(error, .unauthorized)
            XCTAssertNotNil((error as? ProviderFailure)?.credentialFingerprint)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    // MARK: Keychain consent

    func testKeychainIsNotReadWithoutConsent() async {
        let keychain = FakeKeychain()
        keychain.foreign[ClaudeCredentialLocator.keychainService] = credentialsJSON()
        do {
            _ = try await provider(Self.usageAndProfile(), keychain: keychain, consent: false).fetch(FetchContext(now: referenceDate))
            XCTFail("Expected failure")
        } catch {
            assertFailure(error, .needsKeychainAccess)
        }
        XCTAssertTrue(keychain.reads.isEmpty, "No Keychain data read without consent")
    }

    func testBackgroundKeychainReadNeverPrompts() async {
        let keychain = FakeKeychain()
        keychain.foreign[ClaudeCredentialLocator.keychainService] = credentialsJSON()
        keychain.backgroundResult = .interactionRequired
        let provider = provider(Self.usageAndProfile(), keychain: keychain, consent: true)
        for _ in 0..<3 {
            do {
                _ = try await provider.fetch(FetchContext(isInteractive: false, now: referenceDate))
                XCTFail("Expected failure")
            } catch {
                assertFailure(error, .needsKeychainAccess)
            }
        }
        XCTAssertEqual(keychain.reads.count, 3)
        XCTAssertTrue(keychain.reads.allSatisfy { !$0.interactive })
    }

    func testInteractiveKeychainGrantThenCachesInMemory() async throws {
        let keychain = FakeKeychain()
        keychain.foreign[ClaudeCredentialLocator.keychainService] = credentialsJSON()
        keychain.backgroundResult = .interactionRequired
        let provider = provider(Self.usageAndProfile(), keychain: keychain, consent: true)
        let snapshot = try await provider.fetch(FetchContext(isInteractive: true, now: referenceDate))
        XCTAssertEqual(snapshot.source, .claudeKeychain)
        _ = try await provider.fetch(FetchContext(isInteractive: false, now: referenceDate))
        XCTAssertEqual(keychain.reads.map(\.interactive), [true], "The second, background fetch reuses the in-memory login")
    }

    func testKeychainDenialIsReported() async {
        let keychain = FakeKeychain()
        keychain.foreign[ClaudeCredentialLocator.keychainService] = credentialsJSON()
        keychain.interactiveResult = .denied
        do {
            _ = try await provider(Self.usageAndProfile(), keychain: keychain, consent: true)
                .fetch(FetchContext(isInteractive: true, now: referenceDate))
            XCTFail("Expected failure")
        } catch {
            assertFailure(error, .needsKeychainAccess)
        }
    }

    func testWelcomeTourAsksOnlyWhenTheKeychainIsTheOnlyWayIn() {
        let keychain = FakeKeychain()
        let locator = ClaudeCredentialLocator(environment: [:], home: home, keychain: keychain)
        XCTAssertFalse(locator.needsKeychainAccess(consented: false), "Not signed in: nothing to ask")

        keychain.foreign[ClaudeCredentialLocator.keychainService] = credentialsJSON()
        XCTAssertTrue(locator.needsKeychainAccess(consented: false))
        XCTAssertTrue(keychain.reads.isEmpty, "Without consent the item's data is never read")

        keychain.backgroundResult = .interactionRequired
        XCTAssertTrue(locator.needsKeychainAccess(consented: true))
        keychain.backgroundResult = nil
        XCTAssertFalse(locator.needsKeychainAccess(consented: true), "Always Allow was granted")
        XCTAssertTrue(keychain.reads.allSatisfy { !$0.interactive })

        writeCredentialsFile(credentialsJSON())
        keychain.backgroundResult = .interactionRequired
        XCTAssertFalse(locator.needsKeychainAccess(consented: true), "A credentials file needs no Keychain")
    }

    func testCustomConfigDirNeverBorrowsDefaultKeychainLogin() async {
        let keychain = FakeKeychain()
        keychain.foreign[ClaudeCredentialLocator.keychainService] = credentialsJSON()
        do {
            _ = try await provider(Self.usageAndProfile(), keychain: keychain, consent: true,
                                   environment: ["CLAUDE_CONFIG_DIR": home.appendingPathComponent("profile-b").path])
                .fetch(FetchContext(now: referenceDate))
            XCTFail("Expected failure")
        } catch {
            assertFailure(error, .notConnected)
        }
        XCTAssertTrue(keychain.reads.isEmpty)
    }

    // MARK: Request

    func testRequestShapeAndMapping() async throws {
        writeCredentialsFile(credentialsJSON())
        let transport = Self.usageAndProfile()
        let snapshot = try await provider(transport).fetch(FetchContext(now: referenceDate))

        let usage = try XCTUnwrap(transport.requests.first { $0.url?.path == "/api/oauth/usage" })
        XCTAssertEqual(usage.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage?cedar_ember=1")
        XCTAssertEqual(usage.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        XCTAssertEqual(usage.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(usage.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertTrue(usage.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("claude-cli/") ?? false)

        XCTAssertEqual(snapshot.planLabel, "Max 20x")
        XCTAssertEqual(snapshot.accountLabel, "dev@example.com")
        XCTAssertEqual(snapshot.coreWindows.map(\.label), ["Session", "Weekly"])
        XCTAssertEqual(snapshot.coreWindows[0].percentUsed, 37.5)
        XCTAssertEqual(snapshot.coreWindows[0].resetsAt, ISO8601.parse("2026-09-21T18:00:00Z"))
        XCTAssertEqual(snapshot.coreWindows[0].windowSeconds, 5 * 3600)
        XCTAssertEqual(snapshot.extraWindows.map(\.label), ["Fable only", "Sonnet weekly", "Routines"])

        let spend = try XCTUnwrap(snapshot.spending?.lines.first)
        XCTAssertEqual(spend.used, 12.34, accuracy: 0.001, "extra_usage is reported in cents")
        XCTAssertEqual(spend.limit, 50)

        // Saved resets are inventory, separate from every window's reset time.
        XCTAssertEqual(snapshot.credits?.savedResets, 2)
        XCTAssertEqual(snapshot.credits?.savedResetsNextExpiry, ISO8601.parse("2026-10-01T00:00:00Z"))
    }

    func testSameAccountAcrossTokenRotationAndDifferentAccountsStayApart() async throws {
        writeCredentialsFile(credentialsJSON())
        let first = try await provider(Self.usageAndProfile()).fetch(FetchContext(now: referenceDate))
        writeCredentialsFile(credentialsJSON(accessToken: "sk-ant-oat01-SYNTHETIC-rotated"))
        let rotated = try await provider(Self.usageAndProfile()).fetch(FetchContext(now: referenceDate))
        XCTAssertEqual(first.accountKey, rotated.accountKey)

        let otherAccount = MockTransport { request in
            request.url?.path == "/api/oauth/profile"
                ? MockTransport.json(200, #"{"account": {"uuid": "00000000-0000-4000-8000-0000000000ff"}}"#)
                : MockTransport.fixture("claude_usage_full")
        }
        let other = try await provider(otherAccount).fetch(FetchContext(now: referenceDate))
        XCTAssertNotEqual(first.accountKey, other.accountKey)
    }

    func testWeeklyOnlyWhenNoSessionWindow() async throws {
        writeCredentialsFile(credentialsJSON())
        let snapshot = try await provider(Self.usageAndProfile("claude_usage_weekly_only")).fetch(FetchContext(now: referenceDate))
        XCTAssertEqual(snapshot.windows.map(\.label), ["Weekly"], "No invented 5-hour window")
        XCTAssertEqual(snapshot.windows.first?.percentUsed, 80.2)
    }

    func testExtrasOffSkipsInventoryAndModelWindows() async throws {
        writeCredentialsFile(credentialsJSON())
        let transport = Self.usageAndProfile()
        let snapshot = try await provider(transport).fetch(FetchContext(includeExtras: false, now: referenceDate))
        XCTAssertNil(transport.requests.first { $0.url?.path == "/api/oauth/usage" }?.url?.query)
        XCTAssertTrue(snapshot.extraWindows.isEmpty)
        XCTAssertNil(snapshot.credits)
        XCTAssertNil(snapshot.spending)
    }

    func testRetriesWithoutInventoryWhenRejected() async throws {
        writeCredentialsFile(credentialsJSON())
        let transport = MockTransport { request in
            if request.url?.path == "/api/oauth/profile" { return MockTransport.fixture("claude_profile") }
            return request.url?.query == nil ? MockTransport.fixture("claude_usage_weekly_only")
                : MockTransport.json(400, #"{"error": "unknown parameter"}"#)
        }
        let snapshot = try await provider(transport).fetch(FetchContext(now: referenceDate))
        XCTAssertEqual(snapshot.windows.map(\.label), ["Weekly"])
        let usageCalls = transport.requests.filter { $0.url?.path == "/api/oauth/usage" }
        XCTAssertEqual(usageCalls.map { $0.url?.query }, ["cedar_ember=1", nil])
        XCTAssertTrue(usageCalls[1].value(forHTTPHeaderField: "User-Agent")?.hasPrefix("claude-code/") ?? false)
    }

    func testMissingProfileScopeDoesNotRetry() async {
        writeCredentialsFile(credentialsJSON())
        let transport = MockTransport { _ in MockTransport.json(403, #"{"error": "requires scope user:profile"}"#) }
        do {
            _ = try await provider(transport).fetch(FetchContext(now: referenceDate))
            XCTFail("Expected failure")
        } catch {
            assertFailure(error, .unauthorized)
        }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testUnauthorizedNeverEchoesSecrets() async {
        writeCredentialsFile(credentialsJSON())
        let transport = MockTransport { _ in MockTransport.json(401, #"{"error": "invalid token \#(self.token)"}"#) }
        do {
            _ = try await provider(transport).fetch(FetchContext(now: referenceDate))
            XCTFail("Expected failure")
        } catch {
            assertFailure(error, .unauthorized)
            let failure = error as! ProviderFailure
            XCTAssertNotNil(failure.credentialFingerprint)
            XCTAssertFalse(failure.message.contains(token))
            XCTAssertFalse(String(describing: failure).contains(token))
        }
    }

    func testRateLimitHonoursRetryAfter() async {
        writeCredentialsFile(credentialsJSON())
        let transport = MockTransport { _ in MockTransport.json(429, "{}", headers: ["Retry-After": "120"]) }
        do {
            _ = try await provider(transport).fetch(FetchContext(includeExtras: false, now: referenceDate))
            XCTFail("Expected failure")
        } catch {
            assertFailure(error, .rateLimited(retryAfter: referenceDate.addingTimeInterval(120)))
        }
    }

    func testNetworkLossAndTimeoutAreUnavailable() async {
        writeCredentialsFile(credentialsJSON())
        for code in [URLError.Code.notConnectedToInternet, .timedOut] {
            let transport = MockTransport { _ in throw URLError(code) }
            do {
                _ = try await provider(transport).fetch(FetchContext(now: referenceDate))
                XCTFail("Expected failure")
            } catch {
                assertFailure(error, .unavailable)
            }
        }
    }

    func testMalformedJSONIsInvalidResponse() async {
        writeCredentialsFile(credentialsJSON())
        let transport = MockTransport { _ in MockTransport.json(200, "[1, 2") }
        do {
            _ = try await provider(transport).fetch(FetchContext(now: referenceDate))
            XCTFail("Expected failure")
        } catch {
            assertFailure(error, .invalidResponse)
        }
    }

    func testNullAndMissingFieldsStayUnknown() throws {
        let usage = try JSONDecoder().decode(ClaudeUsageResponse.self,
                                             from: Data(#"{"five_hour": {"utilization": null}, "seven_day": {"resets_at": "bad"}}"#.utf8))
        let credentials = try ClaudeOAuthCredentials.parse(credentialsJSON())
        let snapshot = ClaudeUsageProvider.snapshot(from: usage, credentials: credentials,
                                                    identity: .init(accountKey: "a", email: nil), source: .claudeCredentialsFile,
                                                    includeExtras: true, now: referenceDate)
        XCTAssertTrue(snapshot.windows.isEmpty, "No utilization means no window, never 0%")
    }

    func testScopedLimitsSkipAllModelsAndDuplicates() {
        let json = #"""
        [{"kind": "weekly_scoped", "group": "weekly", "percent": 1, "scope": {"model": {"id": "m", "display_name": "Fable"}}},
         {"kind": "weekly_scoped", "group": "weekly", "percent": 2, "scope": {"model": {"id": "m", "display_name": "Fable"}}},
         {"kind": "weekly_scoped", "group": "weekly", "percent": 3, "scope": {"model": {"display_name": "All Models"}}}]
        """#
        let limits = try! JSONDecoder().decode([ClaudeUsageResponse.Limit].self, from: Data(json.utf8))
        XCTAssertEqual(ClaudeUsageProvider.scopedWeeklyWindows(limits).map(\.percentUsed), [1])
    }

    func testCancellationStopsFetch() async {
        writeCredentialsFile(credentialsJSON())
        let transport = MockTransport { _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return MockTransport.fixture("claude_usage_full")
        }
        let provider = provider(transport)
        let task = Task { try await provider.fetch(FetchContext(now: referenceDate)) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let started = Date()
        _ = try? await task.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }
}
