import XCTest
@testable import AIUsage

/// A provider whose answers the test scripts, recording each fetch's context.
final class ScriptedProvider: UsageProvider, @unchecked Sendable {
    let id: AIProviderID
    private let lock = NSLock()
    private var contexts: [FetchContext] = []
    var delay: UInt64 = 0
    var result: () -> Result<ProviderUsageSnapshot, ProviderFailure>

    init(_ id: AIProviderID, result: @escaping () -> Result<ProviderUsageSnapshot, ProviderFailure>) {
        self.id = id
        self.result = result
    }

    var fetches: [FetchContext] { lock.withLock { contexts } }

    func fetch(_ context: FetchContext) async throws -> ProviderUsageSnapshot {
        lock.withLock { contexts.append(context) }
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return try result().get()
    }
}

func makeSnapshot(_ provider: AIProviderID = .codex, account: String = "account-a", fingerprint: String? = "fp-a",
                  percent: Double? = 40, at date: Date = referenceDate) -> ProviderUsageSnapshot {
    ProviderUsageSnapshot(provider: provider, accountKey: account, credentialFingerprint: fingerprint, planLabel: "Pro",
                          accountLabel: "dev@example.com",
                          windows: [QuotaWindow(id: "\(provider.rawValue).weekly", label: "Weekly", percentUsed: percent,
                                                resetsAt: date.addingTimeInterval(86400), windowSeconds: 604_800)],
                          refreshedAt: date, credits: nil, spending: nil, source: .codexAuthFile)
}

@MainActor
final class UsageStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        suite = "AIUsageTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func store() -> AIUsageStore {
        let store = AIUsageStore()
        store.load(defaults: defaults)
        return store
    }

    // MARK: Account ownership

    func testAnotherAccountsReadingIsNeverShown() {
        let store = store()
        store.apply(makeSnapshot(account: "account-a"))
        store.apply(ProviderFailure(.unavailable, "Offline", accountKey: "account-b"), for: .codex)
        XCTAssertNil(store.state(for: .codex).snapshot)
        XCTAssertEqual(store.state(for: .codex).status, .unavailable)

        store.apply(makeSnapshot(account: "account-a", percent: 40))
        store.apply(makeSnapshot(account: "account-b", percent: 90))
        XCTAssertEqual(store.state(for: .codex).snapshot?.accountKey, "account-b")
        XCTAssertEqual(store.state(for: .codex).snapshot?.windows.first?.percentUsed, 90, "Replaced, never merged")
    }

    func testNetworkFailureKeepsSameAccountReadingWithOriginalTimestamp() {
        let store = store()
        store.apply(makeSnapshot(at: referenceDate))
        store.apply(ProviderFailure(.unavailable, "Offline", accountKey: "account-a"), for: .codex)
        let state = store.state(for: .codex)
        XCTAssertEqual(state.status, .stale)
        XCTAssertEqual(state.snapshot?.refreshedAt, referenceDate)
        XCTAssertEqual(state.message, "Offline")
    }

    func testFingerprintIdentifiesLoginWhenAccountUnknown() {
        let store = store()
        store.apply(makeSnapshot(.claude, fingerprint: "fp-a"))
        store.apply(ProviderFailure(.unavailable, "Offline", credentialFingerprint: "fp-a"), for: .claude)
        XCTAssertNotNil(store.state(for: .claude).snapshot)
        store.apply(ProviderFailure(.unavailable, "Offline", credentialFingerprint: "fp-other"), for: .claude)
        XCTAssertNil(store.state(for: .claude).snapshot)
        store.apply(makeSnapshot(.claude))
        store.apply(ProviderFailure(.unavailable, "Offline"), for: .claude)
        XCTAssertNil(store.state(for: .claude).snapshot, "An unidentified failure can't vouch for the old reading")
    }

    func testSignedOutDropsReading() {
        let store = store()
        store.apply(makeSnapshot())
        store.apply(ProviderFailure(.notConnected, "Run codex login"), for: .codex)
        XCTAssertNil(store.state(for: .codex).snapshot)
        XCTAssertEqual(store.state(for: .codex).status, .notConnected)
    }

    func testRateLimitedAndUnauthorizedKeepSameAccountReading() {
        let store = store()
        store.apply(makeSnapshot())
        let until = referenceDate.addingTimeInterval(60)
        store.apply(ProviderFailure(.rateLimited(retryAfter: until), "Slow down", accountKey: "account-a"), for: .codex)
        XCTAssertEqual(store.state(for: .codex).status, .rateLimited(until: until))
        XCTAssertNotNil(store.state(for: .codex).snapshot)
        store.apply(ProviderFailure(.unauthorized, "Sign in", accountKey: "account-a"), for: .codex)
        XCTAssertEqual(store.state(for: .codex).status, .unauthorized)
        XCTAssertNotNil(store.state(for: .codex).snapshot)
    }

    // MARK: Cache

    func testCacheHoldsNoIdentifiersOrSecretsAndRestoresStale() throws {
        let store = store()
        store.apply(makeSnapshot())
        let data = try XCTUnwrap(defaults.data(forKey: AIUsageSettings.Keys.snapshots))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("dev@example.com"), "Emails are never cached")
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("snapshots") || key.hasSuffix("Providers") {
            XCTAssertFalse(String(describing: defaults.object(forKey: key)).lowercased().contains("bearer"))
        }

        let restored = self.store()
        XCTAssertEqual(restored.state(for: .codex).status, .stale)
        XCTAssertEqual(restored.state(for: .codex).snapshot?.refreshedAt, referenceDate)
        XCTAssertNil(restored.state(for: .codex).snapshot?.accountLabel)
    }

    func testSettingsPersistWithoutCredentials() {
        let store = store()
        store.settings.showsRemaining = true
        store.settings.refreshMinutes = 15
        store.settings.enabled.remove(.cursor)
        let reloaded = self.store()
        XCTAssertTrue(reloaded.settings.showsRemaining)
        XCTAssertEqual(reloaded.settings.refreshMinutes, 15)
        XCTAssertFalse(reloaded.settings.isEnabled(.cursor))
        XCTAssertFalse(reloaded.settings.claudeKeychainAccess, "Keychain consent is off until the user turns it on")
    }

    // MARK: Values

    func testPercentsAreNeverGuessed() {
        let unknown = QuotaWindow(id: "x", label: "x", percentUsed: nil)
        XCTAssertNil(unknown.percentRemaining)
        XCTAssertNil(unknown.displayUsed)
        let over = QuotaWindow(id: "x", label: "x", percentUsed: 104)
        XCTAssertEqual(over.displayUsed, 100)
        XCTAssertEqual(over.percentRemaining, -4, "Raw value kept for diagnostics")
        XCTAssertEqual(over.displayRemaining, 0)
        XCTAssertNil(QuotaWindow(id: "x", label: "x", percentUsed: .nan).displayUsed)
        XCTAssertEqual(UsageFormat.percent(0.36), "0.4%")
        XCTAssertEqual(UsageFormat.percent(0.05), "<0.1%")
        XCTAssertEqual(UsageFormat.countdown(to: referenceDate.addingTimeInterval(8040), from: referenceDate), "2h 14m")
        XCTAssertEqual(UsageFormat.countdown(to: referenceDate.addingTimeInterval(3 * 86400 + 4 * 3600), from: referenceDate), "3d 4h")
    }

    // MARK: Coordinator

    func testQuickRefreshPressesCoalesce() async {
        let store = store()
        let provider = ScriptedProvider(.codex) { .success(makeSnapshot()) }
        provider.delay = 100_000_000
        let coordinator = UsageCoordinator(store: store, providers: [provider], now: { referenceDate })
        for _ in 0..<5 { coordinator.refresh([.codex], trigger: .manual) }
        await coordinator.waitUntilIdle()
        XCTAssertEqual(provider.fetches.count, 1)
        XCTAssertEqual(store.state(for: .codex).status, .fresh)
    }

    func testDisabledProviderIsNeverFetchedAndSwitchingOffDropsResult() async {
        let store = store()
        store.settings.enabled = [.claude]
        let codex = ScriptedProvider(.codex) { .success(makeSnapshot()) }
        let claude = ScriptedProvider(.claude) { .success(makeSnapshot(.claude)) }
        claude.delay = 100_000_000
        let coordinator = UsageCoordinator(store: store, providers: [codex, claude], now: { referenceDate })
        coordinator.refresh(trigger: .manual)
        XCTAssertTrue(codex.fetches.isEmpty)
        store.settings.enabled = []
        await coordinator.waitUntilIdle()
        XCTAssertNil(store.state(for: .claude).snapshot)
    }

    func testStopCancelsWorkAndDropsResults() async {
        let store = store()
        let provider = ScriptedProvider(.codex) { .success(makeSnapshot()) }
        provider.delay = 300_000_000
        let coordinator = UsageCoordinator(store: store, providers: [provider], now: { referenceDate })
        let tasks = coordinator.refresh([.codex], trigger: .manual)
        coordinator.stop()
        for task in tasks { await task.value }
        XCTAssertNil(store.state(for: .codex).snapshot)
        XCTAssertFalse(store.state(for: .codex).isRefreshing)
    }

    func testRetryAfterIsHonouredEvenForManualRefresh() async {
        let store = store()
        var clock = referenceDate
        let provider = ScriptedProvider(.codex) { .failure(ProviderFailure(.rateLimited(retryAfter: referenceDate.addingTimeInterval(600)), "Slow")) }
        let coordinator = UsageCoordinator(store: store, providers: [provider], now: { clock })
        coordinator.refresh([.codex], trigger: .manual)
        await coordinator.waitUntilIdle()
        coordinator.refresh([.codex], trigger: .manual)
        await coordinator.waitUntilIdle()
        XCTAssertEqual(provider.fetches.count, 1)
        clock = referenceDate.addingTimeInterval(601)
        coordinator.refresh([.codex], trigger: .manual)
        await coordinator.waitUntilIdle()
        XCTAssertEqual(provider.fetches.count, 2)
    }

    func testOnlyAnExplicitGrantMayPrompt() async {
        let store = store()
        var clock = referenceDate
        let provider = ScriptedProvider(.claude) { .failure(ProviderFailure(.needsKeychainAccess, "Allow")) }
        let coordinator = UsageCoordinator(store: store, providers: [provider], now: { clock })
        for trigger in [RefreshTrigger.activation, .manual, .settingsChanged, .timer, .pageOpened, .wake, .keychainGrant] {
            clock = clock.addingTimeInterval(7200)
            coordinator.refresh([.claude], trigger: trigger)
            await coordinator.waitUntilIdle()
        }
        XCTAssertEqual(provider.fetches.map(\.isInteractive), [false, false, false, false, false, false, true])
    }

    func testTimerWaitsForIntervalAndBacksOffAfterFailures() async {
        let store = store()
        var clock = referenceDate
        var fail = false
        let provider = ScriptedProvider(.codex) {
            fail ? .failure(ProviderFailure(.unavailable, "Offline", accountKey: "account-a")) : .success(makeSnapshot(at: clock))
        }
        let coordinator = UsageCoordinator(store: store, providers: [provider], now: { clock }, isLowPower: { false })
        coordinator.refresh([.codex], trigger: .activation)
        await coordinator.waitUntilIdle()

        clock = clock.addingTimeInterval(60)
        coordinator.refresh([.codex], trigger: .timer)
        coordinator.refresh([.codex], trigger: .pageOpened)
        await coordinator.waitUntilIdle()
        XCTAssertEqual(provider.fetches.count, 1, "Fresh reading: no timer or page-open fetch yet")

        fail = true
        clock = clock.addingTimeInterval(300)
        coordinator.refresh([.codex], trigger: .timer)
        await coordinator.waitUntilIdle()
        XCTAssertEqual(provider.fetches.count, 2)
        XCTAssertEqual(store.state(for: .codex).status, .stale)

        clock = clock.addingTimeInterval(300)
        coordinator.refresh([.codex], trigger: .timer)
        await coordinator.waitUntilIdle()
        XCTAssertEqual(provider.fetches.count, 3)

        clock = clock.addingTimeInterval(300)
        coordinator.refresh([.codex], trigger: .timer)
        await coordinator.waitUntilIdle()
        XCTAssertEqual(provider.fetches.count, 3, "Two failures in a row: the next try waits two intervals")
    }

    func testNotchShowsOnlyConnectedSubscriptionsAndFitsDetails() {
        let store = store()
        store.apply(makeSnapshot(.codex))
        XCTAssertEqual(store.connectedProviders, [.codex], "Only connected subscriptions reach the notch")
        let closed = AIUsagePage.height(for: store)
        var changes = 0
        store.onChange = { changes += 1 }
        store.selected = .codex
        XCTAssertEqual(changes, 1)
        XCTAssertNotEqual(AIUsagePage.height(for: store), closed, "The notch fits the open details")
        XCTAssertLessThanOrEqual(AIUsagePage.height(for: store), AIUsagePage.maxHeight)
        store.settings.enabled.remove(.codex)
        store.clear(.codex)
        XCTAssertNil(store.selected)
        XCTAssertLessThan(AIUsagePage.height(for: store), closed, "Nothing connected: just the empty state")
    }

    func testBadgeCountsProvidersNearTheirLimit() {
        let store = store()
        store.apply(makeSnapshot(.codex, percent: 95))
        store.apply(makeSnapshot(.claude, percent: 20))
        XCTAssertNil(store.badge, "Off by default")
        store.settings.badgesNearLimit = true
        XCTAssertEqual(store.badge, 1)
    }
}
