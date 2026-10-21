import AppKit
import Combine

/// The single way XNotch asks for a permission: opens the right pane in
/// System Settings, docks a guide under its window with XNotch's icon to drag
/// into the list, and watches for the grant.
@MainActor
final class PermissionCenter: ObservableObject {
    static let shared = PermissionCenter()

    @Published private(set) var granted: Set<Permission> = []
    @Published private(set) var activeRequest: Permission?
    /// Screen frame of the guide while it's up (nil once it leaves), so the notch can watch it.
    var onGuideMoved: ((NSRect?) -> Void)?
    var onGuideFinished: ((Bool) -> Void)?

    private var guide: PermissionGuideController?
    private var pollTimer: Timer?

    private init() {
        refresh()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func isGranted(_ permission: Permission) -> Bool { granted.contains(permission) }

    func refresh() {
        let current = Set(Permission.allCases.filter(\.isGranted))
        if current != granted { granted = current }
    }

    /// `source` is the screen rect the guide flies out of, usually the button
    /// that asked. `completion` gets whether the permission ended up granted.
    func request(_ permission: Permission, from source: NSRect? = nil, completion: ((Bool) -> Void)? = nil) {
        refresh()
        guard !granted.contains(permission) else {
            completion?(true)
            return
        }
        guide(permission, subject: .xnotch, from: source, isGranted: { permission.isGranted }) { [weak self] granted in
            self?.refresh()
            completion?(granted)
        }
    }

    /// The same guide for another app, which has to answer for its own grants.
    func request(_ permission: Permission, for app: URL, from source: NSRect? = nil,
                 isGranted: @escaping @Sendable () async -> Bool) async -> Bool {
        if await isGranted() { return true }
        return await withCheckedContinuation { continuation in
            guide(permission, subject: .app(at: app), from: source, isGranted: isGranted) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func guide(_ permission: Permission, subject: PermissionSubject, from source: NSRect?,
                       isGranted: @escaping @Sendable () async -> Bool, completion: @escaping (Bool) -> Void) {
        guide?.dismiss()
        let pointer = NSEvent.mouseLocation
        let guide = PermissionGuideController(
            permission: permission,
            subject: subject,
            source: source ?? NSRect(x: pointer.x - 20, y: pointer.y - 20, width: 40, height: 40)
        )
        var wasGranted = false
        guide.onMove = { [weak self] frame in self?.onGuideMoved?(frame) }
        guide.onFinish = { [weak self, weak guide] _ in
            guard let self, let guide, self.guide === guide else { return }
            self.guide = nil
            activeRequest = nil
            pollTimer?.invalidate()
            pollTimer = nil
            onGuideMoved?(nil)
            onGuideFinished?(wasGranted)
            completion(wasGranted)
        }
        self.guide = guide
        activeRequest = permission
        guide.start()

        pollTimer?.invalidate()
        var checking = false
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard !checking else { return }
                checking = true
                Task { @MainActor [weak self, weak guide] in
                    let granted = await isGranted()
                    checking = false
                    guard granted, let self, let guide, self.guide === guide else { return }
                    wasGranted = true
                    self.pollTimer?.invalidate()
                    self.pollTimer = nil
                    self.refresh()
                    guide.markGranted()
                }
            }
        }
    }

    /// Calls off the request in progress, as if its guide had been closed.
    func cancel() {
        guide?.dismiss()
    }

    /// Starts a fresh copy once this one has quit, for grants macOS only
    /// applies at launch.
    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$0\"",
                          Bundle.main.bundlePath, "\(ProcessInfo.processInfo.processIdentifier)"]
        try? task.run()
        NSApp.terminate(nil)
    }
}

/// Follows System Settings' main window through the window server, which
/// needs no permission of its own (window bounds are not protected).
@MainActor
final class SystemSettingsTracker {
    nonisolated static let bundleIdentifier = "com.apple.systempreferences"

    var onChange: ((NSRect?) -> Void)?
    private(set) var frame: NSRect?
    private var timer: Timer?
    /// System Settings briefly has no window while it swaps panes.
    private var misses = 0

    var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.bundleIdentifier
    }

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer?.tolerance = 0.004
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let next = Self.windowFrame()
        if next == nil {
            misses += 1
            guard misses >= 12 else { return }
        } else {
            misses = 0
        }
        guard next != frame else { return }
        frame = next
        onChange?(next)
    }

    /// The largest on-screen, normal-level window of System Settings, in AppKit coordinates.
    private static func windowFrame() -> NSRect? {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .map(\.processIdentifier))
        guard !pids.isEmpty,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return nil }
        // Window server rects have a top-left origin on the primary display.
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return windows.compactMap { info -> NSRect? in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  info[kCGWindowLayer as String] as? Int ?? 0 == 0,
                  info[kCGWindowAlpha as String] as? Double ?? 1 > 0,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary),
                  bounds.width > 320, bounds.height > 240 else { return nil }
            return NSRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
        }
        .max { $0.width * $0.height < $1.width * $1.height }
    }
}
