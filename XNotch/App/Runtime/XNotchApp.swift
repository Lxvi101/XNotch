import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notch: NotchWindowController?
    private var lockScreen: LockScreenController?
    private var settings: SettingsWindowController?
    private let updater = SoftwareUpdater()

    func applicationDidFinishLaunching(_ notification: Notification) {
        LegacyMigration.run()
        updater.start()
        guard let screen = NotchWindowController.preferredScreen() else { return }
        let notch = NotchWindowController(screen: screen)
        let model = notch.model
        let lockScreen = LockScreenController(media: model.media, preferences: model.preferences)
        lockScreen.onLock = { [weak model] in model?.close() }
        let settings = SettingsWindowController(model: model, lockScreen: lockScreen, updater: updater)
        model.onOpenSettings = { [weak settings] in settings?.show() }
        self.notch = notch
        self.lockScreen = lockScreen
        self.settings = settings
    }

    /// There's no Dock icon or menu bar, so opening the app again shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings?.show()
        return false
    }

    /// xnotch://open/<music|shelf|extension-id[/page-id]>, xnotch://close,
    /// xnotch://settings[/<pane>], xnotch://lockscreen/preview, xnotch://pills/preview
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "xnotch" {
            handle(url)
        }
    }

    private func handle(_ url: URL) {
        let path = url.pathComponents.filter { $0 != "/" }
        switch url.host {
        case "open":
            guard let model = notch?.model, let target = path.first else { return }
            switch target {
            case "music": model.open(page: .media)
            case "shelf": model.open(page: .shelf)
            default:
                let page = model.extensionPages.first {
                    $0.extensionID == target && (path.count < 2 || $0.descriptor.id == path[1])
                }
                if let page { model.open(page: page.page) }
            }
        case "close":
            notch?.model.close()
        case "settings":
            let panes: [String: SettingsPane] = [
                "general": .general, "music": .music, "lockscreen": .lockScreen,
                "shelf": .shelf, "extensions": .extensions, "about": .about
            ]
            let pane = path.first.map { panes[$0] ?? .extensionPane($0) }
            settings?.show(pane: pane)
        case "lockscreen":
            if path.first == "preview" { lockScreen?.preview() }
        case "pills":
            if path.first == "preview" { notch?.model.previewPills() }
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
