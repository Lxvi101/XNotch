import SwiftUI

/// Where everything sits on the wheel, shared by the drawing and the drop
/// target's hit-testing. Offsets are from the centre, y down, like SwiftUI.
/// Angles run clockwise from 12 o'clock, in radians.
struct WheelGeometry: Equatable {
    enum Hit: Hashable {
        case hub
        case format(Int)
        case tool(Int)
    }

    static let hubRadius: CGFloat = 50
    static let gap: CGFloat = 4
    /// The glass reaches this far past the outer ring, so a hovered sector's lift stays on it.
    static let glassInset: CGFloat = 7
    static let shadowBlur: CGFloat = 14
    static let shadowDrop: CGFloat = 7
    /// Clear room the shadow needs around the glass: a blur spreads about twice its radius.
    static let shadowReach: CGFloat = shadowBlur * 2 + shadowDrop + 4
    /// The window: the largest wheel and its shadow, uncut.
    static let panelSide: CGFloat = ((maximumRadius + glassInset + shadowReach) * 2).rounded(.up)
    static let maximumRadius: CGFloat = 158
    /// How far past the rim the pointer can go before the wheel lets it go.
    static let reach: CGFloat = 34

    let formatCount: Int
    let toolCount: Int

    var formatRing: ClosedRange<CGFloat> { Self.hubRadius + Self.gap + 2...(toolCount > 0 ? 116 : 132) }
    var toolRing: ClosedRange<CGFloat>? { toolCount > 0 ? formatRing.upperBound + Self.gap...Self.maximumRadius : nil }
    var radius: CGFloat { toolRing?.upperBound ?? formatRing.upperBound }

    /// What's under a point, or nil once it's off the wheel.
    func hit(_ offset: CGPoint) -> Hit? {
        let distance = hypot(offset.x, offset.y)
        let between = { (inner: CGFloat, outer: CGFloat) in (inner + outer) / 2 }
        let hubEdge = between(Self.hubRadius, formatRing.lowerBound)
        if distance < hubEdge { return .hub }
        let angle = Self.angle(of: offset)
        if let toolRing {
            let edge = between(formatRing.upperBound, toolRing.lowerBound)
            if distance < edge { return formatCount > 0 ? .format(Self.index(at: angle, count: formatCount)) : nil }
            if distance < toolRing.upperBound + Self.reach { return .tool(Self.index(at: angle, count: toolCount)) }
            return nil
        }
        if distance < formatRing.upperBound + Self.reach, formatCount > 0 {
            return .format(Self.index(at: angle, count: formatCount))
        }
        return nil
    }

    /// 0 at 12 o'clock, growing clockwise, in 0..<2π.
    static func angle(of offset: CGPoint) -> Double {
        let angle = atan2(Double(offset.x), Double(-offset.y))
        return angle < 0 ? angle + 2 * .pi : angle
    }

    /// The sector an angle falls in; sector 0 is centred on 12 o'clock.
    static func index(at angle: Double, count: Int) -> Int {
        let span = 2 * Double.pi / Double(count)
        return Int(((angle + span / 2) / span).rounded(.down)) % count
    }

    /// Where a sector starts and ends.
    static func span(of index: Int, count: Int) -> (start: Double, end: Double) {
        let span = 2 * Double.pi / Double(count)
        let middle = Double(index) * span
        return (middle - span / 2, middle + span / 2)
    }

    /// A point at an angle and distance from the centre.
    static func point(angle: Double, distance: CGFloat, center: CGPoint = .zero) -> CGPoint {
        CGPoint(x: center.x + distance * CGFloat(sin(angle)), y: center.y - distance * CGFloat(cos(angle)))
    }
}

/// A slice of a ring with rounded corners, and straight gaps of even width
/// between neighbours, like the segments of a dial.
struct RingSector: Shape {
    var start: Double
    var end: Double
    var inner: CGFloat
    var outer: CGFloat
    var gap: CGFloat = WheelGeometry.gap
    var corner: CGFloat = 9

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        // A lone sector is the whole ring.
        if end - start >= 2 * .pi - 0.0001 {
            var path = Path()
            path.addEllipse(in: CGRect(x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2))
            path.addEllipse(in: CGRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2))
            return path.normalized(eoFill: true)
        }
        // Screen angles: 0 along +x, growing clockwise (y is down).
        let a1 = start - .pi / 2, a2 = end - .pi / 2
        let half = Double(gap / 2)
        let maxCorner = min(Double(outer - inner) / 2 - 0.5, Double(inner) * sin((a2 - a1) / 2) - half - 0.5)
        let c = CGFloat(max(min(Double(corner), maxCorner), 0))
        func dir(_ angle: Double) -> CGPoint { CGPoint(x: cos(angle), y: sin(angle)) }
        func at(_ angle: Double, _ distance: CGFloat) -> CGPoint {
            let d = dir(angle)
            return CGPoint(x: center.x + d.x * distance, y: center.y + d.y * distance)
        }
        // Corner circles sit inside, tangent to the arc and to the gap's edge.
        let alpha = asin(min((half + Double(c)) / Double(outer - c), 1))
        let beta = asin(min((half + Double(c)) / Double(inner + c), 1))
        let outerStart = a1 + alpha, outerEnd = a2 - alpha
        let innerStart = a1 + beta, innerEnd = a2 - beta
        let pOS = at(outerStart, outer - c), pOE = at(outerEnd, outer - c)
        let pIS = at(innerStart, inner + c), pIE = at(innerEnd, inner + c)
        func deg(_ radians: Double) -> Angle { .radians(radians) }

        var path = Path()
        path.move(to: at(outerStart, outer))
        path.addArc(center: center, radius: outer, startAngle: deg(outerStart), endAngle: deg(outerEnd), clockwise: false)
        path.addArc(center: pOE, radius: c, startAngle: deg(outerEnd), endAngle: deg(a2 + .pi / 2), clockwise: false)
        path.addArc(center: pIE, radius: c, startAngle: deg(a2 + .pi / 2), endAngle: deg(innerEnd + .pi), clockwise: false)
        path.addArc(center: center, radius: inner, startAngle: deg(innerEnd), endAngle: deg(innerStart), clockwise: true)
        path.addArc(center: pIS, radius: c, startAngle: deg(innerStart + .pi), endAngle: deg(a1 + 1.5 * .pi), clockwise: false)
        path.addArc(center: pOS, radius: c, startAngle: deg(a1 - .pi / 2), endAngle: deg(outerStart), clockwise: false)
        path.closeSubpath()
        return path
    }
}
