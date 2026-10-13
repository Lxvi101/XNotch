/*
 * Drag-out handling adapted from Atoll (DynamicIsland),
 * components/Shelf/Views/ShelfItemView.swift (DraggableClickHandler)
 * Copyright (C) 2024-2026 Atoll Contributors, originally from boring.notch.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import AppKit
import SwiftUI

/// AppKit overlay for a shelf tile: click/⌘-click selection, double-click to
/// open, right-click menu, and dragging files out as real file URLs. Hover is
/// hit-tested by the window controller instead, because tracking areas inside
/// a non-activating panel that toggles `ignoresMouseEvents` drop enter events.
struct ShelfItemInteraction: NSViewRepresentable {
    let item: ShelfItem
    let store: ShelfStore
    let dragImage: NSImage?
    let onDragOut: (Bool) -> Void

    func makeNSView(context: Context) -> ShelfItemInteractionView {
        let view = ShelfItemInteractionView()
        update(view)
        return view
    }

    func updateNSView(_ view: ShelfItemInteractionView, context: Context) {
        update(view)
    }

    private func update(_ view: ShelfItemInteractionView) {
        view.item = item
        view.store = store
        view.dragImage = dragImage
        view.onDragOut = onDragOut
    }
}

final class ShelfItemInteractionView: NSView, NSDraggingSource {
    var item: ShelfItem!
    weak var store: ShelfStore?
    var dragImage: NSImage?
    var onDragOut: ((Bool) -> Void)?

    private var mouseDownEvent: NSEvent?
    private var draggedItems: [ShelfItem] = []
    private let dragThreshold: CGFloat = 3

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @MainActor private var targets: [ShelfItem] {
        store?.actionTargets(for: item) ?? [item]
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        if event.clickCount == 2 {
            MainActor.assumeIsolated { ShelfActions.open(targets) }
            mouseDownEvent = nil
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil }
        guard let down = mouseDownEvent, down.clickCount == 1 else { return }
        MainActor.assumeIsolated { select(with: down.modifierFlags) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent else { return }
        let distance = hypot(event.locationInWindow.x - down.locationInWindow.x,
                             event.locationInWindow.y - down.locationInWindow.y)
        guard distance > dragThreshold else { return }
        mouseDownEvent = nil
        MainActor.assumeIsolated { beginDrag(with: event) }
    }

    override func rightMouseDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            if store?.selection.contains(item.id) != true { store?.selection = [item.id] }
            NSMenu.popUpContextMenu(menu(for: targets), with: event, for: self)
        }
    }

    @MainActor private func select(with flags: NSEvent.ModifierFlags) {
        guard let store else { return }
        withAnimation(Motion.content) {
            if flags.contains(.command) || flags.contains(.shift) {
                if store.selection.contains(item.id) {
                    store.selection.remove(item.id)
                } else {
                    store.selection.insert(item.id)
                }
            } else {
                store.selection = store.selection == [item.id] ? [] : [item.id]
            }
        }
    }

    @MainActor private func beginDrag(with event: NSEvent) {
        let dragged = targets
        let image = dragImage ?? NSWorkspace.shared.icon(forFile: item.path)
        let side: CGFloat = 48
        let origin = convert(event.locationInWindow, from: nil)
        let items = dragged.enumerated().map { index, shelfItem -> NSDraggingItem in
            let draggingItem = NSDraggingItem(pasteboardWriter: shelfItem.url as NSURL)
            let offset = CGFloat(index) * 4
            let frame = NSRect(x: origin.x - side / 2 + offset, y: origin.y - side / 2 - offset, width: side, height: side)
            draggingItem.setDraggingFrame(frame, contents: shelfItem.id == item.id ? image : NSWorkspace.shared.icon(forFile: shelfItem.path))
            return draggingItem
        }
        draggedItems = dragged
        onDragOut?(true)
        beginDraggingSession(with: items, event: event, source: self)
    }

    @MainActor private func menu(for items: [ShelfItem]) -> NSMenu {
        let menu = NSMenu()
        let count = items.count
        menu.addItem(ClosureMenuItem("Open", symbol: "arrow.up.forward.app") { ShelfActions.open(items) })
        menu.addItem(ClosureMenuItem("Quick Look", symbol: "eye") { ShelfActions.quickLook(items) })
        menu.addItem(ClosureMenuItem("Show in Finder", symbol: "folder") { ShelfActions.reveal(items) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Copy", symbol: "doc.on.doc") { ShelfActions.copy(items) })
        menu.addItem(ClosureMenuItem("AirDrop", symbol: "dot.radiowaves.left.and.right") {
            ShelfActions.airDrop(items.map(\.url))
        })
        menu.addItem(.separator())
        let removeTitle = count > 1 ? "Remove \(count) Items" : "Remove from Shelf"
        menu.addItem(ClosureMenuItem(removeTitle, symbol: "minus.circle") { [weak store] in
            withAnimation(Motion.content) { store?.remove(Set(items.map(\.id))) }
        })
        return menu
    }

    // MARK: NSDraggingSource

    /// Finder moves files when the source allows it; apps that only take
    /// copies (uploads, mail) still accept the drop.
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.move, .copy, .generic] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let dragged = draggedItems
        draggedItems = []
        MainActor.assumeIsolated {
            onDragOut?(false)
            if operation.contains(.move) || operation.contains(.delete) {
                removeFromShelf(dragged)
            }
        }
        // Finder can finish a move after the session ends; drop items whose file left its path.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            let gone = dragged.filter { !FileManager.default.fileExists(atPath: $0.path) }
            if !gone.isEmpty { self?.removeFromShelf(gone) }
        }
    }

    @MainActor private func removeFromShelf(_ items: [ShelfItem]) {
        guard let store else { return }
        let ids = Set(items.map(\.id)).intersection(store.items.map(\.id))
        guard !ids.isEmpty else { return }
        withAnimation(Motion.content) { store.remove(ids) }
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler() }
}
