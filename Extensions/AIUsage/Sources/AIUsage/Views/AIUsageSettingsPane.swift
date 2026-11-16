import SwiftUI

/// Where subscriptions are chosen and connected. The notch only ever shows their numbers.
struct AIUsageSettingsPane: View {
    @ObservedObject var store: AIUsageStore
    let `extension`: AIUsageExtension

    var body: some View {
        Form {
            Section("Subscriptions") {
                ForEach(AIProviderID.allCases) { id in
                    SubscriptionRow(provider: id, store: store, extension: `extension`)
                }
            }

            Section("Display") {
                Picker("Show", selection: $store.settings.showsRemaining) {
                    Text("Percent used").tag(false)
                    Text("Percent remaining").tag(true)
                }
                Toggle("Today's share of weekly limits", isOn: $store.settings.showsTodayPace)
                Toggle("Model limits, credits and spend", isOn: $store.settings.showsExtras)
                Toggle("Account emails", isOn: $store.settings.showsAccountLabels)
                Toggle("Badge when a limit is 90% used", isOn: $store.settings.badgesNearLimit)
            }

            Section("Refresh") {
                Picker("Every", selection: $store.settings.refreshMinutes) {
                    ForEach(AIUsageSettings.refreshChoices, id: \.self) { minutes in
                        Text(minutes == 60 ? "hour" : minutes == 1 ? "minute" : "\(minutes) minutes").tag(minutes)
                    }
                }
                Toggle("Half as often in Low Power Mode", isOn: $store.settings.slowerOnLowPower)
                Button("Refresh Now") { `extension`.refresh() }
            }
        }
        .formStyle(.grouped)
        .onAppear { `extension`.checkProxies() }
    }
}

private struct SubscriptionRow: View {
    let provider: AIProviderID
    @ObservedObject var store: AIUsageStore
    let `extension`: AIUsageExtension

    @State private var connectingTo: HubAddress?

    private var state: ProviderState { store.state(for: provider) }
    private var isOn: Bool { store.settings.isEnabled(provider) }

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill((Color(hex: provider.tintHex) ?? .gray).gradient)
                .frame(width: 26, height: 26)
                .overlay {
                    Image(systemName: provider.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Toggle(provider.displayName, isOn: Binding {
                isOn
            } set: { on in
                if on { store.settings.enabled.insert(provider) } else { store.settings.enabled.remove(provider) }
            })
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .help(state.message ?? "")
        .sheet(item: $connectingTo) { address in
            HubConnectSheet(address: address.text, extension: `extension`)
        }
        if isOn, let setup = hubSetup ?? setup {
            setup
        }
    }

    /// For a Claude Code or Codex that goes through a proxy: how XNotch reads it, or what it takes.
    private var hubSetup: AnyView? {
        switch store.proxyRoutes[provider] {
        case let .connected(host, removable):
            return AnyView(LabeledContent {
                if removable { Button("Disconnect") { `extension`.disconnectHub() } }
            } label: {
                caption("Through your CLIProxyAPI hub at \(host)."
                    + (removable ? "" : " Its key comes from \(CLIProxyHubLocator.keysFileDisplayPath)."))
            })
        case let .cliProxy(origin, managementEnabled: true):
            return AnyView(LabeledContent {
                Button("Connect…") { connectingTo = HubAddress(text: origin.absoluteString) }
            } label: {
                caption("Goes through a CLIProxyAPI hub at \(origin.host ?? "?"). Connect it to see the limits of its logins.")
            })
        case let .cliProxy(origin, managementEnabled: false):
            return AnyView(LabeledContent {
                Button("Check Again") { `extension`.checkProxies() }
            } label: {
                caption("Goes through a CLIProxyAPI hub at \(origin.host ?? "?") with remote management off. "
                    + CLIProxyHub.managementHint(host: origin.host ?? ""))
            })
        case let .otherProxy(host):
            return AnyView(LabeledContent {
                EmptyView()
            } label: {
                caption("Goes through a proxy at \(host), which can't report subscription limits.")
            })
        case let .unreachable(origin):
            return AnyView(LabeledContent {
                HStack {
                    Button("Connect…") { connectingTo = HubAddress(text: origin.absoluteString) }
                    Button("Check Again") { `extension`.checkProxies() }
                }
            } label: {
                caption("Goes through \(origin.host ?? "?"), which didn't answer.")
            })
        case .direct, nil:
            return nil
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private var status: String {
        guard isOn else { return "Off" }
        if state.isRefreshing, state.snapshot == nil { return "Checking…" }
        switch state.status {
        case .fresh, .stale:
            let parts = [state.snapshot?.planLabel,
                         state.snapshot.map { "updated \(UsageFormat.age(of: $0.refreshedAt, now: Date()))" },
                         state.status == .stale ? "offline" : nil].compactMap { $0 }
            return parts.joined(separator: " · ")
        case .loading: return "Checking…"
        case .notConnected: return "Not signed in"
        case .needsKeychainAccess: return "Needs Keychain access"
        case .unauthorized: return "Sign in again"
        case .rateLimited: return "Rate limited, retrying later"
        case .unavailable: return "Offline"
        case .error: return state.message ?? "Error"
        }
    }

    /// What it takes to connect this subscription, when it isn't.
    private var setup: AnyView? {
        switch provider {
        case .claude:
            if state.status == .needsKeychainAccess {
                return AnyView(LabeledContent {
                    Button("Allow Access…") { `extension`.allowKeychainAccess(for: .claude) }
                } label: {
                    Text("Claude Code keeps its login in your Keychain. Choose Always Allow.")
                        .font(.caption).foregroundStyle(.secondary)
                })
            }
            if state.status == .notConnected || state.status == .unauthorized {
                return AnyView(instruction("Run `claude` in Terminal and sign in."))
            }
        case .cursor:
            if store.isSigningInToCursor {
                return AnyView(LabeledContent {
                    HStack {
                        Button("Open Again") { `extension`.signInToCursor() }
                        Button("Cancel") { `extension`.cancelCursorSignIn() }
                    }
                } label: {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Finish signing in in your browser.").font(.caption).foregroundStyle(.secondary)
                    }
                })
            }
            if store.hasSavedCursorCookie {
                return AnyView(LabeledContent {
                    Button("Sign Out") { `extension`.removeCursorCookie() }
                } label: {
                    Text("Signed in from XNotch").font(.caption).foregroundStyle(.secondary)
                })
            }
            if state.status == .notConnected || state.status == .unauthorized || state.status == .needsKeychainAccess {
                return AnyView(LabeledContent {
                    Button("Sign In…") { `extension`.signInToCursor() }
                } label: {
                    Text("Or sign in to the Cursor app.").font(.caption).foregroundStyle(.secondary)
                })
            }
        case .codex:
            if state.status == .notConnected || state.status == .unauthorized {
                return AnyView(instruction("Run `codex login` in Terminal and choose ChatGPT."))
            }
        }
        return nil
    }

    private func instruction(_ text: LocalizedStringKey) -> some View {
        LabeledContent {
            Button("Refresh") { `extension`.refresh(provider) }
        } label: {
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct HubAddress: Identifiable {
    var text: String
    var id: String { text }
}

/// Asks for the one thing XNotch can't find itself: the hub's management key. The address comes from
/// Claude Code's or Codex's own settings.
private struct HubConnectSheet: View {
    let `extension`: AIUsageExtension
    @Environment(\.dismiss) private var dismiss
    @State private var address: String
    @State private var key = ""
    @State private var isConnecting = false
    @State private var problem: String?
    @State private var connected: String?

    init(address: String, extension: AIUsageExtension) {
        self.extension = `extension`
        _address = State(initialValue: address)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect CLIProxyAPI Hub").font(.headline)
                Text("XNotch reads the limits of the hub's Claude and Codex logins. The logins stay on the hub.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Form {
                TextField("Address", text: $address, prompt: Text("https://my-mac.ts.net:8317"))
                SecureField("Management key", text: $key, prompt: Text("remote-management.secret-key"))
                    .onSubmit(connect)
            }
            .disabled(isConnecting || connected != nil)
            Text("The management key controls the whole hub. XNotch only reads limits with it, and keeps it in your Keychain.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let connected {
                Label(connected, systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if isConnecting { ProgressView().controlSize(.small) }
                Spacer()
                if connected != nil {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Connect", action: connect)
                        .keyboardShortcut(.defaultAction)
                        .disabled(isConnecting || key.trimmingCharacters(in: .whitespaces).isEmpty || address.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func connect() {
        guard !isConnecting, !key.isEmpty else { return }
        isConnecting = true
        problem = nil
        Task { @MainActor in
            switch await `extension`.connectHub(address: address, key: key) {
            case let .success(summary): connected = summary
            case let .failure(failure): problem = failure.message
            }
            isConnecting = false
        }
    }
}
