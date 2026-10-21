import CoreGraphics
import Foundation

/// Where the eyes look while an agent works: roughly at its cursor, not
/// locked on. They settle on a spot near the cursor for a second or so, drift
/// to another, now and then glance at the window being read or off to the
/// side, and when the cursor jumps away they notice a beat later and catch up.
struct GazePlanner {
    struct Look: Equatable {
        /// AppKit screen coordinates; nil follows the user's pointer.
        var point: CGPoint?
        /// How long to hold it before choosing again.
        var hold: TimeInterval
    }

    /// How far from the cursor a resting look may land.
    static let nearRadius: CGFloat = 90
    /// A cursor move farther than this from the current look is noticed.
    static let noticeDistance: CGFloat = 160
    /// The beat before the eyes catch up with a jump.
    static let reaction: ClosedRange<TimeInterval> = 0.18...0.45

    /// Where the eyes look now.
    private(set) var look: CGPoint?

    /// Picks the next look. `roll` and `jitter` are 0..<1 draws, injectable for tests.
    mutating func next(cursor: CGPoint?, window: CGPoint?,
                       roll: Double = .random(in: 0..<1), jitter: () -> Double = { .random(in: 0..<1) }) -> Look {
        guard let anchor = cursor ?? window else {
            look = nil
            return Look(point: nil, hold: 0.8)
        }
        func around(_ point: CGPoint, distance: ClosedRange<Double>) -> CGPoint {
            let angle = jitter() * 2 * .pi
            let r = distance.lowerBound + jitter() * (distance.upperBound - distance.lowerBound)
            return CGPoint(x: point.x + CGFloat(cos(angle) * r), y: point.y + CGFloat(sin(angle) * r))
        }
        func span(_ range: ClosedRange<TimeInterval>) -> TimeInterval {
            range.lowerBound + jitter() * (range.upperBound - range.lowerBound)
        }

        let result: Look
        if roll < 0.14, let window, cursor != nil {
            // A glance at the window the agent is reading.
            result = Look(point: around(window, distance: 0...60), hold: span(0.5...1.0))
        } else if roll < 0.26 {
            // A glance off to the side.
            result = Look(point: around(anchor, distance: 260...480), hold: span(0.3...0.7))
        } else {
            // Resting somewhere near the cursor.
            result = Look(point: around(anchor, distance: 0...Double(Self.nearRadius)), hold: span(0.7...1.8))
        }
        look = result.point
        return result
    }

    /// Whether the cursor has moved far enough from where the eyes are looking to be noticed.
    func notices(_ cursor: CGPoint?) -> Bool {
        guard let cursor else { return false }
        guard let look else { return true }
        return hypot(cursor.x - look.x, cursor.y - look.y) > Self.noticeDistance
    }
}
