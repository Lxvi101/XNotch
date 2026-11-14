import AppKit
import XNotchKit

/// Notices when XNotch or an extension needs a permission it doesn't have
/// (a grant an update added, an extension switched on in Settings, a grant
/// macOS dropped) and runs just that step of the welcome tour.
///
/// It looks at launch, whenever an extension starts, after the Mac wakes and
/// when XNotch comes forward. It waits while the tour, a permission guide,
/// the lock screen or a full-screen app is up. What the user turned down
/// with "Not Now" isn't asked again until it's been granted once; Settings
/// can always ask.
@MainActor
final class PermissionCheckup {
    private let onboarding: OnboardingController
    private let extensions: ExtensionManager
    private let preferences: Preferences
    private var scheduled: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    /// What a checkup has already shown this launch. Asked for on its own
    /// at most once a launch, so an extension that reports a grant it then
    /// doesn't see can't bring the checkup back over and over.
    private var shown: Set<String> = []

    init(onboarding: OnboardingController, extensions: ExtensionManager, preferences: Preferences) {
        self.onboarding = onboarding
        self.extensions = extensions
        self.preferences = preferences
    }

    func start() {
        guard observers.isEmpty else { return }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule(after: 3) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule(after: 1) }
        })
        schedule(after: 1.5)
    }

    /// Checks once things have been quiet for `delay`; repeated calls coalesce,
    /// so a launch that starts ten extensions checks once.
    func schedule(after delay: TimeInterval = 1.2) {
        scheduled?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.check(includingDeclined: false) }
        }
        scheduled = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Settings' "Allow…": everything missing, including what was turned down.
    func review() {
        scheduled?.cancel()
        check(includingDeclined: true)
    }

    private func check(includingDeclined: Bool) {
        // The tour asks for itself, and says when it's done.
        guard preferences.hasCompletedOnboarding, !onboarding.isRunning else { return }
        guard PermissionCenter.shared.activeRequest == nil, !Self.screenIsLocked, !Self.fullScreenAppIsFrontmost else {
            return schedule(after: 5)
        }
        PermissionCenter.shared.refresh()
        let pending = extensions.pendingPermissions
        Self.forgetGranted(pending: pending, activeExtensions: Set(extensions.entries.filter(\.isActive).map(\.id)))

        let declined = Self.declined
        let skipped = includingDeclined ? [] : declined.union(shown)
        let own = Permission.requested.filter { !$0.isGranted && !skipped.contains(Self.key($0)) }
        let others = pending.filter { !skipped.contains($0.key) }
        if onboarding.startCheckup(own: own, extensions: others) {
            shown.formUnion(own.map(Self.key) + others.map(\.key))
        }
    }

    // MARK: Turned down

    private static let declinedKey = "declinedPermissions"

    static func key(_ permission: Permission) -> String { "xnotch/\(permission.rawValue)" }

    static var declined: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: declinedKey) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: declinedKey) }
    }

    static func decline(_ permission: Permission) {
        declined.insert(key(permission))
    }

    static func decline(_ pending: ExtensionManager.PendingPermission) {
        declined.insert(pending.key)
    }

    /// A permission granted since it was turned down is asked for again if
    /// it ever goes missing. Only what can be checked is forgotten: an
    /// extension that isn't running can't say what it has.
    private static func forgetGranted(pending: [ExtensionManager.PendingPermission], activeExtensions: Set<ExtensionID>) {
        let current = declined
        guard !current.isEmpty else { return }
        let missing = Set(pending.map(\.key))
        let kept = current.filter { key in
            let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return false }
            if parts[0] == "xnotch" {
                return Permission(rawValue: parts[1]).map { !$0.isGranted } ?? false
            }
            return !activeExtensions.contains(parts[0]) || missing.contains(key)
        }
        if kept != current { declined = kept }
    }

    // MARK: When not to interrupt

    private static var screenIsLocked: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// A video or a presentation filling the main screen.
    private static var fullScreenAppIsFrontmost: Bool {
        guard let screen = NotchDisplays.mainScreen(),
              let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return false }
        return windows.contains { info in
            guard info[kCGWindowOwnerPID as String] as? pid_t == front.processIdentifier,
                  info[kCGWindowLayer as String] as? Int ?? 0 == 0,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary) else { return false }
            return bounds.width >= screen.frame.width && bounds.height >= screen.frame.height
        }
    }
}
