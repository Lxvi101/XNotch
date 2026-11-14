import AppKit

/// The folder's face in the menu bar: a rounded tile holding up to four of
/// its icons, like a folder on the Home Screen. Drawn when shown, so it picks
/// up the menu bar's current appearance.
enum FolderGlyph {
    /// Symbols a folder can wear instead of its contents.
    static let symbols: [(name: String, title: String)] = [
        ("folder.fill", "Folder"), ("tray.fill", "Tray"), ("archivebox.fill", "Box"),
        ("square.grid.2x2.fill", "Grid"), ("ellipsis.circle.fill", "More"), ("star.fill", "Star"),
        ("heart.fill", "Heart"), ("bolt.fill", "Bolt"), ("wrench.and.screwdriver.fill", "Tools"),
        ("hammer.fill", "Hammer"), ("gearshape.fill", "Gear"), ("network", "Network"),
        ("wifi", "Wi-Fi"), ("lock.fill", "Lock"), ("cloud.fill", "Cloud"), ("music.note", "Music"),
        ("camera.fill", "Camera"), ("message.fill", "Messages"), ("paperplane.fill", "Send"),
        ("briefcase.fill", "Work"), ("house.fill", "Home"), ("gamecontroller.fill", "Games"),
        ("sparkles", "Sparkles"), ("leaf.fill", "Leaf"),
    ]

    /// The folder's face: its symbol when it has one, else its icons.
    static func image(for folder: BarFolder, icons: [NSImage]) -> NSImage {
        if let name = folder.symbol,
           let symbol = NSImage(systemSymbolName: name, accessibilityDescription: folder.name)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium)) {
            // A template, so it takes the menu bar's colour like the system's icons.
            symbol.isTemplate = true
            return symbol
        }
        return image(for: icons)
    }

    static func image(for icons: [NSImage]) -> NSImage {
        guard !icons.isEmpty else {
            let empty = NSImage(systemSymbolName: "square.dashed", accessibilityDescription: "Empty folder")
                ?? NSImage()
            empty.isTemplate = true
            return empty
        }
        let side: CGFloat = 17
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            let tile = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 4.5, yRadius: 4.5)
            NSColor.labelColor.withAlphaComponent(0.14).setFill()
            tile.fill()
            NSColor.labelColor.withAlphaComponent(0.55).setStroke()
            tile.lineWidth = 1.1
            tile.stroke()

            if icons.count == 1, let icon = icons.first {
                // One icon fills the folder rather than a quarter of it.
                let box = rect.insetBy(dx: 3.5, dy: 3.5)
                icon.draw(in: aspectFit(icon.size, in: box), from: .zero, operation: .sourceOver, fraction: 1,
                          respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
                return true
            }
            let inset: CGFloat = 3, gap: CGFloat = 1.5
            let cell = (side - inset * 2 - gap) / 2
            for (index, icon) in icons.prefix(4).enumerated() {
                let column = CGFloat(index % 2), row = CGFloat(index / 2)
                let box = NSRect(x: inset + column * (cell + gap), y: inset + row * (cell + gap), width: cell, height: cell)
                icon.draw(in: aspectFit(icon.size, in: box), from: .zero, operation: .sourceOver, fraction: 1,
                          respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            }
            return true
        }
        image.accessibilityDescription = "Folder"
        return image
    }

    static func aspectFit(_ size: NSSize, in box: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        let fitted = NSSize(width: size.width * scale, height: size.height * scale)
        return NSRect(x: box.midX - fitted.width / 2, y: box.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }
}
