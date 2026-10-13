import CryptoKit
import Foundation

enum AIProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, cursor, codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .cursor: "Cursor"
        case .codex: "Codex"
        }
    }

    var symbol: String {
        switch self {
        case .claude: "sparkle"
        case .cursor: "cursorarrow.rays"
        case .codex: "chevron.left.forwardslash.chevron.right"
        }
    }

    var tintHex: String {
        switch self {
        case .claude: "#D97757"
        case .cursor: "#A9B4C2"
        case .codex: "#10A37F"
        }
    }

    /// How to sign in with the provider's own app; XNotch never logs in for you.
    var signInHint: String {
        switch self {
        case .claude: "Sign in with Claude Code: run `claude` in Terminal and choose your Claude subscription."
        case .cursor: "Sign in to the Cursor app, or sign in from Settings → AI Usage."
        case .codex: "Sign in with the Codex CLI: run `codex login` and choose ChatGPT."
        }
    }

    var helpURL: URL {
        switch self {
        case .claude: URL(string: "https://docs.anthropic.com/en/docs/claude-code/setup")!
        case .cursor: URL(string: "https://cursor.com/dashboard")!
        case .codex: URL(string: "https://developers.openai.com/codex/cli")!
        }
    }
}

/// One quota lane: a rolling session, a weekly cap, a monthly plan, a model-specific limit.
struct QuotaWindow: Codable, Identifiable, Equatable, Sendable {
    /// Stable per provider, account, model and period.
    var id: String
    /// "Session", "Weekly", "Sonnet only", "Included plan"…
    var label: String
    /// 0…100 as reported. Nil is unknown: never invent 0 or 100.
    var percentUsed: Double?
    /// Nil when the service doesn't report a recurring reset.
    var resetsAt: Date?
    var windowSeconds: TimeInterval?
    /// Extra context, e.g. "142 / 500 requests".
    var detail: String?
    /// Core windows are always shown; the rest live behind the detail expander.
    var isCore: Bool = true
    /// A shorter label for the narrow tiles, when `label` won't fit.
    var shortLabel: String?

    /// The reported value, clamped for drawing. Nil when unknown or not finite.
    var displayUsed: Double? {
        guard let percentUsed, percentUsed.isFinite else { return nil }
        return min(100, max(0, percentUsed))
    }

    var percentRemaining: Double? {
        guard let percentUsed, percentUsed.isFinite else { return nil }
        return 100 - percentUsed
    }

    var displayRemaining: Double? {
        percentRemaining.map { min(100, max(0, $0)) }
    }
}

/// Prepaid balances and saved resets. A saved reset is a redeemable credit, not a quota's reset date.
struct CreditSummary: Codable, Equatable, Sendable {
    /// Monetary or credit balance, with its unit spelled out ("credits", "USD").
    var balance: Double?
    var balanceUnit: String?
    var isUnlimited: Bool = false
    /// Saved, redeemable limit resets. Display only; XNotch never redeems them.
    var savedResets: Int?
    var savedResetsNextExpiry: Date?

    var isEmpty: Bool { balance == nil && !isUnlimited && (savedResets ?? 0) == 0 }
}

/// Money spent against a budget, already converted from cents where the provider uses cents.
struct SpendLine: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var label: String
    var used: Double
    var limit: Double?
    var currencyCode: String
    var resetsAt: Date?
}

struct SpendingSummary: Codable, Equatable, Sendable {
    var lines: [SpendLine]
}

/// Where a reading's credential came from.
enum CredentialSource: String, Codable, Sendable {
    case claudeCredentialsFile
    case claudeKeychain
    case cursorDesktop
    case cursorManualCookie
    case codexAuthFile

    var label: String {
        switch self {
        case .claudeCredentialsFile: "Claude Code credentials file"
        case .claudeKeychain: "Claude Code Keychain login"
        case .cursorDesktop: "Cursor app session"
        case .cursorManualCookie: "Saved cursor.com cookie"
        case .codexAuthFile: "Codex auth.json"
        }
    }
}

struct ProviderUsageSnapshot: Codable, Equatable, Sendable {
    var provider: AIProviderID
    /// Stable, nonsecret, hashed account identifier. Readings never cross accounts.
    var accountKey: String
    /// One-way hash of the credential that produced this reading, to recognise the same login offline.
    var credentialFingerprint: String?
    var planLabel: String?
    /// Email or name. Shown only when the user allows it, and never cached.
    var accountLabel: String?
    var windows: [QuotaWindow]
    var refreshedAt: Date
    var credits: CreditSummary?
    var spending: SpendingSummary?
    var source: CredentialSource

    var coreWindows: [QuotaWindow] { windows.filter(\.isCore) }
    var extraWindows: [QuotaWindow] { windows.filter { !$0.isCore } }

    /// The copy that may be written to defaults: no personal identifiers.
    var cacheable: ProviderUsageSnapshot {
        var copy = self
        copy.accountLabel = nil
        return copy
    }
}

enum ProviderStatus: Equatable, Sendable {
    case notConnected
    case loading
    case fresh
    case stale
    case unauthorized
    case rateLimited(until: Date?)
    case unavailable
    case error
    /// Credentials live in a Keychain item XNotch may not read without asking. Only a click asks.
    case needsKeychainAccess
}

struct ProviderState: Equatable, Sendable {
    var status: ProviderStatus = .notConnected
    var snapshot: ProviderUsageSnapshot?
    /// User-facing explanation for anything but `.fresh`. Never contains secrets.
    var message: String?
    var isRefreshing = false
    var lastAttempt: Date?
}

enum Hashing {
    /// A short, one-way, domain-separated identifier. Safe to persist and log.
    static func key(_ parts: String...) -> String {
        let material = Data(("xnotch.ai-usage.v1\0" + parts.joined(separator: "\0")).utf8)
        return SHA256.hash(data: material).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
