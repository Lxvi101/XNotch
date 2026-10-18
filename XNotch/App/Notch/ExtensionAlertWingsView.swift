import SwiftUI
import XNotchKit

/// The closed notch's wings while an extension has something to say: its
/// symbol and title in the left wing, the value and its ring in the right.
/// Shown with eyes, a warning sign takes the symbol's place and the eyes
/// take the value's, reacting to how serious it is.
struct ExtensionAlertWingsView: View {
    let alert: NotchAlert
    var eyes: NotchAlertSeverity?
    let notchSize: CGSize

    private var tint: Color { alert.tint.flatMap(Color.init(hex:)) ?? .white }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: eyes == nil ? alert.symbol : "exclamationmark.triangle.fill")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(eyes == nil ? tint : .yellow)
                    .symbolEffect(.bounce, options: .nonRepeating, value: alert)
                Text(alert.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
            }
            .frame(width: NotchMetrics.alertWingWidth - 14, alignment: .leading)
            Spacer(minLength: notchSize.width)
            if let eyes {
                AlertEyes(severity: eyes, unit: notchSize.height)
                    .frame(width: NotchMetrics.alertWingWidth - 16, alignment: .trailing)
            } else {
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
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .padding(.leading, NotchMetrics.closedTopCornerRadius + 10)
        // The eyes sit closer to the edge than text, which needs room from the curve.
        .padding(.trailing, NotchMetrics.closedTopCornerRadius + (eyes == nil ? 12 : 6))
        .frame(width: NotchMetrics.alertWings(notchSize).outerWidth, height: notchSize.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(alert.title), \(alert.value)")
    }
}

/// The notch's eyes in the right wing: glancing side to side for a caution;
/// when critical, growing wide and round, the pupils widening before it ends.
private struct AlertEyes: View {
    let severity: NotchAlertSeverity
    let unit: CGFloat

    @State private var eyes = NotchEyes()

    var body: some View {
        NotchEyesView(eyes: eyes, unit: unit)
            .frame(width: unit * 1.5, height: unit)
            .task {
                // Looking straight out, at nothing in particular.
                eyes.focus = eyes.anchor
                guard severity == .critical else {
                    eyes.expression = .worried
                    return
                }
                // A moment as the usual eyes first, so the shock reads as them widening.
                try? await Task.sleep(for: .seconds(0.7))
                eyes.expression = .shocked
                // The pupils widen over the alert's last second and a half.
                try? await Task.sleep(for: .seconds(NotchMetrics.alertDuration - 0.7 - 1.5))
                guard !Task.isCancelled else { return }
                eyes.expression = .stunned
            }
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
