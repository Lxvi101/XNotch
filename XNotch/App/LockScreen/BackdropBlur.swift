import AppKit
import SwiftUI

/// Frosted glass over whatever is behind the window: the wallpaper on the
/// Lock Screen, the desktop in a preview.
///
/// SwiftUI's materials follow the window's active state, and this window is
/// never active, so they render the flat inactive fill. This view is pinned
/// to the active state, and its rounded mask is applied in the window server
/// so the blur itself has the corners, not just the content above it.
struct BackdropBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        update(view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        update(view)
    }

    private func update(_ view: NSVisualEffectView) {
        view.material = material
        view.blendingMode = blending
        view.maskImage = Self.mask(cornerRadius: cornerRadius)
    }

    /// A stretchable rounded rectangle: only the corners keep their size.
    private static func mask(cornerRadius radius: CGFloat) -> NSImage {
        let edge = 2 * radius + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
