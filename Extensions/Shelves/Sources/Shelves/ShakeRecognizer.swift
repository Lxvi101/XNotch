import AppKit

/// Recognizes a side-to-side shake of the pointer: enough horizontal
/// direction changes, each after a long enough stroke, in a short time.
/// Pure, so it can be tested without events.
struct ShakeRecognizer {
    struct Tuning: Equatable {
        /// Horizontal travel, in points, before a change of direction counts.
        var minimumStroke: CGFloat
        /// Direction changes needed.
        var reversals: Int
        /// The changes must all fall within this many seconds; a pause this
        /// long starts over.
        var window: TimeInterval
    }

    var tuning: Tuning

    /// x where the current stroke turned furthest.
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

    /// Feeds a pointer position; true when it completes a shake, after which
    /// the recognizer starts over.
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

/// Watches file drags in other apps and asks for a shelf when the pointer is
/// shaken, or a modifier key is held, mid-drag. Drags that start in an
/// ignored app are left alone.
@MainActor
final class DragMonitor {
    /// The pointer, in screen coordinates, when a shelf should appear.
    var onTrigger: ((CGPoint) -> Void)?
    /// The drag that asked for a shelf has let go, wherever it landed.
    var onTriggeringDragEnded: (() -> Void)?

    private let preferences: ShelvesPreferences
    private var monitors: [Any] = []
    private let dragPasteboard = NSPasteboard(name: .drag)
    private var changeCount = -1
    private var isMouseDown = false
    private var isDragging = false
    private var hasTriggered = false
    private var isIgnored = false
    private var mouseDownTime: TimeInterval = 0
    private var draggedEvents = 0
    private var recognizer: ShakeRecognizer

    init(preferences: ShelvesPreferences) {
        self.preferences = preferences
        recognizer = ShakeRecognizer(tuning: preferences.sensitivity.tuning)
    }

    func start() {
        stop()
        add(.leftMouseDown) { monitor, _ in monitor.mouseDown() }
        add(.leftMouseDragged) { monitor, event in monitor.mouseDragged(event) }
        add(.leftMouseUp) { monitor, _ in monitor.mouseUp() }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        hasTriggered = false
        mouseUp()
    }

    private func mouseDown() {
        changeCount = dragPasteboard.changeCount
        isMouseDown = true
        isDragging = false
        hasTriggered = false
        isIgnored = false
        mouseDownTime = ProcessInfo.processInfo.systemUptime
        draggedEvents = 0
        recognizer = ShakeRecognizer(tuning: preferences.sensitivity.tuning)
    }

    private func mouseDragged(_ event: NSEvent) {
        guard isMouseDown, !isIgnored, !hasTriggered else { return }
        if !isDragging {
            // Every drag in every app lands here, including text selections and
            // window moves. Reading the drag pasteboard is a round trip to the
            // pasteboard server, so after the first second, when a file drag
            // would long have begun, only every eighth event looks.
            draggedEvents += 1
            if event.timestamp - mouseDownTime > 1, draggedEvents % 8 != 0 { return }
            guard dragPasteboard.changeCount != changeCount, PasteboardReader.canRead(dragPasteboard) else { return }
            isDragging = true
            // Read once the drag has begun: by then a click into a background
            // window has made its app frontmost.
            let source = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            isIgnored = source.map(preferences.isIgnored) ?? false
            if isIgnored { return }
        }
        let point = NSEvent.mouseLocation
        let modifier = preferences.modifierEnabled && event.modifierFlags.contains(preferences.modifier.flags)
        let shaken = preferences.shakeEnabled && recognizer.add(point, at: event.timestamp)
        guard modifier || shaken else { return }
        hasTriggered = true
        onTrigger?(point)
    }

    private func mouseUp() {
        if hasTriggered {
            hasTriggered = false
            onTriggeringDragEnded?()
        }
        isMouseDown = false
        isDragging = false
        changeCount = -1
    }

    private func add(_ mask: NSEvent.EventTypeMask, handler: @escaping @MainActor (DragMonitor, NSEvent) -> Void) {
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self, event)
            }
        }
        if let monitor { monitors.append(monitor) }
    }
}
