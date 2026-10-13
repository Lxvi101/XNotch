import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: NotchViewModel
    private let lockScreen: LockScreenController
    private let updater: SoftwareUpdater
    private let navigation = SettingsNavigation()
    private let onReplayOnboarding: () -> Void

    init(model: NotchViewModel, lockScreen: LockScreenController, updater: SoftwareUpdater,
         onReplayOnboarding: @escaping () -> Void) {
        self.model = model
        self.lockScreen = lockScreen
        self.updater = updater
        self.onReplayOnboarding = onReplayOnboarding
    }

    func show(pane: SettingsPane? = nil) {
        if let pane { navigation.selection = pane }
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let view = SettingsView(navigation: navigation, preferences: .shared, extensions: model.extensions,
                                updater: updater,
                                shelf: model.shelf, media: model.media,
                                onPreviewLockScreen: { [weak self] in self?.lockScreen.preview() },
                                onReplayOnboarding: { [weak self] in
                                    self?.window?.orderOut(nil)
                                    self?.onReplayOnboarding()
                                })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentViewController = NSHostingController(rootView: view)
        window.title = "XNotch Settings"
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 720, height: 500))
        window.center()
        window.setFrameAutosaveName("XNotchSettings")
        window.delegate = self
        return window
    }
}
