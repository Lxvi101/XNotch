import SwiftUI
import XNotchKit

/// Pills that drop out from under the closed notch on hover and name where a
/// click goes. On open they fly up into the header and dissolve into the page
/// switcher, so the destination you picked is where you land.
struct DestinationPills: View, Animatable {
    var reveal: CGFloat
    var travel: CGFloat
    let destinations: [PageInfo]
    let highlighted: OpenPage?
    let restingHeight: CGFloat
    let notchSize: CGSize
    let iconOnly: Bool

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(reveal, travel) }
        set {
            reveal = newValue.first
            travel = newValue.second
        }
    }

    /// Each later pill starts this much later in the reveal, which staggers
    /// them in and, run backwards, out.
    private let stagger: CGFloat = 0.16

    var body: some View {
        let mid = NotchMetrics.canvasSize.width / 2
        let frames = PillLayout.frames(count: destinations.count, below: restingHeight, iconOnly: iconOnly)
        let t = travel.clamped()
        let delayStep = destinations.count > 1 ? min(stagger, 0.4 / CGFloat(destinations.count - 1)) : 0

        ZStack(alignment: .topLeading) {
            if reveal > 0.001 && t < 0.999 {
                ForEach(Array(destinations.enumerated()), id: \.element.id) { index, info in
                    let delay = delayStep * CGFloat(index)
                    let r = ((reveal - delay) / (1 - delay)).clamped()
                    let tucked = 1 - r
                    let segment = PillLayout.segmentFrame(index: index, count: destinations.count, notch: notchSize)
                    let frame = frames[index].lerp(to: segment, t)

                    DestinationPill(info: info, isHighlighted: highlighted == info.page, iconOnly: iconOnly,
                                    labelOpacity: Double(1 - (t * 2.2).clamped()))
                        .frame(width: frame.width, height: frame.height)
                        .scaleEffect(0.72 + 0.28 * r, anchor: .top)
                        .blur(radius: r.revealBlur(6))
                        .opacity(Double(r.smoothstep * (1 - t)))
                        .position(x: mid + frame.midX, y: frame.midY - 16 * tucked)
                }
            }
        }
        .frame(width: NotchMetrics.canvasSize.width, height: NotchMetrics.canvasSize.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

private struct DestinationPill: View {
    let info: PageInfo
    let isHighlighted: Bool
    let iconOnly: Bool
    let labelOpacity: Double

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: info.symbol)
                .font(.system(size: 11, weight: .semibold))
            if !iconOnly {
                Text(info.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .opacity(labelOpacity)
                if info.badge > 0 {
                    Text("\(info.badge)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(KitStyle.green)
                        .opacity(labelOpacity)
                }
            }
        }
        .fixedSize()
        .foregroundStyle(.white.opacity(isHighlighted ? 1 : 0.62))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Capsule()
                .fill(.black)
                .overlay(Capsule().fill(.white.opacity(isHighlighted ? 0.16 : 0)))
                .overlay(Capsule().strokeBorder(.white.opacity(isHighlighted ? 0.18 : 0.09), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        }
        .overlay(alignment: .topTrailing) {
            if iconOnly && info.badge > 0 {
                Circle()
                    .fill(KitStyle.green)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().strokeBorder(.black, lineWidth: 1.5))
                    .offset(x: 1, y: -1)
                    .opacity(labelOpacity)
            }
        }
        .scaleEffect(isHighlighted ? 1.06 : 1)
        .animation(Motion.content, value: isHighlighted)
    }
}
