import AppKit
import SwiftUI
import XNotchKit

@objc(AIUsagePrincipal)
public final class AIUsagePrincipal: NSObject, XNotchExtensionPrincipal {
    public override init() { super.init() }

    @MainActor public func makeExtension() -> AnyObject { AIUsageExtension() }
}

@MainActor
final class AIUsageExtension: XNotchExtension {
    static let id: ExtensionID = "ai-usage"
    static let pageID = "usage"

    let store = AIUsageStore()
    private let keychain = SystemKeychain()
    private let hubs = CLIProxyHubLocator(secrets: SystemKeychain())
    /// Asks proxies what they are, without any key.
    private lazy var probeTransport = URLSessionTransport(extraHosts: { [hubs] in hubs.routedHosts })
    private var proxyCheck: Task<Void, Never>?
    private var coordinator: UsageCoordinator?
    private var host: ExtensionHost?
    private var transport: HTTPTransport?
    private var cursorSignIn: (login: CursorBrowserLogin, task: Task<Void, Never>)?
    /// The descriptor XNotch last read, so it's only told about real changes.
    private var lastPage: NotchPageDescriptor?

    func activate(host: ExtensionHost) throws {
        self.host = host
        store.load(defaults: host.storage.defaults)
        store.setSavedCursorCookie(keychain.exists(CursorUsageProvider.manualCookieName))

        let codexHome = hubs.codexHome
        let hubs = hubs
        let transport = URLSessionTransport(extraHosts: {
            // The CLIProxyAPI hub the user set up gets the management key; nothing else does.
            hubs.hosts.union(CodexUsageProvider.configuredHost(codexHome).map { [$0] } ?? [])
        })
        self.transport = transport
        let mirror = store.mirror
        let keychain = keychain
        let coordinator = UsageCoordinator(store: store, providers: [
            ClaudeUsageProvider(transport: transport, keychainAllowed: { mirror.value.claudeKeychainAccess }, hubs: hubs),
            CursorUsageProvider(transport: transport, secrets: keychain, preference: { mirror.value.cursorSource }),
            CodexUsageProvider(transport: transport, codexHome: codexHome, hubs: hubs),
        ], log: host.log)
        self.coordinator = coordinator

        store.onSettingsChange = { [weak self] old, new in self?.settingsChanged(from: old, to: new) }
        store.onChange = { [weak self] in self?.pageMayHaveChanged() }
        coordinator.start()
        checkProxies()
        host.log.info("AI Usage activated")
    }

    func deactivate() {
        cancelCursorSignIn()
        proxyCheck?.cancel()
        proxyCheck = nil
        transport = nil
        coordinator?.stop()
        coordinator = nil
        store.onSettingsChange = nil
        store.onChange = nil
        lastPage = nil
        host = nil
    }

    // MARK: Actions

    func refresh(_ id: AIProviderID? = nil) {
        host?.feedback.tick()
        checkProxies()
        coordinator?.refresh(id.map { [$0] }, trigger: .manual)
    }

    func pageBecameActive() {
        coordinator?.refresh(trigger: .pageOpened)
    }

    /// The user asked for it: the only path that may show a macOS Keychain prompt.
    func allowKeychainAccess(for id: AIProviderID) {
        if id == .claude, !store.settings.claudeKeychainAccess {
            store.settings.claudeKeychainAccess = true
        }
        coordinator?.refresh([id], trigger: .keychainGrant)
    }

    func saveCursorCookie(_ raw: String) -> Bool {
        // Accept a bare token value or a full header; keep only the header, never in defaults.
        var cookie = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cookie.lowercased().hasPrefix("cookie:") { cookie = String(cookie.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        if !cookie.contains("=") { cookie = "WorkosCursorSessionToken=\(cookie)" }
        guard !cookie.isEmpty, keychain.write(CursorUsageProvider.manualCookieName, value: Data(cookie.utf8)) == errSecSuccess else {
            return false
        }
        store.setSavedCursorCookie(true)
        coordinator?.refresh([.cursor], trigger: .manual)
        return true
    }

    /// Opens Cursor's login in the user's own browser and waits for them to finish there; only the
    /// resulting session is kept, in the Keychain. Clicking again reopens the same link.
    func signInToCursor() {
        if let pending = cursorSignIn {
            open(pending.login.loginURL)
            return
        }
        guard let transport else { return }
        let login = CursorBrowserLogin()
        let task = Task { [weak self] in
            let deadline = Date().addingTimeInterval(CursorBrowserLogin.timeout)
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(nanoseconds: CursorBrowserLogin.pollInterval)
                guard !Task.isCancelled else { return }
                // Network hiccups while waiting are retried; only a finished sign-in ends the wait.
                if let session = try? await login.poll(transport), let cookie = session.cookieHeader {
                    self?.finishCursorSignIn(cookie)
                    return
                }
            }
            self?.cancelCursorSignIn()
        }
        cursorSignIn = (login, task)
        store.isSigningInToCursor = true
        open(login.loginURL)
    }

    func cancelCursorSignIn() {
        cursorSignIn?.task.cancel()
        cursorSignIn = nil
        store.isSigningInToCursor = false
    }

    private func finishCursorSignIn(_ cookie: String) {
        cursorSignIn = nil
        store.isSigningInToCursor = false
        if !store.settings.isEnabled(.cursor) { store.settings.enabled.insert(.cursor) }
        _ = saveCursorCookie(cookie)
        host?.feedback.tick()
    }

    func removeCursorCookie() {
        _ = keychain.delete(CursorUsageProvider.manualCookieName)
        store.setSavedCursorCookie(false)
        coordinator?.refresh([.cursor], trigger: .settingsChanged)
    }

    // MARK: CLIProxyAPI hub

    /// Works out what Claude Code and Codex go through: on activation, when Settings opens, after a change.
    func checkProxies() {
        proxyCheck?.cancel()
        let hubs = hubs
        let transport = probeTransport
        var pending: [(AIProviderID, URL)] = []
        var switched: [AIProviderID] = []
        for id in [AIProviderID.claude, .codex] {
            let wasConnected = store.proxyRoutes[id].map(Self.isConnected)
            let known = hubs.knownRoute(for: id)
            // A hub key added or removed outside the Connect sheet changes where limits come from.
            if let wasConnected, wasConnected != known.map(Self.isConnected) ?? false { switched.append(id) }
            if let known {
                store.setProxyRoute(known, for: id)
            } else if let origin = hubs.routedOrigin(for: id) {
                pending.append((id, origin))
            }
        }
        if !switched.isEmpty { coordinator?.refresh(switched, trigger: .settingsChanged) }
        guard !pending.isEmpty else { return }
        proxyCheck = Task { [weak self] in
            // Both tools usually share one hub: ask each address once.
            var routes: [URL: ProxyRoute] = [:]
            for (id, origin) in pending {
                if routes[origin] == nil { routes[origin] = await CLIProxyProbe.probe(origin, transport: transport) }
                guard !Task.isCancelled else { return }
                self?.store.setProxyRoute(routes[origin], for: id)
            }
        }
    }

    private static func isConnected(_ route: ProxyRoute) -> Bool {
        if case .connected = route { return true }
        return false
    }

    /// Checks the key against the hub before keeping it. Returns what it found, or why it couldn't connect.
    func connectHub(address: String, key: String) async -> Result<String, ProviderFailure> {
        guard let origin = CLIProxyHubLocator.origin(address) else {
            return .failure(ProviderFailure(.invalidResponse, "Enter the hub's address, like https://my-mac.ts.net:8317. "
                + "Plain http:// only works for a hub on this Mac."))
        }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let hub = CLIProxyHub(baseURL: origin, managementKey: key)
        let transport = URLSessionTransport(extraHosts: { [hub.host] })
        let inventory: [AIProviderID: Int]
        do {
            inventory = try await hub.inventory(transport: transport)
        } catch {
            return .failure(ProviderFailure.from(error, provider: .codex))
        }
        guard hubs.save(hub) else {
            return .failure(ProviderFailure(.unavailable, "Couldn't save the key in your Keychain."))
        }
        let served = [AIProviderID.claude, .codex].filter { hubs.hub(for: $0) != nil }
        for id in served where (inventory[id] ?? 0) > 0 && !store.settings.isEnabled(id) {
            store.settings.enabled.insert(id)
        }
        checkProxies()
        coordinator?.refresh(served, trigger: .manual)
        host?.feedback.tick()

        let found = [AIProviderID.codex, .claude].compactMap { id -> String? in
            guard let count = inventory[id], count > 0 else { return nil }
            return "\(count) \(id == .codex ? "Codex" : "Claude") login\(count == 1 ? "" : "s")"
        }
        var summary = found.isEmpty ? "Connected, but the hub has no Claude or Codex logins yet."
            : "Connected. Found \(found.joined(separator: " and "))."
        if served.isEmpty { summary += " Neither Claude Code nor Codex sends its requests to this hub, though." }
        return .success(summary)
    }

    func disconnectHub() {
        hubs.forget()
        checkProxies()
        coordinator?.refresh([.claude, .codex], trigger: .manual)
    }

    func open(_ url: URL) {
        host?.workspace.open(url)
    }

    private func settingsChanged(from old: AIUsageSettings, to new: AIUsageSettings) {
        for id in AIProviderID.allCases where old.isEnabled(id) != new.isEnabled(id) {
            if new.isEnabled(id) {
                coordinator?.refresh([id], trigger: .settingsChanged)
            } else {
                coordinator?.cancel(id)
                store.clear(id)
            }
        }
        if old.showsExtras != new.showsExtras { coordinator?.refresh(trigger: .settingsChanged) }
        if old.claudeKeychainAccess != new.claudeKeychainAccess { coordinator?.refresh([.claude], trigger: .settingsChanged) }
        if old.cursorSource != new.cursorSource { coordinator?.refresh([.cursor], trigger: .settingsChanged) }
    }

    /// The page grows when a provider's details open; XNotch reshapes the notch to match.
    private func pageMayHaveChanged() {
        guard let page = pages.first, page != lastPage else { return }
        lastPage = page
        host?.notch.pagesDidChange()
    }
}

extension AIUsageExtension: NotchPageProviding {
    var pages: [NotchPageDescriptor] {
        [NotchPageDescriptor(id: Self.pageID, title: "AI Usage", symbol: "chart.bar.fill",
                             contentHeight: AIUsagePage.height(for: store), badge: store.badge)]
    }

    func makePageView(for page: NotchPageDescriptor, context: NotchPageContext) -> AnyView {
        AnyView(AIUsagePage(store: store, extension: self, size: context.size, isActive: context.isActive))
    }
}

extension AIUsageExtension: SettingsPaneProviding {
    func makeSettingsPane() -> AnyView {
        AnyView(AIUsageSettingsPane(store: store, extension: self))
    }
}

extension AIUsageExtension: PermissionRequesting {
    static let claudeKeychainPermission = "claude-keychain"

    private var claudeLocator: ClaudeCredentialLocator { ClaudeCredentialLocator(keychain: keychain) }

    var pendingPermissions: [ExtensionPermission] {
        guard store.settings.isEnabled(.claude), hubs.hub(for: .claude) == nil,
              claudeLocator.needsKeychainAccess(consented: store.settings.claudeKeychainAccess) else { return [] }
        return [ExtensionPermission(
            id: Self.claudeKeychainPermission, title: "Claude Code limits", detail: "Keychain",
            reason: "I read Claude Code's login from your Keychain to show its limits, and only send it to Anthropic. "
                + "macOS asks once: choose Always Allow.",
            symbol: AIProviderID.claude.symbol, tint: AIProviderID.claude.tintHex)]
    }

    func requestPermission(_ id: String) async -> Bool {
        guard id == Self.claudeKeychainPermission, let coordinator else { return false }
        store.settings.claudeKeychainAccess = true
        for task in coordinator.refresh([.claude], trigger: .keychainGrant) { await task.value }
        // "Allow" lets this one read through; only "Always Allow" lets later refreshes read without asking.
        return !claudeLocator.needsKeychainAccess(consented: true)
    }
}
