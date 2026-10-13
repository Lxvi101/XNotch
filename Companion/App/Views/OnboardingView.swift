import SwiftUI

/// Three steps, then pairing.
struct OnboardingView: View {
    let onFinish: () -> Void
    #if DEBUG
    // `-onboardingStep 2` opens a later step, for screenshots.
    @State private var step = UserDefaults.standard.integer(forKey: "onboardingStep")
    #else
    @State private var step = 0
    #endif

    var body: some View {
        ZStack {
            switch step {
            case 0:
                WelcomeStep { advance() }
                    .transition(stepTransition)
            case 1:
                StepLayout(title: "Share to your Mac",
                           subtitle: "Tap Share in any app and pick XNotch. It lands on your Mac's shelf, under the notch.",
                           footer: "Photos, PDFs, downloads, anything") {
                    ShareSheetIllustration()
                } actions: {
                    Button("Continue") { advance() }.buttonStyle(PillButtonStyle())
                }
                .transition(stepTransition)
            default:
                StepLayout(title: "Copy here, paste there",
                           subtitle: "Send text straight to your Mac's clipboard, then press ⌘V.",
                           footer: "Text never leaves your network") {
                    ClipboardIllustration()
                } actions: {
                    Button("Continue") { advance() }.buttonStyle(PillButtonStyle())
                }
                .transition(stepTransition)
            }
        }
        .animation(.spring(response: 0.55, dampingFraction: 0.88), value: step)
    }

    private var stepTransition: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(x: 40)),
                    removal: .opacity.combined(with: .offset(x: -40)))
    }

    private func advance() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if step < 2 { step += 1 } else { onFinish() }
    }
}

private struct WelcomeStep: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("Your iPhone,\none drop from the notch")
                .font(.system(size: 36, weight: .bold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 12)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .frame(height: 240)
                // Wider than the screen on purpose; as a background it doesn't widen the layout.
                .background { GlowArcs().offset(y: 30) }
                .padding(.top, 30)
            NotchIllustration()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Button("Continue", action: onContinue)
                .buttonStyle(PillButtonStyle())
            Text("Works with XNotch on your Mac")
                .font(.system(size: 15))
                .foregroundStyle(Palette.tertiary)
                .padding(.top, 18)
        }
        .padding(.horizontal, 26)
        .padding(.bottom, 12)
        .frame(maxWidth: 560)
    }
}

/// The top of a Mac screen: the notch, its eyes, and files falling into it.
struct NotchIllustration: View {
    @State private var drop = false

    var body: some View {
        GeometryReader { proxy in
            let width = min(proxy.size.width, 420)
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.13), Color(white: 0.05)], startPoint: .top, endPoint: .bottom))
                    .overlay {
                        DotGrid(spacing: 17, intensity: 0.8)
                            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1.5)
                    }
                NotchShape()
                    .fill(.black)
                    .frame(width: width * 0.42, height: 46)
                    .overlay(alignment: .center) {
                        HStack(spacing: 12) {
                            Capsule().fill(.white).frame(width: 9, height: 20)
                            Capsule().fill(.white).frame(width: 9, height: 20)
                        }
                        .offset(y: 4)
                    }
                ForEach(0..<3) { index in
                    FileChip(symbol: ["photo.fill", "doc.richtext.fill", "film.fill"][index],
                             tint: [Palette.cyan, .orange, .pink][index])
                        .offset(x: CGFloat(index - 1) * 74, y: drop ? 22 : 190)
                        .scaleEffect(drop ? 0.35 : 1)
                        .opacity(drop ? 0 : 1)
                        .animation(.easeIn(duration: 1.1).delay(Double(index) * 0.25)
                                    .repeatForever(autoreverses: false), value: drop)
                }
            }
            .frame(width: width, height: min(proxy.size.height, 280))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { drop = true }
    }
}

private struct FileChip: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 58, height: 58)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.raised))
            .shadow(color: tint.opacity(0.35), radius: 14)
    }
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
            Capsule().fill(.white.opacity(0.25)).frame(width: 40, height: 5)
            HStack(spacing: 18) {
                appIcon(symbol: "dot.radiowaves.left.and.right", color: Palette.blue, name: "AirDrop", lit: false)
                appIcon(symbol: "message.fill", color: Palette.green, name: "Messages", lit: false)
                VStack(spacing: 8) {
                    Image("AppIconImage")
                        .resizable()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                        .shadow(color: Palette.cyan.opacity(lit ? 0.8 : 0.2), radius: lit ? 18 : 6)
                        .scaleEffect(lit ? 1.08 : 1)
                    Text("XNotch").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                }
                appIcon(symbol: "envelope.fill", color: Palette.blue, name: "Mail", lit: false)
            }
        }
        .padding(.vertical, 24)
        .padding(.horizontal, 20)
        .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .onAppear {
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) { lit = true }
        }
    }

    private func appIcon(symbol: String, color: Color, name: String, lit: Bool) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(color.opacity(0.85)))
                .opacity(0.45)
            Text(name).font(.system(size: 13)).foregroundStyle(Palette.tertiary)
        }
    }
}

/// Text travelling from the phone to the Mac's clipboard.
private struct ClipboardIllustration: View {
    @State private var sent = false

    var body: some View {
        VStack(spacing: 22) {
            Text("Meeting notes: ship the notch companion on Friday")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white)
                .padding(18)
                .frame(maxWidth: 300, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Palette.raised))
                .offset(y: sent ? -8 : 0)
            Image(systemName: "arrow.down")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Palette.cyan)
                .opacity(sent ? 1 : 0.3)
            HStack(spacing: 14) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mac clipboard").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    StatusCaps(text: sent ? "Ready to paste" : "Waiting", color: sent ? Palette.green : Palette.tertiary)
                }
                Spacer()
                Text("⌘V")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Palette.raised))
            }
            .padding(18)
            .frame(maxWidth: 320)
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Palette.card))
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.4).repeatForever(autoreverses: true)) {
                sent = true
            }
        }
    }
}
