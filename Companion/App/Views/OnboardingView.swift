import SwiftUI

/// Three steps, then pairing. A picture in a white sheet, a caps line, a
/// title and one line under it; back, dots and Next at the bottom.
struct OnboardingView: View {
    let onFinish: () -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass
    #if DEBUG
    // `-onboardingStep 2` opens a later step, for screenshots.
    @State private var step = UserDefaults.standard.integer(forKey: "onboardingStep")
    #else
    @State private var step = 0
    #endif

    private static let count = 3
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        GeometryReader { proxy in
            if sizeClass == .regular && proxy.size.width > proxy.size.height * 1.15 && proxy.size.width >= 900 {
                HStack(spacing: 48) {
                    visualCard
                        .frame(maxHeight: 560)
                    VStack(alignment: .leading, spacing: 0) {
                        copy(alignment: .leading, titleSize: 46)
                        nav
                            .padding(.top, 36)
                    }
                    .frame(maxWidth: 440, alignment: .leading)
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    visualCard
                        .frame(height: min(proxy.size.height * 0.46, sizeClass == .regular ? 520 : 340))
                        .padding(.top, 14)
                    copy(alignment: .center, titleSize: sizeClass == .regular ? 40 : 32)
                        .padding(.top, 30)
                        .padding(.horizontal, 6)
                    Spacer(minLength: 20)
                    nav
                        .padding(.bottom, 12)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
            }
        }
        .animation(.spring(response: 0.55, dampingFraction: 0.88), value: step)
    }

    // MARK: Content

    private var eyebrow: String {
        ["Send to your notch", "Share sheet", "Clipboard"][step]
    }

    private var title: String {
        switch step {
        case 0: isPad ? "Your iPad,\none drag from your Mac" : "Your iPhone,\none tap from your Mac"
        case 1: "Share to\nyour Mac"
        default: "Copy here,\npaste there"
        }
    }

    private var subtitle: String {
        switch step {
        case 0: "Photos, files and text land on your Mac's shelf, right under the notch."
        case 1: "Tap Share in any app and pick XNotch. Photos, PDFs, downloads, anything."
        default: "Send text straight to your Mac's clipboard, then press ⌘V."
        }
    }

    private var visualCard: some View {
        ZStack {
            switch step {
            case 0: MacShelfIllustration(device: isPad ? "iPad" : "iPhone").transition(stepTransition)
            case 1: ShareSheetIllustration().transition(stepTransition)
            default: ClipboardIllustration().transition(stepTransition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 32, style: .continuous).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 32, style: .continuous).strokeBorder(Palette.line.opacity(0.7)))
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
    }

    private func copy(alignment: HorizontalAlignment, titleSize: CGFloat) -> some View {
        let text: TextAlignment = alignment == .center ? .center : .leading
        return VStack(alignment: alignment, spacing: 0) {
            StatusCaps(text: eyebrow, color: Palette.secondary)
                .tracking(1.2)
            Text(title)
                .font(.system(size: titleSize, weight: .bold))
                .tracking(-titleSize * 0.035)
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(text)
                .padding(.top, 10)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(.system(size: titleSize > 40 ? 18 : 16))
                .foregroundStyle(Palette.secondary)
                .multilineTextAlignment(text)
                .lineSpacing(3)
                .padding(.top, 12)
                .fixedSize(horizontal: false, vertical: true)
        }
        .id(step)
        .transition(stepTransition)
    }

    private var nav: some View {
        HStack(spacing: 14) {
            Button { back() } label: {
                CircleButtonLabel(symbol: "arrow.left", size: 56)
            }
            .opacity(step == 0 ? 0 : 1)
            .disabled(step == 0)
            .accessibilityLabel("Back")
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<Self.count, id: \.self) { index in
                    Capsule()
                        .fill(index == step ? Palette.ink : Palette.tertiary.opacity(0.45))
                        .frame(width: index == step ? 26 : 7, height: 7)
                }
            }
            Spacer()
            Button { advance() } label: {
                HStack(spacing: 10) {
                    Text(step == Self.count - 1 ? "Get Started" : "Next")
                    Image(systemName: "arrow.right")
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.onInk)
                .padding(.horizontal, 24)
                .frame(height: 56)
                .background(Capsule().fill(Palette.ink))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 6)
                .contentTransition(.opacity)
            }
        }
    }

    private var stepTransition: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(x: 30)),
                    removal: .opacity.combined(with: .offset(x: -30)))
    }

    private func advance() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if step < Self.count - 1 { step += 1 } else { onFinish() }
    }

    private func back() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if step > 0 { step -= 1 }
    }
}

// MARK: Illustrations

/// The top of a Mac screen: the notch with its eyes, files landing on the
/// shelf one by one, and the phone they came from.
struct MacShelfIllustration: View {
    let device: String
    @State private var landed = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let width = min(proxy.size.width * 0.8, 440)
            let height = width * 0.74
            let tile = width * 0.17
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.clear)
                    .passCard(radius: 20)
                NotchShape()
                    .fill(.black)
                    .frame(width: width * 0.4, height: width * 0.1)
                    .overlay {
                        HStack(spacing: width * 0.033) {
                            Capsule().fill(.white).frame(width: width * 0.022, height: width * 0.048)
                            Capsule().fill(.white).frame(width: width * 0.022, height: width * 0.048)
                        }
                    }
                HStack(spacing: tile * 0.18) {
                    ForEach(0..<3) { index in
                        shelfTile(index)
                            .frame(width: tile, height: tile)
                            .scaleEffect(index < landed ? 1 : 0.4)
                            .opacity(index < landed ? 1 : 0)
                            .offset(y: index < landed ? 0 : -tile * 0.6)
                    }
                }
                .padding(.top, width * 0.16)
                HStack(spacing: 8) {
                    LiveDot()
                    Text(landed == 1 ? "1 item from \(device)" : "\(landed) items from \(device)")
                        .font(.system(size: max(11, width * 0.035), weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .contentTransition(.numericText())
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(height: width * 0.12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.07)))
                .padding(.horizontal, width * 0.06)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, width * 0.06)
            }
            .frame(width: width, height: height)
            .overlay(alignment: .bottomTrailing) {
                MiniPhone()
                    .frame(width: width * 0.3, height: width * 0.52)
                    .rotationEffect(.degrees(-8))
                    .offset(x: -width * 0.02, y: width * 0.3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .offset(y: -proxy.size.height * 0.04)
        }
        .task {
            if reduceMotion { landed = 3; return }
            while !Task.isCancelled {
                for count in 1...3 {
                    try? await Task.sleep(nanoseconds: 650_000_000)
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { landed = count }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                withAnimation(.easeInOut(duration: 0.35)) { landed = 0 }
            }
        }
    }

    @ViewBuilder
    private func shelfTile(_ index: Int) -> some View {
        switch index {
        case 0: RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Swatch.sunset)
        case 1: RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Swatch.sea)
        default:
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white)
                .overlay(Text("PDF").font(.system(size: 11, weight: .heavy)).foregroundStyle(Color(hex: 0xE2626B)))
        }
    }
}

/// The phone, tilted, with a photo on its screen.
private struct MiniPhone: View {
    var body: some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: proxy.size.width * 0.22, style: .continuous)
                .fill(Color.white)
                .overlay(alignment: .top) {
                    RoundedRectangle(cornerRadius: proxy.size.width * 0.13, style: .continuous)
                        .fill(Swatch.sunset)
                        .frame(height: proxy.size.height * 0.34)
                        .padding(.horizontal, proxy.size.width * 0.11)
                        .padding(.top, proxy.size.height * 0.16)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: proxy.size.width * 0.22, style: .continuous)
                        .strokeBorder(Color(hex: 0x111113), lineWidth: max(4, proxy.size.width * 0.055))
                }
                .shadow(color: .black.opacity(0.3), radius: 14, y: 10)
        }
    }
}

/// The gradients that stand in for photos.
enum Swatch {
    static let sunset = LinearGradient(colors: [Color(hex: 0xF8B26A), Color(hex: 0xE2626B), Color(hex: 0x6B4AA8)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
    static let sea = LinearGradient(colors: [Color(hex: 0x9AD0EC), Color(hex: 0x3C7DBA), Color(hex: 0x24496E)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// The notch: straight top, rounded bottom corners.
struct NotchShape: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = rect.height * 0.42
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// A share sheet's app row, with XNotch lit.
private struct ShareSheetIllustration: View {
    @State private var lit = false

    var body: some View {
        VStack(spacing: 18) {
            Capsule().fill(Palette.tertiary.opacity(0.5)).frame(width: 40, height: 5)
            HStack(spacing: 16) {
                appIcon(symbol: "dot.radiowaves.left.and.right", color: Color(hex: 0x2E8BFF), name: "AirDrop")
                appIcon(symbol: "message.fill", color: Palette.green, name: "Messages")
                VStack(spacing: 8) {
                    Image("AppIconImage")
                        .resizable()
                        .frame(width: 62, height: 62)
                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                        .shadow(color: .black.opacity(lit ? 0.35 : 0.12), radius: lit ? 16 : 6, y: lit ? 10 : 3)
                        .scaleEffect(lit ? 1.1 : 1)
                    Text("XNotch").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
                }
                appIcon(symbol: "envelope.fill", color: Color(hex: 0x2E8BFF), name: "Mail")
            }
            HStack(spacing: 10) {
                Image(systemName: "photo").foregroundStyle(Palette.secondary)
                Text("IMG_2041.HEIC")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.ink)
                Spacer()
                Text("3.4 MB").font(.system(size: 12)).foregroundStyle(Palette.tertiary)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.card))
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 18)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Palette.raised))
        .padding(20)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) { lit = true }
        }
    }

    private func appIcon(symbol: String, color: Color, name: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 62, height: 62)
                .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(color))
                .opacity(0.35)
            Text(name).font(.system(size: 12)).foregroundStyle(Palette.tertiary)
        }
    }
}

/// Text travelling from the phone to the Mac's clipboard, on a small pass.
private struct ClipboardIllustration: View {
    @State private var sent = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Meeting notes: ship the notch companion on Friday")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Palette.ink)
                .padding(16)
                .frame(maxWidth: 290, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.raised))
                .scaleEffect(sent ? 0.97 : 1)
                .opacity(sent ? 0.55 : 1)
            Image(systemName: "arrow.down")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Palette.ink)
                .opacity(sent ? 1 : 0.25)
                .offset(y: sent ? 4 : -4)
            HStack(spacing: 14) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 22))
                    .foregroundStyle(.white)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mac clipboard").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    // Pinned to the leading edge, so the swap happens in place.
                    ZStack(alignment: .leading) {
                        if sent {
                            StatusCaps(text: "Ready to paste", color: Palette.green)
                                .transition(.blurReplace)
                        } else {
                            StatusCaps(text: "Waiting", color: Palette.passTertiary)
                                .transition(.blurReplace)
                        }
                    }
                }
                .fixedSize()
                Spacer(minLength: 8)
                Text("⌘V")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .fixedSize()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(sent ? Palette.green.opacity(0.3) : .white.opacity(0.1)))
            }
            .padding(18)
            .frame(maxWidth: 310)
            .passCard(radius: 24)
        }
        .padding(20)
        .task {
            // Copy, arrive, pause, again.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 900_000_000)
                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { sent = true }
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                withAnimation(.easeInOut(duration: 0.4)) { sent = false }
            }
        }
    }
}
