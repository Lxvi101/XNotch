import Foundation
import SwiftUI

/// What the user chose in Settings. Persisted in the extension's defaults; never holds credentials.
struct AIUsageSettings: Equatable, Sendable {
    var enabled: Set<AIProviderID> = Set(AIProviderID.allCases)
    var showsRemaining = false
    var refreshMinutes = 5
    var slowerOnLowPower = true
    var showsAccountLabels = false
    var showsExtras = true
    var claudeKeychainAccess = false
    var cursorSource: CursorSourcePreference = .automatic
    var badgesNearLimit = false

    static let refreshChoices = [1, 2, 5, 10, 15, 30, 60]

    func isEnabled(_ id: AIProviderID) -> Bool { enabled.contains(id) }

    fileprivate static func load(from defaults: UserDefaults) -> AIUsageSettings {
        var settings = AIUsageSettings()
        if let raw = defaults.array(forKey: Keys.enabled) as? [String] {
            settings.enabled = Set(raw.compactMap(AIProviderID.init(rawValue:)))
        }
        settings.showsRemaining = defaults.object(forKey: Keys.showsRemaining) as? Bool ?? settings.showsRemaining
        if let minutes = defaults.object(forKey: Keys.refreshMinutes) as? Int, refreshChoices.contains(minutes) {
            settings.refreshMinutes = minutes
        }
        settings.slowerOnLowPower = defaults.object(forKey: Keys.slowerOnLowPower) as? Bool ?? settings.slowerOnLowPower
        settings.showsAccountLabels = defaults.object(forKey: Keys.showsAccountLabels) as? Bool ?? settings.showsAccountLabels
        settings.showsExtras = defaults.object(forKey: Keys.showsExtras) as? Bool ?? settings.showsExtras
        settings.claudeKeychainAccess = defaults.object(forKey: Keys.claudeKeychainAccess) as? Bool ?? false
        settings.cursorSource = defaults.string(forKey: Keys.cursorSource).flatMap(CursorSourcePreference.init) ?? .automatic
        settings.badgesNearLimit = defaults.object(forKey: Keys.badgesNearLimit) as? Bool ?? settings.badgesNearLimit
        return settings
    }

    fileprivate func save(to defaults: UserDefaults) {
        defaults.set(AIProviderID.allCases.filter(enabled.contains).map(\.rawValue), forKey: Keys.enabled)
        defaults.set(showsRemaining, forKey: Keys.showsRemaining)
        defaults.set(refreshMinutes, forKey: Keys.refreshMinutes)
        defaults.set(slowerOnLowPower, forKey: Keys.slowerOnLowPower)
        defaults.set(showsAccountLabels, forKey: Keys.showsAccountLabels)
        defaults.set(showsExtras, forKey: Keys.showsExtras)
        defaults.set(claudeKeychainAccess, forKey: Keys.claudeKeychainAccess)
        defaults.set(cursorSource.rawValue, forKey: Keys.cursorSource)
        defaults.set(badgesNearLimit, forKey: Keys.badgesNearLimit)
    }

    enum Keys {
        static let enabled = "enabledProviders"
        static let showsRemaining = "showsRemaining"
        static let refreshMinutes = "refreshMinutes"
        static let slowerOnLowPower = "slowerOnLowPower"
        static let showsAccountLabels = "showsAccountLabels"
        static let showsExtras = "showsExtras"
        static let claudeKeychainAccess = "claudeKeychainAccess"
        static let cursorSource = "cursorSource"
        static let badgesNearLimit = "badgesNearLimit"
        static let snapshots = "snapshots.v1"
    }
}

/// A copy of the settings providers can read off the main actor.
final class SettingsMirror: @unchecked Sendable {
    private let lock = NSLock()
    private var current = AIUsageSettings()

    var value: AIUsageSettings {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

/// The page's and Settings' single source of truth: settings, per-provider state, and the last
/// good reading of each provider (restored on launch, marked stale until refreshed).
@MainActor
final class AIUsageStore: ObservableObject {
    @Published private(set) var states: [AIProviderID: ProviderState] = [:]
    @Published var settings = AIUsageSettings() {
        didSet {
            guard settings != oldValue else { return }
            mirror.value = settings
            if let defaults { settings.save(to: defaults) }
            onSettingsChange?(oldValue, settings)
            onChange?()
        }
    }
    /// The provider whose details are open under the tiles; survives the page closing.
    @Published var selected: AIProviderID? {
        didSet { if selected != oldValue { onChange?() } }
    }
    @Published private(set) var hasSavedCursorCookie = false
    /// True while XNotch waits for the user to finish signing in to Cursor in their browser.
    @Published var isSigningInToCursor = false

    let mirror = SettingsMirror()
    var onSettingsChange: ((AIUsageSettings, AIUsageSettings) -> Void)?
    /// Called after anything that can change the page's height or badge.
    var onChange: (() -> Void)?

    private var defaults: UserDefaults?

    func load(defaults: UserDefaults) {
        self.defaults = defaults
        let loaded = AIUsageSettings.load(from: defaults)
        let callback = onSettingsChange
        onSettingsChange = nil
        settings = loaded
        mirror.value = loaded
        onSettingsChange = callback
        var restored: [AIProviderID: ProviderState] = [:]
        if let data = defaults.data(forKey: AIUsageSettings.Keys.snapshots),
           let snapshots = try? JSONDecoder().decode([ProviderUsageSnapshot].self, from: data) {
            for snapshot in snapshots {
                restored[snapshot.provider] = ProviderState(status: .stale, snapshot: snapshot,
                                                            message: "Last reading, from before XNotch restarted.")
            }
        }
        states = restored
    }

    func state(for id: AIProviderID) -> ProviderState {
        states[id] ?? ProviderState()
    }

    var visibleProviders: [AIProviderID] {
        AIProviderID.allCases.filter(settings.isEnabled)
    }

    /// What the notch shows: switched-on subscriptions with a reading. Setting one up happens in Settings.
    var connectedProviders: [AIProviderID] {
        visibleProviders.filter { states[$0]?.snapshot != nil }
    }

    /// Whether a switched-on subscription is still being read for the first time.
    var isLoadingFirstReading: Bool {
        visibleProviders.contains { states[$0]?.snapshot == nil && states[$0]?.status == .loading }
    }

    func setSavedCursorCookie(_ saved: Bool) {
        if hasSavedCursorCookie != saved { hasSavedCursorCookie = saved }
    }

    // MARK: Updates

    func beginRefresh(_ id: AIProviderID, at date: Date) {
        var state = state(for: id)
        state.isRefreshing = true
        state.lastAttempt = date
        if state.snapshot == nil, state.status == .notConnected || state.status == .error || state.status == .unavailable {
            state.status = .loading
        }
        states[id] = state
    }

    func endRefresh(_ id: AIProviderID) {
        guard states[id]?.isRefreshing == true else { return }
        states[id]?.isRefreshing = false
        if states[id]?.status == .loading { states[id]?.status = states[id]?.snapshot == nil ? .notConnected : .stale }
    }

    func apply(_ snapshot: ProviderUsageSnapshot) {
        var state = state(for: snapshot.provider)
        // A different account replaces the old reading outright; nothing is merged across accounts.
        state.snapshot = snapshot
        state.status = .fresh
        state.message = nil
        state.isRefreshing = false
        update(snapshot.provider, to: state)
    }

    func apply(_ failure: ProviderFailure, for id: AIProviderID) {
        var state = state(for: id)
        state.isRefreshing = false
        state.message = failure.message
        // Keep the last reading only when it provably belongs to the same login, with its original timestamp.
        if let previous = state.snapshot, !Self.belongsToSameLogin(previous, failure) {
            state.snapshot = nil
        }
        let hasReading = state.snapshot != nil
        switch failure.kind {
        case .notConnected:
            state.snapshot = nil
            state.status = .notConnected
        case .needsKeychainAccess:
            state.status = .needsKeychainAccess
        case .unauthorized:
            state.status = .unauthorized
        case let .rateLimited(retryAfter):
            state.status = .rateLimited(until: retryAfter)
        case .unavailable:
            state.status = hasReading ? .stale : .unavailable
        case .invalidResponse:
            state.status = .error
        }
        update(id, to: state)
    }

    /// A disabled provider forgets its reading and is left alone.
    func clear(_ id: AIProviderID) {
        states[id] = nil
        if selected == id { selected = nil }
        persist()
        onChange?()
    }

    static func belongsToSameLogin(_ snapshot: ProviderUsageSnapshot, _ failure: ProviderFailure) -> Bool {
        if let key = failure.accountKey { return key == snapshot.accountKey }
        if let fingerprint = failure.credentialFingerprint { return fingerprint == snapshot.credentialFingerprint }
        return false
    }

    private func update(_ id: AIProviderID, to state: ProviderState) {
        states[id] = state
        persist()
        onChange?()
    }

    // MARK: Derived

    /// Providers with a core window at 90% or more, for the optional page badge.
    var nearLimitCount: Int {
        visibleProviders.filter { id in
            state(for: id).snapshot?.coreWindows.contains { ($0.displayUsed ?? 0) >= 90 } ?? false
        }.count
    }

    var badge: Int? {
        guard settings.badgesNearLimit else { return nil }
        let count = nearLimitCount
        return count > 0 ? count : nil
    }

    private func persist() {
        guard let defaults else { return }
        let snapshots = AIProviderID.allCases.compactMap { states[$0]?.snapshot?.cacheable }
        if let data = try? JSONEncoder().encode(snapshots) {
            defaults.set(data, forKey: AIUsageSettings.Keys.snapshots)
        }
    }
}
