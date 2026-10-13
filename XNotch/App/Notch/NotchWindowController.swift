import AppKit
import Combine
import SwiftUI
import XNotchKit

/// Positions the canvas over the notch, decides where the pointer counts as
/// "inside", and translates pointer, press and file-drag input into model
/// transitions.
@MainActor
final class NotchWindowController {
    private let window: NotchWindow
    let model: NotchViewModel
    private let dragDetector = DragDetector()
    private var screen: NSScreen
    private var monitors: [Any] = []
    private var cancellables: Set<AnyCancellable> = []
    private var pointerWasFar = false

    /// Proximity radius over which the closed shell starts reaching for the pointer.
    private let pointerRadius: CGFloat = 80
    private let fileDragRadius: CGFloat = 260

    init(screen: NSScreen) {
        self.screen = screen
        model = NotchViewModel(notchSize: NotchMetrics.physicalNotchSize(on: screen))
        window = NotchWindow(contentRect: Self.canvasFrame(on: screen))

        let container = NotchContainerView(frame: NSRect(origin: .zero, size: NotchMetrics.canvasSize))
        let host = NotchHostingView(rootView: NotchShellView(model: model))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        window.contentView = container
        window.orderFrontRegardless()

        container.onDragUpdated = { [weak self] point in self?.updateDropTarget(at: point) }
        container.onDrop = { [weak self] urls, point in self?.drop(urls, at: point) ?? false }
        container.onPromisedFileReceived = { [weak self] url in self?.model.receive([url]) }
        model.onPointerSyncNeeded = { [weak self] in self?.syncPointer(NSEvent.mouseLocation) }

        installMonitors()
        installDragDetector()

        model.$surface
            .filter { $0 != .open }
            .sink { [weak self] _ in self?.window.releaseKeyboard() }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenParametersChanged() }
        }
    }

    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    private static func canvasFrame(on screen: NSScreen) -> NSRect {
        let size = NotchMetrics.canvasSize
        return NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                      width: size.width, height: size.height)
    }

    private func screenParametersChanged() {
        guard let next = Self.preferredScreen() else { return }
        screen = next
        window.setFrame(Self.canvasFrame(on: next), display: true)
        model.updateNotchSize(NotchMetrics.physicalNotchSize(on: next))
    }

    // MARK: Geometry

    /// Screen-space (AppKit, bottom-left origin) rect of a shell geometry.
    private func rect(for geometry: NotchShellGeometry) -> NSRect {
        let width = geometry.outerWidth
        return NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - geometry.height,
                      width: width, height: geometry.height)
    }

    private var interactionRect: NSRect {
        switch model.surface {
        case .closed:
            // Generous below the notch so the hover can be reached without precision.
            let resting = rect(for: model.restingGeometry)
            let body = NSRect(x: resting.minX - 6, y: resting.minY - 8, width: resting.width + 12, height: resting.height + 8)
            guard model.pillsActive, let row = pillFrames().map(\.1).reduce(nil, { $0?.union($1) ?? $1 }) else { return body }
            return body.union(row.insetBy(dx: -8, dy: -8))
        case .dropZone:
            return rect(for: NotchMetrics.dropZone).insetBy(dx: -28, dy: -28)
        case .open:
            return rect(for: model.targetGeometry)
        }
    }

    /// Screen-space destination pill frames under the closed notch.
    private func pillFrames() -> [(OpenPage, NSRect)] {
        let frames = PillLayout.frames(count: model.destinations.count, below: model.restingGeometry.height,
                                       iconOnly: model.pillsIconOnly)
        return zip(model.destinations, frames).map { page, frame in
            (page, NSRect(x: screen.frame.midX + frame.minX, y: screen.frame.maxY - frame.maxY,
                          width: frame.width, height: frame.height))
        }
    }

    private func pill(at point: NSPoint) -> OpenPage? {
        guard model.pillsActive else { return nil }
        return pillFrames().first { $0.1.insetBy(dx: -3, dy: -4).contains(point) }?.0
    }

    /// The closed media wings' right wing, where the play/pause glyph sits.
    private func isOnMediaGlyph(_ point: NSPoint) -> Bool {
        guard model.showsMediaWings else { return false }
        let wings = rect(for: model.restingGeometry)
        let glyph = NSRect(x: screen.frame.midX + model.notchSize.width / 2, y: wings.minY - 8,
                           width: wings.maxX - screen.frame.midX - model.notchSize.width / 2, height: wings.height + 8)
        return glyph.contains(point)
    }

    private func distance(from point: NSPoint, to rect: NSRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    private func attract(toward point: NSPoint, radius: CGFloat, isFileDrag: Bool) {
        let resting = rect(for: model.restingGeometry)
        let pull = (1 - distance(from: point, to: resting) / radius).smoothstep
        let lean = ((point.x - resting.midX) / (resting.width / 2 + radius)).clamped(-1, 1)
        model.updatePointer(pull: pull, inside: !isFileDrag && interactionRect.contains(point),
                            lean: lean, isFileDrag: isFileDrag)
    }

    // MARK: Pointer

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event, isLocal: false) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event, isLocal: true) }
            return event
        }) {
            monitors.append(local)
        }
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, self.window.isKeyWindow else { return false }
                return self.model.handleKey(event)
            }
            return handled ? nil : event
        }) {
            monitors.append(keys)
        }
        if let menus = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleSecondaryClick(event) ?? true } ? event : nil
        }) {
            monitors.append(menus)
        }
    }

    /// The notch's own menu, unless the click is on something with its own
    /// (a shelf tile, an extension's `notchContextMenu`). Returns whether the
    /// event should continue to the window.
    private func handleSecondaryClick(_ event: NSEvent) -> Bool {
        guard event.window === window, model.surface != .dropZone,
              interactionRect.contains(NSEvent.mouseLocation), let content = window.contentView else { return true }
        var view = content.hitTest(event.locationInWindow)
        while let current = view {
            if current is NotchContextMenuView || current is ShelfItemInteractionView { return true }
            view = current.superview
        }
        let menu = NotchContextMenuView.menu([
            .action("Settings…", symbol: "gearshape") { [weak model] in model?.openSettings() },
            .separator,
            .action("Quit XNotch", symbol: "power") { NSApp.terminate(nil) },
        ])
        NSMenu.popUpContextMenu(menu, with: event, for: content)
        return false
    }

    private func handle(_ event: NSEvent, isLocal: Bool) {
        // File drags are driven by the drag detector and the drop target.
        guard !dragDetector.isContentDragging else { return }
        let point = NSEvent.mouseLocation
        // Global moves arrive for the whole screen. Far from a closed notch
        // they change nothing once the shell has relaxed, so skip them.
        if event.type == .mouseMoved || event.type == .leftMouseDragged, model.surface == .closed, !model.pillsActive {
            let far = distance(from: point, to: rect(for: model.restingGeometry)) > pointerRadius + 40
            defer { pointerWasFar = far }
            if far && pointerWasFar { return }
        } else {
            pointerWasFar = false
        }
        let inside = interactionRect.contains(point)

        switch event.type {
        case .leftMouseDown:
            if inside {
                model.pointerEntered()
                model.pressBegan(onPill: pill(at: point) != nil)
                if model.surface == .open && isLocal { window.takeKeyboard() }
            } else if model.surface == .open && !isLocal {
                model.close()
            }
        case .leftMouseUp:
            let wasOpen = model.surface == .open
            model.pressEnded(onMediaGlyph: isOnMediaGlyph(point), pill: pill(at: point))
            if !wasOpen && model.surface == .open && isLocal { window.takeKeyboard() }
        default:
            break
        }

        syncPointer(point)
    }

    private func syncPointer(_ point: NSPoint) {
        if model.surface == .closed {
            attract(toward: point, radius: pointerRadius, isFileDrag: false)
        }
        let inside = interactionRect.contains(point)
        if inside {
            model.pointerEntered()
        } else {
            model.pointerExited()
        }
        model.updateShelfHover(at: inside ? canvasPoint(point) : nil)
        if model.surface == .closed {
            let resting = rect(for: model.restingGeometry)
            let onBody = NSRect(x: resting.minX - 6, y: resting.minY - 8, width: resting.width + 12,
                                height: resting.height + 8).contains(point)
            model.updatePillHighlight(pill: pill(at: point), onBody: onBody, onMediaGlyph: isOnMediaGlyph(point))
        }
        window.ignoresMouseEvents = !interactionRect.contains(point)
    }

    private func canvasPoint(_ point: NSPoint) -> CGPoint {
        CGPoint(x: point.x - window.frame.minX, y: window.frame.maxY - point.y)
    }

    // MARK: File drag

    private func installDragDetector() {
        dragDetector.onDragBegan = { [weak self] in
            MainActor.assumeIsolated { self?.model.fileDragBegan() }
        }
        dragDetector.onDragMoved = { [weak self] point in
            MainActor.assumeIsolated { self?.fileDragMoved(to: point) }
        }
        dragDetector.onDragEnded = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.fileDragEnded()
                self.syncPointer(NSEvent.mouseLocation)
            }
        }
        dragDetector.start()
    }

    private func fileDragMoved(to point: NSPoint) {
        switch model.surface {
        case .closed:
            attract(toward: point, radius: fileDragRadius, isFileDrag: true)
            let resting = rect(for: model.restingGeometry)
            let entry = NSRect(x: resting.minX - 24, y: resting.minY - 30,
                               width: resting.width + 48, height: resting.height + 30)
            if entry.contains(point) {
                model.enterDropZone()
                window.ignoresMouseEvents = false
            }
        case .dropZone:
            if interactionRect.contains(point) {
                updateDropTarget(at: point)
            } else {
                model.exitDropZone()
                window.ignoresMouseEvents = true
            }
        case .open:
            let inside = interactionRect.contains(point)
            if inside { model.selectPage(.shelf) }
            window.ignoresMouseEvents = !inside
        }
    }

    private func dropTarget(at point: NSPoint) -> DropTarget {
        point.x < screen.frame.midX ? .shelf : .airDrop
    }

    private func updateDropTarget(at point: NSPoint) {
        guard model.surface == .dropZone else { return }
        let zone = rect(for: NotchMetrics.dropZone)
        model.setHoveredDropTarget(zone.insetBy(dx: -28, dy: -28).contains(point) ? dropTarget(at: point) : nil)
    }

    private func drop(_ urls: [URL], at point: NSPoint) -> Bool {
        switch model.surface {
        case .dropZone:
            model.performDrop(urls, on: model.hoveredDropTarget ?? dropTarget(at: point))
            return true
        case .open:
            model.selectPage(.shelf)
            model.receive(urls)
            return true
        case .closed:
            return false
        }
    }
}

/// Window content view that accepts file drops (URLs and file promises) and
/// reports continuous drag positions in screen coordinates.
final class NotchContainerView: NSView {
    var onDragUpdated: ((NSPoint) -> Void)?
    var onDrop: (([URL], NSPoint) -> Bool)?
    var onPromisedFileReceived: ((URL) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(DragDetector.droppableTypes)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragUpdated?(screenPoint(of: sender))
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        let point = screenPoint(of: sender)
        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty { return onDrop?(urls, point) ?? false }

        guard let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
              !receivers.isEmpty,
              onDrop?([], point) == true else { return false }
        let destination = ShelfStore.receivedFilesDirectory
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: .main) { [weak self] url, error in
                guard error == nil else { return }
                MainActor.assumeIsolated { self?.onPromisedFileReceived?(url) }
            }
        }
        return true
    }

    private func screenPoint(of info: NSDraggingInfo) -> NSPoint {
        window?.convertPoint(toScreen: info.draggingLocation) ?? NSEvent.mouseLocation
    }
}
