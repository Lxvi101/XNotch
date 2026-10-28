import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ShelvesSettingsPane: View {
    @ObservedObject var preferences: ShelvesPreferences
    @ObservedObject var library: ShelfLibrary
    let folderMonitor: FolderMonitor
    let chooseFolders: () -> [URL]

    @State private var storageSize: Int64 = 0
    @State private var editedRule: UUID?

    var body: some View {
        Form {
            activation
            ignoredApps
            interaction
            instantActions
            links
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

    private var links: some View {
        Section {
            Toggle(isOn: $preferences.linksToFiles) {
                Text("Turn dropped links into files")
                Text("A Pinterest pin becomes its image, a link to a picture the picture.")
            }
            if preferences.linksToFiles {
                ForEach($preferences.linkRules) { $rule in
                    LinkRuleRow(rule: $rule, isEditing: Binding(get: { editedRule == rule.id },
                                                                set: { editedRule = $0 ? rule.id : nil }),
                                onRemove: { preferences.linkRules.removeAll { $0.id == rule.id } })
                    .contextMenu {
                        Button("Export Rule\u{2026}") { export([rule]) }
                        Button("Duplicate") { duplicate(rule) }
                        if !rule.isBuiltIn {
                            Button("Delete", role: .destructive) { preferences.linkRules.removeAll { $0.id == rule.id } }
                        }
                    }
                }
                .onMove { preferences.linkRules.move(fromOffsets: $0, toOffset: $1) }
                HStack {
                    Button("Import\u{2026}", action: importRules)
                    Button("Export\u{2026}") { export(preferences.linkRules) }
                    Spacer()
                    Button("Add Rule") {
                        let rule = LinkRule(name: "New Rule", hosts: [], source: .previewImage)
                        preferences.linkRules.append(rule)
                        editedRule = rule.id
                    }
                }
            }
        } header: {
            Text("Links")
        } footer: {
            Text("The first rule that covers a dropped link downloads its file. Other links, and links whose file can\u{2019}t be downloaded, land as link files. Drag rows to reorder; right-click one to share it.")
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

    private func duplicate(_ rule: LinkRule) {
        var copy = rule
        copy.id = UUID()
        copy.name = rule.name + " Copy"
        let index = preferences.linkRules.firstIndex { $0.id == rule.id }.map { $0 + 1 } ?? preferences.linkRules.endIndex
        preferences.linkRules.insert(copy, at: index)
        editedRule = copy.id
    }

    private func export(_ rules: [LinkRule]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = rules.count == 1 ? rules[0].name : "Link Rules"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try LinkRule.export(rules).write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func importRules() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do {
                try preferences.importLinkRules(from: Data(contentsOf: url))
            } catch {
                let alert = NSAlert()
                alert.messageText = "\u{201C}\(url.lastPathComponent)\u{201D} has no link rules XNotch can read."
                alert.informativeText = "A rule needs at least a name, hosts and a source, \u{201C}link\u{201D} or \u{201C}previewImage\u{201D}."
                alert.runModal()
            }
        }
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

/// A link rule, and its editor when open.
private struct LinkRuleRow: View {
    @Binding var rule: LinkRule
    @Binding var isEditing: Bool
    let onRemove: () -> Void

    @State private var hosts = ""
    @State private var paths = ""
    @State private var testLink = ""
    @State private var testResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: rule.source == .previewImage ? "photo" : "link")
                    .frame(width: 24)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(rule.name.isEmpty ? "Untitled Rule" : rule.name)
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
                Toggle("", isOn: $rule.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Button { isEditing.toggle() } label: {
                    Image(systemName: isEditing ? "chevron.up.circle.fill" : "pencil.circle")
                }
                .buttonStyle(.borderless)
                .help(isEditing ? "Done" : "Edit Rule")
                if !rule.isBuiltIn {
                    Button(role: .destructive, action: onRemove) {
                        Image(systemName: "minus.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .red)
                    }
                    .buttonStyle(.borderless)
                    .help("Delete Rule")
                }
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
            }
            if isEditing { editor }
        }
        .onAppear {
            hosts = rule.hosts.joined(separator: ", ")
            paths = rule.paths.joined(separator: ", ")
        }
        .onChange(of: hosts) { _, new in rule.hosts = LinkRule.patterns(from: new) }
        .onChange(of: paths) { _, new in rule.paths = LinkRule.patterns(from: new) }
    }

    private var editor: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
            field("Name") { TextField("Name", text: $rule.name, prompt: Text("Untitled Rule")) }
            field("Sites") { TextField("Sites", text: $hosts, prompt: Text("example.com, *.example.org")) }
            field("Paths") { TextField("Paths", text: $paths, prompt: Text("Any path, or /photo/*")) }
            field("File") {
                Picker("File", selection: $rule.source) {
                    ForEach(LinkSource.allCases) { Text($0.title).tag($0) }
                }
                .fixedSize()
            }
            field("Replace") { TextField("Replace", text: $rule.find, prompt: Text("Regular expression, optional")) }
            field("With") { TextField("With", text: $rule.replace, prompt: Text("Replacement, like /originals/")) }
                .disabled(rule.find.isEmpty)
            field("Try") {
                HStack {
                    TextField("Try", text: $testLink, prompt: Text("Paste a link"))
                        .onSubmit(test)
                    Button("Find File", action: test)
                        .disabled(URL(string: testLink)?.host() == nil)
                }
            }
            if let testResult {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Text(testResult)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(.leading, 34)
        .padding(.bottom, 4)
    }

    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            content().labelsHidden()
        }
    }

    private var summary: String {
        let sites = rule.hosts.isEmpty ? "No sites" : rule.hosts == ["*"] ? "Any site" : rule.hosts.joined(separator: " ")
        let paths = rule.paths.prefix(3).joined(separator: " ") + (rule.paths.count > 3 ? " \u{2026}" : "")
        return [sites, paths].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Shows where the rule finds the file for the link, without downloading it.
    private func test() {
        guard let url = URL(string: testLink.trimmingCharacters(in: .whitespaces)), url.host() != nil else { return }
        guard rule.matches(url) else { return testResult = "This rule doesn\u{2019}t cover that link." }
        testResult = "Looking\u{2026}"
        let rule = rule
        Task {
            do {
                let addresses = try await LinkResolver.addresses(for: url, with: rule)
                testResult = addresses.map(\.absoluteString).joined(separator: "\nor ")
            } catch {
                testResult = error.localizedDescription
            }
        }
    }
}
