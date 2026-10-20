import AppKit
import QuartzCore
import SwiftUI

/// The shelf's motion vocabulary, so every part moves with the same physics.
enum ShelfMotion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// A shelf shaken into being arrives with momentum, so it may overshoot a little.
    static var appear: Animation { reduced ? .easeOut(duration: 0.18) : .spring(response: 0.42, dampingFraction: 0.72) }
    /// Leaving is decisive: no bounce.
    static var disappear: Animation { reduced ? .easeIn(duration: 0.14) : .spring(response: 0.26, dampingFraction: 1) }
    /// Content changes inside the shelf: crisp, barely alive.
    static var content: Animation { reduced ? .easeInOut(duration: 0.18) : .spring(response: 0.34, dampingFraction: 0.86) }
    /// The bolt blooming into actions, and folding back.
    static var bloom: Animation { reduced ? .easeInOut(duration: 0.18) : .spring(response: 0.36, dampingFraction: 0.8) }
    /// Hover and highlight changes under the pointer.
    static var hover: Animation { reduced ? .easeOut(duration: 0.12) : .spring(response: 0.24, dampingFraction: 0.82) }
    /// A tile's share of the bloom, a few milliseconds after the one before.
    static func bloom(index: Int) -> Animation {
        reduced ? bloom : bloom.delay(Double(index) * 0.018)
    }
}

/// Drives a window's frame with a damped spring on the display link.
/// Interruptible: a new target starts from where the frame is on screen,
/// at the speed it is moving, so a reversal never stalls or jumps.
@MainActor
final class FrameSpring: NSObject {
    var response: Double = 0.4
    var damping: Double = 0.86
    var onFrame: ((CGRect) -> Void)?

    private(set) var isAnimating = false
    private var position = SIMD4<Double>.zero
    private var velocity = SIMD4<Double>.zero
    private var target = SIMD4<Double>.zero
    private var link: CADisplayLink?
    private var lastTime: CFTimeInterval?

    /// Springs to `rect` from `current`, unless already moving, in which
    /// case it re-targets from the frame on screen. `initialVelocity`, in
    /// points per second, carries a hand-off from the pointer.
    func animate(from current: CGRect, to rect: CGRect, initialVelocity: CGVector = .zero, in view: NSView) {
        if !isAnimating {
            position = Self.vector(current)
            velocity = SIMD4(initialVelocity.dx, initialVelocity.dy, 0, 0)
        }
        target = Self.vector(rect)
        guard !ShelfMotion.reduced else {
            stop()
            onFrame?(rect)
            return
        }
        guard link == nil else { return }
        isAnimating = true
        lastTime = nil
        let link = view.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        isAnimating = false
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = min(lastTime.map { now - $0 } ?? (1.0 / 120), 1.0 / 30)
        lastTime = now
        let stiffness = pow(2 * .pi / response, 2)
        let friction = 4 * .pi * damping / response
        // Small fixed sub-steps keep the integration stable at any refresh rate.
        let substeps = max(1, Int((dt / (1.0 / 480)).rounded(.up)))
        let h = dt / Double(substeps)
        for _ in 0..<substeps {
            let force = (target - position) * stiffness - velocity * friction
            velocity += force * h
            position += velocity * h
        }
        let offset = target - position
        let settled = (offset * offset).sum() < 0.01 && (velocity * velocity).sum() < 0.5
        if settled {
            position = target
            velocity = .zero
            stop()
        }
        onFrame?(CGRect(x: position.x, y: position.y, width: position.z, height: position.w))
    }

    private static func vector(_ rect: CGRect) -> SIMD4<Double> {
        SIMD4(rect.origin.x, rect.origin.y, rect.width, rect.height)
    }
}
