import SwiftUI

/// What the notch's eyes look at and how they feel. Read by the eyes view on
/// every frame rather than observed, so following the pointer never
/// re-renders the shell.
///
/// The eye model follows bloub's measurements of the x.ai avatar: tall
/// capsules that compress and lean as they turn, exponential ease-outs with
/// no overshoot, blinks every 1.9–4.6 s (sometimes doubled), and every change
/// of expression hidden behind a blink.
@MainActor
final class NotchEyes {
    enum Expression {
        case asleep, sleepy, neutral, attentive, curious, happy, excited, surprised
        /// Drooping, glancing about and blinking often: something needs a look.
        case worried
        /// Popped wide and round with pinprick pupils, too stunned to blink.
        case shocked
        /// Still wide and round, the pupils grown and the eyes trembling as the shock sinks in.
        case stunned

        /// Wide-eyed alarm: upright, unblinking, pupils darting.
        var isAlarmed: Bool { self == .shocked || self == .stunned }
    }

    var expression: Expression = .neutral {
        didSet { if expression != oldValue { expressionChangedAt = CACurrentMediaTime() } }
    }
    /// Screen point between the eyes.
    var anchor: CGPoint = .zero
    var pointer: CGPoint = .zero
    /// Overrides the pointer: something on screen the eyes should watch.
    var focus: CGPoint?
    private(set) var expressionChangedAt: CFTimeInterval = 0

    /// -1...1 on each axis; positive y looks down.
    var gazeTarget: CGVector {
        let point = focus ?? pointer
        let dx = point.x - anchor.x
        let dy = anchor.y - point.y
        return CGVector(dx: dx / (abs(dx) + 170), dy: dy / (abs(dy) + 110))
    }

    /// 0...1 as the pointer comes within reach; the eyes open wider for it.
    var closeness: CGFloat {
        guard focus == nil else { return 0 }
        return (1 - hypot(pointer.x - anchor.x, pointer.y - anchor.y) / 240).clamped()
    }

    /// Briefly shows an expression, then returns to `then`.
    func flash(_ expression: Expression, for duration: TimeInterval = 1.4, then next: Expression = .neutral) {
        self.expression = expression
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.expression == expression else { return }
            self.expression = next
        }
    }
}

/// One eye's shape, in units of the eye radius. `tilt` in degrees, positive
/// leans the top to the right; `open` is a held lid (1 open, 0 shut);
/// `pupil` is the diameter of a dark pupil, 0 for none.
private struct EyeShape {
    var width: CGFloat
    var height: CGFloat
    var tilt: CGFloat = 0
    var open: CGFloat = 1
    var pupil: CGFloat = 0

    func mix(toward other: EyeShape, _ k: CGFloat) -> EyeShape {
        EyeShape(width: width + (other.width - width) * k, height: height + (other.height - height) * k,
                 tilt: tilt + (other.tilt - tilt) * k, open: open + (other.open - open) * k,
                 pupil: pupil + (other.pupil - pupil) * k)
    }
}

private struct FacePose {
    var left: EyeShape
    var right: EyeShape
    /// Spacing multiplier and head roll in degrees.
    var split: CGFloat = 1
    var roll: CGFloat = 0

    static func pair(_ width: CGFloat, _ height: CGFloat, tilt: CGFloat = 0, open: CGFloat = 1,
                     split: CGFloat = 1, roll: CGFloat = 0, pupil: CGFloat = 0) -> FacePose {
        FacePose(left: EyeShape(width: width, height: height, tilt: tilt, open: open, pupil: pupil),
                 right: EyeShape(width: width, height: height, tilt: -tilt, open: open, pupil: pupil),
                 split: split, roll: roll)
    }

    static func of(_ expression: NotchEyes.Expression) -> FacePose {
        switch expression {
        case .asleep: .pair(0.24, 0.42, open: 0)
        case .sleepy: .pair(0.2, 0.42, open: 0.42, roll: -3)
        case .neutral: .pair(0.186, 0.412)
        case .attentive: .pair(0.21, 0.44, split: 1.04)
        case .curious: FacePose(left: EyeShape(width: 0.24, height: 0.46, tilt: -8),
                                right: EyeShape(width: 0.2, height: 0.38, tilt: -8), split: 1.06, roll: -12)
        case .happy: .pair(0.27, 0.17, tilt: 14, split: 1.1)
        case .excited: .pair(0.3, 0.5, tilt: -10, split: 1.2)
        case .surprised: .pair(0.32, 0.46, split: 1.2)
        case .worried: .pair(0.22, 0.36, open: 0.72, split: 0.94)
        case .shocked: .pair(0.5, 0.5, split: 1.4, pupil: 0.12)
        case .stunned: .pair(0.5, 0.5, split: 1.4, pupil: 0.3)
        }
    }

    func mix(toward other: FacePose, _ k: CGFloat) -> FacePose {
        FacePose(left: left.mix(toward: other.left, k), right: right.mix(toward: other.right, k),
                 split: split + (other.split - split) * k, roll: roll + (other.roll - roll) * k)
    }
}

/// Per-view animation state, advanced once per frame.
@MainActor
private final class EyeMotion {
    var gaze = CGVector.zero
    var closeness: CGFloat = 0
    var pose = FacePose.of(.asleep)
    var lastTime: CFTimeInterval?
    var blinkStart: CFTimeInterval = -1
    var nextBlink: CFTimeInterval = 0
    var seenExpressionChange: CFTimeInterval = 0
    /// When the eyes last popped open in shock.
    var popStart: CFTimeInterval = -1
    /// How hard the eyes tremble, 0...1; eases in so the tremble starts gently.
    var tremble: CGFloat = 0
    /// The tremble's offset on top of the gaze, in units of the eye size.
    var shake = CGVector.zero
    /// Where the pupils look inside the eyes, -1...1 on each axis.
    var pupilLook = CGVector.zero
    private var pupilTarget = CGVector.zero
    private var nextPupilMove: CFTimeInterval = 0

    static let blinkDuration: CFTimeInterval = 0.18

    /// 1 open → 0 shut: a fast close and a slightly slower reopen.
    func lid(at time: CFTimeInterval) -> CGFloat {
        let k = (time - blinkStart) / Self.blinkDuration
        guard k >= 0, k <= 1 else { return 1 }
        return CGFloat(k < 0.45 ? 1 - k / 0.45 : (k - 0.45) / 0.55)
    }

    /// Size multiplier for the end of the shocked grow: a soft overshoot that settles at 1.
    func pop(at time: CFTimeInterval) -> CGFloat {
        let k = time - popStart
        guard popStart >= 0, k >= 0, k < 2 else { return 1 }
        return CGFloat(1 + 0.12 * exp(-k / 0.25) * sin(k * 2 * .pi / 0.45))
    }

    func advance(to time: CFTimeInterval, eyes: NotchEyes) {
        let dt = min(0.1, time - (lastTime ?? time))
        lastTime = time
        if nextBlink == 0 { nextBlink = time + 0.8 }

        if eyes.expressionChangedAt > seenExpressionChange {
            seenExpressionChange = eyes.expressionChangedAt
            switch eyes.expression {
            case .shocked:
                // No blink to hide it: the eyes are seen to grow, and spring at the end.
                popStart = time + 0.55
            case .stunned:
                // The pupils are seen to grow.
                break
            default:
                blinkStart = time
            }
        }
        if eyes.expression.isAlarmed {
            // A stunned stare: no blinking until it passes.
            nextBlink = max(nextBlink, time + 0.6)
        } else if time >= nextBlink {
            blinkStart = time
            let calm = eyes.expression == .worried ? 0.7 + Double.random(in: 0...0.9) : 1.9 + Double.random(in: 0...2.7)
            nextBlink = time + (Double.random(in: 0...1) < 0.18 ? 0.24 : calm)
        }

        // Slow wander on incommensurate periods, so the drift never visibly repeats.
        let wander = CGVector(
            dx: 0.05 * sin(time * 2 * .pi / 11.3 + 0.4) + 0.016 * sin(time * 2 * .pi / 3.7 + 2.1),
            dy: 0.04 * sin(time * 2 * .pi / 9.1 + 1.3) + 0.012 * sin(time * 2 * .pi / 4.3 + 0.7)
        )
        var target = eyes.gazeTarget
        if eyes.expression == .worried {
            // Nervous glances, side to side.
            target.dx += sin(time * 2 * .pi / 1.7) > 0 ? 0.8 : -0.8
        }
        if eyes.expression.isAlarmed {
            // Darting about in alarm, slower once it sinks in.
            if time >= nextPupilMove {
                pupilTarget = CGVector(dx: .random(in: -1...1), dy: .random(in: -0.7...0.7))
                nextPupilMove = time + (eyes.expression == .stunned ? .random(in: 0.6...1.2) : .random(in: 0.25...0.6))
            }
        } else {
            pupilTarget = .zero
        }
        let pupilK = CGFloat(1 - exp(-dt / 0.045))
        pupilLook.dx += (pupilTarget.dx - pupilLook.dx) * pupilK
        pupilLook.dy += (pupilTarget.dy - pupilLook.dy) * pupilK
        let gazeK = CGFloat(1 - exp(-dt / 0.085))
        gaze.dx += (target.dx + wander.dx - gaze.dx) * gazeK
        gaze.dy += (target.dy + wander.dy - gaze.dy) * gazeK
        closeness += (eyes.closeness - closeness) * CGFloat(1 - exp(-dt / 0.16))
        // Shock grows slowly enough to read as these eyes widening.
        let poseTime = eyes.expression.isAlarmed ? 0.3 : 0.11
        tremble += ((eyes.expression == .stunned ? 1 : 0) - tremble) * CGFloat(1 - exp(-dt / 0.35))
        shake = CGVector(dx: tremble * 0.03 * sin(time * 2 * .pi * 17), dy: tremble * 0.018 * sin(time * 2 * .pi * 23 + 1))
        pose = pose.mix(toward: FacePose.of(eyes.expression), CGFloat(1 - exp(-dt / poseTime)))
    }
}

struct NotchEyesView: View {
    let eyes: NotchEyes
    /// Eye size: the radius of the head they're drawn on, in points.
    var unit: CGFloat = 46
    @State private var motion = EyeMotion()

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                motion.advance(to: time, eyes: eyes)
                draw(in: &context, size: size, lid: motion.lid(at: time), pop: motion.pop(at: time))
            }
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, lid: CGFloat, pop: CGFloat) {
        let gaze = motion.gaze
        let pose = motion.pose
        let center = CGPoint(x: size.width / 2 + (gaze.dx * 0.3 + motion.shake.dx) * unit,
                             y: size.height / 2 + (gaze.dy * 0.13 + motion.shake.dy) * unit)
        let spacing = unit * 0.31 * pose.split * (1 - 0.14 * abs(gaze.dx))
        let wide = 1 + 0.16 * motion.closeness
        context.addFilter(.shadow(color: .white.opacity(0.45), radius: unit * 0.1))
        // Alarm keeps the eyes upright; otherwise they lean into a sideways look.
        let lean: CGFloat = eyes.expression == .worried || eyes.expression.isAlarmed ? 0 : 11

        for (side, shape) in [(-1.0, pose.left), (1.0, pose.right)] as [(CGFloat, EyeShape)] {
            // The eye turning toward the edge of the "sphere" foreshortens.
            let depth = 1 - 0.3 * max(0, gaze.dx * side)
            let width = shape.width * unit * depth * (1 + 0.08 * motion.closeness) * pop
            let height = shape.height * unit * wide * pop
            let squash = 0.06 + 0.94 * (lid * shape.open).clamped()
            let angle = (shape.tilt + pose.roll - lean * gaze.dx) * .pi / 180
            // Blinks squash vertically in screen space, after the lean.
            let transform = CGAffineTransform(rotationAngle: angle)
                .concatenating(CGAffineTransform(scaleX: 1, y: squash))
                .concatenating(CGAffineTransform(translationX: center.x + side * spacing * (side * gaze.dx > 0 ? 0.92 : 1),
                                                 y: center.y))
            let rect = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
            let path = Path(roundedRect: rect, cornerRadius: min(width, height) / 2).applying(transform)
            context.fill(path, with: .color(.white))
            if shape.pupil > 0.005 {
                let diameter = shape.pupil * unit
                let look = motion.pupilLook
                let x = look.dx * (width - diameter) * 0.32 + gaze.dx * width * 0.1
                let y = look.dy * (height - diameter) * 0.32 + gaze.dy * height * 0.1
                let pupil = CGRect(x: x - diameter / 2, y: y - diameter / 2, width: diameter, height: diameter)
                context.fill(Path(ellipseIn: pupil).applying(transform), with: .color(.black))
            }
        }
    }
}
