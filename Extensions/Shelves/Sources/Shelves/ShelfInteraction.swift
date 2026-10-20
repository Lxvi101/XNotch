import AppKit
import SwiftUI

/// The shelf's empty space: drags move the shelf, a double-click expands or
/// collapses it, a right-click opens the menu for every file.
struct BackgroundArea: NSViewRepresentable {
    let controller: ShelfController

    func makeNSView(context: Context) -> BackgroundAreaView {
        let view = BackgroundAreaView()
        view.controller = controller
        return view
    }

    func updateNSView(_ view: BackgroundAreaView, context: Context) {
        view.controller = controller
    }
}

final class BackgroundAreaView: NSView {
    weak var controller: ShelfController?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            guard let controller, let window else { return }
            if event.clickCount == 2, !controller.shelf.files.isEmpty {
                return controller.setExpanded(!controller.shelf.isExpanded)
            }
            let before = window.frame.origin
            window.performDrag(with: event)
            if window.frame.origin == before, !controller.shelf.selection.isEmpty {
                withAnimation(ShelfMotion.hover) { controller.shelf.selection.removeAll() }
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            guard let controller else { return }
            NSMenu.popUpContextMenu(controller.menu(for: controller.shelf.files), with: event, for: self)
        }
    }
}

/// Over a file (or, with `file` nil, the compact shelf's stack of all of
/// them): selection, double-click, the right-click menu and dragging out.
struct FileItemArea: NSViewRepresentable {
    let controller: ShelfController
    let file: ShelfFile?

    func makeNSView(context: Context) -> FileItemView {
        let view = FileItemView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: FileItemView, context: Context) {
        view.controller = controller
        view.file = file
    }
}

final class FileItemView: NSView {
    weak var controller: ShelfController?
    var file: ShelfFile?
    private var mouseDownEvent: NSEvent?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    @MainActor private var targets: [ShelfFile] {
        guard let shelf = controller?.shelf else { return [] }
        guard let file else { return shelf.files }
        return shelf.targets(for: file)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        // Takes the keys, without activating XNotch, for the space bar's Quick Look.
        window?.makeKey()
        guard event.clickCount == 2 else { return }
        mouseDownEvent = nil
        MainActor.assumeIsolated { controller?.doubleClick(targets) }
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil }
        guard let down = mouseDownEvent, down.clickCount == 1, let file else { return }
        let extending = !down.modifierFlags.intersection([.command, .shift]).isEmpty
        MainActor.assumeIsolated { controller?.select(file, extending: extending) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent else { return }
        guard hypot(event.locationInWindow.x - down.locationInWindow.x,
                    event.locationInWindow.y - down.locationInWindow.y) > 3 else { return }
        mouseDownEvent = nil
        MainActor.assumeIsolated {
            let image = file.flatMap { Thumbnails.cachedThumbnail(for: $0.path) }
                ?? targets.last.flatMap { Thumbnails.cachedThumbnail(for: $0.path) }
            controller?.beginDrag(targets, event: event, from: self, image: image)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            guard let controller else { return }
            if let file, !controller.shelf.selection.contains(file.id) {
                controller.shelf.selection = [file.id]
            }
            NSMenu.popUpContextMenu(controller.menu(for: targets), with: event, for: self)
        }
    }
}

/// Opens the shelf's menu under the chevron on any click.
struct MenuAnchor: NSViewRepresentable {
    let controller: ShelfController

    func makeNSView(context: Context) -> MenuAnchorView {
        let view = MenuAnchorView()
        view.controller = controller
        return view
    }

    func updateNSView(_ view: MenuAnchorView, context: Context) {
        view.controller = controller
    }
}

final class MenuAnchorView: NSView {
    weak var controller: ShelfController?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            guard let controller else { return }
            let menu = controller.menu(for: controller.shelf.targets)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: isFlipped ? bounds.maxY + 4 : -4), in: self)
        }
    }
}
