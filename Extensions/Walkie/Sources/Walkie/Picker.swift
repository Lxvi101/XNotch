import AppKit

extension NSOpenPanel {
    /// Shows the picker above the notch and the menu bar panel, without a modal loop.
    ///
    /// Both of those windows float above normal windows. A picker at its usual level sits
    /// under them, and while `runModal` runs, the clicks they catch go nowhere: the picker
    /// looks open but can't be used. `begin` also keeps the run loop in its normal mode,
    /// so the notch keeps tracking the pointer.
    func presentAboveOverlays(_ chosen: @escaping @MainActor ([URL]) -> Void) {
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
        NSApp.activate(ignoringOtherApps: true)
        // Leave the SwiftUI action that asked for it before showing anything.
        DispatchQueue.main.async {
            self.begin { response in
                let urls = response == .OK ? self.urls : []
                MainActor.assumeIsolated { chosen(urls) }
            }
            self.makeKeyAndOrderFront(nil)
        }
    }
}
