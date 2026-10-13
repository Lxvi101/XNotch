import AppKit
import SwiftUI

/// Borderless, non-activating panel that sits above the menu bar on every
/// space. Mouse events pass through except while the pointer is over the shell.
final class NotchWindow: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
        hidesOnDeactivate = false
    }

    /// Key status is only granted while the shelf is open and was clicked, so
    /// the notch never steals typing from the frontmost app otherwise.
    var acceptsKeyboard = false

    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }

    func takeKeyboard() {
        acceptsKeyboard = true
        if !isKeyWindow { makeKey() }
    }

    /// Ordering a key panel out hands keyboard focus back to the active app's
    /// key window; ordering straight back in keeps the notch visible.
    func releaseKeyboard() {
        acceptsKeyboard = false
        guard isKeyWindow else { return }
        orderOut(nil)
        orderFrontRegardless()
    }
}

final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
