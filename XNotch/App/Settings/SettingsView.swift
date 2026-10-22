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
        // The sidebar always shows, as in System Settings: the window doesn't
        // resize to make room for it, so collapsing it only squeezed and
        // re-flowed the pane, and a collapsed sidebar stayed collapsed.
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: $navigation.selection) {
                Section {
                    row(.general, "General", "gearshape.fill", .gray)
                    row(.music, "Music", "music.note", .pink)
                    row(.lockScreen, "Lock Screen", "lock.fill", .indigo)
                    row(.shelf, "Tray", "tray.full.fill", .green)
                }
                Section("Extensions") {
                    row(.extensions, "Extension Store", "puzzlepiece.extension.fill", .purple)
                    ForEach(extensions.installed) { entry in
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
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .frame(minWidth: 460)
        }
        .frame(minWidth: 680, maxWidth: .infinity, minHeight: 460, maxHeight: .infinity)
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
            GeneralPane(preferences: preferences, permissions: .shared, extensions: extensions,
                        onReplayOnboarding: onReplayOnboarding)
                .navigationTitle("General")
        case .music:
            MusicPane(preferences: preferences, media: media).navigationTitle("Music")
        case .lockScreen:
            LockScreenPane(preferences: preferences, media: media, onPreview: onPreviewLockScreen)
                .navigationTitle("Lock Screen")
        case .shelf:
            ShelfPane(shelf: shelf).navigationTitle("Tray")
        case .extensions:
            ExtensionStorePane(extensions: extensions, navigation: navigation).navigationTitle("Extension Store")
        case .extensionPane(let id):
            if let entry = extensions.entries.first(where: { $0.id == id }) {
                // An extension without settings, or one that can't run, shows its store page.
                if let pane = extensions.settingsPane(for: id) {
                    pane.navigationTitle(entry.manifest.name)
                } else {
                    ExtensionDetailView(entry: entry, extensions: extensions, navigation: navigation)
                }
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
    @ObservedObject var extensions: ExtensionManager
    let onReplayOnboarding: () -> Void
    @State private var screens = DisplayOption.connected

    /// Every page the notch can show, in the user's order. Music is listed
    /// whenever it's on, even with nothing playing.
    private var pages: [PageInfo] {
        var infos: [PageInfo] = []
        if preferences.showsMediaInNotch {
            infos.append(PageInfo(page: .media, title: "Music", symbol: "music.note", badge: 0))
        }
        infos.append(PageInfo(page: .shelf, title: "Tray", symbol: "tray.full.fill", badge: 0))
        infos += extensions.pageProviders.flatMap { id, provider in
            provider.pages.map { PageInfo(page: .extensionPage(id, $0.id), title: $0.title, symbol: $0.symbol, badge: 0) }
        }
        return PageOrder.sorted(infos, by: preferences.pageOrder)
    }

    /// The pages list: shown pages, then a "Hidden" divider, then hidden ones.
    private enum PageRow: Identifiable {
        case page(PageInfo)
        case hiddenDivider

        var id: String {
            switch self {
            case .page(let info): info.id
            case .hiddenDivider: "hidden-divider"
            }
        }
    }

    private var pageRows: [PageRow] {
        let pages = pages
        let hidden = pages.filter { preferences.hiddenPages.contains($0.id) }
        let shown = pages.filter { !preferences.hiddenPages.contains($0.id) }
        return shown.map(PageRow.page) + [.hiddenDivider] + hidden.map(PageRow.page)
    }

    /// Where a row may be dragged: anywhere, but the shelf and Music stay
    /// above the divider, and the divider stays put.
    private func pageRowRange(_ row: PageRow, in rows: [PageRow]) -> ClosedRange<Int>? {
        guard case .page(let info) = row else { return nil }
        guard [OpenPage.shelf, OpenPage.media].contains(info.page) else { return 0...(rows.count - 1) }
        let divider = rows.firstIndex { $0.id == PageRow.hiddenDivider.id } ?? rows.count
        return 0...max(0, divider - 1)
    }

    /// Dragging a row past the divider hides it, back above shows it.
    private func movePageRow(_ row: PageRow, to index: Int) {
        let rows = pageRows
        guard case .page(let moved) = row else { return }
        var arranged = rows.filter { $0.id != moved.id }
        arranged.insert(row, at: min(index, arranged.count))
        guard let divider = arranged.firstIndex(where: { $0.id == PageRow.hiddenDivider.id }) else { return }
        let listed = rows.compactMap { if case .page(let info) = $0 { info } else { nil } }
        let nowHidden = Set(arranged[(divider + 1)...].map(\.id))
        guard nowHidden.isDisjoint(with: [OpenPage.shelf.id, OpenPage.media.id]) else { return }
        preferences.hiddenPages = preferences.hiddenPages.subtracting(listed.map(\.id)).union(nowHidden)
        preferences.pageOrder = PageOrder.moving(moved.page, to: index > divider ? index - 1 : index, among: listed,
                                                 in: preferences.pageOrder)
    }

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
                Picker("Pills show", selection: Binding(
                    get: { PillLabels.iconOnly(preferences, extensions) },
                    set: { preferences.pillsIconOnlyChoice = $0 }
                )) {
                    Text("Icon and name").tag(false)
                    Text("Icon only").tag(true)
                }
                .disabled(!preferences.showsDestinationPills)
            } header: {
                Text("Notch")
            }
            Section {
                Toggle(isOn: $preferences.showsOnAllDisplays) {
                    Text("Show on all displays")
                    Text("Each display gets its own notch. One without a camera notch gets one drawn at the top.")
                }
                Picker("Display", selection: $preferences.notchDisplay) {
                    Text("Automatic").tag(String?.none)
                    ForEach(screens) { Text($0.name).tag(String?.some($0.id)) }
                    if let picked = preferences.notchDisplay, !screens.contains(where: { $0.id == picked }) {
                        Text("Not connected").tag(String?.some(picked))
                    }
                }
                .disabled(preferences.showsOnAllDisplays)
                Picker("Drawn notch height", selection: $preferences.drawnNotchHeight) {
                    Text("Match the menu bar").tag(DrawnNotchHeight.menuBar)
                    Text("Match a real notch").tag(DrawnNotchHeight.notch)
                }
            } header: {
                Text("Displays")
            } footer: {
                Text("Automatic puts the notch on the built-in display's notch, else on the display with the menu bar. A display that isn't connected hands it back to Automatic.")
                    .foregroundStyle(.secondary)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
                screens = DisplayOption.connected
            }
            Section {
                let rows = pageRows
                ReorderableRows(rows, range: { pageRowRange($0, in: rows) }, onMove: movePageRow) { row in
                    switch row {
                    case .page(let info):
                        HStack(spacing: 10) {
                            Image(systemName: info.symbol)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            Text(info.title)
                        }
                    case .hiddenDivider:
                        Text("Hidden")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Pages")
            } footer: {
                Text("Drag to reorder, or drag the icons in the open notch. Drag a page below Hidden to take it out of the pills and the open notch. Music and the tray always stay. The first four sit left of the camera, the rest on its right. Music only shows while something plays.")
                    .foregroundStyle(.secondary)
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
                LabeledContent("Tray: Quick Look, delete", value: "space, ⌫")
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

private struct DisplayOption: Identifiable {
    let id: String
    let name: String

    @MainActor static var connected: [DisplayOption] {
        NSScreen.screens.compactMap { screen in screen.displayID.map { DisplayOption(id: $0, name: screen.localizedName) } }
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
                Picker(selection: $preferences.musicWingIndicator) {
                    Text("Visualizer").tag(MusicWingIndicator.visualizer)
                    Text("Play/pause symbol").tag(MusicWingIndicator.playPause)
                } label: {
                    Text("Right of the camera")
                    Text("The symbol stays still, for anyone who finds the moving bars distracting.")
                }
                .disabled(!preferences.showsMediaInNotch)
                Toggle(isOn: $preferences.showsHeadphonesInNotch) {
                    Text("Show headphones when they connect")
                    Text("AirPods, Beats and other Bluetooth headphones and speakers appear beside the camera for a moment, with their battery.")
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
                LabeledContent("Items in the tray", value: "\(shelf.items.count)")
                Button("Clear Tray", role: .destructive) {
                    withAnimation(Motion.content) { shelf.removeAll() }
                }
                .disabled(shelf.items.isEmpty)
            } footer: {
                Text("Drag files onto the notch to keep them in the tray. Dragging one out moves it to where you drop it.")
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
