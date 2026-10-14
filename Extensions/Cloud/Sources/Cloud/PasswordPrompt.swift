import AppKit

/// Asks for a link's password and lifetime. The notch can't take typing, so
/// this is a regular alert in front of everything.
@MainActor
enum PasswordPrompt {
    /// `nil` when cancelled.
    static func run(expiries: [(title: String, seconds: TimeInterval)],
                    defaultExpiry: TimeInterval) -> (password: String, expiresIn: TimeInterval)? {
        let alert = NSAlert()
        alert.messageText = "Link with Password"
        alert.informativeText = "People need this password to see or download the files. Send it to them separately."
        alert.icon = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)
        let share = alert.addButton(withTitle: "Copy Link")
        alert.addButton(withTitle: "Cancel")

        // Plain text, not dots: you have to pass it on, so a typo would lock everyone out.
        let field = NSTextField(string: "")
        field.placeholderString = "Password"
        let expiry = NSPopUpButton()
        for choice in expiries {
            expiry.addItem(withTitle: "Expires after \(choice.title)")
            expiry.lastItem?.representedObject = choice.seconds
        }
        expiry.selectItem(at: expiries.firstIndex { $0.seconds == defaultExpiry } ?? 0)

        let stack = NSStackView(views: [field, expiry])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: 56)
        field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        alert.accessoryView = stack
        alert.window.initialFirstResponder = field

        share.isEnabled = false
        let observer = NotificationCenter.default.addObserver(
            forName: NSControl.textDidChangeNotification, object: field, queue: .main
        ) { _ in
            MainActor.assumeIsolated { share.isEnabled = !field.stringValue.isEmpty }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return nil }
        let seconds = expiry.selectedItem?.representedObject as? TimeInterval ?? defaultExpiry
        return (field.stringValue, seconds)
    }
}
