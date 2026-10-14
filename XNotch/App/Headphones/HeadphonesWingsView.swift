import AVFoundation
import SwiftUI

/// The closed notch's wings while headphones connect: the device turning in
/// the left wing, its battery filling up in the right.
struct HeadphonesWingsView: View {
    @ObservedObject var monitor: HeadphonesMonitor
    let notchSize: CGSize

    var body: some View {
        let connection = monitor.latest
        let side = notchSize.height - 2
        HStack(spacing: 0) {
            HeadphonesIcon(kind: connection?.kind ?? .headphones, side: side)
                .id(connection?.id)
            Spacer(minLength: notchSize.width)
            HeadphonesBattery(level: connection?.battery)
        }
        .padding(.leading, NotchMetrics.closedTopCornerRadius + 10)
        .padding(.trailing, NotchMetrics.closedTopCornerRadius + 12)
        .frame(width: NotchMetrics.headphonesWings(notchSize).outerWidth, height: notchSize.height)
    }
}

private struct HeadphonesIcon: View {
    let kind: HeadphonesKind
    let side: CGFloat

    var body: some View {
        if let url = kind.animationName.flatMap(Self.animationURL) {
            LoopingVideo(url: url)
                .frame(width: side, height: side)
        } else {
            Image(systemName: kind.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .symbolEffect(.bounce, value: kind)
                .frame(width: side, height: side)
        }
    }

    private static func animationURL(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "mov", subdirectory: "Headphones")
    }
}

private struct HeadphonesBattery: View {
    let level: Int?

    @State private var fill: CGFloat = 0

    private var tint: Color {
        guard let level else { return .white }
        return level <= 20 ? Color(red: 1, green: 0.27, blue: 0.23) : Color(red: 0.36, green: 0.9, blue: 0.56)
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(level.map { "\($0)%" } ?? "")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.95))
                .contentTransition(.numericText())
            ZStack {
                Circle().stroke(.white.opacity(0.16), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: fill)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 15, height: 15)
        }
        .opacity(level == nil ? 0 : 1)
        .onAppear { fillTo(level) }
        .onChange(of: level) { _, new in fillTo(new) }
    }

    /// The ring sweeps up to the level once it's known.
    private func fillTo(_ level: Int?) {
        guard let level else { return }
        withAnimation(Motion.reduceMotion ? nil : .spring(response: 0.7, dampingFraction: 0.9).delay(0.1)) {
            fill = CGFloat(level) / 100
        }
    }
}

/// A muted, looping movie with its alpha intact (the animations are HEVC with
/// transparency). Torn down with the view, so nothing plays while hidden.
private struct LoopingVideo: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PlayerView {
        PlayerView(url: url)
    }

    func updateNSView(_ view: PlayerView, context: Context) {}

    static func dismantleNSView(_ view: PlayerView, coordinator: ()) {
        view.stop()
    }

    final class PlayerView: NSView {
        private let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?
        private let playerLayer = AVPlayerLayer()

        init(url: URL) {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.backgroundColor = .clear
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspect
            playerLayer.backgroundColor = .clear
            playerLayer.pixelBufferAttributes = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            layer?.addSublayer(playerLayer)
            player.play()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }

        func stop() {
            player.pause()
            looper?.disableLooping()
            looper = nil
            player.removeAllItems()
        }
    }
}
