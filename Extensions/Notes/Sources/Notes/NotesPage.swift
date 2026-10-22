import AppKit
import Carbon.HIToolbox
import SwiftUI
import XNotchKit

/// The notch page: spaces along the top, the space's notes below.
struct NotesPage: View {
    let library: NoteLibrary
    let size: CGSize
    let close: () -> Void
    @Namespace private var spaceHighlight

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SpaceBar(library: library, highlight: spaceHighlight)
            NoteStrip(library: library, close: close)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

// MARK: Spaces

private struct SpaceBar: View {
    let library: NoteLibrary
    let highlight: Namespace.ID

    var body: some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(library.spaces) { space in
                        SpaceChip(space: space, count: library.notes.filter { $0.spaceID == space.id }.count,
                                  isActive: space.id == library.activeSpaceID, highlight: highlight) {
                            library.switchSpace(to: space.id)
                        }
                        .notchContextMenu {
                            var items: [NotchMenuItem] = [.action("Rename Space…", symbol: "pencil") { renameSpace(space) }]
                            if library.spaces.count > 1 {
                                items += [.separator, .action("Delete Space…", symbol: "trash", isDestructive: true) {
                                    deleteSpace(space)
                                }]
                            }
                            return items
                        }
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                    AddSpaceChip { addSpace() }
                }
                .padding(.horizontal, 2)
            }
            Spacer(minLength: 4)
            VisibilityButton(isOn: library.hasVisibleNotes) { library.toggleVisibility() }
        }
        .frame(height: 24)
    }

    private func addSpace() {
        guard let name = ask("New Space", message: "A space groups notes, like a folder. Notes from any space can be open together.", value: "",
                             placeholder: "Work", button: "Create") else { return }
        let space = library.addSpace(named: name)
        library.switchSpace(to: space.id)
    }

    private func renameSpace(_ space: NoteSpace) {
        guard let name = ask("Rename Space", message: "", value: space.name, placeholder: space.name, button: "Rename") else { return }
        library.rename(space, to: name)
    }

    private func deleteSpace(_ space: NoteSpace) {
        confirmDeleting(space, in: library)
    }
}

/// Asks before a space and its notes go to the Trash.
@MainActor
func confirmDeleting(_ space: NoteSpace, in library: NoteLibrary) {
    let count = library.notes.filter { $0.spaceID == space.id }.count
    let alert = NSAlert()
    alert.messageText = "Delete “\(space.name)”?"
    alert.informativeText = count == 0 ? "The space is empty."
        : "Its \(count == 1 ? "note goes" : "\(count) notes go") to the Trash, with \(count == 1 ? "its bucket" : "their buckets")."
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    library.delete(space)
}

/// A one-field prompt in front of everything.
@MainActor
func ask(_ title: String, message: String, value: String, placeholder: String, button: String) -> String? {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    field.stringValue = value
    field.placeholderString = placeholder
    alert.accessoryView = field
    alert.addButton(withTitle: button)
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? nil : name
}

/// The active space's highlight slides between chips, stretching on the way.
private struct SpaceChip: View {
    let space: NoteSpace
    let count: Int
    let isActive: Bool
    let highlight: Namespace.ID
    let action: () -> Void

    var body: some View {
        NotchHoverReader { hovered in
            Button(action: action) {
                HStack(spacing: 5) {
                    Text(space.name)
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white.opacity(isActive ? 0.55 : 0.3))
                            .contentTransition(.numericText(value: Double(count)))
                    }
                }
                .foregroundStyle(.white.opacity(isActive ? 0.96 : (hovered ? 0.75 : 0.48)))
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background {
                    if isActive {
                        Capsule().fill(.white.opacity(0.14))
                            .matchedGeometryEffect(id: "active", in: highlight)
                    } else {
                        Capsule().fill(.white.opacity(hovered ? 0.06 : 0))
                    }
                }
                .contentShape(Capsule())
            }
            .buttonStyle(PressScaleStyle(scale: 0.94))
            .animation(KitMotion.content, value: hovered)
            .animation(KitMotion.content, value: isActive)
        }
    }
}

private struct AddSpaceChip: View {
    let action: () -> Void

    var body: some View {
        NotchHoverReader { hovered in
            Button(action: action) {
                Image(systemName: "plus")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.white.opacity(hovered ? 0.85 : 0.4))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.white.opacity(hovered ? 0.1 : 0)))
                    .contentShape(Circle())
            }
            .buttonStyle(PressScaleStyle())
            .animation(KitMotion.content, value: hovered)
        }
    }
}

private struct VisibilityButton: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        ShelfHeaderButton(action: action) {
            Image(systemName: isOn ? "eye" : "eye.slash")
                .contentTransition(.symbolEffect(.replace))
        }
        .environment(\.shelfHeaderButtonSize, 22)
        .help(isOn ? "Hide all notes" : "Show your notes")
    }
}

// MARK: Notes

private struct NoteStrip: View {
    let library: NoteLibrary
    let close: () -> Void

    var body: some View {
        let notes = library.notes(in: library.activeSpaceID)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                NewNoteCard {
                    library.newNote()
                    close()
                }
                ForEach(notes) { note in
                    NoteCard(note: note, isOpen: library.isOpen(note)) {
                        library.open(note, from: NotePlacement.notchPoint)
                        close()
                    }
                    .notchContextMenu { menu(for: note) }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                if notes.isEmpty {
                    Text("Notes float over everything. Drop files on one to keep them in its bucket.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(KitStyle.tertiaryText)
                        .frame(width: 220, alignment: .leading)
                        .padding(.leading, 6)
                }
            }
            .padding(.horizontal, 2)
            .animation(KitMotion.content, value: notes.map(\.id))
        }
        .id(library.activeSpaceID)
        .transition(.opacity)
    }

    private func menu(for note: Note) -> [NotchMenuItem] {
        var items: [NotchMenuItem] = [
            .action(library.isOpen(note) ? "Show Note" : "Open Note", symbol: "macwindow") {
                library.open(note, from: NotePlacement.notchPoint)
                close()
            },
            .action(note.isPinned ? "Unpin" : "Pin", symbol: "pin") { library.togglePin(note) }
        ]
        if library.isOpen(note) {
            items.append(.action("Close Note", symbol: "xmark") { library.close(note) })
        }
        let others = library.spaces.filter { $0.id != note.spaceID }
        if !others.isEmpty {
            items.append(.separator)
            items += others.map { space in
                .action("Move to “\(space.name)”", symbol: "arrow.right.square") { library.move(note, to: space) }
            }
        }
        items += [.separator, .action("Delete Note", symbol: "trash", isDestructive: true) { library.delete(note) }]
        return items
    }
}

private struct NewNoteCard: View {
    let action: () -> Void

    var body: some View {
        NotchHoverReader { hovered in
            Button(action: action) {
                VStack(spacing: 6) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.white.opacity(hovered ? 0.92 : 0.55))
                    Text("New Note")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(hovered ? 0.82 : 0.45))
                }
                .frame(width: 72, height: NoteCard.height)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(hovered ? 0.32 : 0.16), style: StrokeStyle(lineWidth: 1.1, dash: [3.5, 3]))
                }
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(PressScaleStyle(scale: 0.94))
            .animation(KitMotion.content, value: hovered)
        }
    }
}

private struct NoteCard: View {
    static let height: CGFloat = 76
    let note: Note
    let isOpen: Bool
    let action: () -> Void

    var body: some View {
        NotchHoverReader { hovered in
            Button(action: action) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        if note.isPinned {
                            Image(systemName: "pin.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(noteAccent)
                        }
                        Text(note.displayTitle)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.94))
                            .lineLimit(1)
                    }
                    Text(note.preview.isEmpty ? " " : note.preview)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        if !note.attachments.isEmpty {
                            BucketIcon(hits: 0)
                                .frame(width: 10, height: 10)
                            Text("\(note.attachments.count)")
                                .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                        }
                        Spacer(minLength: 0)
                        Text(note.modified, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                            .font(.system(size: 9))
                    }
                    .foregroundStyle(.white.opacity(0.35))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .frame(width: 128, height: Self.height, alignment: .topLeading)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(hovered ? 0.11 : 0.07), .white.opacity(hovered ? 0.07 : 0.035)],
                                             startPoint: .top, endPoint: .bottom))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.06)))
                }
                .overlay(alignment: .topTrailing) {
                    if isOpen {
                        Circle().fill(noteAccent).frame(width: 5, height: 5).padding(7)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(PressScaleStyle(scale: 0.95))
            .scaleEffect(hovered ? 1.03 : 1)
            .animation(KitMotion.content, value: hovered)
            .animation(KitMotion.content, value: isOpen)
        }
    }
}

// MARK: Settings

struct NotesSettingsPane: View {
    @ObservedObject var preferences: NotesPreferences
    let library: NoteLibrary

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $preferences.floatsOnTop) {
                    Text("Keep notes above other windows")
                    Text("Off, notes sit among your windows like any other.")
                }
                Toggle(isOn: $preferences.onAllDesktops) {
                    Text("Show notes on every desktop")
                    Text("Off, a note stays on the desktop where you opened it.")
                }
            }
            Section {
                ForEach(library.spaces) { space in
                    SpaceRow(space: space, count: library.notes.filter { $0.spaceID == space.id }.count,
                             isActive: space.id == library.activeSpaceID, canDelete: library.spaces.count > 1,
                             onRename: { library.rename(space, to: $0) }, onDelete: { confirmDeleting(space, in: library) })
                }
                Button("Add Space") {
                    library.addSpace(named: "Space \(library.spaces.count + 1)")
                }
            } header: {
                Text("Spaces")
            } footer: {
                Text("Spaces group notes, like folders. Notes from any space can float on screen together; the notch shows one space at a time, and new notes go into it.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle(isOn: $preferences.syncICloud) {
                    Text("Sync notes with iCloud Drive")
                    Text("Every note as a Markdown file in iCloud Drive › XNotch Notes, a folder per space, its bucket beside it. Edits made on another Mac or in any editor come back.")
                }
                .disabled(library.cloudFolder == nil)
                LabeledContent {
                    HStack(spacing: 8) {
                        Text(cloudStatusText).foregroundStyle(.secondary)
                        if let folder = library.cloudFolder, preferences.syncICloud {
                            Button("Show in Finder") {
                                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                                NSWorkspace.shared.open(folder)
                            }
                        }
                    }
                } label: {
                    Text("iCloud Drive")
                }
            } header: {
                Text("Sync")
            } footer: {
                Text(library.cloudFolder == nil
                     ? "Turn on iCloud Drive in System Settings › Apple Account › iCloud to sync notes."
                     : "Notes are read from this Mac, never straight from iCloud: a note that hasn't downloaded yet never holds you up.")
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Notes on this Mac") {
                    Button("Show in Finder") { NSWorkspace.shared.open(library.notesFolder) }
                }
            } footer: {
                Text("Files dropped on a note are copied into its bucket, so they stay when the originals move.")
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent {
                    ShortcutRecorder(shortcut: $preferences.toggleShortcut)
                } label: {
                    Text("Show and hide notes")
                    Text("From any app. Notes fold into the notch and come back where they were, ready to type in.")
                }
            } footer: {
                if preferences.toggleShortcutTaken {
                    Text("Another app already uses this shortcut. Choose a different one.")
                        .foregroundStyle(.red)
                }
            }
            Section("Editor") {
                Toggle(isOn: $preferences.cursorGlide) {
                    Text("Cursor glide")
                    Text("The cursor slides to its new position as you type. Off snaps it there instead.")
                }
                Toggle(isOn: $preferences.showNotePosition) {
                    Text("Show note position")
                    Text("Where a note sits in the ⌘[ / ⌘] cycle, shown briefly when it opens.")
                }
                Toggle(isOn: $preferences.checkSpelling) {
                    Text("Check spelling while typing")
                    Text("macOS's dictionaries and your learned words. Code, links and #tags are left alone. Right-click a word for suggestions.")
                }
                Toggle(isOn: $preferences.predictiveText) {
                    Text("Predictive text")
                    Text("Apple's inline suggestions after the caret; press Space to accept. English, French and Spanish keyboards.")
                }
                Toggle(isOn: $preferences.moveCompletedTasks) {
                    Text("Move completed tasks to the bottom")
                    Text("A checked task drops below the rest of its list.")
                }
                Toggle(isOn: $preferences.clearCompletedTasks) {
                    Text("Clear completed tasks")
                    Text("A checked task fades out and is removed a second later — uncheck it in time to keep it. ⌘Z brings it back.")
                }
            }
            Section("Shortcuts in a note") {
                ShortcutRow(keys: "⌘K", action: "Find a note; type > for actions")
                ShortcutRow(keys: "⇧⌘P", action: "Actions for this note")
                ShortcutRow(keys: "⌘[  ⌘]", action: "Previous or next note")
                ShortcutRow(keys: "⌘N", action: "New note beside this one")
                ShortcutRow(keys: "⇧⌘B", action: "Open the bucket")
                ShortcutRow(keys: "⌘B  ⌘I  ⌘E", action: "Bold, italic, code")
                ShortcutRow(keys: "⌘L", action: "Checklist item")
                ShortcutRow(keys: "⌘W", action: "Close note")
                ShortcutRow(keys: "⇧⌘⌫", action: "Move note to the Trash")
            }
        }
        .formStyle(.grouped)
    }
}

private extension NotesSettingsPane {
    var cloudStatusText: String {
        guard library.cloudFolder != nil else { return "Off in System Settings" }
        guard preferences.syncICloud else { return "Off" }
        switch library.cloudStatus {
        case .syncing: return "Syncing…"
        case .unavailable: return "Unavailable"
        case .idle(let date?): return "Up to date · " + date.formatted(.relative(presentation: .named))
        case .idle(nil): return "Up to date"
        }
    }
}

private struct SpaceRow: View {
    let space: NoteSpace
    let count: Int
    let isActive: Bool
    let canDelete: Bool
    let onRename: (String) -> Void
    let onDelete: () -> Void
    @State private var name = ""

    var body: some View {
        HStack {
            TextField("Name", text: $name)
                .labelsHidden()
                .textFieldStyle(.plain)
                .fontWeight(isActive ? .semibold : .regular)
                .onSubmit { onRename(name) }
            Spacer()
            Text(count == 1 ? "1 note" : "\(count) notes").foregroundStyle(.secondary)
            if canDelete {
                Button(role: .destructive, action: onDelete) { Image(systemName: "minus.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .help("Delete space and move its notes to the Trash")
            }
        }
        .onAppear { name = space.name }
        .onChange(of: space.name) { _, new in name = new }
    }
}

private struct ShortcutRow: View {
    let keys: String
    let action: String

    var body: some View {
        LabeledContent(action) {
            Text(keys).font(.system(.body, design: .rounded)).foregroundStyle(.secondary)
        }
    }
}

/// Click, then press the shortcut. Escape cancels; Delete clears it.
private struct ShortcutRecorder: View {
    @Binding var shortcut: KeyShortcut?
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                isRecording ? stop() : start()
            } label: {
                Text(isRecording ? "Type shortcut…" : (shortcut?.display ?? "Record Shortcut"))
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .foregroundStyle(isRecording ? Color.accentColor : .primary)
                    .frame(minWidth: 110)
            }
            .help(isRecording ? "Press a key with ⌘, ⌥ or ⌃. Escape cancels." : "Click to record a new shortcut")
            if shortcut != nil, !isRecording {
                Button {
                    shortcut = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Turn the shortcut off")
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case kVK_Escape:
                stop()
            case kVK_Delete where event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                 kVK_ForwardDelete where event.modifierFlags.intersection([.command, .option, .control]).isEmpty:
                shortcut = nil
                stop()
            default:
                // Without ⌘, ⌥ or ⌃ it would fire while typing: wait for a real one.
                guard let recorded = KeyShortcut(event: event) else {
                    NSSound.beep()
                    return nil
                }
                shortcut = recorded
                stop()
            }
            return nil
        }
    }

    private func stop() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
