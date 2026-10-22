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
        let hosting = NSHostingController(rootView: view)
        // The split view has a minimum height of its own (the sidebar, plus the
        // toolbar). In a window shorter than that it overflowed and left a strip
        // under the sidebar, so the window takes its minimum size from SwiftUI.
        hosting.sizingOptions = [.minSize]
        window.contentViewController = hosting
        window.title = "XNotch Settings"
        // An opaque titlebar, so the toolbar keeps its material and the title
        // never sits on top of a pane scrolled beneath it.
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 720, height: 500))
        window.center()
        window.setFrameAutosaveName("XNotchSettings")
        // A size saved before the minimum existed may be too short.
        let minimum = hosting.sizeThatFits(in: NSSize(width: 720, height: 1))
        if window.frame.height < minimum.height {
            window.setContentSize(NSSize(width: max(window.frame.width, minimum.width), height: minimum.height))
        }
        window.delegate = self
        return window
    }

    /// Let go once closed: a closed window would keep its panes alive,
    /// observing media, extensions and preferences.
    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
