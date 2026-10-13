import SQLite3
import XCTest
@testable import AIUsage

final class CursorProviderTests: XCTestCase {
    private static func token(sub: String = "auth0|user_01ABC", expires: Date = referenceDate.addingTimeInterval(86400)) -> String {
        TestJWT.make(["sub": sub, "exp": Int(expires.timeIntervalSince1970)])
    }

    // MARK: SQLite

    /// A Cursor-like state database with one ItemTable row.
    private func makeDatabase(value: Data? = nil, text: String? = nil, wal: Bool = false) -> String {
        let path = temporaryDirectory().appendingPathComponent("state.vscdb").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        if wal { sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil) }
        sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);", nil, nil, nil)
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', ?);", -1, &statement, nil)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        if let text {
            sqlite3_bind_text(statement, 1, text, -1, transient)
        } else if let value {
            _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(value.count), transient) }
        }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        sqlite3_finalize(statement)
        sqlite3_close(db)
        return path
    }

    private func directoryListing(of path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: (path as NSString).deletingLastPathComponent))?.sorted() ?? []
    }

    func testReadsTextTokenWithoutTouchingTheDatabase() throws {
        let token = Self.token()
        let path = makeDatabase(text: token)
        let before = directoryListing(of: path)
        let modified = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
        let session = try CursorDesktopAuth(dbPath: path).loadSession()
        XCTAssertEqual(session?.accessToken, token)
        XCTAssertEqual(directoryListing(of: path), before, "No sidecars or other files created")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date, modified)
    }

    func testDecodesUTF16LittleEndianBlob() throws {
        let token = Self.token()
        let path = makeDatabase(value: token.data(using: .utf16LittleEndian)!)
        XCTAssertEqual(try CursorDesktopAuth(dbPath: path).loadSession()?.accessToken, token)
        XCTAssertEqual(CursorDesktopAuth.decodeBlob(Data("abc".utf8)), "abc")
    }

    func testIdleWALDatabaseWithoutSidecarsUsesImmutableRead() throws {
        let token = Self.token()
        let path = makeDatabase(text: token, wal: true)
        // An idle Cursor database: checkpointed, sidecars gone (Apple's SQLite may keep them, so remove them),
        // and WAL mode still recorded in the header.
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
        let before = directoryListing(of: path)
        XCTAssertEqual(try CursorDesktopAuth(dbPath: path).loadSession()?.accessToken, token)
        XCTAssertEqual(directoryListing(of: path), before)
    }

    func testLiveWALDatabaseReadsUncheckpointedValue() throws {
        let path = makeDatabase(text: "old", wal: true)
        var writer: OpaquePointer?
        sqlite3_open(path, &writer)
        sqlite3_exec(writer, "PRAGMA wal_autocheckpoint=0;", nil, nil, nil)
        let token = Self.token()
        sqlite3_exec(writer, "INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', '\(token)');", nil, nil, nil)
        defer { sqlite3_close(writer) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "-wal"))
        XCTAssertEqual(try CursorDesktopAuth(dbPath: path).loadSession()?.accessToken, token)
    }

    func testMissingDatabaseIsNoSession() throws {
        XCTAssertNil(try CursorDesktopAuth(dbPath: "/nonexistent/state.vscdb").loadSession())
    }

    // MARK: Session

    func testSessionIdentityExpiryAndCookie() {
        let session = CursorSession(accessToken: Self.token())
        XCTAssertEqual(session.userID, "user_01ABC")
        XCTAssertTrue(session.isUsable(at: referenceDate))
        XCTAssertEqual(session.cookieHeader, "WorkosCursorSessionToken=user_01ABC%3A%3A\(session.accessToken)")
        XCTAssertEqual(CursorSession.userID(fromCookieHeader: "a=b; " + session.cookieHeader!), "user_01ABC")

        let expiring = CursorSession(accessToken: Self.token(expires: referenceDate.addingTimeInterval(60)))
        XCTAssertFalse(expiring.isUsable(at: referenceDate), "Tokens with a minute or less left aren't used")
        XCTAssertFalse(CursorSession(accessToken: "not-a-jwt").isUsable(at: referenceDate))
        XCTAssertNil(CursorSession(accessToken: TestJWT.make(["sub": "auth0|bad id", "exp": 9_999_999_999])).userID)
    }

    // MARK: Mapping

    private func map(_ name: String, requests: CursorRequestUsage? = nil, sand: String? = nil) throws -> ProviderUsageSnapshot {
        let summary = try JSONDecoder().decode(CursorUsageSummary.self, from: Fixture.data(name))
        let sandUsage = try sand.map { try JSONDecoder().decode(CursorSandUsage.self, from: Fixture.data($0)) }
        return CursorUsageProvider.snapshot(summary: summary, requests: requests, sand: sandUsage, accountKey: "k", fingerprint: nil,
                                            email: nil, source: .cursorDesktop, includeExtras: true, now: referenceDate)
    }

    func testPercentFieldsAreAlreadyPercentAndCentsBecomeDollars() throws {
        let snapshot = try map("cursor_usage_summary", sand: "cursor_sand_included")
        let plan = try XCTUnwrap(snapshot.coreWindows.first)
        XCTAssertEqual(plan.label, "Plan")
        XCTAssertEqual(plan.percentUsed, 0.36, "0.36 means 0.36%, not 36%")
        XCTAssertEqual(plan.detail, "\(Money.format(4.12, "USD")) of \(Money.format(20, "USD"))")
        XCTAssertEqual(plan.resetsAt, ISO8601.parse("2026-10-01T00:00:00Z"), "billingCycleEnd is the monthly reset")
        XCTAssertEqual(plan.windowSeconds, 30 * 86400)
        XCTAssertEqual(snapshot.planLabel, "Pro")
        XCTAssertEqual(snapshot.coreWindows.map(\.label), ["Plan", "Third-party models"], "Third-party models are pinned")
        XCTAssertEqual(snapshot.coreWindows[1].percentUsed, 4.5)
        XCTAssertEqual(snapshot.coreWindows[1].shortLabel, "Third party")
        XCTAssertEqual(snapshot.extraWindows.map(\.label), ["Cursor models", "Grok Bot"])
        let onDemand = try XCTUnwrap(snapshot.spending?.lines.first)
        XCTAssertEqual(onDemand.used, 2.5)
        XCTAssertEqual(onDemand.limit, 50)
    }

    func testMissingPlanDataIsUnknownNotZero() throws {
        let snapshot = try map("cursor_usage_unknown")
        XCTAssertNil(snapshot.coreWindows.first?.percentUsed)
        XCTAssertNil(snapshot.coreWindows.first?.displayUsed)
        XCTAssertEqual(UsageFormat.percent(snapshot.coreWindows.first?.displayUsed), "–")
    }

    func testLegacyRequestPlanUsesRequestCounts() throws {
        let requests = try JSONDecoder().decode(CursorRequestUsage.self, from: Fixture.data("cursor_legacy_requests"))
        let snapshot = try map("cursor_usage_summary", requests: requests, sand: "cursor_sand_included")
        XCTAssertEqual(snapshot.coreWindows.map(\.label), ["Requests"])
        XCTAssertEqual(snapshot.coreWindows[0].percentUsed ?? 0, 28.4, accuracy: 0.001)
        XCTAssertEqual(snapshot.coreWindows[0].detail, "142 / 500 requests")
        XCTAssertTrue(snapshot.extraWindows.isEmpty, "No token percentages or Grok Bot beside a request quota")
    }

    func testGrokBotTrialExpiryIsNotAWeeklyReset() throws {
        let trial = try XCTUnwrap(try map("cursor_usage_summary", sand: "cursor_sand_trial").extraWindows.last)
        XCTAssertEqual(trial.label, "Grok Bot trial")
        XCTAssertNil(trial.resetsAt)
        let included = try XCTUnwrap(try map("cursor_usage_summary", sand: "cursor_sand_included").extraWindows.last)
        XCTAssertEqual(included.resetsAt, ISO8601.parse("2026-09-28T00:00:00Z"))
    }

    func testTeamPoolWithoutPersonalPlan() throws {
        let snapshot = try map("cursor_usage_team")
        XCTAssertEqual(snapshot.coreWindows.first?.percentUsed, 25)
        XCTAssertEqual(snapshot.spending?.lines.map(\.label), ["Team on-demand", "Your on-demand"])
        XCTAssertEqual(snapshot.spending?.lines.last?.used, 18)
    }

    // MARK: Fetch

    private final class StaticSession: CursorSessionLoading, @unchecked Sendable {
        let session: CursorSession?
        init(_ session: CursorSession?) { self.session = session }
        func loadSession() throws -> CursorSession? { session }
    }

    func testOptionalEndpointsFailingKeepsMonthlyQuota() async throws {
        let transport = MockTransport { request in
            request.url?.path == "/api/usage-summary" ? MockTransport.fixture("cursor_usage_summary") : MockTransport.json(500, "{}")
        }
        let provider = CursorUsageProvider(transport: transport, desktop: StaticSession(CursorSession(accessToken: Self.token())),
                                           secrets: FakeKeychain(), preference: { .automatic })
        let snapshot = try await provider.fetch(FetchContext(now: referenceDate))
        XCTAssertEqual(snapshot.coreWindows.first?.percentUsed, 0.36)
        XCTAssertEqual(snapshot.source, .cursorDesktop)
        XCTAssertEqual(snapshot.accountKey, Hashing.key("cursor-account", "user_01abc"))

        let sand = try XCTUnwrap(transport.requests.first { $0.url?.path == "/api/dashboard/get-sand-usage-status" })
        XCTAssertEqual(sand.httpMethod, "POST")
        XCTAssertEqual(sand.value(forHTTPHeaderField: "Origin"), "https://cursor.com")
        XCTAssertTrue(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie")?.hasPrefix("WorkosCursorSessionToken=") ?? false })
        XCTAssertFalse(transport.requests.contains { $0.url?.path.contains("team") ?? false }, "No team budget lookups")
    }

    func testRejectedDesktopSessionFallsBackToSavedCookie() async throws {
        let secrets = FakeKeychain()
        let cookieToken = Self.token(sub: "auth0|user_02XYZ")
        secrets.own[CursorUsageProvider.manualCookieName] = Data("WorkosCursorSessionToken=user_02XYZ%3A%3A\(cookieToken)".utf8)
        let transport = MockTransport { request in
            let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
            if cookie.contains("user_01ABC") { return MockTransport.json(401, "{}") }
            return request.url?.path == "/api/usage-summary" ? MockTransport.fixture("cursor_usage_summary") : MockTransport.json(404, "{}")
        }
        let provider = CursorUsageProvider(transport: transport, desktop: StaticSession(CursorSession(accessToken: Self.token())),
                                           secrets: secrets, preference: { .automatic })
        let snapshot = try await provider.fetch(FetchContext(now: referenceDate))
        XCTAssertEqual(snapshot.source, .cursorManualCookie)
        XCTAssertEqual(snapshot.accountKey, Hashing.key("cursor-account", "user_02xyz"), "The cookie's own account, never the app's")
    }

    func testExpiredDesktopSessionWithoutCookieIsNotConnected() async {
        let provider = CursorUsageProvider(
            transport: MockTransport { _ in MockTransport.fixture("cursor_usage_summary") },
            desktop: StaticSession(CursorSession(accessToken: Self.token(expires: referenceDate.addingTimeInterval(-5)))),
            secrets: FakeKeychain(), preference: { .automatic })
        do {
            _ = try await provider.fetch(FetchContext(now: referenceDate))
            XCTFail("Expected failure")
        } catch {
            assertFailure(error, .notConnected)
            XCTAssertTrue((error as! ProviderFailure).message.contains("expired"))
        }
    }

    func testSavedCookieReadInBackgroundNeverPrompts() async {
        let secrets = FakeKeychain()
        secrets.own[CursorUsageProvider.manualCookieName] = Data("WorkosCursorSessionToken=x".utf8)
        secrets.backgroundResult = .interactionRequired
        let provider = CursorUsageProvider(transport: MockTransport { _ in MockTransport.json(500, "{}") },
                                           desktop: StaticSession(nil), secrets: secrets, preference: { .manualCookie })
        do {
            _ = try await provider.fetch(FetchContext(isInteractive: false, now: referenceDate))
            XCTFail("Expected failure")
        } catch {
            assertFailure(error, .needsKeychainAccess)
        }
        XCTAssertTrue(secrets.reads.allSatisfy { !$0.interactive })
    }

    func testUnauthorizedFailureCarriesAccount() async {
        let provider = CursorUsageProvider(transport: MockTransport { _ in MockTransport.json(403, "{}") },
                                           desktop: StaticSession(CursorSession(accessToken: Self.token())),
                                           secrets: FakeKeychain(), preference: { .desktop })
        do {
            _ = try await provider.fetch(FetchContext(now: referenceDate))
            XCTFail("Expected failure")
        } catch {
            assertFailure(error, .unauthorized)
            XCTAssertEqual((error as? ProviderFailure)?.accountKey, Hashing.key("cursor-account", "user_01abc"))
        }
    }

    // MARK: Browser sign-in

    func testBrowserLoginLinkCarriesOnlyTheChallenge() {
        let login = CursorBrowserLogin(uuid: "u-1", verifier: "abc")
        XCTAssertEqual(login.challenge, "ungWv48Bz-pBQUDeXa4iI7ADYaOWF3qctBD_YfIAFa0", "base64url SHA-256 of the verifier")
        let url = login.loginURL.absoluteString
        XCTAssertTrue(url.hasPrefix("https://cursor.com/loginDeepControl?"))
        XCTAssertTrue(url.contains("challenge=ungWv48Bz-pBQUDeXa4iI7ADYaOWF3qctBD_YfIAFa0"))
        XCTAssertTrue(url.contains("uuid=u-1"))
        XCTAssertFalse(url.contains("verifier"), "The verifier never leaves XNotch except to collect the session")
        XCTAssertNotEqual(CursorBrowserLogin().verifier, CursorBrowserLogin().verifier)
    }

    func testBrowserLoginPollsUntilSignedIn() async throws {
        let token = Self.token()
        let signedIn = Locked(false)
        let transport = MockTransport { request in
            XCTAssertEqual(request.url?.host, "api2.cursor.sh")
            XCTAssertTrue(request.url?.query?.contains("verifier=abc") ?? false)
            return signedIn.value ? MockTransport.json(200, #"{"accessToken": "\#(token)", "authId": "auth0|user_01ABC"}"#)
                : MockTransport.json(404, "Not found")
        }
        let login = CursorBrowserLogin(uuid: "u-1", verifier: "abc")
        let pending = try await login.poll(transport)
        XCTAssertNil(pending)
        signedIn.value = true
        let session = try await login.poll(transport)
        XCTAssertEqual(session?.userID, "user_01ABC")
        XCTAssertEqual(session?.cookieHeader, "WorkosCursorSessionToken=user_01ABC%3A%3A\(token)")
    }
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
