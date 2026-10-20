import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var displays: NotchDisplays?
    private var lockScreen: LockScreenController?
    private var settings: SettingsWindowController?
    private var onboarding: OnboardingController?
    private let updater = SoftwareUpdater()

    func applicationDidFinishLaunching(_ notification: Notification) {
        LegacyMigration.run()
        NSApp.applicationIconImage = AppIcon.image
        updater.start()
        guard let displays = NotchDisplays() else { return }
        let model = displays.model
        let lockScreen = LockScreenController(media: model.media, preferences: model.preferences)
        lockScreen.onLock = { [weak displays] in displays?.close() }
        let onboarding = OnboardingController(model: model, preferences: model.preferences)
        let settings = SettingsWindowController(model: model, lockScreen: lockScreen, updater: updater,
                                                onReplayOnboarding: { [weak onboarding] in onboarding?.start() })
        displays.onOpenSettings = { [weak settings] pane in settings?.show(pane: pane) }
        let permissions = PermissionCenter.shared
        permissions.onGuideMoved = { [weak displays] frame in displays?.models.forEach { $0.watchPermissionGuide(frame) } }
        permissions.onGuideFinished = { [weak displays] granted in
            displays?.models.forEach { $0.permissionGuideFinished(granted: granted) }
        }
        self.displays = displays
        self.lockScreen = lockScreen
        self.settings = settings
        self.onboarding = onboarding
        if model.preferences.hasCompletedOnboarding {
            displays.startServices()
        } else {
            // Services that read files wait for the Full Disk Access step.
            onboarding.onSettled = { [weak displays] in displays?.startServices() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak onboarding, weak displays] in
                if onboarding?.startIfNeeded() != true { displays?.startServices() }
            }
        }
    }

    /// There's no Dock icon or menu bar, so opening the app again shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard onboarding?.isRunning != true else { return false }
        settings?.show()
        return false
    }

    /// xnotch://open/<music|tray|extension-id[/page-id]>, xnotch://close,
    /// xnotch://settings[/<pane>], xnotch://lockscreen/preview, xnotch://pills/preview, xnotch://onboarding,
    /// xnotch://permissions/<fullDiskAccess|accessibility|screenRecording>
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "xnotch" {
            handle(url)
        }
    }

    private func handle(_ url: URL) {
        let path = url.pathComponents.filter { $0 != "/" }
        switch url.host {
        case "open":
            guard let model = displays?.activeModel, let target = path.first else { return }
            switch target {
            case "music": model.open(page: .media)
            case "tray", "shelf": model.open(page: .shelf)
            default:
                let page = model.extensionPages.first {
                    $0.extensionID == target && (path.count < 2 || $0.descriptor.id == path[1])
                }
                if let page { model.open(page: page.page) }
            }
        case "close":
            displays?.close()
        case "settings":
            let panes: [String: SettingsPane] = [
                "general": .general, "music": .music, "lockscreen": .lockScreen,
                "tray": .shelf, "shelf": .shelf, "extensions": .extensions, "changelog": .changelog, "about": .about
            ]
            let pane = path.first.map { panes[$0] ?? .extensionPane($0) }
            settings?.show(pane: pane)
        case "lockscreen":
            if path.first == "preview" { lockScreen?.preview() }
        case "pills":
            if path.first == "preview" { displays?.activeModel.previewPills() }
        case "onboarding":
            onboarding?.start()
        case "permissions":
            if let permission = path.first.flatMap(Permission.init(rawValue:)) {
                PermissionCenter.shared.request(permission)
            }
        default:
            break
        }
    }
}

@main
enum XNotchMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
