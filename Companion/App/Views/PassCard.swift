import SwiftUI
import UIKit
import XNotchLink

/// The dark "boarding pass": this device → the Mac, the route on the arc,
/// and while the basket goes over, how far it's got.
struct PassCard: View {
    @EnvironmentObject private var link: MacLink

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 8) {
                end(code: left.code, big: left.big, sub: left.sub, alignment: .leading)
                RouteArc(state: arcState, label: arcLabel)
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                end(code: right.code, big: right.big, sub: right.sub, alignment: .trailing)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 16)

            Rectangle().fill(Palette.passLine).frame(height: 1)

            HStack(spacing: 8) {
                LiveDot(color: dotColor)
                Text(statusText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 20)
            .frame(height: 48)
        }
        .passCard()
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: link.status)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: pending.count)
    }

    private func end(code: String, big: String, sub: String, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            StatusCaps(text: code, color: Palette.passSecondary)
            Text(big)
                .font(.system(size: 27, weight: .semibold))
                .tracking(-0.5)
                .foregroundStyle(.white)
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if !sub.isEmpty {
                Text(sub)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.passTertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: 120, alignment: alignment == .leading ? .leading : .trailing)
        .layoutPriority(1)
    }

    // MARK: What it says

    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }

    private var pending: [MacLink.Outgoing] {
        link.outgoing.filter { $0.state == .waiting || $0.isSending }
    }

    private var current: (item: MacLink.Outgoing, fraction: Double)? {
        for item in link.outgoing { if case .sending(let fraction) = item.state { return (item, fraction) } }
        return nil
    }

    private var left: (code: String, big: String, sub: String) {
        if !pending.isEmpty, link.status.isConnected {
            let count = pending.count
            return (device, count == 1 ? "1 item" : "\(count) items", FileSizes.total(of: pending))
        }
        return ("From", device, "")
    }

    private var right: (code: String, big: String, sub: String) {
        if let current, link.status.isConnected {
            return ("Mac", "\(Int((current.fraction * 100).rounded()))%", "Sending")
        }
        if !pending.isEmpty, link.status.isConnected { return ("Mac", "0%", "Starting") }
        return ("To", "Mac", link.mac?.name ?? "")
    }

    private var arcState: RouteArc.State {
        switch link.status {
        case .connected:
            if let current { return .progress(current.fraction) }
            return .idle(Palette.green)
        case .searching, .unpaired: return .searching
        case .failed: return .idle(Palette.orange)
        }
    }

    private var arcLabel: String {
        switch link.status {
        case .connected(_, let title): title
        case .searching, .unpaired: "Looking"
        case .failed: "Offline"
        }
    }

    private var dotColor: Color {
        switch link.status {
        case .connected: Palette.green
        case .searching, .unpaired: Palette.passTertiary
        case .failed: Palette.orange
        }
    }

    private var statusText: String {
        switch link.status {
        case .connected: "Connected"
        case .searching, .unpaired: "Looking for your Mac"
        case .failed(let reason): reason
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if link.stored.pairings.count > 1 {
            Menu {
                Picker("Send to", selection: Binding(get: { link.mac?.id ?? "" }, set: { link.select($0) })) {
                    ForEach(link.stored.pairings) { mac in
                        Label(mac.name, systemImage: "laptopcomputer").tag(mac.id)
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text("Switch")
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .bold))
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
            }
        }
    }
}

/// The flight path: dotted while idle, filling as a file goes over.
struct RouteArc: View {
    enum State: Equatable {
        case idle(Color), searching, progress(Double)
    }

    let state: State
    let label: String
    @SwiftUI.State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height - 18
            let start = CGPoint(x: 2, y: height)
            let end = CGPoint(x: width - 2, y: height)
            let control = CGPoint(x: width / 2, y: -height * 0.5)
            let peak = CGPoint(x: width / 2, y: (start.y + 2 * control.y + end.y) / 4)
            let arc = Path { path in
                path.move(to: start)
                path.addQuadCurve(to: end, control: control)
            }
            ZStack {
                switch state {
                case .progress(let fraction):
                    arc.stroke(.white.opacity(0.2), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    arc.trim(from: 0, to: max(0.02, fraction))
                        .stroke(.white, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                        .animation(.linear(duration: 0.15), value: fraction)
                case .idle(let color):
                    arc.stroke(.white.opacity(0.3), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0.5, 6]))
                    Circle().fill(color).frame(width: 7, height: 7).position(peak)
                case .searching:
                    arc.stroke(.white.opacity(0.22), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0.5, 6]))
                    Circle().fill(.white.opacity(pulse ? 0.7 : 0.25)).frame(width: 7, height: 7).position(peak)
                        .onAppear {
                            guard !reduceMotion else { return }
                            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
                        }
                }
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                    .position(x: width / 2, y: peak.y + 18)
                    .contentTransition(.opacity)
            }
        }
    }
}

/// File sizes for the pass, read once per file.
@MainActor
enum FileSizes {
    private static var cache: [URL: Int64] = [:]

    static func size(of item: MacLink.Outgoing) -> Int64 {
        switch item.content {
        case .text(let text): return Int64(text.utf8.count)
        case .file(let url):
            if let known = cache[url] { return known }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
            cache[url] = size
            return size
        }
    }

    static func total(of items: [MacLink.Outgoing]) -> String {
        ByteCountFormatter.string(fromByteCount: items.reduce(0) { $0 + size(of: $1) }, countStyle: .file)
    }

    static func label(for item: MacLink.Outgoing) -> String {
        if case .text = item.content { return "Text" }
        return ByteCountFormatter.string(fromByteCount: size(of: item), countStyle: .file)
    }
}
