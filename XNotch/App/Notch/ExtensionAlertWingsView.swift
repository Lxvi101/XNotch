import SwiftUI
import XNotchKit

/// The closed notch's wings while an extension has something to say: its
/// symbol and title in the left wing, the value and its ring in the right.
struct ExtensionAlertWingsView: View {
    let alert: NotchAlert
    let notchSize: CGSize

    private var tint: Color { alert.tint.flatMap(Color.init(hex:)) ?? .white }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: alert.symbol)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(tint)
                    .symbolEffect(.bounce, options: .nonRepeating, value: alert)
                Text(alert.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
            }
            .frame(width: NotchMetrics.alertWingWidth - 14, alignment: .leading)
            Spacer(minLength: notchSize.width)
            HStack(spacing: 5) {
                Text(alert.value)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.95))
                if let progress = alert.progress {
                    AlertRing(progress: progress, tint: tint)
                }
            }
            .frame(width: NotchMetrics.alertWingWidth - 16, alignment: .trailing)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .padding(.leading, NotchMetrics.closedTopCornerRadius + 10)
        .padding(.trailing, NotchMetrics.closedTopCornerRadius + 12)
        .frame(width: NotchMetrics.alertWings(notchSize).outerWidth, height: notchSize.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(alert.title), \(alert.value)")
    }
}

/// The headphones' battery ring: sweeps up to its value once shown.
private struct AlertRing: View {
    let progress: Double
    let tint: Color

    @State private var fill: CGFloat = 0

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.16), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: fill)
                .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 15, height: 15)
        .onAppear {
            withAnimation(Motion.reduceMotion ? nil : .spring(response: 0.7, dampingFraction: 0.9).delay(0.1)) {
                fill = CGFloat(min(1, max(0, progress)))
            }
        }
    }
}
