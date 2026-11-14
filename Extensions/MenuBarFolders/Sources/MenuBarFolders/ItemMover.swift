import AppKit
import OSLog

/// Moves and clicks other apps' menu bar items with synthetic events.
///
/// A move is the Command-drag macOS already supports: a Command-press on the
/// item, then a release beside the target. The press lands off every display
/// so nothing under it reacts; the window fields route it to the item. Ice
/// and Thaw (GPL-3.0) worked out this technique; this is a small version of it.
@MainActor
final class ItemMover {
    enum Side { case left, right }

    private let source = CGEventSource(stateID: .hidSystemState)
    private(set) var busy = false

    /// Field 0x33, the window an event is addressed to.
    private static let windowField = CGEventField(rawValue: 0x33)!

    init() {
        WindowServer.allowBackgroundCursorControl()
    }

    /// Puts `item` on `side` of the window `target`. Returns whether it moved.
    @discardableResult
    func move(_ item: BarItem, to side: Side, of target: CGWindowID) async -> Bool {
        guard !busy, let before = WindowServer.bounds(of: target) else { return false }
        busy = true
        defer { busy = false }

        func releasePoint(_ bounds: CGRect) -> CGPoint {
            CGPoint(x: side == .left ? bounds.minX - 1 : bounds.maxX + 1, y: bounds.midY)
        }
        let start = item.liveBounds().origin
        let press = CGPoint(x: 20_000, y: 20_000)
        let planned = releasePoint(before)

        return await withHiddenCursor(warpingTo: Self.isOnScreen(planned) ? planned : nil) {
            guard let down = event(.leftMouseDown, at: press, window: item.windowID, pid: item.pid, command: true)
            else { return false }
            deliverMove(down, pid: item.pid)
            // The item lifts (jumps to the pointer) when it takes the press,
            // and the icons left of its old slot slide over to close the gap.
            // The target may be one of them, so measure it again now.
            let lifted = await waitToLeave(item.windowID, origin: start, timeout: .milliseconds(300))
            try? await Task.sleep(for: .milliseconds(20))
            let release = WindowServer.bounds(of: target).map(releasePoint) ?? planned
            if release != planned, Self.isOnScreen(release) { CGWarpMouseCursorPosition(release) }
            guard let up = event(.leftMouseUp, at: release, window: target, pid: item.pid, command: false) else { return false }
            deliverMove(up, pid: item.pid)
            deliverMove(up, pid: item.pid) // A second release keeps the item from sticking mid-drag.
            // Dropped, it slides into its slot. Only a resting item is safe
            // to click or to compare with where it started.
            let rest = await waitToSettle(item.windowID, leaving: lifted ?? start)
            DebugLog.write("move \(item.id) \(side) of \(target): lifted=\(lifted != nil) start=\(start.x) rest=\(rest?.x ?? -1)")
            return rest.map { $0 != start } ?? false
        }
    }

    /// Clicks an item that is on screen, as the user would.
    func click(_ item: BarItem) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let bounds = item.liveBounds()
        let point = CGPoint(x: bounds.midX, y: bounds.midY)
        _ = await withHiddenCursor(warpingTo: point) {
            guard let down = event(.leftMouseDown, at: point, window: item.windowID, pid: item.pid, command: false, clickState: 1),
                  let up = event(.leftMouseUp, at: point, window: item.windowID, pid: item.pid, command: false, clickState: 0)
            else { return false }
            DebugLog.write("click \(item.id) at \(point)")
            down.post(tap: .cgSessionEventTap)
            try? await Task.sleep(for: .milliseconds(12))
            up.post(tap: .cgSessionEventTap)
            return true
        }
    }

    // MARK: Events

    private func event(_ type: CGEventType, at point: CGPoint, window: CGWindowID, pid: pid_t,
                       command: Bool, clickState: Int64? = nil) -> CGEvent? {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                                  mouseButton: .left) else { return nil }
        event.flags = command ? .maskCommand : []
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window))
        if let clickState {
            event.setIntegerValueField(.mouseEventClickState, value: clickState)
        } else {
            event.setIntegerValueField(Self.windowField, value: Int64(window))
        }
        return event
    }

    /// Through the session, which runs the reorder, then straight to the owner.
    private func deliverMove(_ event: CGEvent, pid: pid_t) {
        event.post(tap: .cgSessionEventTap)
        event.postToPid(pid)
    }

    /// The new origin once the window has left `origin`, nil on timeout.
    private func waitToLeave(_ window: CGWindowID, origin: CGPoint, timeout: Duration) async -> CGPoint? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
            if let now = WindowServer.bounds(of: window)?.origin, now != origin { return now }
        }
        return nil
    }

    /// Where the window comes to rest: it left `origin` and then held still
    /// for two polls.
    private func waitToSettle(_ window: CGWindowID, leaving origin: CGPoint) async -> CGPoint? {
        _ = await waitToLeave(window, origin: origin, timeout: .milliseconds(250))
        var last = WindowServer.bounds(of: window)?.origin
        var stillPolls = 0
        let deadline = ContinuousClock.now + .milliseconds(600)
        while ContinuousClock.now < deadline, stillPolls < 2 {
            try? await Task.sleep(for: .milliseconds(20))
            let now = WindowServer.bounds(of: window)?.origin
            stillPolls = now == last ? stillPolls + 1 : 0
            last = now
        }
        return last
    }

    private func withHiddenCursor(warpingTo point: CGPoint?, _ body: () async -> Bool) async -> Bool {
        // The user's own input keeps working while ours is posted.
        source?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents],
                                                           state: .eventSuppressionStateSuppressionInterval)
        source?.localEventsSuppressionInterval = 0
        let saved = CGEvent(source: nil)?.location
        CGDisplayHideCursor(CGMainDisplayID())
        if let point {
            CGWarpMouseCursorPosition(point)
            try? await Task.sleep(for: .milliseconds(10))
        }
        let result = await body()
        if let saved { CGWarpMouseCursorPosition(saved) }
        CGDisplayShowCursor(CGMainDisplayID())
        return result
    }

    private static func isOnScreen(_ point: CGPoint) -> Bool {
        NSScreen.screens.contains { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            return CGDisplayBounds(id).contains(point)
        }
    }
}
