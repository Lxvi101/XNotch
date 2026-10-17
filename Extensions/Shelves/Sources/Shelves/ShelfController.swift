import AppKit
import Combine
import SwiftUI

/// One shelf on screen: its panel, the label above it, drops onto it, drags
/// out of it and its menu.
@MainActor
final class ShelfController: NSObject {
    let shelf: Shelf
    let panel: ShelfPanel
    /// Set when the shelf shows new files from a watched folder.
    var watchedFolderID: UUID?
    private let labelPanel = ActionLabelPanel()
    private unowned let library: ShelfLibrary
    private let preferences: ShelvesPreferences
    private let frameSpring = FrameSpring()
    private var observers: Set<AnyCancellable> = []
    private var draggedFiles: [ShelfFile] = []
    /// Where the drag was last seen, in shelf coordinates.
    private var dragPoint: CGPoint?
    private var hasReceivedDrop = false
    private(set) var isClosing = false

    init(shelf: Shelf, library: ShelfLibrary, preferences: ShelvesPreferences) {
        self.shelf = shelf
        self.library = library
        self.preferences = preferences
        panel = ShelfPanel(shelfSize: ShelfGeometry.compact)
        super.init()
        let dropView = ShelfDropView(frame: CGRect(origin: .zero, size: panel.frame.size))
        dropView.controller = self
        let hosting = ShelfHostingView(rootView: ShelfView(shelf: shelf, library: library, controller: self))
        hosting.frame = dropView.bounds
        hosting.autoresizingMask = [.width, .height]
        dropView.addSubview(hosting)
        panel.contentView = dropView
        panel.onKeyDown = { [weak self] event in self?.handleKey(event) ?? false }
        frameSpring.onFrame = { [weak self] frame in self?.panel.setFrame(frame, display: true) }
        applySpaces()
        shelf.actions = preferences.instantActions
        // Settings change rarely; the shelf keeps its own copy of what they mean.
        preferences.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.applySpaces()
                    let actions = self.preferences.instantActions
                    if self.shelf.actions != actions { self.shelf.actions = actions }
                }
            }
        }.store(in: &observers)
    }

    private func applySpaces() {
        let behavior: NSWindow.CollectionBehavior = preferences.onAllSpaces
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.moveToActiveSpace, .fullScreenAuxiliary]
        if panel.collectionBehavior != behavior { panel.collectionBehavior = behavior }
    }

    private var shelfFrame: CGRect { ShelfGeometry.shelfFrame(inWindow: panel.frame) }

    // MARK: Showing

    /// Shows the shelf centred on a point, in screen coordinates, growing out of it.
    func show(centeredAt point: CGPoint) {
        let size = ShelfGeometry.compact
        show(shelfAt: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2), growingFrom: point)
    }

    /// Shows the shelf with its bottom-left corner at a point, kept on screen.
    func show(at origin: CGPoint) {
        let size = ShelfGeometry.compact
        show(shelfAt: origin, growingFrom: CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2))
    }

    private func show(shelfAt origin: CGPoint, growingFrom point: CGPoint) {
        let frame = clamped(CGRect(origin: origin, size: ShelfGeometry.compact))
        // The shelf grows out of the pointer, even when the screen edge pushed it aside.
        shelf.presenceAnchor = UnitPoint(x: min(max((point.x - frame.minX) / frame.width, 0), 1),
                                         y: min(max((frame.maxY - point.y) / frame.height, 0), 1))
        panel.setFrame(ShelfGeometry.windowFrame(forShelf: frame), display: true)
        panel.orderFrontRegardless()
        // One frame at rest first, so the spring has a starting point to leave from.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                withAnimation(ShelfMotion.appear) { self.shelf.isPresented = true }
            }
        }
    }

    func bringToFront() {
        panel.orderFrontRegardless()
    }

    func setExpanded(_ expanded: Bool) {
        guard shelf.isExpanded != expanded, !isClosing else { return }
        let size = expanded ? ShelfGeometry.expanded : ShelfGeometry.compact
        // Where the frame is heading, not where it is, so a quick reversal
        // keeps the shelf's top-left corner still.
        let current = shelfFrame
        let target = clamped(CGRect(x: current.minX, y: current.maxY - size.height, width: size.width, height: size.height))
        withAnimation(ShelfMotion.content) {
            shelf.isExpanded = expanded
            if !expanded { shelf.selection.removeAll() }
        }
        frameSpring.response = 0.42
        frameSpring.damping = 0.86
        frameSpring.animate(from: panel.frame, to: ShelfGeometry.windowFrame(forShelf: target), in: panel.contentView!)
    }

    /// Closes the shelf; it stays in Recent Shelves unless it's empty.
    func close(clearing: Bool = false) {
        guard !isClosing else { return }
        isClosing = true
        if clearing { shelf.remove(Set(shelf.files.map(\.id))) }
        hideLabel()
        withAnimation(ShelfMotion.disappear) { shelf.isPresented = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + (ShelfMotion.reduced ? 0.16 : 0.24)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.frameSpring.stop()
                self.panel.orderOut(nil)
                self.labelPanel.orderOut(nil)
                self.library.didClose(self)
            }
        }
    }

    /// Hides the panel at once, for the extension switching off.
    func dismiss() {
        frameSpring.stop()
        panel.orderOut(nil)
        labelPanel.orderOut(nil)
    }

    /// Keeps a shelf frame on the screen it's mostly on.
    private func clamped(_ frame: CGRect) -> CGRect {
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return frame }
        var frame = frame
        frame.origin.x = min(max(frame.minX, visible.minX + 6), visible.maxX - frame.width - 6)
        frame.origin.y = min(max(frame.minY, visible.minY + 6), visible.maxY - frame.height - 6)
        return frame
    }

    func setHovered(_ hovered: Bool) {
        guard shelf.isHovered != hovered else { return }
        withAnimation(ShelfMotion.hover) { shelf.isHovered = hovered }
    }

    // MARK: The action label

    private func showLabel(_ title: String) {
        labelPanel.model.title = title
        if !labelPanel.isVisible || !labelPanel.model.isVisible {
            let frame = shelfFrame
            let size = ActionLabelPanel.size
            labelPanel.setFrame(CGRect(x: frame.midX - size.width / 2, y: frame.maxY + 2, width: size.width, height: size.height),
                                display: false)
            labelPanel.orderFrontRegardless()
        }
        labelPanel.model.isVisible = true
    }

    private func hideLabel() {
        labelPanel.model.isVisible = false
    }

    // MARK: Drops

    private var actions: [InstantAction] { shelf.actions }

    /// Called on every drag update, so it changes state only when something changed.
    func dragMoved(to point: CGPoint, in size: CGSize, isOwn: Bool) -> NSDragOperation {
        dragPoint = point
        if !shelf.isDragInside {
            withAnimation(ShelfMotion.hover) {
                shelf.isDragInside = true
                shelf.isDropTarget = !isOwn
            }
        }
        if shelf.showsActions {
            let index = ShelfGeometry.actionFrames(count: actions.count, in: size).firstIndex { $0.contains(point) }
            let action = index.map { actions[$0] }
            if shelf.hoveredAction != action {
                withAnimation(ShelfMotion.hover) { shelf.hoveredAction = action }
                if let action {
                    showLabel(action.title)
                    library.tick()
                } else {
                    hideLabel()
                }
            }
            return action == nil ? [] : .copy
        }
        if !actions.isEmpty, ShelfGeometry.boltFrame(in: size).insetBy(dx: -6, dy: -6).contains(point) {
            withAnimation(ShelfMotion.bloom) { shelf.showsActions = true }
            library.tick()
            return []
        }
        return isOwn ? [] : .copy
    }

    func dragLeft() {
        guard shelf.isDragInside || shelf.showsActions else { return }
        hideLabel()
        withAnimation(ShelfMotion.bloom) {
            shelf.isDragInside = false
            shelf.isDropTarget = false
            shelf.showsActions = false
            shelf.hoveredAction = nil
        }
    }

    func drop(_ pasteboard: NSPasteboard, at point: CGPoint, isOwn: Bool) -> Bool {
        hasReceivedDrop = true
        if shelf.showsActions {
            guard let action = shelf.hoveredAction else { return false }
            let wasEmpty = shelf.files.isEmpty
            PasteboardReader.read(pasteboard, into: library.filesDirectory) { [weak self] urls, _ in
                guard let self else { return }
                let done = action.perform(with: urls, sendToNotchShelf: self.library.sendToNotchShelf)
                if done && wasEmpty && self.preferences.closeAfterAction && !self.shelf.isPinned && self.shelf.files.isEmpty {
                    self.close()
                }
            }
            return true
        }
        guard !isOwn else { return false }
        shelf.lastDrop = point
        add(from: pasteboard)
        return true
    }

    /// The drag that shook this shelf out let go. Dropped anywhere but here,
    /// the shelf was a mistake, so it goes away again.
    func triggeringDragEnded() {
        // The drop can reach the shelf just after the mouse comes up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.hasReceivedDrop, !self.shelf.isPinned, self.shelf.files.isEmpty else { return }
                self.close()
            }
        }
    }

    func add(from pasteboard: NSPasteboard) {
        PasteboardReader.read(pasteboard, into: library.filesDirectory) { [weak self] urls, owned in
            self?.add(urls, owned: owned)
        }
    }

    func add(_ urls: [URL], owned: Set<URL> = []) {
        let count = withAnimation(ShelfMotion.appear) {
            shelf.add(urls, owned: owned)
        }
        if count > 0 {
            shelf.landings += 1
            library.tick()
        } else if !urls.isEmpty {
            NSSound.beep()
        }
        shelf.lastDrop = nil
    }

    // MARK: Clicks

    func doubleClick(_ files: [ShelfFile]) {
        let urls = files.map(\.url)
        switch preferences.doubleClick {
        case .open: FileActions.open(urls)
        case .reveal: FileActions.reveal(urls)
        case .quickLook: QuickLook.shared.show(urls)
        }
    }

    func select(_ file: ShelfFile, extending: Bool) {
        withAnimation(ShelfMotion.hover) {
            if extending {
                if shelf.selection.contains(file.id) { shelf.selection.remove(file.id) } else { shelf.selection.insert(file.id) }
            } else {
                shelf.selection = shelf.selection == [file.id] ? [] : [file.id]
            }
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (event.keyCode, modifiers) {
        case (49, []): // space
            QuickLook.shared.show(shelf.targets.map(\.url))
        case (53, []): // escape
            if shelf.isExpanded { setExpanded(false) } else { close() }
        case (51, []), (117, []): // delete
            guard !shelf.selection.isEmpty else { return false }
            remove(Set(shelf.selection))
        case (0, [.command]): // ⌘A
            withAnimation(ShelfMotion.hover) { shelf.selection = Set(shelf.files.map(\.id)) }
        case (8, [.command]): // ⌘C
            FileActions.copyToPasteboard(shelf.targets.map(\.url))
        case (9, [.command]): // ⌘V
            add(from: .general)
        case (13, [.command]): // ⌘W
            close()
        default:
            return false
        }
        return true
    }

    private func remove(_ ids: Set<UUID>) {
        withAnimation(ShelfMotion.content) { shelf.remove(ids) }
    }

    // MARK: Menu

    func menu(for files: [ShelfFile]) -> NSMenu {
        let menu = NSMenu()
        let urls = files.map(\.url)
        if !files.isEmpty {
            let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            openWith.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil)
            let apps = NSMenu()
            for (index, app) in FileActions.applications(toOpen: urls).prefix(16).enumerated() {
                let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
                let item = ClosureMenuItem(index == 0 ? "\(name) (default)" : name) { FileActions.open(urls, with: app) }
                let icon = NSWorkspace.shared.icon(forFile: app.path)
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
                apps.addItem(item)
            }
            openWith.submenu = apps
            openWith.isEnabled = !apps.items.isEmpty
            menu.addItem(openWith)
            menu.addItem(ClosureMenuItem("Show in Finder", symbol: "folder") { FileActions.reveal(urls) })
            menu.addItem(ClosureMenuItem("Quick Look", symbol: "eye") { QuickLook.shared.show(urls) })
            menu.addItem(.separator())
            for action in [InstantAction.airDrop, .mail, .messages] where action.isAvailable {
                let item = ClosureMenuItem(action.title) { [weak self] in
                    _ = action.perform(with: urls, sendToNotchShelf: self?.library.sendToNotchShelf ?? { _ in })
                }
                let icon = action.icon.copy() as? NSImage
                icon?.size = NSSize(width: 16, height: 16)
                item.image = icon
                menu.addItem(item)
            }
            let share = NSSharingServicePicker(items: urls).standardShareMenuItem
            share.title = "More"
            menu.addItem(share)
            menu.addItem(.separator())
            let copyTitle = files.count == 1 ? "Copy “\(files[0].name)”" : "Copy \(files.count) Items"
            menu.addItem(ClosureMenuItem(copyTitle, symbol: "doc.on.doc") { FileActions.copyToPasteboard(urls) })
            menu.addItem(ClosureMenuItem(files.count == 1 ? "Copy Path" : "Copy Paths", symbol: "link") {
                FileActions.copyPaths(urls)
            })
            menu.addItem(ClosureMenuItem("Copy to…", symbol: "plus.square.on.square") { [weak self] in
                self?.transfer(files, move: false)
            })
            menu.addItem(ClosureMenuItem("Move to…", symbol: "folder.badge.plus") { [weak self] in
                self?.transfer(files, move: true)
            })
            menu.addItem(ClosureMenuItem("Send to Notch Shelf", symbol: "rectangle.topthird.inset.filled") { [weak self] in
                self?.library.sendToNotchShelf(urls)
            })
            if files.count < shelf.files.count {
                menu.addItem(.separator())
                let title = files.count == 1 ? "Remove from Shelf" : "Remove \(files.count) Items"
                menu.addItem(ClosureMenuItem(title, symbol: "minus.circle") { [weak self] in
                    self?.remove(Set(files.map(\.id)))
                })
            }
            menu.addItem(.separator())
        }
        let clipboard = ClosureMenuItem("Add from Clipboard", symbol: "doc.on.clipboard") { [weak self] in
            self?.add(from: .general)
        }
        clipboard.isEnabled = PasteboardReader.canRead(.general)
        menu.addItem(clipboard)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Rename Shelf…", symbol: "pencil") { [weak self] in self?.rename() })
        let pin = ClosureMenuItem("Pin Shelf", symbol: "pin") { [weak self] in self?.shelf.isPinned.toggle() }
        pin.state = shelf.isPinned ? .on : .off
        menu.addItem(pin)
        if !shelf.files.isEmpty {
            menu.addItem(ClosureMenuItem(shelf.isExpanded ? "Collapse Shelf" : "Expand Shelf",
                                         symbol: shelf.isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") { [weak self] in
                guard let self else { return }
                setExpanded(!shelf.isExpanded)
            })
            menu.addItem(ClosureMenuItem("Clear Shelf", symbol: "trash") { [weak self] in
                self?.close(clearing: true)
            })
        }
        menu.addItem(ClosureMenuItem("Close Shelf", symbol: "xmark") { [weak self] in self?.close() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Shelves Settings…", symbol: "gearshape") { [weak self] in
            self?.library.openSettings()
        })
        return menu
    }

    private func transfer(_ files: [ShelfFile], move: Bool) {
        guard let folder = FileActions.chooseFolder(prompt: move ? "Move" : "Copy") else { return }
        let moved = FileActions.transfer(files.map(\.url), to: folder, move: move)
        guard move else { return }
        // The shelf follows its files to their new home.
        for (index, file) in shelf.files.enumerated() {
            if let destination = moved[file.url], var updated = ShelfFile(url: destination, isOwned: false) {
                updated.id = file.id
                shelf.files[index] = updated
            }
        }
    }

    private func rename() {
        let alert = NSAlert()
        alert.messageText = "Rename Shelf"
        alert.informativeText = "Leave it empty to name the shelf after its files."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = shelf.customName ?? ""
        field.placeholderString = ShelfSummary.name(for: shelf.files)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        shelf.customName = name.isEmpty ? nil : name
    }

    // MARK: Dragging out

    func beginDrag(_ files: [ShelfFile], event: NSEvent, from view: NSView, image: NSImage?) {
        guard !files.isEmpty else { return }
        let side: CGFloat = 56
        let origin = view.convert(event.locationInWindow, from: nil)
        let items = files.enumerated().map { index, file -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: file.url as NSURL)
            let offset = CGFloat(min(index, 4)) * 4
            item.setDraggingFrame(NSRect(x: origin.x - side / 2 + offset, y: origin.y - side / 2 - offset, width: side, height: side),
                                  contents: index == 0 ? (image ?? Thumbnails.image(for: file.path)) : Thumbnails.image(for: file.path))
            return item
        }
        draggedFiles = files
        let session = view.beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }
}

extension ShelfController: NSDraggingSource {
    /// Finder moves files when the source allows it, which is what a shelf
    /// is for; apps that only take copies still accept the drop.
    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .generic] : [.copy, .generic]
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        MainActor.assumeIsolated { dragEnded(operation: operation) }
    }

    private func dragEnded(operation: NSDragOperation) {
        let dragged = draggedFiles
        draggedFiles = []
        guard operation != [] else { return }
        let finish: @MainActor () -> Void = { [weak self] in
            guard let self, !isClosing else { return }
            let gone = Set(dragged.filter { !FileManager.default.fileExists(atPath: $0.path) }.map(\.id))
            if !gone.isEmpty { remove(gone) }
            guard !shelf.isPinned else { return }
            switch preferences.dragOut {
            case .always: close()
            case .whenMoved: if !gone.isEmpty && shelf.files.isEmpty { close() }
            case .never: break
            }
        }
        // Finder can finish a move after the session ends.
        if operation.contains(.move) || operation.contains(.delete) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { MainActor.assumeIsolated { finish() } }
        } else {
            finish()
        }
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, symbol: String? = nil, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() {
        MainActor.assumeIsolated { handler() }
    }
}
