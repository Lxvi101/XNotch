import AppKit
import SwiftUI

/// An entry in a `notchContextMenu`.
public struct NotchMenuItem {
    enum Kind {
        case action(title: String, symbol: String?, isDestructive: Bool, handler: @MainActor () -> Void)
        case separator
    }

    let kind: Kind

    public static func action(_ title: String, symbol: String? = nil, isDestructive: Bool = false,
                              handler: @escaping @MainActor () -> Void) -> NotchMenuItem {
        NotchMenuItem(kind: .action(title: title, symbol: symbol, isDestructive: isDestructive, handler: handler))
    }

    public static var separator: NotchMenuItem { NotchMenuItem(kind: .separator) }
}

extension View {
    /// A right-click (or control-click) menu that works inside the notch.
    /// SwiftUI's `contextMenu` doesn't: the notch panel isn't key while you
    /// hover it. Left clicks pass through to the view.
    public func notchContextMenu(_ items: @escaping @MainActor () -> [NotchMenuItem]) -> some View {
        overlay(NotchContextMenuArea(items: items))
    }
}

private struct NotchContextMenuArea: NSViewRepresentable {
    let items: @MainActor () -> [NotchMenuItem]

    func makeNSView(context: Context) -> NotchContextMenuView {
        let view = NotchContextMenuView()
        view.items = items
        return view
    }

    func updateNSView(_ view: NotchContextMenuView, context: Context) {
        view.items = items
    }
}

/// Only claims secondary clicks, so everything else reaches SwiftUI.
public final class NotchContextMenuView: NSView {
    var items: (@MainActor () -> [NotchMenuItem])?

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent, Self.isSecondaryClick(event) else { return nil }
        return super.hitTest(point)
    }

    public override func rightMouseDown(with event: NSEvent) {
        popUp(with: event)
    }

    public override func mouseDown(with event: NSEvent) {
        guard Self.isSecondaryClick(event) else { return super.mouseDown(with: event) }
        popUp(with: event)
    }

    static func isSecondaryClick(_ event: NSEvent) -> Bool {
        event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
    }

    private func popUp(with event: NSEvent) {
        MainActor.assumeIsolated {
            guard let items, case let entries = items(), !entries.isEmpty else { return }
            NSMenu.popUpContextMenu(Self.menu(entries), with: event, for: self)
        }
    }

    @MainActor public static func menu(_ entries: [NotchMenuItem]) -> NSMenu {
        let menu = NSMenu()
        for entry in entries {
            switch entry.kind {
            case .separator:
                menu.addItem(.separator())
            case let .action(title, symbol, isDestructive, handler):
                let item = HandlerMenuItem(title: title, handler: handler)
                item.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
                if isDestructive {
                    item.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.systemRed])
                }
                menu.addItem(item)
            }
        }
        return menu
    }
}

private final class HandlerMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() {
        MainActor.assumeIsolated { handler() }
    }
}
