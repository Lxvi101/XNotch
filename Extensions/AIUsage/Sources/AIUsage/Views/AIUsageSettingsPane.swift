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
    }
}

private struct SubscriptionRow: View {
    let provider: AIProviderID
    @ObservedObject var store: AIUsageStore
    let `extension`: AIUsageExtension

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
        if isOn, let setup {
            setup
        }
    }

    private var status: String {
        guard isOn else { return "Off" }
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
