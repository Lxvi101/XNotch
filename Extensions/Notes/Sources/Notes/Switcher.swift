import AppKit
import Observation
import SwiftUI

/// An action in the command bar: what `>` in the switcher lists.
struct NoteCommand: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var shortcut: String?
    var section: String
    var isDestructive = false
    let run: @MainActor () -> Void
}

/// The switcher's search and selection: every note, the window's space first,
/// or with `>`, actions on the note.
@MainActor @Observable
final class SwitcherModel {
    /// The note window's actions, built when the bar opens.
    @ObservationIgnored var commandSource: () -> [NoteCommand] = { [] }
    @ObservationIgnored private var cachedCommands: [NoteCommand] = []

    var query = "" {
        didSet { selection = 0 }
    }
    var selection = 0
    private(set) var currentID: UUID?
    private(set) var currentSpaceID: UUID?
    @ObservationIgnored private unowned let library: NoteLibrary

    init(library: NoteLibrary) {
        self.library = library
    }

    func prepare(current: Note, commands: Bool = false) {
        currentID = current.id
        currentSpaceID = current.spaceID
        cachedCommands = commandSource()
        query = commands ? "> " : ""
        selection = 0
    }

    var isCommandMode: Bool { query.hasPrefix(">") }

    /// Actions whose titles hold every word typed after the `>`, best first:
    /// a title that starts with the first word comes before one that has it inside.
    var commands: [NoteCommand] {
        let words = query.dropFirst().lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return cachedCommands }
        let matching = cachedCommands.filter { command in
            let title = command.title.lowercased()
            return words.allSatisfy { title.contains($0) || command.section.lowercased().contains($0) }
        }
        return matching.sorted { a, b in
            let aStarts = a.title.lowercased().hasPrefix(words[0]), bStarts = b.title.lowercased().hasPrefix(words[0])
            return aStarts && !bStarts
        }
    }

    struct Section: Identifiable {
        let space: NoteSpace
        let notes: [Note]
        var id: UUID { space.id }
    }

    /// Notes matching the query, grouped by space, the current space first.
    var sections: [Section] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        let spaces = library.spaces.filter { $0.id == currentSpaceID } + library.spaces.filter { $0.id != currentSpaceID }
        return spaces.compactMap { space in
            let notes = library.notes(in: space.id).filter { note in
                words.allSatisfy { word in
                    note.title.lowercased().contains(word) || note.text.lowercased().contains(word)
                }
            }
            return notes.isEmpty ? nil : Section(space: space, notes: notes)
        }
    }

    var flat: [Note] { sections.flatMap(\.notes) }

    /// Arrows, Return and Escape; everything else types into the search.
    func handle(_ event: NSEvent, open: (Note, Bool) -> Void, close: () -> Void) -> Bool {
        let notes = flat
        let actions = commands
        let count = isCommandMode ? actions.count : notes.count
        let command = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 125: // down
            if count > 0 { withAnimation(NoteMotion.hover) { selection = (selection + 1) % count } }
        case 126: // up
            if count > 0 { withAnimation(NoteMotion.hover) { selection = (selection - 1 + count) % count } }
        case 36, 76: // return
            if isCommandMode {
                guard actions.indices.contains(selection) else { return true }
                run(actions[selection], close: close)
                return true
            }
            guard notes.indices.contains(selection) else { return true }
            open(notes[selection], command)
        case 53: // escape
            close()
        default:
            return false
        }
        return true
    }

    /// The bar folds away first, so the action happens in the note, not over it.
    func run(_ command: NoteCommand, close: () -> Void) {
        close()
        let action = command.run
        DispatchQueue.main.async { MainActor.assumeIsolated { action() } }
    }

    func delete(_ note: Note) {
        library.delete(note)
        selection = min(selection, max(0, flat.count - 1))
    }

    func togglePin(_ note: Note) { library.togglePin(note) }
}

struct SwitcherLayer: View {
    let controller: NoteController
    let state: NoteWindowState

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                if state.showsSwitcher {
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { controller.toggleSwitcher() }
                    let width = min(proxy.size.width - 20, 400)
                    SwitcherCard(controller: controller, model: controller.switcher)
                        .frame(width: width)
                        .frame(maxHeight: proxy.size.height - NoteGeometry.header - 14, alignment: .top)
                        .fixedSize(horizontal: false, vertical: true)
                        .offset(y: NoteGeometry.header)
                        .frame(maxWidth: .infinity)
                        .transition(.bloom(from: UnitPoint(x: 0.5 + (state.plusCenter.x - 26 - proxy.size.width / 2) / max(width, 1),
                                                           y: -0.04)))
                }
            }
            // As with the bucket: a closing switcher doesn't take clicks.
            .allowsHitTesting(state.showsSwitcher)
        }
    }
}

/// Mote's note switcher: a search field over the notes, pin and delete on
/// the selected row, and the keys at the bottom.
private struct SwitcherCard: View {
    let controller: NoteController
    @Bindable var model: SwitcherModel
    @FocusState private var focused: Bool

    var body: some View {
        let sections = model.sections
        let flat = sections.flatMap(\.notes)
        VStack(alignment: .leading, spacing: 0) {
            TextField("", text: $model.query, prompt: Text("Search notes, or type > for actions").foregroundStyle(.white.opacity(0.3)))
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundStyle(.white.opacity(0.92))
                .focused($focused)
                .tint(noteAccent)
                .padding(.horizontal, 16)
                .frame(height: 46)
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            if model.isCommandMode {
                CommandList(controller: controller, model: model)
            } else if flat.isEmpty {
                Text(model.query.isEmpty ? "No notes yet." : "No notes match “\(model.query)”.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
            } else {
                ScrollViewReader { reader in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(sections) { section in
                                Text(section.space.name)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.4))
                                    .padding(.horizontal, 10)
                                    .padding(.top, 9)
                                    .padding(.bottom, 3)
                                ForEach(section.notes) { note in
                                    let index = flat.firstIndex { $0.id == note.id } ?? 0
                                    SwitcherRow(note: note, isSelected: index == model.selection,
                                                isCurrent: note.id == model.currentID, model: model) {
                                        controller.openFromSwitcher(note, inNewWindow: NSEvent.modifierFlags.contains(.command))
                                    }
                                    .id(note.id)
                                    .onHover { if $0 { model.selection = index } }
                                }
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                    }
                    .frame(maxHeight: 300)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: model.selection) { _, index in
                        guard flat.indices.contains(index) else { return }
                        withAnimation(NoteMotion.content) { reader.scrollTo(flat[index].id) }
                    }
                }
            }
            HStack(spacing: 14) {
                if !model.isCommandMode {
                    KeyHint(title: "Actions", keys: [">"])
                }
                Spacer(minLength: 0)
                if model.isCommandMode {
                    KeyHint(title: "Run", keys: ["↩"])
                } else {
                    KeyHint(title: "Open Note", keys: ["↩"])
                    KeyHint(title: "New Window", keys: ["⌘", "↩"])
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(white: 0.14).opacity(0.94))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.1)))
                .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
        }
        .onAppear {
            DispatchQueue.main.async { focused = true }
        }
    }
}

private struct SwitcherRow: View {
    let note: Note
    let isSelected: Bool
    let isCurrent: Bool
    let model: SwitcherModel
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(noteAccent)
                .frame(width: 6, height: 6)
                .opacity(isCurrent ? 1 : 0)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if note.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(noteAccent.opacity(0.9))
                    }
                    Text(note.displayTitle)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                }
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isSelected {
                HStack(spacing: 2) {
                    RowButton(symbol: note.isPinned ? "pin.slash" : "pin", help: note.isPinned ? "Unpin" : "Pin") {
                        model.togglePin(note)
                    }
                    RowButton(symbol: "trash", help: "Move to Trash") { model.delete(note) }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.white.opacity(isSelected ? 0.09 : 0))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .animation(NoteMotion.hover, value: isSelected)
    }

    private var subtitle: String {
        let when = isCurrent ? "Current" : note.modified.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
        var parts = [when, "\(note.characterCount) characters"]
        if !note.attachments.isEmpty { parts.append(note.attachments.count == 1 ? "1 file" : "\(note.attachments.count) files") }
        return parts.joined(separator: " • ")
    }
}

private struct RowButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(hovered ? 0.95 : 0.6))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovered = $0 }
        .help(help)
    }
}

private struct KeyHint: View {
    let title: String
    let keys: [String]

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(minWidth: 20, minHeight: 20)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.white.opacity(0.1)))
            }
        }
    }
}

/// `>` in the switcher: the note's actions, grouped, with their shortcuts.
private struct CommandList: View {
    let controller: NoteController
    let model: SwitcherModel

    var body: some View {
        let commands = model.commands
        if commands.isEmpty {
            Text("No actions match “\(model.query.dropFirst().trimmingCharacters(in: .whitespaces))”.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
        } else {
            ScrollViewReader { reader in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                            if index == 0 || commands[index - 1].section != command.section {
                                Text(command.section)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.4))
                                    .padding(.horizontal, 10)
                                    .padding(.top, 9)
                                    .padding(.bottom, 3)
                            }
                            CommandRow(command: command, isSelected: index == model.selection)
                                .id(command.id)
                                .onHover { if $0 { model.selection = index } }
                                .onTapGesture { model.run(command) { controller.toggleSwitcher() } }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
                .frame(maxHeight: 300)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: model.selection) { _, index in
                    guard commands.indices.contains(index) else { return }
                    withAnimation(NoteMotion.content) { reader.scrollTo(commands[index].id) }
                }
            }
        }
    }
}

private struct CommandRow: View {
    let command: NoteCommand
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: command.symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(command.isDestructive ? Color(red: 1, green: 0.45, blue: 0.42) : .white.opacity(isSelected ? 0.9 : 0.6))
                .frame(width: 20)
            Text(command.title)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(command.isDestructive ? Color(red: 1, green: 0.55, blue: 0.52) : .white.opacity(0.92))
                .lineLimit(1)
            Spacer(minLength: 0)
            if let shortcut = command.shortcut {
                Text(shortcut)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(isSelected ? 0.09 : 0))
        }
        .contentShape(Rectangle())
        .animation(NoteMotion.hover, value: isSelected)
    }
}
