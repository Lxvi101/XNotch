import AppKit

/// XNotch runs without a menu bar, and AppKit finds ⌘C, ⌘V, ⌘X, ⌘A and ⌘Z
/// through the main menu's key equivalents. Without this menu, text fields
/// in the notch, the floating panels and Settings can't copy, paste or undo.
/// It stays invisible while XNotch is an accessory app; when the updater
/// briefly makes it a regular app, it shows as a plain Edit menu.
enum EditMenu {
    @MainActor
    static func install() {
        let main = NSMenu()

        // The first item is always the app menu. Quit has no ⌘Q, so the
        // shortcut can never reach XNotch from a focused notch by mistake.
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit XNotch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let plain = edit.addItem(withTitle: "Paste and Match Style",
                                 action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "V")
        plain.keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }
}
