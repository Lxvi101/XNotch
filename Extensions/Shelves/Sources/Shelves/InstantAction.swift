import AppKit

/// Something a dragged file can be dropped on: drag onto the shelf's bolt and
/// the shelf turns into a grid of these.
enum InstantAction: String, CaseIterable, Codable, Identifiable, Hashable {
    case airDrop, messages, mail, notchShelf, copy, reveal

    static let disabledByDefault: Set<InstantAction> = [.copy, .reveal]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .airDrop: "AirDrop"
        case .messages: "Messages"
        case .mail: "Mail"
        case .notchShelf: "Tray"
        case .copy: "Copy"
        case .reveal: "Show in Finder"
        }
    }

    /// Whether macOS offers the action. Creating a sharing service loads its
    /// extension, so this is worked out once, not on every drag update.
    var isAvailable: Bool { Self.availability[self] ?? true }

    private static let availability: [InstantAction: Bool] = [
        .airDrop: NSSharingService(named: .sendViaAirDrop) != nil,
        .messages: NSSharingService(named: .composeMessage) != nil,
        .mail: NSSharingService(named: .composeEmail) != nil,
    ]

    /// The app's own icon where there is one, so the grid reads at a glance.
    @MainActor var icon: NSImage {
        if let icon = Self.icons[self] { return icon }
        let icon = makeIcon()
        Self.icons[self] = icon
        return icon
    }

    @MainActor private static var icons: [InstantAction: NSImage] = [:]

    @MainActor private func makeIcon() -> NSImage {
        let workspace = NSWorkspace.shared
        func app(_ id: String) -> NSImage? {
            workspace.urlForApplication(withBundleIdentifier: id).map { workspace.icon(forFile: $0.path) }
        }
        switch self {
        case .airDrop:
            let path = "/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app"
            if FileManager.default.fileExists(atPath: path) { return workspace.icon(forFile: path) }
            return Self.symbol("dot.radiowaves.left.and.right")
        case .messages: return app("com.apple.MobileSMS") ?? Self.symbol("message.fill")
        case .mail: return app("com.apple.mail") ?? Self.symbol("envelope.fill")
        case .notchShelf: return NSApp.applicationIconImage ?? Self.symbol("tray.fill")
        case .copy: return Self.symbol("doc.on.doc.fill")
        case .reveal: return app("com.apple.finder") ?? Self.symbol("folder.fill")
        }
    }

    /// A white glyph on a blue app-icon-shaped tile, for actions without an app.
    private static func symbol(_ name: String) -> NSImage {
        let side: CGFloat = 64
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let tile = rect.insetBy(dx: 6, dy: 6)
            NSColor(red: 0.04, green: 0.52, blue: 1, alpha: 1).setFill()
            NSBezierPath(roundedRect: tile, xRadius: 12, yRadius: 12).fill()
            let configuration = NSImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
                .applying(.init(paletteColors: [.white]))
            if let glyph = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
                let size = glyph.size
                glyph.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
            }
            return true
        }
    }

    /// Runs the action; false when it couldn't.
    @MainActor func perform(with urls: [URL], sendToNotchShelf: ([URL]) -> Void) -> Bool {
        guard !urls.isEmpty else { return false }
        func share(_ name: NSSharingService.Name) -> Bool {
            guard let service = NSSharingService(named: name), service.canPerform(withItems: urls) else { return false }
            NSApp.activate(ignoringOtherApps: true)
            service.perform(withItems: urls)
            return true
        }
        switch self {
        case .airDrop: return share(.sendViaAirDrop)
        case .messages: return share(.composeMessage)
        case .mail: return share(.composeEmail)
        case .notchShelf:
            sendToNotchShelf(urls)
            return true
        case .copy:
            FileActions.copyToPasteboard(urls)
            return true
        case .reveal:
            FileActions.reveal(urls)
            return true
        }
    }
}
