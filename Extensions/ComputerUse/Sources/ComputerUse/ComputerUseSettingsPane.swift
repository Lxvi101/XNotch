import SwiftUI

struct ComputerUseSettingsPane: View {
    @ObservedObject var sessions: AgentSessions
    @ObservedObject var preferences: ComputerUsePreferences
    @ObservedObject var installer: WinkInstaller

    var body: some View {
        Form {
            server
            apps
            eyes
            now
        }
        .formStyle(.grouped)
        .task { await installer.refresh() }
    }

    private var server: some View {
        Section {
            LabeledContent {
                if installer.isWorking {
                    ProgressView().controlSize(.small)
                } else if installer.isInstalled {
                    Button("Remove", role: .destructive) { Task { await installer.uninstall() } }
                } else {
                    Button("Install") { Task { await installer.install() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(installer.bundled == nil)
                }
            } label: {
                Text("Wink Computer Use")
                Text(installer.isInstalled ? "Installed, and added to the apps switched on below."
                     : "Lets AI agents use your Mac's apps in the background, with their own cursor.")
            }
            if let error = installer.error {
                Text(error).foregroundStyle(.red)
            }
        } footer: {
            Text("Install adds it to every app below that's on this Mac. Remove takes it out of them all again. Allow Accessibility and Screen Recording for each app when macOS asks: the agent works through it.")
                .foregroundStyle(.secondary)
        }
    }

    private var apps: some View {
        Section("Apps") {
            if !installer.hasRefreshed {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            } else {
                ForEach(installer.clients) { client in
                    ClientRow(client: client, state: installer.states[client.id] ?? .init(),
                              isBusy: installer.busy.contains(client.id)) { on in
                        Task { await installer.setConfigured(on, for: client) }
                    }
                }
            }
        }
    }

    private var eyes: some View {
        Section {
            Toggle(isOn: $preferences.followsCursor) {
                Text("Follow the agent's cursor")
                Text("Off, the eyes still open while an agent works, but keep watching your pointer.")
            }
        } header: {
            Text("Eyes")
        } footer: {
            Text("While an agent drives your Mac, the notch's eyes open under it and keep roughly to the agent's cursor. They close a moment after it's done.")
                .foregroundStyle(.secondary)
        }
    }

    private var now: some View {
        Section("Now") {
            if sessions.sessions.isEmpty {
                Text("No agent is using the computer.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sessions.sessions.values.sorted { $0.started < $1.started }) { session in
                    LabeledContent(session.clientName ?? "An agent") {
                        Text(session.app.map { "Using \($0)" } ?? "Starting")
                    }
                }
            }
        }
    }
}

private struct ClientRow: View {
    let client: MCPClient
    let state: WinkInstaller.ClientState
    let isBusy: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(client.name)
                    .foregroundStyle(state.isInstalled ? .primary : .secondary)
                Spacer()
                if isBusy {
                    ProgressView().controlSize(.small)
                } else if state.isInstalled {
                    Toggle("", isOn: Binding(get: { state.isConfigured }, set: onChange))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                } else {
                    Text("Not on this Mac").foregroundStyle(.tertiary)
                }
            }
            if let error = state.error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
            }
        }
    }
}
