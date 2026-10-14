import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ShelvesSettingsPane: View {
    @ObservedObject var preferences: ShelvesPreferences
    @ObservedObject var library: ShelfLibrary
    let folderMonitor: FolderMonitor
    let chooseFolders: () -> [URL]

    @State private var storageSize: Int64 = 0

    var body: some View {
        Form {
            activation
            ignoredApps
            interaction
            instantActions
            folders
            data
        }
        .formStyle(.grouped)
        .onAppear { storageSize = library.storageSize() }
    }

    // MARK: Sections

    private var activation: some View {
        Section {
            Toggle(isOn: $preferences.shakeEnabled) {
                Text("Activate with shake gesture")
                Text("Shake the pointer while dragging files.")
            }
            if preferences.shakeEnabled {
                Picker("Sensitivity", selection: $preferences.sensitivity) {
                    ForEach(ShakeSensitivity.allCases) { Text($0.title).tag($0) }
                }
            }
            Toggle(isOn: $preferences.modifierEnabled) {
                Text("Activate with modifier key")
                Text("Hold a key while dragging files.")
            }
            if preferences.modifierEnabled {
                Picker("Key", selection: $preferences.modifier) {
                    ForEach(TriggerModifier.allCases) { Text($0.title).tag($0) }
                }
            }
            HStack {
                Button("New Shelf") { library.newShelfUnderNotch() }
                Button("New Shelf from Clipboard") { library.newShelfFromClipboard() }
            }
        } header: {
            Text("Shelf Activation")
        } footer: {
            Text("A shelf appears under the pointer. Drop files on it, then drag them out wherever you need them. Shelves are also in the notch, under Shelves.")
                .foregroundStyle(.secondary)
        }
    }

    private var ignoredApps: some View {
        Section {
            if preferences.ignoredApps.isEmpty {
                Text("No ignored apps.")
                    .foregroundStyle(.secondary)
            }
            ForEach(preferences.ignoredApps) { app in
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                        .resizable()
                        .frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name)
                        Text(app.bundleID).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        preferences.ignoredApps.removeAll { $0.id == app.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .red)
                    }
                    .buttonStyle(.borderless)
                    .help("Stop ignoring \(app.name)")
                }
            }
            HStack {
                Spacer()
                Button("Add Application…", action: addApps)
            }
        } header: {
            Text("Ignored Applications")
        } footer: {
            Text("Dragging files from these apps never opens a shelf, by shaking or with the modifier key. Useful for apps where you drag a lot, like design tools or games.")
                .foregroundStyle(.secondary)
        }
    }

    private var interaction: some View {
        Section {
            Picker("Double-click files", selection: $preferences.doubleClick) {
                ForEach(DoubleClickAction.allCases) { Text($0.title).tag($0) }
            }
            Picker("Close on drag out", selection: $preferences.dragOut) {
                ForEach(DragOutBehavior.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Show shelves on every Space", isOn: $preferences.onAllSpaces)
        } header: {
            Text("Shelf Interaction")
        } footer: {
            Text("Dragging a file out of a shelf moves it when the destination allows it, like Finder on the same disk. Pinned shelves never close on their own.")
                .foregroundStyle(.secondary)
        }
    }

    private var instantActions: some View {
        Section {
            Toggle("Enable Instant Actions", isOn: $preferences.instantActionsEnabled)
            if preferences.instantActionsEnabled {
                ForEach(preferences.actionOrder) { action in
                    HStack(spacing: 10) {
                        Image(nsImage: action.icon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 24, height: 24)
                        Text(action.title)
                        Spacer()
                        Toggle("", isOn: Binding(get: { !preferences.disabledActions.contains(action) },
                                                 set: { preferences.setAction(action, enabled: $0) }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .disabled(!action.isAvailable)
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.tertiary)
                    }
                }
                .onMove { preferences.actionOrder.move(fromOffsets: $0, toOffset: $1) }
                Toggle("Close the shelf after an action", isOn: $preferences.closeAfterAction)
            }
        } header: {
            Text("Instant Actions")
        } footer: {
            Text("Drag files onto the bolt in a shelf's corner and the shelf turns into these actions. Drop on one to perform it. Drag rows to reorder.")
                .foregroundStyle(.secondary)
        }
    }

    private var folders: some View {
        Section {
            ForEach($preferences.watchedFolders) { $folder in
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path))
                        .resizable()
                        .frame(width: 26, height: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(FileManager.default.displayName(atPath: folder.path))
                        HStack(spacing: 4) {
                            Circle()
                                .fill(folder.isEnabled && folderMonitor.isActive(folder) ? Color.green : Color.secondary)
                                .frame(width: 6, height: 6)
                            Text(status(of: folder))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $folder.isEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    Button(role: .destructive) {
                        preferences.watchedFolders.removeAll { $0.id == folder.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .red)
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                Spacer()
                Button("Add Folder…") { preferences.watch(chooseFolders()) }
            }
        } header: {
            Text("Folder Monitoring")
        } footer: {
            Text("New files in these folders appear in a shelf in the top-right corner of the screen, like a download finishing.")
                .foregroundStyle(.secondary)
        }
    }

    private var data: some View {
        Section {
            LabeledContent("Recent shelves") {
                Text("\(library.closedRecent.count)")
            }
            LabeledContent("Files kept by shelves") {
                Text(ByteCountFormatter.string(fromByteCount: storageSize, countStyle: .file))
            }
            HStack {
                Spacer()
                Button("Clear Recent Shelves…", role: .destructive, action: confirmClear)
                    .disabled(library.closedRecent.isEmpty)
            }
        } header: {
            Text("Application Data")
        } footer: {
            Text("Shelves hold references to your files, not copies. Only text, images and files dropped from apps like Mail or Photos are kept by XNotch, and they're deleted with their shelf.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Helpers

    private func status(of folder: WatchedFolder) -> String {
        guard folder.isEnabled else { return "Paused" }
        guard FileManager.default.fileExists(atPath: folder.path) else { return "Folder not found" }
        return folderMonitor.isActive(folder) ? "Active" : "Not monitoring"
    }

    private func addApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Ignore"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        preferences.ignore(appsAt: panel.urls)
    }

    private func confirmClear() {
        let alert = NSAlert()
        alert.messageText = "Clear recent shelves?"
        alert.informativeText = "Shelves that are open stay. Your files stay where they are; text and images dropped onto shelves are deleted."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        library.clearRecent()
        storageSize = library.storageSize()
    }
}
