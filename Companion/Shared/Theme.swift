import SwiftUI

enum Palette {
    static let background = Color(white: 0.04)
    static let card = Color(white: 0.11)
    static let raised = Color(white: 0.17)
    static let secondary = Color(white: 0.56)
    static let tertiary = Color(white: 0.34)
    static let green = Color(red: 0.2, green: 0.84, blue: 0.4)
    static let blue = Color(red: 0.16, green: 0.56, blue: 1)
    static let cyan = Color(red: 0.3, green: 0.85, blue: 1)
}

/// The big dark pill: "Continue", "Scan Code".
struct PillButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(prominent ? .black : .white)
            .frame(maxWidth: .infinity)
            .frame(height: 60)
            .background {
                Capsule()
                    .fill(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(
                        LinearGradient(colors: [Color(white: 0.18), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)))
                    .overlay {
                        Capsule().strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.03)], startPoint: .top, endPoint: .bottom),
                            lineWidth: 1)
                    }
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// The round dark buttons of the bottom bar.
struct CircleButtonLabel: View {
    let symbol: String
    var size: CGFloat = 54

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Palette.card))
            .overlay(Circle().strokeBorder(.white.opacity(0.07), lineWidth: 1))
    }
}

/// Small caps label, as in "CONNECTED".
struct StatusCaps: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 13, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(color)
    }
}

/// A field of dots, brightening where a soft glow slowly breathes up from
/// the bottom. Decoration only: it doesn't react to touches.
struct DotGrid: View {
    var spacing: CGFloat = 19
    var intensity: Double = 1
    @Environment(\.dotGridPaused) private var paused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // A slow drift needs few frames; none at all with Reduce Motion or in Low Power Mode.
        let still = paused || reduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled
        TimelineView(.animation(minimumInterval: 1 / 20, paused: still)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let center = CGPoint(x: size.width / 2 + sin(time * 0.6) * size.width * 0.12,
                                              y: size.height * (1.02 - 0.04 * sin(time * 0.9)))
                let reach = max(size.width, size.height) * 0.42
                let columns = Int(size.width / spacing)
                let rows = Int(size.height / spacing)
                let inset = CGPoint(x: (size.width - CGFloat(columns - 1) * spacing) / 2,
                                    y: (size.height - CGFloat(rows - 1) * spacing) / 2)
                for row in 0..<rows {
                    for column in 0..<columns {
                        let point = CGPoint(x: inset.x + CGFloat(column) * spacing, y: inset.y + CGFloat(row) * spacing)
                        let distance = hypot(point.x - center.x, point.y - center.y)
                        let glow = max(0, 1 - distance / reach)
                        let eased = glow * glow * (3 - 2 * glow) * intensity
                        let radius = 0.9 + 3.6 * eased
                        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
                        context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.2 + 0.7 * eased)))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// A title, a grey line under it, the picture, and one way forward.
struct StepLayout<Visual: View, Actions: View>: View {
    let title: String
    let subtitle: String
    var footer: String?
    @ViewBuilder let visual: Visual
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 38, weight: .bold))
                .foregroundStyle(.white)
                .padding(.top, 40)
            Text(subtitle)
                .font(.system(size: 20))
                .foregroundStyle(Palette.secondary)
                .lineSpacing(4)
                .padding(.top, 12)
                .fixedSize(horizontal: false, vertical: true)
            visual
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            actions
            if let footer {
                Text(footer)
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.tertiary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .padding(.top, 18)
            }
        }
        .padding(.horizontal, 26)
        .padding(.bottom, 12)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }
}

private struct DotGridPausedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Stops the dot grids' idle animation, for when they can't be seen.
    var dotGridPaused: Bool {
        get { self[DotGridPausedKey.self] }
        set { self[DotGridPausedKey.self] = newValue }
    }
}
