import XCTest
@testable import AIUsage

/// Queries the real accounts signed in on this Mac, read-only, and prints a redacted summary: no
/// emails, account IDs or tokens. Skipped unless AIUSAGE_LIVE=1. Never prompts for Keychain access.
final class LiveProviderTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AIUSAGE_LIVE"] == "1", "Set AIUSAGE_LIVE=1 to query real accounts")
    }

    private let transport = URLSessionTransport(extraHosts: { CodexUsageProvider.configuredHost(CodexHome()).map { [$0] } ?? [] })

    func testClaude() async {
        let allowKeychain = ProcessInfo.processInfo.environment["AIUSAGE_LIVE_CLAUDE_KEYCHAIN"] == "1"
        await report(ClaudeUsageProvider(transport: transport, keychainAllowed: { allowKeychain }))
    }

    func testCursor() async {
        await report(CursorUsageProvider(transport: transport, secrets: SystemKeychain(), preference: { .automatic }))
    }

    func testCodex() async {
        await report(CodexUsageProvider(transport: transport))
    }

    private func report(_ provider: UsageProvider) async {
        let now = Date()
        do {
            let snapshot = try await provider.fetch(FetchContext(isInteractive: false, includeExtras: true, now: now))
            var lines = ["LIVE \(provider.id.rawValue): OK plan=\(snapshot.planLabel ?? "–") source=\(snapshot.source.rawValue)"]
            for window in snapshot.windows {
                let reset = window.resetsAt.map { "\(UsageFormat.countdown(to: $0, from: now)) (\(UsageFormat.fullResetTime($0)))" } ?? "none"
                lines.append("  \(window.isCore ? "core " : "extra") \(window.label): \(UsageFormat.percent(window.percentUsed)) "
                    + "reset=\(reset) window=\(window.windowSeconds.map { "\(Int($0))s" } ?? "–") \(window.detail ?? "")")
            }
            if let credits = snapshot.credits {
                lines.append("  credits balance=\(credits.balance.map { "\($0)" } ?? "–") unlimited=\(credits.isUnlimited) "
                    + "savedResets=\(credits.savedResets.map(String.init) ?? "–")")
            }
            for line in snapshot.spending?.lines ?? [] {
                lines.append("  spend \(line.label): \(Money.format(line.used, line.currencyCode)) of "
                    + "\(line.limit.map { Money.format($0, line.currencyCode) } ?? "no limit")")
            }
            print(lines.joined(separator: "\n"))
        } catch {
            let failure = ProviderFailure.from(error, provider: provider.id)
            print("LIVE \(provider.id.rawValue): \(failure.kind) — \(failure.message)")
        }
    }
}
