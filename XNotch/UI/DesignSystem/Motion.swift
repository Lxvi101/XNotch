import AppKit
import SwiftUI
import XNotchKit

/// One spring per kind of change. Bounce is reserved for transitions that
/// arrive with momentum (opening, a drop landing); anything settling back to
/// rest is critically damped.
enum Motion {
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Pointer-driven shaping. Short enough to read as tracking, long enough
    /// to smooth discrete mouse samples.
    static var track: Animation {
        reduceMotion ? .linear(duration: 0.12) : .interactiveSpring(response: 0.2, dampingFraction: 0.86)
    }

    static var press: Animation {
        .spring(response: 0.18, dampingFraction: 0.9)
    }

    /// Shell morphing open into a surface.
    static var open: Animation {
        // Shared with extensions, whose pages resize along with it.
        KitMotion.shell
    }

    /// Shell settling back into the notch.
    static var close: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 1)
    }

    /// Fast compression when a drop lands...
    static var impact: Animation {
        .spring(response: 0.1, dampingFraction: 1)
    }

    /// ...and the rebound that carries its energy away.
    static var rebound: Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.55)
    }

    static var content: Animation {
        .spring(response: 0.34, dampingFraction: 0.86)
    }
}

extension CGFloat {
    func clamped(_ lower: CGFloat = 0, _ upper: CGFloat = 1) -> CGFloat {
        Swift.min(Swift.max(self, lower), upper)
    }

    /// Hermite smoothstep over 0...1.
    var smoothstep: CGFloat {
        let t = clamped()
        return t * t * (3 - 2 * t)
    }

    /// Blur radius for an element `self` of the way through its reveal. None
    /// at either end: a blur filter costs an offscreen pass every frame the
    /// notch redraws, even on an element that's invisible.
    func revealBlur(_ maxRadius: CGFloat) -> CGFloat {
        let p = clamped()
        return p > 0.001 && p < 0.999 ? maxRadius * (1 - p) : 0
    }
}

/// Blur-to-focus reveal: hidden content sits slightly smaller, blurred and
/// tucked up under the notch, and resolves as `progress` reaches 1. Clamping
/// here keeps spring overshoot from over-scaling content.
struct RevealModifier: ViewModifier, Animatable {
    var progress: CGFloat
    var hiddenScale: CGFloat = 0.84
    var maxBlur: CGFloat = 10
    var travel: CGFloat = -10
    /// Removes the content from the view tree while fully hidden, so it costs
    /// nothing on frames where other surfaces animate. Its state resets.
    var unmountsWhenHidden = false

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = progress.clamped()
        let visible = p > 0.001
        if visible || !unmountsWhenHidden {
            content
                .environment(\.isNotchSurfaceVisible, visible)
                .scaleEffect(hiddenScale + (1 - hiddenScale) * p, anchor: .top)
                .offset(y: travel * (1 - p))
                .blur(radius: p.revealBlur(maxBlur))
                .opacity(Double(p.smoothstep))
        }
    }
}

extension View {
    func reveal(_ progress: CGFloat, hiddenScale: CGFloat = 0.84, maxBlur: CGFloat = 10, travel: CGFloat = -10,
                unmountsWhenHidden: Bool = false) -> some View {
        modifier(RevealModifier(progress: progress, hiddenScale: hiddenScale, maxBlur: maxBlur, travel: travel,
                                unmountsWhenHidden: unmountsWhenHidden))
    }
}
