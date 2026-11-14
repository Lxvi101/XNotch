import AppKit

/// Watches the pointer over the menu bar: hovering a folder opens it, and a
/// menu bar icon Command-dragged onto a folder and let go is filed there.
///
/// macOS runs the drag itself; this only watches it. A Command-press on
/// another app's icon starts watching, the folder under the pointer opens its
/// drawer as a drop target, and letting go there files the icon.
///
/// Hover comes from here rather than a tracking area on the folder button:
/// the mover hides and warps the cursor, which leaves AppKit's tracking
/// convinced the pointer never left.
@MainActor
final class DragIntoFolderWatcher {
    private weak var controller: BarController?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var dragged: BarItem?
    private var target: UUID?
    private var hovered: UUID?
    /// Below this the pointer is clear of the menu bar on every Mac.
    private static let barReach: CGFloat = 60
    private var dwell: DispatchWorkItem?

    /// A listen-only tap on the session: it sees every press and drag on the
    /// way to whichever app gets it, and never holds one up.
    init(controller: BarController) {
        self.controller = controller
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue) | (1 << CGEventType.mouseMoved.rawValue)
        let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                    eventsOfInterest: CGEventMask(mask), callback: { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let watcher = Unmanaged<DragIntoFolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let flags = event.flags
            let location = event.location
            // Every mouse move system-wide lands here: leave at once unless
            // the pointer is up in the menu bar.
            if type == .mouseMoved, location.y > DragIntoFolderWatcher.barReach, !watcher.isHovering {
                return Unmanaged.passUnretained(event)
            }
            MainActor.assumeIsolated { watcher.handle(type, command: flags.contains(.maskCommand), at: location) }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        DebugLog.write("event tap created=\(tap != nil)")
        guard let tap else { return }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
        source = nil
    }

    /// Read from the tap thread without isolation; only ever a hint.
    nonisolated(unsafe) private var hoveringFlag = false
    nonisolated var isHovering: Bool { hoveringFlag }

    /// The folder a drag over `point` is aimed at: a folder's icon, or the
    /// drawer it opened. macOS reorders the bar live during a Command-drag,
    /// so the icon often slides out from under the pointer; the drawer stays.
    private func dropTarget(at point: CGPoint, controller: BarController) -> UUID? {
        if let folder = controller.folderFrames.first(where: { $0.frame.insetBy(dx: -6, dy: -4).contains(point) })?.id {
            return folder
        }
        if controller.drawer.isDropTarget, controller.drawer.contains(globalPoint: point) {
            return controller.drawer.openFolder
        }
        return nil
    }

    /// `point` is in global display coordinates (top-left origin), the space
    /// the window server reports item bounds in.
    private func handle(_ type: CGEventType, command: Bool, at point: CGPoint) {
        guard let controller else { return }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        switch type {
        case .mouseMoved:
            let over = point.y <= Self.barReach
                ? controller.folderFrames.first { $0.frame.insetBy(dx: -1, dy: -1).contains(point) }?.id : nil
            hoveringFlag = over != nil
            guard over != hovered else { return }
            if let previous = hovered { controller.hoverChanged(false, folder: previous) }
            hovered = over
            if let over { controller.hoverChanged(true, folder: over) }
            DebugLog.write("hover folder=\(over?.uuidString ?? "none")")
        case .leftMouseDown:
            // A click anywhere but the drawer and the folders puts a clicked-open drawer away.
            if !controller.mover.busy, controller.drawer.isPinned, !controller.drawer.contains(globalPoint: point),
               !controller.folderFrames.contains(where: { $0.frame.contains(point) }) {
                controller.drawer.close(animated: true)
            }
            // The mover's own presses happen with the cursor hidden and land
            // off screen; ignore everything while it works.
            guard command, !controller.mover.busy else { return }
            let filed = controller.store.filedIDs
            dragged = BarItem.current().first { $0.bounds.contains(point) && $0.isMovable && !filed.contains($0.id) }
            DebugLog.write("cmd-press at \(point) on \(dragged?.id ?? "nothing")")
            target = nil
        case .leftMouseDragged:
            guard dragged != nil else { return }
            let over = dropTarget(at: point, controller: controller)
            guard over != target else { return }
            target = over
            dwell?.cancel()
            // Over the drawer it's already showing; only a folder's icon opens it.
            if let over, controller.drawer.openFolder != over || !controller.drawer.isDropTarget {
                let work = DispatchWorkItem { [weak controller] in controller?.present(over, asDropTarget: true) }
                dwell = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
            }
        case .leftMouseUp:
            dwell?.cancel()
            defer { dragged = nil; target = nil }
            guard let dragged else { return }
            let landed = dropTarget(at: point, controller: controller) ?? target
            DebugLog.write("release at \(point); into folder=\(landed?.uuidString ?? "none")")
            guard let landed else {
                // Let go somewhere else: the drawer that was waiting for it goes away.
                if controller.drawer.isDropTarget { controller.drawer.close(animated: true) }
                return
            }
            controller.drawer.dropLanded()
            controller.file(dragged, in: landed)
        default:
            break
        }
    }
}
