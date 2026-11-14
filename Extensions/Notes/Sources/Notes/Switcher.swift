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

    /// Which notes the list shows: every space, or one space with its sub-spaces.
    enum Scope: Hashable {
        case all
        case space(UUID)
    }

    var query = "" {
        didSet { selection = 0 }
    }
    var scope = Scope.all {
        didSet { selection = 0 }
    }
    var selection = 0
    private(set) var currentID: UUID?
    private(set) var currentSpaceID: UUID?
    @ObservationIgnored unowned let library: NoteLibrary

    init(library: NoteLibrary) {
        self.library = library
    }

    func prepare(current: Note, commands: Bool = false) {
        currentID = current.id
        currentSpaceID = current.spaceID
        cachedCommands = commandSource()
        query = commands ? "> " : ""
        // Opens on the note's own space; Tab or a chip moves along.
        scope = library.spaces.count > 1 ? .space(current.spaceID) : .all
        selection = 0
    }

    /// The chips along the top: every space, sub-spaces after their parent.
    var scopes: [Scope] { [.all] + library.orderedSpaces.map { .space($0.id) } }

    /// Tab and Shift-Tab step through the chips.
    func cycleScope(by step: Int) {
        let all = scopes
        let index = all.firstIndex(of: scope) ?? 0
        withAnimation(NoteMotion.hover) { scope = all[(index + step + all.count) % all.count] }
    }

    func setScope(_ scope: Scope) {
        guard scope != self.scope else { return }
        withAnimation(NoteMotion.hover) { self.scope = scope }
    }

    /// Matches for the query outside the scope, for the empty list's hint.
    var matchesElsewhere: Int {
        guard scope != .all else { return 0 }
        let inScope = Set(sections.flatMap(\.notes).map(\.id))
        let words = query.lowercased().split(separator: " ").map(String.init)
        return library.notes.filter { note in
            !inScope.contains(note.id) && words.allSatisfy { note.title.lowercased().contains($0) || note.text.lowercased().contains($0) }
        }.count
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

    /// Notes matching the query in the scope, grouped by space in the
    /// spaces' order, sub-spaces after their parent.
    var sections: [Section] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        let spaces: [NoteSpace]
        switch scope {
        case .all: spaces = library.orderedSpaces
        case .space(let id): spaces = library.orderedSpaces.filter { library.family(of: id).contains($0.id) }
        }
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
    func handle(_ event: NSEvent, open: (Note, Bool) -> Void, create: (String) -> Void, close: () -> Void) -> Bool {
        let notes = flat
        let actions = commands
        let count = isCommandMode ? actions.count : notes.count
        let command = event.modifierFlags.contains(.command)
        if event.keyCode == 48, !isCommandMode { // tab
            cycleScope(by: event.modifierFlags.contains(.shift) ? -1 : 1)
            return true
        }
        if !isCommandMode, handleSpaceKey(event) { return true }
        // ⌘0 for every space, ⌘1 to ⌘9 for the chips after it.
        if command, !isCommandMode, let digit = event.charactersIgnoringModifiers.flatMap(Int.init), (0...9).contains(digit) {
            let all = scopes
            if all.indices.contains(digit) { setScope(all[digit]) } else { NSSound.beep() }
            return true
        }
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
            // ⌘↩ always makes a note; ↩ does when there's nothing to open.
            guard !command, notes.indices.contains(selection) else {
                create(query)
                return true
            }
            open(notes[selection], event.modifierFlags.contains(.option))
        case 53: // escape
            close()
        default:
            return false
        }
        return true
    }

    /// The space keys, as VS Code moves lines and indents them:
    /// ← → step through the chips while nothing's typed (Tab and ⌘0–9 always),
    /// ⌥← ⌥→ move the chosen space along, ⌘] puts it inside the space to its
    /// left and ⌘[ takes it back out, F2 (or ⌘R) renames it, ⌥⌘N makes a new one.
    private func handleSpaceKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.keyCode
        // On a German keyboard "[" and "]" are ⌥5 and ⌥6: the character counts, not only the key.
        let typed = event.characters ?? ""
        let indent = modifiers.contains(.command) && modifiers.isSubset(of: [.command, .option])
            && ((modifiers == [.command] && key == 30) || typed == "]")
        let outdent = modifiers.contains(.command) && modifiers.isSubset(of: [.command, .option])
            && ((modifiers == [.command] && key == 33) || typed == "[")
        // With something typed, ⌥← ⌥→ jump by words in the search, as anywhere.
        let move = modifiers == [.option] && query.isEmpty && (key == 123 || key == 124)
        let rename = key == 120 && modifiers.isEmpty || key == 15 && modifiers == [.command] // F2, ⌘R
        if modifiers.isEmpty, query.isEmpty, key == 123 || key == 124, library.spaces.count > 1 {
            cycleScope(by: key == 123 ? -1 : 1)
            return true
        }
        if modifiers == [.command, .option], event.charactersIgnoringModifiers?.lowercased() == "n" {
            DispatchQueue.main.async { [self] in
                MainActor.assumeIsolated {
                    guard let name = ask("New Space", message: "A space groups notes, like a folder.", value: "",
                                         placeholder: "Work", button: "Create") else { return }
                    setScope(.space(library.addSpace(named: name).id))
                }
            }
            return true
        }
        guard indent || outdent || move || rename else { return false }
        // Every space at once: nothing to move or rename.
        guard case .space(let id) = scope, let space = library.space(id) else {
            NSSound.beep()
            return true
        }
        if rename {
            // After this key is done with: the prompt runs its own loop.
            DispatchQueue.main.async { [library] in MainActor.assumeIsolated { askToRename(space, library: library) } }
            return true
        }
        let moved = indent ? library.indent(space)
            : outdent ? library.outdent(space)
            : library.reorder(space, by: key == 123 ? -1 : 1)
        if !moved { NSSound.beep() }
        return true
    }

    /// The bar folds away first, so the action happens in the note, not over it.
    func run(_ command: NoteCommand, close: () -> Void) {
        close()
        let action = command.run
        DispatchQueue.main.async { MainActor.assumeIsolated { action() } }
    }

    func delete(_ note: Note) {
        // The window's own note: the window stays and the list follows it.
        if note.id == currentID, let next = library.deleteKeepingWindow(note) {
            currentID = next.id
        } else {
            library.delete(note)
        }
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
            if !model.isCommandMode && model.library.spaces.count > 1 {
                SpaceStrip(model: model)
            }
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            if model.isCommandMode {
                CommandList(controller: controller, model: model)
            } else if flat.isEmpty {
                VStack(spacing: 6) {
                    Text(model.query.isEmpty ? "No notes here yet." : "No notes match “\(model.query)” here.")
                    Button {
                        controller.newNoteFromSwitcher(query: model.query)
                    } label: {
                        Text(model.query.isEmpty ? "New Note  ↩" : "New Note “\(model.query)”  ↩")
                            .lineLimit(1)
                            .foregroundStyle(noteAccent.opacity(0.9))
                    }
                    .buttonStyle(.plain)
                    let elsewhere = model.query.isEmpty ? 0 : model.matchesElsewhere
                    if elsewhere > 0 {
                        Button {
                            model.setScope(.all)
                        } label: {
                            Text("\(elsewhere) in other spaces  ⌘0")
                                .foregroundStyle(noteAccent.opacity(0.9))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
            } else {
                ScrollViewReader { reader in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(sections) { section in
                                Text(model.library.path(of: section.space))
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.4))
                                    .padding(.horizontal, 10)
                                    .padding(.top, 9)
                                    .padding(.bottom, 3)
                                ForEach(section.notes) { note in
                                    let index = flat.firstIndex { $0.id == note.id } ?? 0
                                    SwitcherRow(note: note, isSelected: index == model.selection,
                                                isCurrent: note.id == model.currentID, model: model) {
                                        controller.openFromSwitcher(note, inNewWindow: NSEvent.modifierFlags.contains(.option))
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
            // The hints never widen the card: in a narrow note the least needed
            // ones go, rather than pushing the whole card past the note's edge.
            ViewThatFits(in: .horizontal) {
                footer(spaces: true, newNote: true, canOpen: !flat.isEmpty)
                footer(spaces: false, newNote: true, canOpen: !flat.isEmpty)
                footer(spaces: false, newNote: false, canOpen: !flat.isEmpty)
            }
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

    private func footer(spaces: Bool, newNote: Bool, canOpen: Bool) -> some View {
        HStack(spacing: 12) {
            if !model.isCommandMode {
                KeyHint(title: "Actions", keys: [">"])
                if spaces && model.library.spaces.count > 1 {
                    KeyHint(title: "Spaces", keys: ["⇥"])
                        .help("← → or Tab: other spaces. ⌥← ⌥→: move this space. ⌘] ⌘[: put it inside the one to its left, or take it out. F2: rename. ⌥⌘N: new space.")
                }
            }
            Spacer(minLength: 0)
            if model.isCommandMode {
                KeyHint(title: "Run", keys: ["↩"])
            } else {
                // With nothing to open, ↩ makes a note, as the empty list says.
                if canOpen {
                    KeyHint(title: "Open", keys: ["↩"])
                        .help("⌥↩ or ⌥-click: open in a new window")
                }
                if newNote {
                    KeyHint(title: "New Note", keys: ["⌘", "↩"])
                }
            }
        }
        .padding(.horizontal, 14)
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
                .lineLimit(1)
                .fixedSize()
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

// MARK: Spaces

/// The switcher's spaces, as chips under the search field: All, then each
/// space with its sub-spaces gathered after it. The highlight slides to the
/// chip in scope; right-click a chip to order, nest or rename it.
private struct SpaceStrip: View {
    let model: SwitcherModel
    @Namespace private var highlight

    var body: some View {
        let library = model.library
        let current = library.space(model.currentSpaceID ?? UUID())
        ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ScopeChip(title: "All", count: library.notes.count, isOn: model.scope == .all, isHome: false,
                              highlight: highlight) { model.setScope(.all) }
                        .id(SwitcherModel.Scope.all)
                    ForEach(library.orderedSpaces.filter { $0.parentID == nil }) { space in
                        let children = library.children(of: space.id)
                        HStack(spacing: 0) {
                            chip(for: space, current: current)
                            ForEach(children) { child in
                                // Its own slot, so a highlighted neighbour never covers it.
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 7.5, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.25))
                                    .frame(width: 14)
                                chip(for: child, current: current)
                            }
                        }
                        .background {
                            // A space and its sub-spaces read as one group. The outline sits
                            // outside the chips, so it adds no space and every gap stays even.
                            if !children.isEmpty {
                                Capsule().fill(.white.opacity(0.045))
                                    .overlay(Capsule().strokeBorder(.white.opacity(0.06)))
                                    .padding(-3)
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            // Chips scrolling off either edge fade out rather than being cut.
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 12)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 18)
                }
            }
            .onChange(of: model.scope) { _, scope in
                withAnimation(NoteMotion.content) { reader.scrollTo(scope, anchor: .center) }
            }
            // A space moved by the keys stays in view.
            .onChange(of: library.orderedSpaces.map(\.id)) { _, _ in
                withAnimation(NoteMotion.content) { reader.scrollTo(model.scope, anchor: .center) }
            }
            .onAppear { reader.scrollTo(model.scope, anchor: .center) }
        }
    }

    private func chip(for space: NoteSpace, current: NoteSpace?) -> some View {
        let library = model.library
        let scope = SwitcherModel.Scope.space(space.id)
        let isSub = space.parentID != nil
        // A parent counts its sub-spaces' notes too.
        let count = isSub ? library.notes(in: space.id).count : library.noteCount(inFamily: space.id)
        return ScopeChip(title: space.name, count: count, isOn: model.scope == scope,
                         isHome: current?.id == space.id, highlight: highlight) {
            model.setScope(scope)
        }
        .id(scope)
        .contextMenu { SpaceMenu(space: space, library: library) }
    }
}

private struct ScopeChip: View {
    let title: String
    let count: Int
    let isOn: Bool
    /// The space of the note in the window.
    let isHome: Bool
    let highlight: Namespace.ID
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isHome {
                    Circle().fill(noteAccent).frame(width: 5, height: 5)
                }
                Text(title)
                    .font(.system(size: 12, weight: isOn ? .semibold : .medium))
                    .foregroundStyle(.white.opacity(isOn ? 0.95 : (hovered ? 0.75 : 0.55)))
                    .lineLimit(1)
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(isOn ? 0.55 : 0.3))
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background {
                if isOn {
                    Capsule().fill(.white.opacity(0.14))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
                        .matchedGeometryEffect(id: "scope", in: highlight)
                } else if hovered {
                    Capsule().fill(.white.opacity(0.06))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .onHover { hovered = $0 }
        .animation(NoteMotion.hover, value: hovered)
    }
}

/// A space chip's right-click menu: its place in the order, its parent, its name.
private struct SpaceMenu: View {
    let space: NoteSpace
    let library: NoteLibrary

    var body: some View {
        let siblings = library.spaces.filter { $0.parentID == space.parentID }
        let index = siblings.firstIndex { $0.id == space.id } ?? 0
        Button("Move Left") { library.reorder(space, by: -1) }
            .keyboardShortcut(.leftArrow, modifiers: .option)
            .disabled(index == 0)
        Button("Move Right") { library.reorder(space, by: 1) }
            .keyboardShortcut(.rightArrow, modifiers: .option)
            .disabled(index == siblings.count - 1)
        Divider()
        if space.parentID == nil {
            Button("New Space Inside…") { askForSpace(in: space, library: library) }
            if library.children(of: space.id).isEmpty {
                if let before = library.spaceBefore(space) {
                    Button("Put Inside “\(before.name)”") { library.indent(space) }
                        .keyboardShortcut("]", modifiers: .command)
                }
                let others = library.spaces.filter { $0.parentID == nil && $0.id != space.id }
                if !others.isEmpty {
                    Menu("Put Inside") {
                        ForEach(others) { parent in
                            Button(parent.name) { library.nest(space, in: parent) }
                        }
                    }
                }
            }
        } else {
            Button("Move Out to Top Level") { library.outdent(space) }
                .keyboardShortcut("[", modifiers: .command)
        }
        Divider()
        Button("Rename…") { askToRename(space, library: library) }
            .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF2FunctionKey)!)), modifiers: [])
        if library.spaces.count > 1 {
            Button("Delete…", role: .destructive) { confirmDeleting(space, in: library) }
        }
    }
}
