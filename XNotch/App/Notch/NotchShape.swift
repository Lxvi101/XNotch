import SwiftUI

/// The notch silhouette: concave quad-curve flares at the top corners and
/// quad-curve rounded corners at the bottom. The rect's width includes both
/// flares; the body is `rect.width - 2 * topCornerRadius`.
struct NotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topCornerRadius, bottomRadius) }
        set {
            topCornerRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let top = min(topCornerRadius, rect.width / 2)
        let bodyMinX = rect.minX + top
        let bodyMaxX = rect.maxX - top
        let bottom = min(bottomRadius, (bodyMaxX - bodyMinX) / 2, rect.height - top)

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: bodyMinX, y: rect.minY + top),
            control: CGPoint(x: bodyMinX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: bodyMinX, y: rect.maxY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: bodyMinX + bottom, y: rect.maxY),
            control: CGPoint(x: bodyMinX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: bodyMaxX - bottom, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: bodyMaxX, y: rect.maxY - bottom),
            control: CGPoint(x: bodyMaxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: bodyMaxX, y: rect.minY + top))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: bodyMaxX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}
