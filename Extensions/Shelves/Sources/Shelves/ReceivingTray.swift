import AppKit
import SwiftUI

/// What's on its way to a shelf from another app, for the tray under it and
/// the expanded shelf's header.
@MainActor
@Observable
final class Delivery {
    enum Phase { case receiving, done, failed }

    var phase = Phase.receiving
    var total = 0
    var received = 0
    var failed = 0
    /// The app sending the files, when known.
    var source: String?

    /// "Receiving 2 of 5", "Received", "Mail couldn't send the file".
    var title: String {
        switch phase {
        case .receiving:
            return total > 1 ? "Receiving \(received) of \(total)" : "Receiving"
        case .done:
            return received == 1 ? "Received" : "\(received) items received"
        case .failed:
            let what = failed == 1 ? "the file" : "\(failed) files"
            if failed < total { return "Couldn\u{2019}t receive \(what)" }
            return source.map { "\($0) couldn\u{2019}t send \(what)" } ?? "Couldn\u{2019}t receive \(what)"
        }
    }

    /// "from Mail", while receiving.
    var detail: String? {
        guard phase == .receiving, let source else { return nil }
        return "from \(source)"
    }

    func reset() {
        phase = .receiving
        total = 0
        received = 0
        failed = 0
        source = nil
    }
}

/// The tray that slides out from under a shelf while files are on their way:
/// what's coming, how far it's got, and a button to stop waiting.
final class ReceivingTrayPanel: NSPanel {
    static let size = CGSize(width: 320, height: 58)
    /// Between the shelf and the tray.
    static let gap: CGFloat = 8

    let delivery: Delivery
    let model = Model()

    @MainActor @Observable final class Model {
        var isVisible = false
        /// The shelf edge it hangs from: below the shelf, or above it near the bottom of the screen.
        var edge = VerticalEdge.bottom
    }

    init(delivery: Delivery, cancel: @escaping @MainActor () -> Void) {
        self.delivery = delivery
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        appearance = NSAppearance(named: .darkAqua)
        let hosting = ShelfHostingView(rootView: Tray(delivery: delivery, model: model, cancel: cancel))
        contentView = hosting
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The window's edge against the shelf is where the tray comes out from:
    /// anything still behind it is cut off, as if under the shelf.
    private struct Tray: View {
        let delivery: Delivery
        let model: Model
        let cancel: () -> Void

        var body: some View {
            let visible = model.isVisible
            let below = model.edge == .bottom
            let receiving = delivery.phase == .receiving
            HStack(spacing: 7) {
                StatusRing(delivery: delivery, isVisible: visible)
                HStack(spacing: 3) {
                    Text(delivery.title)
                        .contentTransition(.numericText())
                    if let detail = delivery.detail {
                        Text(detail)
                            .foregroundStyle(.white.opacity(0.5))
                            .transition(.opacity)
                    }
                }
                .lineLimit(1)
                if receiving {
                    CancelButton(action: cancel)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.leading, 8)
            .padding(.trailing, receiving ? 5 : 11)
            .frame(height: 28)
            .background {
                ZStack {
                    VisualEffect()
                    Color.black.opacity(0.18)
                }
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            }
            .animation(ShelfMotion.content, value: delivery.phase)
            .animation(ShelfMotion.content, value: delivery.received)
            .scaleEffect(x: visible ? 1 : 0.72, y: visible ? 1 : 0.8, anchor: below ? .top : .bottom)
            .offset(y: visible || ShelfMotion.reduced ? 0 : (below ? -38 : 38))
            .blur(radius: visible ? 0 : 4)
            .opacity(visible ? 1 : 0)
            .padding(below ? .top : .bottom, ReceivingTrayPanel.gap)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: below ? .top : .bottom)
        }
    }

    /// Spins while a single file comes in, fills file by file for several, then
    /// turns into a check or a warning.
    private struct StatusRing: View {
        let delivery: Delivery
        let isVisible: Bool

        var body: some View {
            ZStack {
                switch delivery.phase {
                case .receiving:
                    let spins = delivery.total <= 1
                    Circle().stroke(.white.opacity(0.18), lineWidth: 2)
                    TimelineView(.animation(minimumInterval: 1 / 60, paused: !spins || !isVisible)) { context in
                        let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
                        Circle()
                            .trim(from: 0, to: spins ? 0.28 : CGFloat(delivery.received) / CGFloat(max(delivery.total, 1)))
                            .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(spins ? turn * 360 : -90))
                    }
                    .transition(.opacity)
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .resizable()
                        .foregroundStyle(.white, Color(red: 0.19, green: 0.82, blue: 0.35))
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                case .failed:
                    Image(systemName: "exclamationmark.circle.fill")
                        .resizable()
                        .foregroundStyle(.white, Color(red: 1, green: 0.27, blue: 0.23))
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .frame(width: 13, height: 13)
            .frame(width: 15, height: 15)
        }
    }

    private struct CancelButton: View {
        let action: () -> Void
        @State private var hovered = false

        var body: some View {
            Button(action: action) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(hovered ? 0.95 : 0.7))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(.white.opacity(hovered ? 0.24 : 0.12)))
                    .contentShape(Circle())
            }
            .buttonStyle(PressStyle())
            .onHover { hovered = $0 }
            .animation(ShelfMotion.hover, value: hovered)
            .help("Stop receiving")
        }
    }
}
