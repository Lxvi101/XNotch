import AppKit

/// Watches file drags in other apps and opens the wheel when its key is held
/// mid-drag: at once, once the pointer rests, or on a shake, as set. Without
/// the key a drag is never touched. One wheel per drag: once it has been let
/// go, the drag carries on undisturbed.
///
/// Resting is a timer, not an event: a still pointer sends nothing. Moves
/// only push back a deadline the one timer checks when it fires, and pressing
/// the key with the pointer still starts the clock.
@MainActor
final class DragWatcher {
    /// The pointer, in screen coordinates, and what the drag carries.
    var onTrigger: ((CGPoint, WheelFiles) -> Void)?
    /// The drag that opened a wheel has let go, wherever it landed.
    var onTriggeringDragEnded: (() -> Void)?

    private let preferences: ConverterPreferences
    private var monitors: [Any] = []
    private let dragPasteboard = NSPasteboard(name: .drag)
    private var changeCount = -1
    private var isMouseDown = false
    private var mouseDownTime: TimeInterval = 0
    private var draggedEvents = 0
    /// Looked at the pasteboard for this drag already.
    private var hasRead = false
    private var files: WheelFiles?
    private var hasTriggered = false
    private var dockStrip: CGRect = .null
    /// Where the pointer last came to rest with the key held, and when.
    private var restPoint = CGPoint.zero
    private var restTime: TimeInterval = 0
    private var timer: Timer?
    private var shake = ShakeRecognizer(tuning: .wheel)

    /// Pointer travel that still counts as resting.
    private static let restTolerance: CGFloat = 5

    init(preferences: ConverterPreferences) {
        self.preferences = preferences
    }

    func start() {
        stop()
        add(.leftMouseDown) { watcher, event in watcher.mouseDown(event) }
        add(.leftMouseDragged) { watcher, event in watcher.mouseDragged(event) }
        add(.leftMouseUp) { watcher, _ in watcher.mouseUp() }
        add(.flagsChanged) { watcher, event in watcher.flagsChanged(event) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        hasTriggered = false
        mouseUp()
    }

    private var key: NSEvent.ModifierFlags { preferences.modifier.flags }

    private func mouseDown(_ event: NSEvent) {
        changeCount = dragPasteboard.changeCount
        isMouseDown = true
        mouseDownTime = ProcessInfo.processInfo.systemUptime
        draggedEvents = 0
        hasRead = false
        files = nil
        hasTriggered = false
        dockStrip = .null
        shake.reset()
    }

    private func mouseDragged(_ event: NSEvent) {
        guard isMouseDown, !hasTriggered else { return }
        if !hasRead {
            // Every drag in every app lands here, text selections and window
            // moves included. Reading the drag pasteboard is a round trip to
            // the pasteboard server, so after the first second, when a file
            // drag would long have begun, only every eighth event looks.
            draggedEvents += 1
            if event.timestamp - mouseDownTime > 1, draggedEvents % 8 != 0 { return }
            guard dragPasteboard.changeCount != changeCount else { return }
            hasRead = true
            files = Self.read(dragPasteboard)
            if files != nil { dockStrip = Self.dockStrip(around: NSEvent.mouseLocation) }
        }
        guard let files else { return }
        guard event.modifierFlags.contains(key) else {
            shake.reset()
            return
        }
        let point = NSEvent.mouseLocation
        switch preferences.gesture {
        case .press:
            trigger(at: point, files: files)
        case .shake:
            if shake.add(point, at: event.timestamp) { trigger(at: point, files: files) }
        case .pause:
            if hypot(point.x - restPoint.x, point.y - restPoint.y) > Self.restTolerance {
                restPoint = point
                restTime = ProcessInfo.processInfo.systemUptime
            }
            if timer == nil { schedule(after: preferences.pauseDelay.seconds) }
        }
    }

    /// The key going down with the pointer still sends no drag event.
    private func flagsChanged(_ event: NSEvent) {
        guard isMouseDown, !hasTriggered, let files, event.modifierFlags.contains(key) else { return }
        switch preferences.gesture {
        case .press:
            trigger(at: NSEvent.mouseLocation, files: files)
        case .pause:
            restPoint = NSEvent.mouseLocation
            restTime = ProcessInfo.processInfo.systemUptime
            if timer == nil { schedule(after: preferences.pauseDelay.seconds) }
        case .shake:
            break
        }
    }

    private func schedule(after delay: TimeInterval) {
        let timer = Timer(timeInterval: max(delay, 0.02), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.timerFired() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func timerFired() {
        timer = nil
        guard isMouseDown, !hasTriggered, let files, preferences.gesture == .pause,
              NSEvent.modifierFlags.contains(key) else { return }
        let delay = preferences.pauseDelay.seconds
        let rested = ProcessInfo.processInfo.systemUptime - restTime
        guard rested >= delay else { return schedule(after: delay - rested) }
        let point = NSEvent.mouseLocation
        // Moved since the last event? Then it isn't resting.
        guard hypot(point.x - restPoint.x, point.y - restPoint.y) <= Self.restTolerance else { return }
        // Resting on a Dock icon opens the file in that app, key or no key.
        guard !dockStrip.contains(point) else { return }
        trigger(at: point, files: files)
    }

    private func trigger(at point: CGPoint, files: WheelFiles) {
        hasTriggered = true
        timer?.invalidate()
        timer = nil
        onTrigger?(point, files)
    }

    private func mouseUp() {
        timer?.invalidate()
        timer = nil
        if hasTriggered {
            hasTriggered = false
            onTriggeringDragEnded?()
        }
        isMouseDown = false
        files = nil
        changeCount = -1
    }

    // MARK: What's dragged

    /// The dragged files of the first one's kind, if the wheel has anything for them.
    private static func read(_ pasteboard: NSPasteboard) -> WheelFiles? {
        guard pasteboard.types?.contains(.fileURL) == true,
              let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              let first = urls.first, let kind = FileKind(url: first) else { return nil }
        let matching = urls.prefix(500).filter { $0 == first || FileKind(url: $0) == kind }
        return WheelFiles(matching, kind: kind)
    }

    /// The band along the screen edge the Dock's icons can cover, magnified.
    private static func dockStrip(around point: CGPoint) -> CGRect {
        let dock = "com.apple.dock" as CFString
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else { return .null }
        func value(_ key: String) -> Any? { CFPreferencesCopyAppValue(key as CFString, dock) }
        let tile = (value("tilesize") as? NSNumber)?.doubleValue ?? 64
        let magnified = (value("magnification") as? Bool ?? false) ? (value("largesize") as? NSNumber)?.doubleValue ?? 128 : 0
        let reach = max(tile, magnified) + 24
        let frame = screen.frame, visible = screen.visibleFrame
        switch value("orientation") as? String {
        case "left":
            return CGRect(x: frame.minX, y: frame.minY, width: max(visible.minX - frame.minX, reach), height: frame.height)
        case "right":
            let depth = max(frame.maxX - visible.maxX, reach)
            return CGRect(x: frame.maxX - depth, y: frame.minY, width: depth, height: frame.height)
        default:
            return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: max(visible.minY - frame.minY, reach))
        }
    }

    private func add(_ mask: NSEvent.EventTypeMask, handler: @escaping @MainActor (DragWatcher, NSEvent) -> Void) {
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self, event)
            }
        }
        if let monitor { monitors.append(monitor) }
    }
}

/// Recognizes a side-to-side shake of the pointer: enough horizontal
/// direction changes, each after a long enough stroke, in a short time.
struct ShakeRecognizer {
    struct Tuning: Equatable {
        /// Horizontal travel, in points, before a change of direction counts.
        var minimumStroke: CGFloat
        /// Direction changes needed.
        var reversals: Int
        /// The changes must all fall within this many seconds.
        var window: TimeInterval

        /// With the key held the intent is plain, so a smaller shake does.
        static let wheel = Tuning(minimumStroke: 26, reversals: 3, window: 0.9)
    }

    let tuning: Tuning
    private var extreme: CGFloat?
    /// -1 left, 1 right, 0 before the first stroke.
    private var direction = 0
    private var reversalTimes: [TimeInterval] = []
    private var lastTime: TimeInterval = 0

    init(tuning: Tuning) {
        self.tuning = tuning
    }

    mutating func reset() {
        extreme = nil
        direction = 0
        reversalTimes.removeAll()
    }

    /// Feeds a pointer position; true when it completes a shake.
    mutating func add(_ point: CGPoint, at time: TimeInterval) -> Bool {
        defer { lastTime = time }
        guard let turn = extreme, time - lastTime <= tuning.window else {
            reset()
            extreme = point.x
            return false
        }
        let x = point.x
        if direction == 0 {
            if abs(x - turn) >= tuning.minimumStroke {
                direction = x > turn ? 1 : -1
                extreme = x
            }
            return false
        }
        if (x - turn) * CGFloat(direction) > 0 {
            extreme = x
            return false
        }
        guard abs(x - turn) >= tuning.minimumStroke else { return false }
        direction = -direction
        extreme = x
        reversalTimes.append(time)
        reversalTimes.removeAll { time - $0 > tuning.window }
        guard reversalTimes.count >= tuning.reversals else { return false }
        reset()
        return true
    }
}
