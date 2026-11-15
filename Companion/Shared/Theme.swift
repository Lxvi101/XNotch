import SwiftUI
import UIKit

/// Light grey screen, white sheets, black ink and one dark "pass" card.
/// Every color has a dark-mode twin; the pass stays dark in both.
enum Palette {
    static let background = dynamic(light: 0xF2F2F4, dark: 0x0E0E10)
    /// The white sheets: cards, lists, the text box.
    static let card = dynamic(light: 0xFFFFFF, dark: 0x1A1A1D)
    /// Fills inside a sheet: icon wells, quick actions, empty tiles.
    static let raised = dynamic(light: 0xF1F1F4, dark: 0x26262A)
    static let line = dynamic(light: 0xE6E6EA, dark: 0x2A2A2E)
    /// Text, and the fill of the main buttons.
    static let ink = dynamic(light: 0x111113, dark: 0xF4F4F6)
    /// Text and symbols on an ink fill.
    static let onInk = dynamic(light: 0xFFFFFF, dark: 0x111113)
    static let secondary = dynamic(light: 0x6B6B73, dark: 0x9A9AA2)
    static let tertiary = dynamic(light: 0xA1A1A8, dark: 0x5C5C63)
    static let dots = dynamic(light: 0xE2E2E6, dark: 0x2A2A2F)

    static let passTop = dynamic(light: 0x2A2A2E, dark: 0x2E2E33)
    static let passBottom = dynamic(light: 0x141416, dark: 0x18181B)
    static let passLine = Color.white.opacity(0.09)
    static let passSecondary = Color.white.opacity(0.55)
    static let passTertiary = Color.white.opacity(0.4)

    static let green = Color(hex: 0x22C55E)
    static let orange = Color(hex: 0xF08A24)
    static let red = Color(hex: 0xEF4444)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

extension Color {
    init(hex: UInt32) { self.init(uiColor: UIColor(hex: hex)) }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

// MARK: Surfaces

extension View {
    /// A white sheet with a hairline edge.
    func sheetCard(radius: CGFloat = 24) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Palette.line.opacity(0.7), lineWidth: 1))
    }

    /// The dark glossy pass: gradient, a lit top edge and a soft drop shadow.
    func passCard(radius: CGFloat = 28) -> some View {
        background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(LinearGradient(colors: [Palette.passTop, Palette.passBottom], startPoint: .top, endPoint: .bottom))
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.02)], startPoint: .top, endPoint: .bottom),
                                      lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.28), radius: 16, y: 12)
        }
        .environment(\.colorScheme, .dark)
    }
}

// MARK: Buttons

/// The big pill: black "Scan Code", or a white secondary one.
struct PillButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(prominent ? Palette.onInk : Palette.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background {
                Capsule()
                    .fill(prominent ? Palette.ink : Palette.card)
                    .overlay { if !prominent { Capsule().strokeBorder(Palette.line, lineWidth: 1) } }
                    .shadow(color: .black.opacity(prominent ? 0.18 : 0), radius: 10, y: 6)
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// A round button: white with a hairline, or black ("+").
struct CircleButtonLabel: View {
    let symbol: String
    var size: CGFloat = 44
    var prominent = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.36, weight: .semibold))
            .foregroundStyle(prominent ? Palette.onInk : Palette.ink)
            .frame(width: size, height: size)
            .background(Circle().fill(prominent ? Palette.ink : Palette.card))
            .overlay { if !prominent { Circle().strokeBorder(Palette.line, lineWidth: 1) } }
            .shadow(color: .black.opacity(prominent ? 0.22 : 0.04), radius: prominent ? 9 : 2, y: prominent ? 6 : 1)
    }
}

/// Small caps label, as in "IPHONE" or "CONNECTED".
struct StatusCaps: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(color)
    }
}

/// The green "live" dot with its soft ring.
struct LiveDot: View {
    var color: Color = Palette.green

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .background(Circle().fill(color.opacity(0.22)).frame(width: 14, height: 14))
            .frame(width: 14, height: 14)
    }
}

/// A still field of fine dots, for empty and drop areas.
struct DotPattern: View {
    var spacing: CGFloat = 16

    var body: some View {
        Canvas { context, size in
            let color = GraphicsContext.Shading.color(Palette.dots)
            var y = spacing / 2
            while y < size.height {
                var x = spacing / 2
                while x < size.width {
                    context.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)), with: color)
                    x += spacing
                }
                y += spacing
            }
        }
        .allowsHitTesting(false)
    }
}
