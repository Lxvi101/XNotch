import AppKit
import SwiftUI

/// XNotch's visual language, so extension pages read as part of the notch.
public enum KitStyle {
    public static let primaryText = Color.white
    public static let secondaryText = Color.white.opacity(0.55)
    public static let tertiaryText = Color.white.opacity(0.35)
    /// Resting fill of a tile or control on the black notch surface.
    public static let fill = Color.white.opacity(0.06)
    public static let hoverFill = Color.white.opacity(0.1)
    public static let stroke = Color.white.opacity(0.09)
    /// The badge and "added" green.
    public static let green = Color(red: 0.36, green: 0.9, blue: 0.56)

    public static let tileCornerRadius: CGFloat = 14
}

public enum KitMotion {
    /// Content changes inside a surface: selection, hover, reordering.
    public static let content = Animation.spring(response: 0.34, dampingFraction: 0.86)
    public static let press = Animation.spring(response: 0.18, dampingFraction: 0.9)

    /// The notch changing shape: opening, and resizing to a page's new
    /// height (API 1.4.0). Animate a change that resizes your page with it,
    /// so your content and the notch move as one body.
    public static var shell: Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .easeOut(duration: 0.22) : .spring(response: 0.46, dampingFraction: 0.8)
    }
}

/// Presses sink slightly and spring back, the notch's button feel.
public struct PressScaleStyle: ButtonStyle {
    private let scale: CGFloat

    public init(scale: CGFloat = 0.86) {
        self.scale = scale
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(KitMotion.press, value: configuration.isPressed)
    }
}

extension Color {
    /// "#RRGGBB" or "RRGGBB"; nil when malformed.
    public init?(hex: String) {
        var string = hex.trimmingCharacters(in: .whitespaces)
        if string.hasPrefix("#") { string.removeFirst() }
        guard string.count == 6, let value = UInt32(string, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

// MARK: Glass

/// The frosted glass of XNotch's floating surfaces (API 1.10.0): Liquid
/// Glass on macOS 26 and later, a behind-window blur with a sheen and a lit
/// rim before. Draw it behind content clipped to the same shape:
///
///     content.background { KitGlass(shape: RoundedRectangle(cornerRadius: 28, style: .continuous)) }
///
/// `shade` darkens the glass for white text on any wallpaper (0 = clear, 1 = black).
/// Glass shows the desktop only in a window that isn't opaque
/// (`isOpaque = false`, `backgroundColor = .clear`).
public struct KitGlass<S: InsettableShape>: View {
    private let shape: S
    private let tint: Color?
    private let shade: Double

    public init(shape: S, tint: Color? = nil, shade: Double = 0.32) {
        self.shape = shape
        self.tint = tint
        self.shade = shade
    }

    public var body: some View {
        ZStack {
            if #available(macOS 26.0, *) {
                Color.clear.glassEffect(.regular.tint(glassTint), in: shape)
            } else {
                BehindWindowBlur()
                    .clipShape(shape)
                shape.fill(Color.black.opacity(shade))
                if let tint { shape.fill(tint.opacity(0.22)) }
                // Light catching the top of the pane.
                shape.fill(LinearGradient(colors: [.white.opacity(0.10), .white.opacity(0)],
                                          startPoint: .top, endPoint: .center))
            }
            // A lit edge, brighter where the light comes from.
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0.08), .white.opacity(0.14)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }

    private var glassTint: Color {
        if let tint { return tint.opacity(0.3) }
        return Color.black.opacity(shade)
    }
}

private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
