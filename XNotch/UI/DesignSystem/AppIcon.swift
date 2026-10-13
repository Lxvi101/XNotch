import AppKit

/// XNotch's icon: the notch with its eyes on a dark tile. build_app.sh
/// renders `drawn` into the bundle's AppIcon.icns; builds without an icon
/// file use the drawing directly, so the permission guide and System
/// Settings still show something recognisable.
@MainActor
enum AppIcon {
    /// Read from Info.plist rather than the bundle on disk, which may sit in
    /// a protected folder during development.
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "XNotch"

    static let image: NSImage = {
        let info = Bundle.main.infoDictionary ?? [:]
        if info["CFBundleIconFile"] != nil || info["CFBundleIconName"] != nil {
            return NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        }
        return drawn
    }()

    static let drawn = NSImage(size: NSSize(width: 512, height: 512), flipped: true) { bounds in
        let tile = bounds.insetBy(dx: 50, dy: 50)
        let radius = tile.width * 0.225
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 16
        shadow.shadowOffset = NSSize(width: 0, height: -8)
        shadow.set()
        let tilePath = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)
        NSColor(white: 0.12, alpha: 1).setFill()
        tilePath.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(colors: [NSColor(red: 0.42, green: 0.52, blue: 0.86, alpha: 1),
                            NSColor(red: 0.84, green: 0.84, blue: 0.9, alpha: 1),
                            NSColor(red: 0.62, green: 0.58, blue: 0.4, alpha: 1)])?
            .draw(in: tilePath, angle: 0)
        // Night falls from the horizon at the top, as in the onboarding.
        NSGradient(colors: [NSColor(white: 0.07, alpha: 0), NSColor(red: 0.08, green: 0.09, blue: 0.13, alpha: 1)],
                   atLocations: [0.08, 0.42], colorSpace: .sRGB)?
            .draw(in: tilePath, angle: 90)

        let notch = NSRect(x: tile.midX - tile.width * 0.27, y: tile.minY, width: tile.width * 0.54, height: tile.height * 0.3)
        let notchPath = NSBezierPath(roundedRect: notch, xRadius: notch.height * 0.42, yRadius: notch.height * 0.42)
        notchPath.append(NSBezierPath(rect: NSRect(x: notch.minX, y: notch.minY, width: notch.width, height: notch.height / 2)))
        NSColor.black.setFill()
        notchPath.fill()

        let eye = NSSize(width: tile.width * 0.055, height: tile.width * 0.12)
        for side in [-1.0, 1.0] {
            let rect = NSRect(x: tile.midX + side * tile.width * 0.07 - eye.width / 2,
                              y: notch.maxY - eye.height - notch.height * 0.16, width: eye.width, height: eye.height)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect, xRadius: eye.width / 2, yRadius: eye.width / 2).fill()
        }
        return true
    }
}
