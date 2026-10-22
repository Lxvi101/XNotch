import AppKit
import Observation
import SwiftUI

struct NoteSpace: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
}

/// What the index keeps about a note; its text lives in its own .md file.
struct NoteRecord: Codable {
    var id: UUID
    var spaceID: UUID
    var created: Date
    var modified: Date
    var isPinned: Bool
    var isOpen: Bool
    /// The note on screen, in AppKit screen coordinates, without its shadow margin.
    var frame: CGRect?
    /// The note's file in iCloud Drive, relative to the notes folder there.
    var cloudPath: String?
    /// The content as last matched with iCloud, to tell edits made here apart.
    var syncedHash: String?
}

/// One note. Views read only what they draw, so a keystroke redraws the
/// title and the count, not the window.
@MainActor @Observable
final class Note: Identifiable {
    let id: UUID
    var spaceID: UUID
    let created: Date
    var modified: Date
    var isPinned: Bool
    var isOpen: Bool
    @ObservationIgnored var frame: CGRect?
    @ObservationIgnored var cloudPath: String?
    @ObservationIgnored var syncedHash: String?
    /// The markdown. Not observed: the editor owns it while the note is open.
    @ObservationIgnored private(set) var text: String
    private(set) var title: String
    private(set) var preview: String
    private(set) var characterCount: Int
    var attachments: [Attachment] = []

    init(record: NoteRecord, text: String) {
        id = record.id
        spaceID = record.spaceID
        created = record.created
        modified = record.modified
        isPinned = record.isPinned
        isOpen = record.isOpen
        frame = record.frame
        cloudPath = record.cloudPath
        syncedHash = record.syncedHash
        self.text = text
        title = MarkdownText.title(of: text)
        preview = MarkdownText.preview(of: text)
        characterCount = text.count
    }

    var record: NoteRecord {
        NoteRecord(id: id, spaceID: spaceID, created: created, modified: modified, isPinned: isPinned, isOpen: isOpen, frame: frame,
                   cloudPath: cloudPath, syncedHash: syncedHash)
    }

    var displayTitle: String { title.isEmpty ? "Untitled" : title }
    var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var attachmentsSize: Int64 { attachments.reduce(0) { $0 + $1.size } }

    /// Takes new text, updating only what changed, so observers redraw only for that.
    func update(text: String) {
        guard text != self.text else { return }
        self.text = text
        modified = Date()
        let title = MarkdownText.title(of: text)
        if title != self.title { self.title = title }
        let count = text.count
        if count != characterCount { characterCount = count }
    }

    /// The preview changes on every keystroke too, but only the notch shows it.
    func refreshPreview() {
        let preview = MarkdownText.preview(of: text)
        if preview != self.preview { self.preview = preview }
    }
}

@MainActor
final class NotesPreferences: ObservableObject {
    private let defaults: UserDefaults
    @Published var floatsOnTop: Bool { didSet { defaults.set(floatsOnTop, forKey: "floatsOnTop") } }
    @Published var onAllDesktops: Bool { didSet { defaults.set(onAllDesktops, forKey: "onAllDesktops") } }
    /// Hides and shows the notes from anywhere; nil when switched off.
    @Published var toggleShortcut: KeyShortcut? {
        // Stored empty when cleared, so it doesn't fall back to the default.
        didSet { defaults.set(toggleShortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: "toggleShortcut") }
    }
    /// Set when another app holds the shortcut, for Settings to say so.
    @Published var toggleShortcutTaken = false
    @Published var cursorGlide: Bool { didSet { defaults.set(cursorGlide, forKey: "cursorGlide") } }
    /// Mirrors every note into iCloud Drive as a Markdown file.
    @Published var syncICloud: Bool { didSet { defaults.set(syncICloud, forKey: "syncICloud") } }
    @Published var showNotePosition: Bool { didSet { defaults.set(showNotePosition, forKey: "showNotePosition") } }
    @Published var checkSpelling: Bool { didSet { defaults.set(checkSpelling, forKey: "checkSpelling") } }
    @Published var predictiveText: Bool { didSet { defaults.set(predictiveText, forKey: "predictiveText") } }
    @Published var moveCompletedTasks: Bool { didSet { defaults.set(moveCompletedTasks, forKey: "moveCompletedTasks") } }
    @Published var clearCompletedTasks: Bool { didSet { defaults.set(clearCompletedTasks, forKey: "clearCompletedTasks") } }

    var editorOptions: EditorOptions {
        EditorOptions(cursorGlide: cursorGlide, checkSpelling: checkSpelling, predictiveText: predictiveText,
                      moveCompletedTasks: moveCompletedTasks, clearCompletedTasks: clearCompletedTasks)
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        floatsOnTop = defaults.object(forKey: "floatsOnTop") as? Bool ?? true
        onAllDesktops = defaults.object(forKey: "onAllDesktops") as? Bool ?? true
        if let data = defaults.data(forKey: "toggleShortcut") {
            toggleShortcut = try? JSONDecoder().decode(KeyShortcut.self, from: data)
        } else {
            toggleShortcut = .toggleDefault
        }
        func flag(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        cursorGlide = flag("cursorGlide", true)
        syncICloud = flag("syncICloud", true)
        showNotePosition = flag("showNotePosition", true)
        checkSpelling = flag("checkSpelling", true)
        predictiveText = flag("predictiveText", false)
        moveCompletedTasks = flag("moveCompletedTasks", false)
        clearCompletedTasks = flag("clearCompletedTasks", false)
    }
}

/// Every note and space, on disk and on screen.
@MainActor @Observable
final class NoteLibrary {
    private struct Index: Codable {
        var spaces: [NoteSpace]
        var activeSpaceID: UUID
        var notes: [NoteRecord]
    }

    private(set) var spaces: [NoteSpace] = []
    private(set) var activeSpaceID = UUID()
    var notes: [Note] = []
    /// Bumped when a note window opens or closes, for the notch's open dots.
    private(set) var openNoteIDs: Set<UUID> = []

    @ObservationIgnored let root: URL
    @ObservationIgnored let preferences: NotesPreferences
    @ObservationIgnored var controllers: [UUID: NoteController] = [:]
    @ObservationIgnored private var dirtyBodies: Set<UUID> = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored var tick: () -> Void = {}
    @ObservationIgnored var openSettings: () -> Void = {}
    @ObservationIgnored var cloud: CloudSync?
    @ObservationIgnored var indexSaveTask: Task<Void, Never>?
    @ObservationIgnored var rescanTimer: Timer?
    var cloudStatus: CloudStatus = .unavailable
    var cloudFolder: URL? { CloudSync.defaultRoot }

    var notesFolder: URL { root.appendingPathComponent("Notes", isDirectory: true) }
    private var indexURL: URL { root.appendingPathComponent("library.json") }

    init(root: URL, preferences: NotesPreferences) {
        self.root = root
        self.preferences = preferences
    }

    func bucketFolder(for note: Note) -> URL {
        root.appendingPathComponent("Buckets", isDirectory: true).appendingPathComponent(note.id.uuidString, isDirectory: true)
    }

    func bodyURL(for id: UUID) -> URL { notesFolder.appendingPathComponent("\(id.uuidString).md") }

    var activeSpace: NoteSpace? { spaces.first { $0.id == activeSpaceID } }

    /// A space's notes: pinned first, then the most recently changed.
    func notes(in spaceID: UUID) -> [Note] {
        notes.filter { $0.spaceID == spaceID }.sorted {
            $0.isPinned != $1.isPinned ? $0.isPinned : $0.modified > $1.modified
        }
    }

    func isOpen(_ note: Note) -> Bool { openNoteIDs.contains(note.id) }

    // MARK: Loading and saving

    func load() {
        try? FileManager.default.createDirectory(at: notesFolder, withIntermediateDirectories: true)
        let data = try? Data(contentsOf: indexURL)
        let index = data.flatMap { try? JSONDecoder().decode(Index.self, from: $0) }
        if let index, !index.spaces.isEmpty {
            spaces = index.spaces
            activeSpaceID = index.spaces.contains { $0.id == index.activeSpaceID } ? index.activeSpaceID : index.spaces[0].id
            notes = index.notes.compactMap { record in
                guard let text = Self.readBody(bodyURL(for: record.id)) else { return nil }
                var record = record
                if !index.spaces.contains(where: { $0.id == record.spaceID }) { record.spaceID = activeSpaceID }
                return Note(record: record, text: text)
            }
        } else {
            if data != nil {
                // Unreadable, not missing: keep it for a person to look at, and
                // rebuild from the notes themselves rather than start over.
                let stamp = Int(Date().timeIntervalSince1970)
                try? FileManager.default.moveItem(at: indexURL, to: root.appendingPathComponent("library-unreadable-\(stamp).json"))
            }
            let space = NoteSpace(id: UUID(), name: "Personal")
            spaces = [space]
            activeSpaceID = space.id
            notes = recoverNotes(into: space)
        }
        // Notes left blank with nothing in their bucket go, as they do when closed.
        for note in notes where isDiscardable(note) { discard(note) }
        saveIndex()
        let folders = notes.map { ($0.id, bucketFolder(for: $0)) }
        Task.detached(priority: .utility) {
            let listed = folders.map { ($0.0, Attachments.list($0.1)) }
            await MainActor.run { [weak self] in
                for (id, attachments) in listed where !attachments.isEmpty {
                    self?.notes.first { $0.id == id }?.attachments = attachments
                }
            }
        }
    }

    /// A note's markdown, in whatever encoding it was saved in.
    private static func readBody(_ url: URL) -> String? {
        if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        var encoding = String.Encoding.utf8
        return try? String(contentsOf: url, usedEncoding: &encoding)
    }

    /// Every .md file in the notes folder, for when the index is gone.
    private func recoverNotes(into space: NoteSpace) -> [Note] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: notesFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.compactMap { url in
            guard url.pathExtension == "md", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let text = Self.readBody(url) else { return nil }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            return Note(record: NoteRecord(id: id, spaceID: space.id, created: modified, modified: modified,
                                           isPinned: false, isOpen: false, frame: nil), text: text)
        }
    }

    func saveIndex() {
        let index = Index(spaces: spaces, activeSpaceID: activeSpaceID, notes: notes.map(\.record))
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// Saves after a short pause in typing, off the keystroke path.
    func noteChanged(_ note: Note) {
        dirtyBodies.insert(note.id)
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        for id in dirtyBodies {
            guard let note = notes.first(where: { $0.id == id }) else { continue }
            try? note.text.write(to: bodyURL(for: id), atomically: true, encoding: .utf8)
            note.refreshPreview()
            push(note)
        }
        dirtyBodies.removeAll()
        saveIndex()
    }

    func refreshAttachments(of note: Note) {
        let attachments = Attachments.list(bucketFolder(for: note))
        let changed = attachments.map(\.name) != note.attachments.map(\.name)
        note.attachments = attachments
        if changed { push(note) }
    }

    // MARK: Windows

    /// Puts the active space's notes back where they were, as XNotch starts.
    /// Every note that was open goes back where it was, whatever its space.
    func restore() {
        for note in notes.sorted(by: { $0.modified < $1.modified }) where note.isOpen {
            show(note, from: nil, focus: false)
        }
    }

    /// Opens a note in its own window, flying out of `source` (a screen point).
    /// A note in another space brings that space along.
    func open(_ note: Note, from source: CGPoint?, focus: Bool = true) {
        if let controller = controllers[note.id] {
            controller.bringToFront(focus: focus)
            return
        }
        show(note, from: source, focus: focus)
    }

    private func show(_ note: Note, from source: CGPoint?, focus: Bool, delay: TimeInterval = 0) {
        let controller = NoteController(note: note, library: self)
        controllers[note.id] = controller
        openNoteIDs.insert(note.id)
        if !note.isOpen {
            note.isOpen = true
            saveIndex()
        }
        controller.show(from: source, focus: focus, delay: delay)
    }

    /// A fresh note beside `parent`, or under the notch.
    @discardableResult
    func newNote(beside parent: NoteController? = nil, from source: CGPoint? = nil, text: String = "") -> Note {
        // Beside a note, in that note's space; from the notch, in the space being browsed.
        let record = NoteRecord(id: UUID(), spaceID: parent?.note.spaceID ?? activeSpaceID, created: Date(), modified: Date(),
                                isPinned: false, isOpen: true, frame: nil)
        let note = Note(record: record, text: text)
        note.frame = NotePlacement.frame(beside: parent?.noteFrame, avoiding: controllers.values.map(\.noteFrame))
        notes.append(note)
        try? text.write(to: bodyURL(for: note.id), atomically: true, encoding: .utf8)
        show(note, from: source ?? parent.map { $0.newNoteSource } ?? NotePlacement.notchPoint, focus: true)
        tick()
        return note
    }

    /// Closes a note's window; the note stays in its space, unless it's empty.
    func close(_ note: Note, to point: CGPoint? = nil) {
        guard let controller = controllers[note.id] else { return }
        note.isOpen = false
        let wasKey = controller.panel.isKeyWindow
        detach(controller)
        controller.hide(to: point ?? NotePlacement.notchPoint)
        if isDiscardable(note) { discard(note) }
        saveNow()
        // The keys move to the next note up, as they would between windows.
        if wasKey {
            controllers.values.min { $0.panel.orderedIndex < $1.panel.orderedIndex }?.bringToFront(focus: true)
        }
    }

    /// Shows another note in a window that has one already, as Mote's switcher does.
    func swap(_ controller: NoteController, to note: Note) {
        guard note.id != controller.note.id else { return }
        if let other = controllers[note.id] {
            other.bringToFront(focus: true)
            return
        }
        let old = controller.note
        old.isOpen = false
        controllers[old.id] = nil
        openNoteIDs.remove(old.id)
        note.isOpen = true
        note.frame = controller.noteFrame
        controllers[note.id] = controller
        openNoteIDs.insert(note.id)
        controller.swap(to: note)
        if isDiscardable(old) { discard(old) }
        saveNow()
    }

    func controllerDidMove(_ controller: NoteController) {
        controller.note.frame = controller.noteFrame
        saveIndex()
    }

    func detach(_ controller: NoteController) {
        if controllers[controller.note.id] === controller { controllers[controller.note.id] = nil }
        openNoteIDs.remove(controller.note.id)
    }

    /// Hides every window at once, for the extension switching off.
    func dismissAll() {
        saveNow()
        controllers.values.forEach { $0.dismiss() }
        for controller in controllers.values where isDiscardable(controller.note) { discard(controller.note) }
        saveIndex()
        controllers.removeAll()
        openNoteIDs.removeAll()
    }

    var openControllers: [NoteController] { Array(controllers.values) }

    func controller(for note: Note) -> NoteController? { controllers[note.id] }

    func applyWindowPreferences() {
        controllers.values.forEach { $0.applyPreferences() }
    }

    // MARK: Spaces

    /// Which space the notch shows, and where new notes from it go. Notes
    /// already on screen stay, whatever space they're in.
    func switchSpace(to id: UUID) {
        guard id != activeSpaceID, spaces.contains(where: { $0.id == id }) else { return }
        withAnimation(NoteMotion.content) { activeSpaceID = id }
        saveIndex()
        tick()
    }

    @discardableResult
    func addSpace(named name: String) -> NoteSpace {
        let space = NoteSpace(id: UUID(), name: name)
        withAnimation(NoteMotion.content) { spaces.append(space) }
        saveIndex()
        return space
    }

    func rename(_ space: NoteSpace, to name: String) {
        guard let index = spaces.firstIndex(of: space), !name.isEmpty else { return }
        let old = spaces[index].name
        spaces[index].name = name
        // The space's folder in iCloud follows its name, and its notes' paths with it.
        let from = CloudSync.fileName(old) + "/", to = CloudSync.fileName(name) + "/"
        if from != to {
            cloud?.renameFolder(from: old, to: name)
            for note in notes where note.spaceID == space.id {
                if let path = note.cloudPath, path.hasPrefix(from) { note.cloudPath = to + path.dropFirst(from.count) }
            }
        }
        saveIndex()
    }

    /// Deletes a space and puts its notes in the Trash.
    func delete(_ space: NoteSpace) {
        guard spaces.count > 1 else { return }
        if space.id == activeSpaceID, let other = spaces.first(where: { $0.id != space.id }) {
            switchSpace(to: other.id)
        }
        for note in notes where note.spaceID == space.id {
            if let controller = controllers[note.id] {
                detach(controller)
                controller.hide(to: NotePlacement.notchPoint)
            }
            trash(note)
        }
        cloud?.removeFolder(space.name)
        withAnimation(NoteMotion.content) { spaces.removeAll { $0.id == space.id } }
        saveIndex()
    }

    /// A note changes space and stays where it is on screen.
    func move(_ note: Note, to space: NoteSpace) {
        guard note.spaceID != space.id else { return }
        withAnimation(NoteMotion.content) { note.spaceID = space.id }
        push(note)
        saveIndex()
    }

    func togglePin(_ note: Note) {
        withAnimation(NoteMotion.content) { note.isPinned.toggle() }
        saveIndex()
    }

    /// Hides or brings back the active space's notes.
    /// `focusing` gives the keys to the note on top as they come back, and
    /// opens a fresh note when the space has none to bring back: what the
    /// global shortcut wants, so you can type straight away.
    /// Every floating note, from every space, folds away or comes back.
    func toggleVisibility(focusing: Bool = false) {
        let open = Array(controllers.values)
        if open.isEmpty {
            var returning = notes.filter(\.isOpen).sorted { $0.modified > $1.modified }
            // Every note closed: the latest one comes back. A new note only
            // when there are none at all.
            if returning.isEmpty, focusing {
                guard let latest = notes.max(by: { $0.modified < $1.modified }) else {
                    newNote()
                    return
                }
                returning = [latest]
            }
            // Most recent last, so it lands on top and takes the keys.
            for (index, note) in returning.reversed().enumerated() {
                show(note, from: NotePlacement.notchPoint, focus: focusing && note.id == returning.first?.id,
                     delay: Double(index) * 0.035)
            }
        } else {
            for (index, controller) in open.enumerated() {
                detach(controller)
                controller.hide(to: NotePlacement.notchPoint, delay: Double(index) * 0.025)
                if isDiscardable(controller.note) { discard(controller.note) }
            }
            saveIndex()
        }
    }

    var hasVisibleNotes: Bool { !openNoteIDs.isEmpty }

    /// Where a note sits among its space's notes, counting from 1.
    func position(of note: Note) -> (index: Int, count: Int)? {
        let list = notes(in: note.spaceID)
        guard let index = list.firstIndex(where: { $0.id == note.id }) else { return nil }
        return (index + 1, list.count)
    }

    /// ⌘[ and ⌘]: the window steps through its space's notes, passing over
    /// ones open in windows of their own.
    func cycle(_ controller: NoteController, by step: Int) {
        let list = notes(in: controller.note.spaceID)
        guard let current = list.firstIndex(where: { $0.id == controller.note.id }) else { return }
        var index = current
        for _ in 0..<list.count {
            index = (index + step + list.count) % list.count
            guard index != current else { break }
            if controllers[list[index].id] == nil {
                swap(controller, to: list[index])
                return
            }
        }
        NSSound.beep()
    }

    // MARK: Deleting

    /// Moves a note and its bucket to the Trash, where it can be put back by hand.
    func delete(_ note: Note) {
        if let controller = controllers[note.id] {
            detach(controller)
            controller.hide(to: NotePlacement.notchPoint)
        }
        if let path = note.cloudPath { cloud?.remove(path: path) }
        trash(note)
        saveIndex()
    }

    func trash(_ note: Note) {
        dirtyBodies.remove(note.id)
        let body = bodyURL(for: note.id)
        if note.hasText {
            // Named after its title in the Trash, not its identifier.
            let named = root.appendingPathComponent("\(note.displayTitle.replacingOccurrences(of: "/", with: "-")).md")
            if (try? FileManager.default.moveItem(at: body, to: named)) != nil {
                try? FileManager.default.trashItem(at: named, resultingItemURL: nil)
            } else {
                try? FileManager.default.trashItem(at: body, resultingItemURL: nil)
            }
        } else {
            try? FileManager.default.removeItem(at: body)
        }
        let bucket = bucketFolder(for: note)
        if FileManager.default.fileExists(atPath: bucket.path) {
            try? FileManager.default.trashItem(at: bucket, resultingItemURL: nil)
        }
        withAnimation(NoteMotion.content) { notes.removeAll { $0.id == note.id } }
    }

    /// No text, and nothing in its bucket on disk: not the list in memory,
    /// which misses files added in Finder or still being copied.
    private func isDiscardable(_ note: Note) -> Bool {
        !note.hasText && Attachments.list(bucketFolder(for: note)).isEmpty
            && !Attachments.isCopying(into: bucketFolder(for: note))
    }

    /// An empty note leaves nothing behind.
    private func discard(_ note: Note) {
        if let path = note.cloudPath { cloud?.remove(path: path) }
        dirtyBodies.remove(note.id)
        try? FileManager.default.removeItem(at: bodyURL(for: note.id))
        let bucket = bucketFolder(for: note)
        if FileManager.default.fileExists(atPath: bucket.path) {
            try? FileManager.default.trashItem(at: bucket, resultingItemURL: nil)
        }
        notes.removeAll { $0.id == note.id }
    }
}

/// Where notes go on screen.
@MainActor
enum NotePlacement {
    static var screen: NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// The notch of the screen the pointer is on, where notes come from and go back to.
    static var notchPoint: CGPoint {
        let screen = screen
        let inset = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness)
        return CGPoint(x: screen.frame.midX, y: screen.frame.maxY - inset / 2)
    }

    /// Beside the parent if there's room, else under the notch, stepping
    /// down and across past notes already there.
    static func frame(beside parent: CGRect?, avoiding others: [CGRect]) -> CGRect {
        let size = NoteGeometry.defaultSize
        let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        if let parent {
            let right = CGRect(x: parent.maxX + 16, y: parent.maxY - size.height, width: size.width, height: size.height)
            if visible.contains(right), !others.contains(where: { $0.intersects(right) }) { return right }
            let left = CGRect(x: parent.minX - 16 - size.width, y: parent.maxY - size.height, width: size.width, height: size.height)
            if visible.contains(left), !others.contains(where: { $0.intersects(left) }) { return left }
        }
        var frame = CGRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 8, width: size.width, height: size.height)
        if let parent {
            frame.origin = CGPoint(x: parent.minX + 28, y: parent.minY - 28 + parent.height - size.height)
        }
        var guardCount = 0
        while others.contains(where: { abs($0.minX - frame.minX) < 20 && abs($0.maxY - frame.maxY) < 20 }), guardCount < 12 {
            frame.origin.x += 28
            frame.origin.y -= 28
            guardCount += 1
        }
        return clamped(frame)
    }

    static func clamped(_ frame: CGRect) -> CGRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? self.screen
        let visible = screen.visibleFrame
        var frame = frame
        frame.size.width = min(frame.width, visible.width - 12)
        frame.size.height = min(frame.height, visible.height - 12)
        frame.origin.x = min(max(frame.minX, visible.minX + 6), visible.maxX - frame.width - 6)
        frame.origin.y = min(max(frame.minY, visible.minY + 6), visible.maxY - frame.height - 6)
        return frame
    }
}
