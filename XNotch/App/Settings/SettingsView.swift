import AppKit
import XNotchKit
import SwiftUI

enum SettingsPane: Hashable {
    case general, music, lockScreen, shelf, extensions, changelog, about
    case extensionPane(ExtensionID)
}

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var selection: SettingsPane = .general
}

struct SettingsView: View {
    @ObservedObject var navigation: SettingsNavigation
    @ObservedObject var preferences: Preferences
    @ObservedObject var extensions: ExtensionManager
    @ObservedObject var updater: SoftwareUpdater
    let shelf: ShelfStore
    let media: NowPlayingService
    let onPreviewLockScreen: () -> Void
    let onReplayOnboarding: () -> Void

    var body: some View {
        NavigationSplitView {
            List(selection: $navigation.selection) {
                Section {
                    row(.general, "General", "gearshape.fill", .gray)
                    row(.music, "Music", "music.note", .pink)
                    row(.lockScreen, "Lock Screen", "lock.fill", .indigo)
                    row(.shelf, "Shelf", "tray.full.fill", .green)
                }
                Section("Extensions") {
                    row(.extensions, "All Extensions", "puzzlepiece.extension.fill", .purple)
                    ForEach(extensions.entries.filter { $0.isActive && extensions.settingsPane(for: $0.id) != nil }) { entry in
                        row(.extensionPane(entry.id), entry.manifest.name, entry.manifest.symbol,
                            entry.manifest.tint.flatMap(Color.init(hex:)) ?? .blue)
                    }
                }
                Section {
                    row(.changelog, "What's New", "sparkles", .orange)
                    row(.about, "About XNotch", "info.circle.fill", .blue)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 210, max: 240)
        } detail: {
            detail
                .frame(minWidth: 460, minHeight: 440)
        }
        .frame(minWidth: 680, minHeight: 460)
    }

    private func row(_ pane: SettingsPane, _ title: String, _ symbol: String, _ color: Color) -> some View {
        Label {
            Text(title)
        } icon: {
            SettingsIcon(symbol: symbol, color: color)
        }
        .tag(pane)
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.selection {
        case .general:
            GeneralPane(preferences: preferences, permissions: .shared, onReplayOnboarding: onReplayOnboarding)
                .navigationTitle("General")
        case .music:
            MusicPane(preferences: preferences, media: media).navigationTitle("Music")
        case .lockScreen:
            LockScreenPane(preferences: preferences, media: media, onPreview: onPreviewLockScreen)
                .navigationTitle("Lock Screen")
        case .shelf:
            ShelfPane(shelf: shelf).navigationTitle("Shelf")
        case .extensions:
            ExtensionsPane(extensions: extensions, navigation: navigation).navigationTitle("Extensions")
        case .extensionPane(let id):
            if let entry = extensions.entries.first(where: { $0.id == id }), let pane = extensions.settingsPane(for: id) {
                pane.navigationTitle(entry.manifest.name)
            } else {
                ContentUnavailableView("Extension unavailable", systemImage: "puzzlepiece.extension")
            }
        case .changelog:
            ChangelogPane().navigationTitle("What's New")
        case .about:
            AboutPane(updater: updater).navigationTitle("About")
        }
    }
}

/// System Settings' coloured rounded-square icon.
struct SettingsIcon: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}

// MARK: Panes

private struct GeneralPane: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var permissions: PermissionCenter
    let onReplayOnboarding: () -> Void

    var body: some View {
        Form {
            Section {
                Toggle("Open XNotch at login", isOn: Binding(
                    get: { preferences.launchesAtLogin },
                    set: { preferences.setLaunchesAtLogin($0) }
                ))
                Toggle("Haptic feedback", isOn: $preferences.hapticsEnabled)
            }
            Section {
                Toggle(isOn: $preferences.showsDestinationPills) {
                    Text("Show destinations on hover")
                    Text("Pills under the notch name where a click will take you. Click one to go straight there.")
                }
                Picker("Pills show", selection: $preferences.pillsIconOnly) {
                    Text("Icon and name").tag(false)
                    Text("Icon only").tag(true)
                }
                .disabled(!preferences.showsDestinationPills)
            } header: {
                Text("Notch")
            }
            Section {
                ForEach(Permission.requested) { permission in
                    PermissionRow(permission: permission, isGranted: permissions.isGranted(permission),
                                  isRequesting: permissions.activeRequest == permission) {
                        permissions.request(permission)
                    }
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("XNotch opens the right place in System Settings and shows you what to drag where.")
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Settings", value: "⌘ ,")
                LabeledContent("Close the notch", value: "esc")
                LabeledContent("Shelf: Quick Look, delete", value: "space, ⌫")
            } header: {
                Text("Keyboard")
            } footer: {
                Text("Shortcuts work when you've opened the notch with a click, or clicked into it.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Show Welcome Tour", action: onReplayOnboarding)
                Button("Quit XNotch", role: .destructive) { NSApp.terminate(nil) }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionRow: View {
    let permission: Permission
    let isGranted: Bool
    let isRequesting: Bool
    let onRequest: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: permission.symbol, color: Color(nsColor: permission.tint), size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                Text(permission.reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if isGranted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
            } else if isRequesting {
                ProgressView().controlSize(.small)
            } else {
                Button("Allow…", action: onRequest)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct MusicPane: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var media: NowPlayingService

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $preferences.showsMediaInNotch) {
                    Text("Show Now Playing in the notch")
                    Text("Artwork and a visualizer sit beside the camera while something plays. Hover the right side for play and pause.")
                }
            }
            Section("Now Playing") {
                if let track = media.track {
                    HStack(spacing: 12) {
                        ArtworkView(image: media.artwork, cornerRadius: 6)
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title.isEmpty ? "Unknown title" : track.title).fontWeight(.medium)
                            Text(track.artist).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(appName(track.bundleIdentifier)).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                } else {
                    Text("Nothing is playing.").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func appName(_ bundleIdentifier: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return "" }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

private struct LockScreenPane: View {
    @ObservedObject var preferences: Preferences
    let media: NowPlayingService
    let onPreview: () -> Void

    @StateObject private var previewState: LockScreenCardState = {
        let state = LockScreenCardState()
        state.presented = true
        return state
    }()

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $preferences.lockScreenMediaEnabled) {
                    Text("Media controls on the Lock Screen")
                    Text("While your Mac is locked and something is playing, a Now Playing card sits below the clock.")
                }
            }
            Section {
                LockScreenMediaCard(media: media, state: previewState, blending: .withinWindow)
                    .scaleEffect(0.82)
                    .frame(height: 170)
                    .frame(maxWidth: .infinity)
                    .background {
                        LinearGradient(colors: [Color(red: 0.16, green: 0.24, blue: 0.48), Color(red: 0.55, green: 0.3, blue: 0.5)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .allowsHitTesting(false)
                    .opacity(preferences.lockScreenMediaEnabled ? 1 : 0.4)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                HStack {
                    Spacer()
                    Button("Preview on Desktop", action: onPreview)
                        .disabled(!preferences.lockScreenMediaEnabled)
                }
            } header: {
                Text("Preview")
            } footer: {
                Text("The preview shows the card over your desktop for a few seconds; click anywhere to dismiss it.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShelfPane: View {
    @ObservedObject var shelf: ShelfStore

    var body: some View {
        Form {
            Section {
                LabeledContent("Items on the shelf", value: "\(shelf.items.count)")
                Button("Clear Shelf", role: .destructive) {
                    withAnimation(Motion.content) { shelf.removeAll() }
                }
                .disabled(shelf.items.isEmpty)
            } footer: {
                Text("Drag files onto the notch to keep them on the shelf. Dragging one out moves it to where you drop it.")
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Received files") {
                    Button("Show in Finder") {
                        let url = ShelfStore.receivedFilesDirectory
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(url)
                    }
                }
            } footer: {
                Text("Files that arrive as promises (from Photos or Mail, for example) are saved here.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ExtensionsPane: View {
    @ObservedObject var extensions: ExtensionManager
    @ObservedObject var navigation: SettingsNavigation

    var body: some View {
        Form {
            Section {
                if extensions.entries.isEmpty {
                    Text("No extensions installed.").foregroundStyle(.secondary)
                }
                ForEach(extensions.entries) { entry in
                    ExtensionRow(entry: entry, isEnabled: Binding(
                        get: { extensions.isEnabled(entry.id) },
                        set: { extensions.setEnabled($0, for: entry.id) }
                    ), hasSettings: extensions.settingsPane(for: entry.id) != nil) {
                        navigation.selection = .extensionPane(entry.id)
                    }
                }
            } header: {
                Text("Installed")
            }
            Section {
                LabeledContent("Extensions folder") {
                    Button("Show in Finder") { NSWorkspace.shared.open(ExtensionManager.userDirectory) }
                }
                LabeledContent("Build your own") {
                    Button("Open SDK Guide") {
                        if let guide = Bundle.main.url(forResource: "XNotchKit", withExtension: "md") {
                            NSWorkspace.shared.open(guide)
                        }
                    }
                }
            } footer: {
                Text("Extensions are .xnext bundles built with XNotchKit. Put one in the extensions folder and restart XNotch.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ExtensionRow: View {
    let entry: ExtensionManager.Entry
    @Binding var isEnabled: Bool
    let hasSettings: Bool
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: entry.manifest.symbol,
                         color: entry.manifest.tint.flatMap(Color.init(hex:)) ?? .blue, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.manifest.name).fontWeight(.medium)
                    Text(entry.manifest.version).foregroundStyle(.tertiary)
                    if entry.isBuiltIn {
                        Text("Built in")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.quaternary))
                    }
                }
                Text(entry.failure ?? entry.manifest.summary)
                    .font(.callout)
                    .foregroundStyle(entry.failure == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    .lineLimit(2)
            }
            Spacer()
            if hasSettings {
                Button("Options…", action: onOpenSettings)
                    .controlSize(.small)
            }
            Toggle("", isOn: $isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(entry.failure != nil)
        }
        .padding(.vertical, 3)
    }
}

private struct AboutPane: View {
    @ObservedObject var updater: SoftwareUpdater

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    SettingsIcon(symbol: "rectangle.topthird.inset.filled", color: .black, size: 64)
                        .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                    Text("XNotch").font(.title2.weight(.semibold))
                    Text("Version \(version) · XNotchKit \(XNotchKit.apiVersion)")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            Section("Updates") {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.setAutomaticallyChecksForUpdates($0) }
                ))
                Toggle("Download and install updates automatically", isOn: Binding(
                    get: { updater.automaticallyDownloadsUpdates },
                    set: { updater.setAutomaticallyDownloadsUpdates($0) }
                ))
                .disabled(!updater.automaticallyChecksForUpdates)
                Button("Check for Updates…", action: updater.checkForUpdates)
                    .disabled(!updater.canCheckForUpdates)
            }
            Section("Acknowledgements") {
                credit("Atoll and boring.notch", "Portions adapted under the GNU GPL v3.")
                credit("mediaremote-adapter", "© Jonas van den Berg, BSD 3-Clause.")
                credit("SkyLightWindow", "© Lakr Aream, MIT.")
                credit("Sparkle", "© Sparkle Project, permissive license.")
                credit("PermissionFlow and AskForPermission", "The permission guide follows their design. MIT.")
                credit("bloub", "The eyes follow its measurements of the x.ai avatar. MIT.")
            }
        }
        .formStyle(.grouped)
    }

    private func credit(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.callout).foregroundStyle(.secondary)
        }
    }
}
