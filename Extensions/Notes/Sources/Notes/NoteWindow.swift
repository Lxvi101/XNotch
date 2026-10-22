import AppKit
import Observation
import QuartzCore
import SwiftUI

enum NoteGeometry {
    static let defaultSize = CGSize(width: 330, height: 360)
    static let minSize = CGSize(width: 240, height: 180)
    static let cornerRadius: CGFloat = 22
    /// Transparent border around the note inside its window, for the shadow
    /// SwiftUI draws: it scales with the note, where a window shadow would pop.
    static let margin: CGFloat = 26
    static let header: CGFloat = 40

    static func windowFrame(forNote rect: CGRect) -> CGRect { rect.insetBy(dx: -margin, dy: -margin) }
    static func noteFrame(inWindow rect: CGRect) -> CGRect { rect.insetBy(dx: margin, dy: margin) }
}

/// One motion vocabulary for every part of a note.
enum NoteMotion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Out of the notch: a long throw, so a touch of overshoot is earned.
    static var appear: Animation { reduced ? .easeOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.84) }
    /// Back into the notch: decisive, no bounce.
    static var disappear: Animation { reduced ? .easeIn(duration: 0.16) : .spring(response: 0.32, dampingFraction: 1) }
    static var content: Animation { reduced ? .easeInOut(duration: 0.18) : .spring(response: 0.34, dampingFraction: 0.86) }
    /// The bucket and switcher blooming open, and folding back.
    static var bloom: Animation { reduced ? .easeInOut(duration: 0.18) : .spring(response: 0.38, dampingFraction: 0.82) }
    static var hover: Animation { reduced ? .easeOut(duration: 0.12) : .spring(response: 0.24, dampingFraction: 0.82) }
}

/// What the note's SwiftUI chrome reads. Each view reads only its part.
@MainActor @Observable
final class NoteWindowState {
    /// The note the window shows; the switcher can change it.
    var note: Note
    var isHovered = false
    var isKey = false
    var showsBucket = false { didSet { if showsBucket != oldValue { onTextFocusChange?() } } }
    var showsSwitcher = false { didSet { if showsSwitcher != oldValue { onTextFocusChange?() } } }
    var isDragTarget = false
    /// Blurs the text out and back while the window changes notes.
    var isSwapping = false { didSet { if isSwapping != oldValue { onTextFocusChange?() } } }
    /// The text behind the bucket and the switcher is dimmed on its own layer, not by SwiftUI.
    @ObservationIgnored var onTextFocusChange: (() -> Void)?
    var selectedAttachment: String?
    /// Files flying from where they were dropped into the bucket.
    var landings: [Landing] = []
    /// Bumped as each file lands, so the bucket can take the hit.
    var bucketHits = 0
    /// The bucket's centre in the note, where landings head.
    @ObservationIgnored var bucketCenter = CGPoint(x: 260, y: 20)
    /// The plus button's centre in the note, where new notes come from.
    @ObservationIgnored var plusCenter = CGPoint(x: 310, y: 20)

    struct Landing: Identifiable {
        let id = UUID()
        let image: NSImage
        let start: CGPoint
        let delay: Double
    }

    var receded: Bool { showsBucket || showsSwitcher }
    /// "2 of 5", shown in place of the title for a moment as a note opens.
    var positionLabel: String?
    /// The `@` picker, while it's up.
    var mention: MentionState?

    init(note: Note) {
        self.note = note
    }
}

/// A borderless panel that floats without activating XNotch, yet takes the
/// keyboard: typing goes to the note while the frontmost app stays frontmost.
final class NotePanel: NSPanel {
    var onKeyDown: ((NSEvent) -> Bool)?
    var onKeyChange: ((Bool) -> Void)?

    init() {
        super.init(contentRect: NoteGeometry.windowFrame(forNote: CGRect(origin: .zero, size: NoteGeometry.defaultSize)),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKeyDown?(event) == true { return }
        super.sendEvent(event)
    }

    override func becomeKey() {
        super.becomeKey()
        onKeyChange?(true)
    }

    override func resignKey() {
        super.resignKey()
        onKeyChange?(false)
    }
}

/// One sticky note on screen.
@MainActor
final class NoteController: NSObject {
    var note: Note { state.note }
    let panel = NotePanel()
    let state: NoteWindowState
    let editor = MarkdownEditor()
    let switcher: SwitcherModel
    private unowned let library: NoteLibrary
    private(set) var isClosing = false
    private var dismissedMentionLocation: Int?

    init(note: Note, library: NoteLibrary) {
        state = NoteWindowState(note: note)
        self.library = library
        switcher = SwitcherModel(library: library)
        super.init()
        switcher.commandSource = { [weak self] in self?.commands() ?? [] }
        let dropView = NoteDropView(frame: CGRect(origin: .zero, size: panel.frame.size))
        dropView.wantsLayer = true
        dropView.controller = self
        let hosting = NoteHostingView(rootView: NoteRootView(controller: self, state: state))
        hosting.frame = dropView.bounds
        hosting.autoresizingMask = [.width, .height]
        dropView.addSubview(hosting)
        panel.contentView = dropView
        panel.onKeyDown = { [weak self] event in self?.handleKey(event) ?? false }
        panel.onKeyChange = { [weak self] isKey in
            guard let self else { return }
            withAnimation(NoteMotion.hover) { self.state.isKey = isKey }
            self.editor.textView.updateActiveRange()
        }
        editor.textView.fileHandler = self
        editor.base = library.bucketFolder(for: note)
        editor.load(note.text)
        editor.onCaretMove = { [weak self] in self?.updateMention() }
        state.onTextFocusChange = { [weak self] in self?.updateTextFocus() }
        editor.onChange = { [weak self] text in
            guard let self, !self.isClosing else { return }
            self.note.update(text: text)
            self.library.noteChanged(self.note)
        }
        applyPreferences()
    }

    func applyPreferences() {
        editor.apply(library.preferences.editorOptions)
        panel.level = library.preferences.floatsOnTop ? .floating : .normal
        panel.collectionBehavior = library.preferences.onAllDesktops
            ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.moveToActiveSpace, .fullScreenAuxiliary]
    }

    var noteFrame: CGRect { NoteGeometry.noteFrame(inWindow: panel.frame) }

    /// Where a note made with this one's plus button comes from, on screen.
    var newNoteSource: CGPoint {
        let frame = NoteGeometry.noteFrame(inWindow: panel.frame)
        return CGPoint(x: frame.minX + state.plusCenter.x, y: frame.maxY - state.plusCenter.y)
    }

    // MARK: Showing and hiding

    /// Fades in where the note was, its text coming into focus. Nothing
    /// travels: a moving window and the glass behind it can't keep up with a
    /// spring, and a fade never asks them to. `source` is where it was opened
    /// from, kept for callers; the note appears in its own place.
    func show(from source: CGPoint?, focus: Bool, delay: TimeInterval = 0) {
        let frame = NotePlacement.clamped(note.frame ?? NotePlacement.frame(beside: nil, avoiding: []))
        note.frame = frame
        panel.setFrame(NoteGeometry.windowFrame(forNote: frame), display: false)
        // Laid out and drawn before the first frame, so the fade only blends
        // pixels that exist.
        panel.contentView?.layoutSubtreeIfNeeded()
        if let container = editor.textView.textContainer { editor.textView.layoutManager?.ensureLayout(for: container) }
        panel.alphaValue = 0
        panel.displayIfNeeded()
        let present = { [weak self] in
            guard let self, !self.isClosing else { return }
            self.panel.orderFrontRegardless()
            if focus {
                self.panel.makeKey()
                self.editor.focus(atEnd: true)
            }
            self.fade(in: true)
            self.flashPosition()
        }
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { present() } }
        } else {
            present()
        }
    }

    /// Fades out where it is, its text blurring away, and goes.
    func hide(to point: CGPoint, delay: TimeInterval = 0) {
        guard !isClosing else { return }
        isClosing = true
        let leave = { [weak self] in
            guard let self else { return }
            self.panel.makeFirstResponder(nil)
            self.panel.ignoresMouseEvents = true
            self.fade(in: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeOut + 0.02) {
                MainActor.assumeIsolated { self.dismiss() }
            }
        }
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { leave() } }
        } else {
            leave()
        }
    }

    private static let fadeIn: TimeInterval = 0.22
    private static let fadeOut: TimeInterval = 0.16

    /// The window's alpha, which the window server blends glass and all, and
    /// a blur on the text alone, which the GPU animates; the blur comes off
    /// once the note is at rest, so typing never pays for it.
    private func fade(in appearing: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = appearing ? Self.fadeIn : Self.fadeOut
            context.timingFunction = CAMediaTimingFunction(name: appearing ? .easeOut : .easeIn)
            panel.animator().alphaValue = appearing ? 1 : 0
        }
        if appearing {
            editor.setFocus(blur: 0, opacity: 1, duration: Self.fadeIn + 0.04, from: (7, 1))
        } else {
            editor.setFocus(blur: 7, opacity: 1, duration: Self.fadeOut, easeIn: true)
        }
    }

    /// Behind the bucket or the switcher the text recedes; while the window
    /// changes notes it blurs out and back.
    private func updateTextFocus() {
        if state.receded {
            editor.setFocus(blur: 8, opacity: 0.35, duration: 0.3)
        } else if state.isSwapping {
            editor.setFocus(blur: 6, opacity: 0, duration: 0.1, easeIn: true)
        } else {
            editor.setFocus(blur: 0, opacity: 1, duration: 0.28)
        }
    }

    /// Off screen at once, and let go: the hosted view holds this controller,
    /// so the panel would otherwise keep it alive.
    func dismiss() {
        panel.orderOut(nil)
        panel.contentView = nil
        panel.onKeyDown = nil
        panel.onKeyChange = nil
        editor.onChange = nil
    }

    func bringToFront(focus: Bool) {
        panel.orderFrontRegardless()
        if focus {
            panel.makeKey()
            editor.focus(atEnd: false)
        }
        // Shows its chrome for a moment, so it's clear which note answered.
        withAnimation(NoteMotion.hover) { state.isHovered = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, (self.panel.contentView as? NoteDropView)?.isPointerInside != true else { return }
                withAnimation(NoteMotion.hover) { self.state.isHovered = false }
            }
        }
    }

    /// Changes notes in place: the text goes out of focus and the new note's comes into it.
    func swap(to note: Note) {
        library.saveNow()
        withAnimation(.easeIn(duration: NoteMotion.reduced ? 0.08 : 0.1)) { state.isSwapping = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.state.note = note
                self.state.selectedAttachment = nil
                self.editor.base = self.library.bucketFolder(for: note)
                self.editor.load(note.text)
                self.library.refreshAttachments(of: note)
                withAnimation(NoteMotion.content) { self.state.isSwapping = false }
                self.editor.focus(atEnd: true)
                self.flashPosition()
            }
        }
    }

    func close() {
        library.close(note)
    }

    /// The note's space, for its header while there's more than one.
    var spaceName: String? {
        guard library.spaces.count > 1 else { return nil }
        return library.spaces.first { $0.id == note.spaceID }?.name
    }

    // MARK: Command bar

    /// What `>` in the switcher offers, for this note as it is now.
    private func commands() -> [NoteCommand] {
        let note = self.note
        let text = editor.textView
        let hasDone = note.text.range(of: #"(?m)^[ \t]*[-*+][ \t]+\[[xX]\]"#, options: .regularExpression) != nil
        var list: [NoteCommand] = [
            NoteCommand(id: "new", title: "New Note", symbol: "square.and.pencil", shortcut: "⌘N", section: "Note") { [weak self] in
                self?.newNote()
            },
            NoteCommand(id: "duplicate", title: "Duplicate Note", symbol: "plus.square.on.square", section: "Note") { [weak self] in
                guard let self else { return }
                self.library.duplicate(note, beside: self)
            },
            NoteCommand(id: "pin", title: note.isPinned ? "Unpin Note" : "Pin Note", symbol: note.isPinned ? "pin.slash" : "pin",
                        section: "Note") { [weak self] in self?.library.togglePin(note) },
            NoteCommand(id: "copy-md", title: "Copy as Markdown", symbol: "doc.on.doc", section: "Note") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(note.text, forType: .string)
            },
            NoteCommand(id: "copy-plain", title: "Copy as Plain Text", symbol: "text.alignleft", section: "Note") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(TaskText.plain(note.text), forType: .string)
            },
            NoteCommand(id: "export", title: "Export Markdown…", symbol: "square.and.arrow.up", section: "Note") { [weak self] in
                self?.exportMarkdown()
            },
        ]
        if let file = library.cloudFile(for: note) {
            list.append(NoteCommand(id: "reveal-cloud", title: "Show in iCloud Drive", symbol: "icloud", section: "Note") {
                NSWorkspace.shared.activateFileViewerSelecting([file])
            })
        }
        list += [
            NoteCommand(id: "close", title: "Close Note", symbol: "xmark", shortcut: "⌘W", section: "Note") { [weak self] in
                self?.close()
            },
            NoteCommand(id: "trash", title: "Move Note to Trash", symbol: "trash", shortcut: "⇧⌘⌫", section: "Note",
                        isDestructive: true) { [weak self] in
                guard let self else { return }
                self.library.delete(self.note)
            },
            NoteCommand(id: "bucket", title: "Open Bucket", symbol: "tray", shortcut: "⇧⌘B", section: "Bucket") { [weak self] in
                self?.toggleBucket()
            },
            NoteCommand(id: "bucket-add", title: "Add Files to Bucket…", symbol: "plus.rectangle.on.folder", section: "Bucket") { [weak self] in
                self?.addFilesWithPanel()
            },
            NoteCommand(id: "bucket-reveal", title: "Show Bucket in Finder", symbol: "folder", section: "Bucket") { [weak self] in
                self?.revealBucket()
            },
        ]
        if hasDone {
            list += [
                NoteCommand(id: "tasks-clear", title: "Clear Completed Tasks", symbol: "checklist.checked", section: "Tasks") {
                    text.rewrite(TaskText.clearingCompleted)
                },
                NoteCommand(id: "tasks-sort", title: "Move Completed Tasks to Bottom", symbol: "arrow.down.to.line",
                            section: "Tasks") { text.rewrite(TaskText.sortingCompleted) },
                NoteCommand(id: "tasks-uncheck", title: "Uncheck All Tasks", symbol: "square", section: "Tasks") {
                    text.rewrite(TaskText.uncheckingAll)
                },
            ]
        }
        let today = Date().formatted(date: .complete, time: .omitted)
        list += [
            NoteCommand(id: "insert-task", title: "Insert Checklist Item", symbol: "checklist", shortcut: "⌘L", section: "Insert") {
                text.toggleTask()
            },
            NoteCommand(id: "insert-code", title: "Insert Code Block", symbol: "chevron.left.forwardslash.chevron.right",
                        section: "Insert") { text.insertBlock("```\n\n```\n", caretOffset: 4) },
            NoteCommand(id: "insert-rule", title: "Insert Divider", symbol: "minus", section: "Insert") {
                text.insertBlock("---\n")
            },
            NoteCommand(id: "insert-date", title: "Insert Today's Date", symbol: "calendar", section: "Insert") {
                text.insertText(today, replacementRange: text.selectedRange())
            },
        ]
        for space in library.spaces where space.id != note.spaceID {
            list.append(NoteCommand(id: "move-\(space.id)", title: "Move to “\(space.name)”", symbol: "arrow.right.square",
                                    section: "Spaces") { [weak self] in self?.library.move(note, to: space) })
        }
        list.append(NoteCommand(id: "space-new", title: "New Space…", symbol: "plus.square", section: "Spaces") { [weak self] in
            guard let self, let name = ask("New Space", message: "A space groups notes, like a folder. Notes from any space can be open together.",
                                           value: "", placeholder: "Work", button: "Create") else { return }
            let space = self.library.addSpace(named: name)
            self.library.switchSpace(to: space.id)
        })
        let onTop = library.preferences.floatsOnTop
        list += [
            NoteCommand(id: "float", title: onTop ? "Stop Keeping Notes on Top" : "Keep Notes Above Other Windows",
                        symbol: onTop ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle", section: "Window") { [weak self] in
                self?.library.preferences.floatsOnTop.toggle()
            },
            NoteCommand(id: "settings", title: "Notes Settings…", symbol: "gearshape", section: "Window") { [weak self] in
                self?.library.openSettings()
            },
        ]
        return list
    }

    private func exportMarkdown() {
        let save = NSSavePanel()
        save.nameFieldStringValue = CloudSync.fileName(note.displayTitle) + ".md"
        save.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        NSApp.activate(ignoringOtherApps: true)
        guard save.runModal() == .OK, let url = save.url else { return }
        try? note.text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Text that came from iCloud, shown without disturbing where you are.
    func showRemoteText(_ text: String) {
        editor.replaceText(text)
    }

    /// Shows where the note sits in the ⌘[ / ⌘] cycle, then the title again.
    private func flashPosition() {
        guard library.preferences.showNotePosition, let position = library.position(of: note), position.count > 1 else { return }
        let label = "\(position.index) of \(position.count)"
        withAnimation(NoteMotion.content) { state.positionLabel = label }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.state.positionLabel == label else { return }
                withAnimation(NoteMotion.content) { self.state.positionLabel = nil }
            }
        }
    }

    func setHovered(_ hovered: Bool) {
        guard state.isHovered != hovered else { return }
        withAnimation(NoteMotion.hover) { state.isHovered = hovered }
    }

    // MARK: Bucket and switcher

    func toggleBucket() {
        if !state.showsBucket { library.refreshAttachments(of: note) }
        withAnimation(NoteMotion.bloom) {
            state.showsSwitcher = false
            state.showsBucket.toggle()
            state.selectedAttachment = nil
        }
        // Typing goes nowhere while the text is behind the drawer.
        if state.showsBucket { panel.makeFirstResponder(nil) } else { editor.focus(atEnd: false) }
    }

    func toggleSwitcher(commands: Bool = false) {
        if !state.showsSwitcher {
            panel.makeKey()
            switcher.prepare(current: note, commands: commands)
        }
        withAnimation(NoteMotion.bloom) {
            state.showsBucket = false
            state.showsSwitcher.toggle()
        }
        if !state.showsSwitcher { editor.focus(atEnd: false) }
    }

    func openFromSwitcher(_ target: Note, inNewWindow: Bool) {
        withAnimation(NoteMotion.bloom) { state.showsSwitcher = false }
        if inNewWindow || library.controller(for: target) != nil {
            library.open(target, from: newNoteSource)
        } else {
            library.swap(self, to: target)
        }
    }

    func newNote() {
        withAnimation(NoteMotion.bloom) {
            state.showsSwitcher = false
            state.showsBucket = false
        }
        library.newNote(beside: self)
    }

    // MARK: Moving and resizing

    func beginMove() {
        panel.makeKey()
    }

    /// Keeps the note's top under the menu bar, as a system window move would.
    func move(to origin: CGPoint) {
        var origin = origin
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
            origin.y = min(origin.y, screen.visibleFrame.maxY - panel.frame.height + NoteGeometry.margin)
        }
        panel.setFrameOrigin(origin)
    }

    func endMove() {
        library.controllerDidMove(self)
    }

    /// Resizes from the bottom-right corner, keeping the top-left still.
    func resize(from start: CGRect, by delta: CGSize) {
        let width = max(NoteGeometry.minSize.width, start.width + delta.width)
        let height = max(NoteGeometry.minSize.height, start.height - delta.height)
        let note = CGRect(x: start.minX, y: start.maxY - height, width: width, height: height)
        panel.setFrame(NoteGeometry.windowFrame(forNote: note), display: true)
    }

    // MARK: Keys

    private func handleKey(_ event: NSEvent) -> Bool {
        // A note on its way out takes nothing more.
        if isClosing { return true }
        if state.mention != nil, handleMentionKey(event) { return true }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if state.showsSwitcher, switcher.handle(event, open: { [weak self] note, newWindow in
            self?.openFromSwitcher(note, inNewWindow: newWindow)
        }, close: { [weak self] in self?.toggleSwitcher() }) {
            return true
        }
        if event.keyCode == 53 { // escape
            if state.showsBucket { toggleBucket(); return true }
            return false
        }
        if state.showsBucket, handleBucketKey(event, modifiers: modifiers) { return true }
        guard modifiers.contains(.command) else { return false }
        // ⌘[ and ⌘], by the key or by the character: on a German keyboard "[" is ⌥5.
        let typed = event.characters ?? ""
        if !state.receded, modifiers.isSubset(of: [.command, .option]) {
            if (modifiers == [.command] && event.keyCode == 33) || typed == "[" { library.cycle(self, by: -1); return true }
            if (modifiers == [.command] && event.keyCode == 30) || typed == "]" { library.cycle(self, by: 1); return true }
        }
        // ⇧⌘⌫: this note to the Trash, its bucket with it.
        if event.keyCode == 51, modifiers == [.command, .shift] {
            library.delete(note)
            return true
        }
        let text = editor.textView
        // Formatting is for the text, not the search field or the drawer over it.
        let editing = !state.receded
        let responder = panel.firstResponder
        switch (key, modifiers) {
        case ("c", [.command]): responder?.tryToPerform(#selector(NSText.copy(_:)), with: nil)
        case ("x", [.command]): responder?.tryToPerform(#selector(NSText.cut(_:)), with: nil)
        case ("v", [.command]): responder?.tryToPerform(#selector(NSText.paste(_:)), with: nil)
        case ("v", [.command, .shift]), ("v", [.command, .shift, .option]):
            responder?.tryToPerform(#selector(NSTextView.pasteAsPlainText(_:)), with: nil)
        case ("a", [.command]): responder?.tryToPerform(#selector(NSText.selectAll(_:)), with: nil)
        case ("z", [.command]): panel.firstResponder?.undoManager?.undo()
        case ("z", [.command, .shift]): panel.firstResponder?.undoManager?.redo()
        case ("b", [.command]) where editing: text.toggleWrap("**")
        case ("i", [.command]) where editing: text.toggleWrap("*")
        case ("e", [.command]) where editing: text.toggleWrap("`")
        case ("x", [.command, .shift]) where editing: text.toggleWrap("~~")
        case ("l", [.command]) where editing: text.toggleTask()
        case ("k", [.command]), ("p", [.command]): toggleSwitcher()
        case ("p", [.command, .shift]), ("k", [.command, .shift]): toggleSwitcher(commands: true)
        case ("b", [.command, .shift]): toggleBucket()
        case ("n", [.command]): newNote()
        case ("w", [.command]): close()
        default: return false
        }
        return true
    }

    private var selectedAttachmentURL: URL? {
        note.attachments.first { $0.id == state.selectedAttachment }?.url
    }
}

// MARK: Files

extension NoteController: NoteFileHandling {
    func fileDragMoved(_ info: NSDraggingInfo) -> NSDragOperation {
        // A file on its way out of the bucket isn't a drop for this note.
        if (info.draggingSource as AnyObject?) === self {
            fileDragEnded()
            return []
        }
        if !state.isDragTarget {
            withAnimation(NoteMotion.hover) { state.isDragTarget = true }
        }
        return .copy
    }

    func fileDragEnded() {
        guard state.isDragTarget else { return }
        withAnimation(NoteMotion.hover) { state.isDragTarget = false }
    }

    func fileDropped(_ info: NSDraggingInfo) -> Bool {
        // The note's own bucket files dropped beside the text: not copies of themselves.
        guard bucketFiles(on: info.draggingPasteboard).isEmpty else {
            fileDragEnded()
            return false
        }
        let window = info.draggingLocation
        let point = CGPoint(x: window.x - NoteGeometry.margin, y: panel.frame.height - window.y - NoteGeometry.margin)
        attach(from: info.draggingPasteboard, at: point)
        fileDragEnded()
        return true
    }

    /// Copies the pasteboard's files into the bucket. They fly in from
    /// `point` in the note, or from the middle of the text when pasted.
    func attach(from pasteboard: NSPasteboard, at point: CGPoint?) {
        let sources = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let images = sources.isEmpty ? [NSImage(named: NSImage.multipleDocumentsName) ?? NSImage()]
            : sources.prefix(3).map { Thumbnails.icon(for: $0.path) }
        let size = NoteGeometry.noteFrame(inWindow: panel.frame).size
        launch(images, from: point ?? CGPoint(x: size.width / 2, y: size.height / 2))
        Attachments.read(pasteboard, into: library.bucketFolder(for: note)) { [weak self] urls in
            self?.received(urls)
        }
    }

    func bucketFiles(on pasteboard: NSPasteboard) -> [URL] {
        let bucket = library.bucketFolder(for: note).standardizedFileURL.path + "/"
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty, urls.allSatisfy({ $0.standardizedFileURL.path.hasPrefix(bucket) }) else { return [] }
        return urls
    }

    /// Bucket files into the text at `index`: pictures on lines of their own, as previews.
    func insertReferences(_ urls: [URL], at index: Int) {
        let text = editor.textView
        let string = text.string as NSString
        let location = min(index, string.length)
        let lineStart = string.lineRange(for: NSRange(location: location, length: 0)).location
        var pieces: [String] = []
        for url in urls {
            let markup = Attachments.markdown(for: url)
            pieces.append(markup.hasPrefix("!") ? markup + "\n" : markup + " ")
        }
        var insertion = pieces.joined()
        if insertion.hasPrefix("!"), location != lineStart { insertion = "\n" + insertion }
        text.replace(NSRange(location: location, length: 0), with: insertion)
        text.setSelectedRange(NSRange(location: location + (insertion as NSString).length, length: 0))
        panel.makeKey()
        editor.focus(atEnd: false)
    }

    func sendToTray(_ urls: [URL]) {
        library.sendToTray(urls)
    }

    func attach(_ urls: [URL]) {
        let size = NoteGeometry.noteFrame(inWindow: panel.frame).size
        launch(urls.prefix(3).map { Thumbnails.icon(for: $0.path) }, from: CGPoint(x: size.width / 2, y: size.height * 0.6))
        Attachments.copy(urls, into: library.bucketFolder(for: note)) { [weak self] copied in self?.received(copied) }
    }

    private func launch(_ images: [NSImage], from point: CGPoint) {
        let landings = images.enumerated().map { index, image in
            NoteWindowState.Landing(image: image, start: CGPoint(x: point.x + CGFloat(index) * 10, y: point.y - CGFloat(index) * 6),
                                    delay: Double(index) * 0.05)
        }
        state.landings.append(contentsOf: landings)
        for landing in landings {
            // The bucket takes each hit as it arrives.
            DispatchQueue.main.asyncAfter(deadline: .now() + landing.delay + (NoteMotion.reduced ? 0.05 : 0.36)) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.state.bucketHits += 1
                    self.state.landings.removeAll { $0.id == landing.id }
                }
            }
        }
    }

    private func received(_ urls: [URL]) {
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        withAnimation(NoteMotion.content) { library.refreshAttachments(of: note) }
        note.modified = Date()
        library.saveIndex()
        library.tick()
    }

    func removeAttachment(_ attachment: Attachment) {
        let files = note.attachments
        let index = files.firstIndex(of: attachment)
        try? FileManager.default.trashItem(at: attachment.url, resultingItemURL: nil)
        Thumbnails.forget([attachment.path])
        withAnimation(NoteMotion.content) {
            library.refreshAttachments(of: note)
            // The selection moves on to the next file, so Delete can keep going.
            if state.selectedAttachment == attachment.id {
                let remaining = note.attachments
                state.selectedAttachment = index.flatMap { remaining.isEmpty ? nil : remaining[min($0, remaining.count - 1)].id }
            }
        }
    }

    /// The bucket's keys: Delete trashes the selected file, arrows move the
    /// selection, Return opens it, Space shows it in Quick Look.
    private func handleBucketKey(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) -> Bool {
        let files = note.attachments
        let index = files.firstIndex { $0.id == state.selectedAttachment }
        switch (Int(event.keyCode), modifiers) {
        case (51, []), (51, [.command]), (117, []): // delete, ⌘⌫, forward delete
            guard let index else { return false }
            removeAttachment(files[index])
        case (49, []): // space
            guard let index else { return false }
            QuickLook.shared.toggle([files[index].url])
        case (36, []), (76, []): // return
            guard let index else { return false }
            NSWorkspace.shared.open(files[index].url)
        case (123, []), (126, []), (124, []), (125, []): // arrows
            guard !files.isEmpty else { return false }
            let forward = event.keyCode == 124 || event.keyCode == 125
            let next = index.map { min(max($0 + (forward ? 1 : -1), 0), files.count - 1) } ?? (forward ? 0 : files.count - 1)
            withAnimation(NoteMotion.hover) { state.selectedAttachment = files[next].id }
        default:
            return false
        }
        return true
    }

    func addFilesWithPanel() {
        let open = NSOpenPanel()
        open.allowsMultipleSelection = true
        open.canChooseDirectories = true
        open.prompt = "Add to Bucket"
        NSApp.activate(ignoringOtherApps: true)
        guard open.runModal() == .OK else { return }
        attach(open.urls)
    }

    func revealBucket() {
        let folder = library.bucketFolder(for: note)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let first = note.attachments.first {
            NSWorkspace.shared.activateFileViewerSelecting([first.url])
        } else {
            NSWorkspace.shared.open(folder)
        }
    }

    /// Writes a link to a bucket file into the text, at the caret: by name,
    /// since bare names point into the bucket. A picture goes on its own line
    /// and shows in the note.
    func insertLink(to attachment: Attachment) {
        withAnimation(NoteMotion.bloom) { state.showsBucket = false }
        editor.focus(atEnd: false)
        insertReferences([attachment.url], at: editor.textView.selectedRange().location)
    }

    // MARK: Mentions

    /// Opens, follows or closes the `@` picker as the caret moves.
    func updateMention() {
        let text = editor.textView
        let string = text.string as NSString
        let selection = text.selectedRange()
        guard text.isFocused, selection.length == 0, !state.receded,
              let found = MentionTrigger.find(in: string, caret: selection.location),
              found.range.location != dismissedMention, !isCode(at: found.range.location),
              let caret = caretInNote(at: found.range.location) else {
            if state.mention != nil { withAnimation(NoteMotion.hover) { state.mention = nil } }
            if let dismissed = dismissedMention, MentionTrigger.find(in: string, caret: selection.location)?.range.location != dismissed {
                dismissedMention = nil
            }
            return
        }
        let files = MentionState.matches(found.query, in: note.attachments)
        let selected = state.mention?.query == found.query ? state.mention?.selection ?? 0 : 0
        let mention = MentionState(range: found.range, query: found.query, files: files,
                                   selection: min(selected, max(0, files.count - 1)),
                                   caretTop: caret.minY, caretBottom: caret.maxY, x: caret.minX)
        if state.mention == nil {
            withAnimation(NoteMotion.bloom) { state.mention = mention }
        } else if state.mention != mention {
            state.mention = mention
        }
    }

    /// Escape closes the picker for this `@` until the caret leaves it.
    private var dismissedMention: Int? {
        get { dismissedMentionLocation }
        set { dismissedMentionLocation = newValue }
    }

    func selectMention(_ index: Int) {
        guard var mention = state.mention, mention.files.indices.contains(index), mention.selection != index else { return }
        mention.selection = index
        withAnimation(NoteMotion.hover) { state.mention = mention }
    }

    private func handleMentionKey(_ event: NSEvent) -> Bool {
        guard let mention = state.mention else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers.isEmpty || modifiers == [.shift] else { return false }
        switch event.keyCode {
        case 125: selectMention(min(mention.selection + 1, max(0, mention.files.count - 1)))
        case 126: selectMention(max(mention.selection - 1, 0))
        case 36, 76, 48: // return, enter, tab
            guard mention.files.indices.contains(mention.selection) else {
                closeMention()
                return event.keyCode == 48
            }
            insertMention(mention.files[mention.selection])
        case 53: closeMention()
        default: return false
        }
        return true
    }

    private func closeMention() {
        dismissedMention = state.mention?.range.location
        withAnimation(NoteMotion.hover) { state.mention = nil }
    }

    /// Replaces `@query` with the file: a picture alone on its line shows as a
    /// preview, with the caret moved below it; one among words, inline.
    func insertMention(_ file: Attachment) {
        guard let mention = state.mention else { return }
        withAnimation(NoteMotion.hover) { state.mention = nil }
        let text = editor.textView
        let string = text.string as NSString
        guard NSMaxRange(mention.range) <= string.length else { return }
        let markup = Attachments.markdown(for: file.url)
        let line = string.lineRange(for: NSRange(location: mention.range.location, length: 0))
        var contentsEnd = 0
        string.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: line)
        let before = string.substring(with: NSRange(location: line.location, length: mention.range.location - line.location))
        let after = string.substring(with: NSRange(location: NSMaxRange(mention.range), length: contentsEnd - NSMaxRange(mention.range)))
        let alone = markup.hasPrefix("!") && before.trimmingCharacters(in: .whitespaces).isEmpty
            && after.trimmingCharacters(in: .whitespaces).isEmpty
        if alone {
            let hasNextLine = contentsEnd < string.length
            text.replace(mention.range, with: markup + (hasNextLine ? "" : "\n"))
            let next = (text.string as NSString).lineRange(for: NSRange(location: mention.range.location, length: 0))
            text.setSelectedRange(NSRange(location: NSMaxRange(next), length: 0))
        } else {
            text.replace(mention.range, with: markup + " ")
            text.setSelectedRange(NSRange(location: mention.range.location + (markup as NSString).length + 1, length: 0))
        }
    }

    private func isCode(at index: Int) -> Bool {
        guard let storage = editor.textView.textStorage, index < storage.length else { return false }
        let attributes = storage.attributes(at: index, effectiveRange: nil)
        return attributes[.mdCodeSpan] != nil || attributes[.mdCodeBlock] != nil
    }

    /// The caret's rectangle at `index`, in the note's coordinates (top-left origin).
    private func caretInNote(at index: Int) -> CGRect? {
        let text = editor.textView
        guard let layout = text.markdownLayout, let container = text.textContainer, let content = panel.contentView,
              let rect = layout.insertionRect(at: index, in: container) else { return nil }
        let origin = text.textContainerOrigin
        let inText = rect.offsetBy(dx: origin.x, dy: origin.y)
        let inContent = text.convert(inText, to: content)
        let top = content.isFlipped ? inContent.minY : content.bounds.height - inContent.maxY
        return CGRect(x: inContent.minX - NoteGeometry.margin, y: top - NoteGeometry.margin,
                      width: inContent.width, height: inContent.height)
    }

    // MARK: Menus

    func menu(for attachment: Attachment) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Open", symbol: "arrow.up.forward.app") { NSWorkspace.shared.open(attachment.url) })
        menu.addItem(ClosureMenuItem("Quick Look", symbol: "eye") { QuickLook.shared.toggle([attachment.url]) })
        menu.addItem(ClosureMenuItem("Show in Finder", symbol: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([attachment.url])
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Insert in Note", symbol: "text.insert") { [weak self] in self?.insertLink(to: attachment) })
        menu.addItem(ClosureMenuItem("Copy", symbol: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([attachment.url as NSURL])
        })
        menu.addItem(ClosureMenuItem("Send to Tray", symbol: "tray.and.arrow.up") { [weak self] in
            self?.sendToTray([attachment.url])
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Remove from Bucket", symbol: "trash") { [weak self] in self?.removeAttachment(attachment) })
        return menu
    }

    func noteMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("New Note", symbol: "plus", key: "n") { [weak self] in self?.newNote() })
        menu.addItem(ClosureMenuItem("Find Note…", symbol: "magnifyingglass", key: "k") { [weak self] in self?.toggleSwitcher() })
        menu.addItem(ClosureMenuItem("Bucket", symbol: "tray") { [weak self] in self?.toggleBucket() })
        menu.addItem(.separator())
        let pin = ClosureMenuItem(note.isPinned ? "Unpin Note" : "Pin Note", symbol: "pin") { [weak self] in
            guard let self else { return }
            self.library.togglePin(self.note)
        }
        menu.addItem(pin)
        let spaces = NSMenuItem(title: "Move to Space", action: nil, keyEquivalent: "")
        spaces.image = NSImage(systemSymbolName: "square.stack", accessibilityDescription: nil)
        let submenu = NSMenu()
        for space in library.spaces {
            let item = ClosureMenuItem(space.name) { [weak self] in
                guard let self else { return }
                self.library.move(self.note, to: space)
            }
            item.state = space.id == note.spaceID ? .on : .off
            submenu.addItem(item)
        }
        spaces.submenu = submenu
        menu.addItem(spaces)
        menu.addItem(ClosureMenuItem("Copy Markdown", symbol: "doc.on.doc") { [weak self] in
            guard let self else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(self.note.text, forType: .string)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Close Note", symbol: "xmark", key: "w") { [weak self] in self?.close() })
        let delete = ClosureMenuItem("Move Note to Trash", symbol: "trash", key: "\u{8}") { [weak self] in
            guard let self else { return }
            self.library.delete(self.note)
        }
        delete.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(delete)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Notes Settings…", symbol: "gearshape") { [weak self] in self?.library.openSettings() })
        return menu
    }

    // MARK: Dragging out

    func beginDrag(_ attachment: Attachment, event: NSEvent, from view: NSView) {
        let side: CGFloat = 52
        let origin = view.convert(event.locationInWindow, from: nil)
        let item = NSDraggingItem(pasteboardWriter: attachment.url as NSURL)
        item.setDraggingFrame(NSRect(x: origin.x - side / 2, y: origin.y - side / 2, width: side, height: side),
                              contents: Thumbnails.image(for: attachment.path))
        let session = view.beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }
}

extension NoteController: NSDraggingSource {
    /// A bucket hands out copies: the note keeps its file.
    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .generic]
    }
}

// MARK: AppKit views

/// The panel's content view: takes file drops anywhere on the note and
/// tells it when the pointer is over it. The shadow margin doesn't count.
final class NoteDropView: NSView {
    weak var controller: NoteController?
    private(set) var isPointerInside = false

    override var isFlipped: Bool { true }

    private var noteRect: CGRect { bounds.insetBy(dx: NoteGeometry.margin, dy: NoteGeometry.margin) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(Attachments.fileTypes)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: noteRect, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        MainActor.assumeIsolated { controller?.setHovered(true) }
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        MainActor.assumeIsolated { controller?.setHovered(false) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        MainActor.assumeIsolated { controller?.fileDragEnded() }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard noteRect.contains(convert(sender.draggingLocation, from: nil)) else { return false }
        return MainActor.assumeIsolated { controller?.fileDropped(sender) ?? false }
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        MainActor.assumeIsolated { controller?.fileDragEnded() }
    }

    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
        let inside = noteRect.contains(convert(sender.draggingLocation, from: nil))
        return MainActor.assumeIsolated {
            guard let controller else { return [] }
            guard inside else {
                controller.fileDragEnded()
                return []
            }
            return controller.fileDragMoved(sender)
        }
    }
}

/// SwiftUI hosting that takes the first click, so a note that isn't key
/// still reacts at once, and leaves drops to `NoteDropView`.
final class NoteHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        unregisterDraggedTypes()
    }

    @MainActor required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
