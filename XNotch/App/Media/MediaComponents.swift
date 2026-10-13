import AppKit
import XNotchKit
import SwiftUI

/// Bars driven by layered sine waves rather than random steps, so they move
/// continuously. `energy` eases them flat when playback pauses.
struct VisualizerBars: View, Animatable {
    var energy: CGFloat
    var color: Color
    var size = MediaLayout.visualizerSize

    @Environment(\.isNotchSurfaceVisible) private var isVisible

    private let barCount = 5
    private let barWidth: CGFloat = 2.4

    var animatableData: CGFloat {
        get { energy }
        set { energy = newValue }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: energy < 0.001 || !isVisible)) { context in
            Canvas { canvas, size in
                let time = context.date.timeIntervalSinceReferenceDate
                let spacing = (size.width - CGFloat(barCount) * barWidth) / CGFloat(barCount - 1)
                for bar in 0..<barCount {
                    let envelope = 1 - abs(CGFloat(bar) - 1.5) / 4
                    let level = Self.level(bar: bar, time: time) * envelope
                    let height = max(barWidth, size.height * (0.16 + 0.84 * level * energy.clamped()))
                    let rect = CGRect(x: CGFloat(bar) * (barWidth + spacing), y: (size.height - height) / 2,
                                      width: barWidth, height: height)
                    canvas.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color))
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private static func level(bar: Int, time: Double) -> CGFloat {
        let b = Double(bar)
        let wave = sin(time * (5.3 + b * 1.1) + b * 1.9) * 0.5
            + sin(time * (8.7 - b * 0.7) + b * 0.4) * 0.3
            + sin(time * 2.3 + b * 2.7) * 0.2
        return CGFloat((wave + 1) / 2)
    }
}

/// Single-line text that, only when it overflows, pauses and then scrolls
/// left in a seamless loop with soft edges.
struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color

    @State private var textWidth: CGFloat = 0
    @State private var start = Date()
    @Environment(\.isNotchSurfaceVisible) private var isVisible

    private let gap: CGFloat = 36
    private let speed: CGFloat = 28
    private let pause: Double = 2.2

    var body: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    let overflows = textWidth > proxy.size.width + 1
                    TimelineView(.animation(minimumInterval: 1 / 60, paused: !overflows || !isVisible)) { context in
                        HStack(spacing: gap) {
                            label
                            if overflows { label }
                        }
                        .offset(x: overflows ? offset(at: context.date) : 0)
                    }
                    .frame(width: proxy.size.width, alignment: .leading)
                    .mask {
                        if overflows {
                            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.04),
                                                   .init(color: .black, location: 0.92), .init(color: .clear, location: 1)],
                                           startPoint: .leading, endPoint: .trailing)
                        } else {
                            Rectangle()
                        }
                    }
                }
            }
            .background {
                label.hidden().background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { textWidth = proxy.size.width }
                            .onChange(of: proxy.size.width) { _, width in textWidth = width }
                    }
                }
            }
            .onChange(of: text) { _, _ in start = Date() }
    }

    private var label: some View {
        Text(text).font(font).foregroundStyle(color).lineLimit(1).fixedSize()
    }

    private func offset(at date: Date) -> CGFloat {
        let cycle = textWidth + gap
        let period = Double(cycle / speed) + pause
        let t = date.timeIntervalSince(start).truncatingRemainder(dividingBy: period)
        return -CGFloat(max(0, t - pause)) * speed
    }
}

/// Elapsed · bar · remaining. The bar thickens under the pointer and follows
/// a drag 1:1; the seek is committed on release.
struct PlaybackScrubber: View {
    let track: NowPlayingTrack
    let onSeek: (Double) -> Void

    @State private var dragProgress: CGFloat?
    @State private var hovering = false
    @Environment(\.isNotchSurfaceVisible) private var isVisible

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !track.isPlaying || dragProgress != nil || !isVisible)) { context in
            let duration = max(track.duration, 0)
            let position = dragProgress.map { Double($0) * duration } ?? track.position(at: context.date)
            let progress = duration > 0 ? CGFloat(position / duration) : 0
            HStack(spacing: 8) {
                timeLabel(position)
                bar(progress: progress)
                timeLabel(duration - position, prefix: "-")
            }
        }
    }

    private func timeLabel(_ seconds: Double, prefix: String = "") -> some View {
        Text(prefix + Self.format(seconds))
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.45))
            .fixedSize()
    }

    private func bar(progress: CGFloat) -> some View {
        let active = hovering || dragProgress != nil
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule().fill(.white.opacity(active ? 1 : 0.85))
                    .frame(width: max(proxy.size.height, proxy.size.width * progress.clamped()))
            }
            .frame(height: active ? 7 : 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in dragProgress = (value.location.x / proxy.size.width).clamped() }
                    .onEnded { value in
                        let target = (value.location.x / proxy.size.width).clamped()
                        onSeek(Double(target) * track.duration)
                        dragProgress = nil
                    }
            )
        }
        .frame(height: 14)
        .animation(Motion.press, value: active)
        .onHover { hovering = $0 }
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}

struct TransportButton: View {
    let symbol: String
    let size: CGFloat
    let action: () -> Void
    @State private var hovering = false
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: taps)
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.9))
                .frame(width: size * 2.1, height: size * 2.1)
                .background(Circle().fill(.white.opacity(hovering ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { inside in withAnimation(Motion.content) { hovering = inside } }
    }
}

/// Artwork that resolves from blur when the image changes.
struct ArtworkView: View {
    let image: NSImage?
    let cornerRadius: CGFloat

    var body: some View {
        Color.white.opacity(0.08)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .id(ObjectIdentifier(image))
                        .transition(.modifier(active: RevealModifier(progress: 0, hiddenScale: 1.08, maxBlur: 12, travel: 0),
                                              identity: RevealModifier(progress: 1)))
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: cornerRadius * 1.6, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .animation(Motion.content, value: image.map(ObjectIdentifier.init))
    }
}
