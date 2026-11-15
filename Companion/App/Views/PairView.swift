import SwiftUI
import XNotchLink

/// Before the first pairing: the code on a pass, where to find it on the
/// Mac, and the way in.
struct PairView: View {
    @EnvironmentObject private var flow: PairingFlow
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            Text("Pair with your Mac")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .frame(height: 56)
            ScrollView {
                VStack(spacing: 14) {
                    PairingPass()
                    VStack(spacing: 0) {
                        step(1, Text("Open ") + Text("XNotch Settings").fontWeight(.semibold) + Text(" on your Mac"))
                        divider
                        step(2, Text("Go to ") + Text("Extensions → iPhone & iPad").fontWeight(.semibold))
                        divider
                        step(3, Text("Scan the code, or point the Camera app at it"))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                    .sheetCard(radius: 22)
                }
                .padding(.top, 6)
            }
            .scrollBounceBehavior(.basedOnSize)
            VStack(spacing: 6) {
                if let message {
                    Text(message)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Palette.orange)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 6)
                        .transition(.opacity)
                }
                Button { flow.beginScanning() } label: {
                    Label("Scan Code", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(PillButtonStyle(prominent: true))
                Button("Paste Pairing Link", action: pasteLink)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Palette.secondary)
                    .frame(height: 40)
            }
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.2), value: message)
    }

    private var divider: some View {
        Rectangle().fill(Palette.line).frame(height: 1).padding(.leading, 38)
    }

    private func step(_ number: Int, _ text: Text) -> some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Palette.ink)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Palette.raised))
            text
                .font(.system(size: 14.5))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
    }

    private func pasteLink() {
        guard let text = UIPasteboard.general.string, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let pairing = LinkPairing(url: url) else {
            message = "The clipboard has no XNotch pairing link"
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        flow.begin(with: pairing)
    }
}

/// The dark pass with a code on it and a green scan line passing over.
private struct PairingPass: View {
    @State private var sweep = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                StatusCaps(text: UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone", color: Palette.passSecondary)
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Palette.passTertiary)
                Spacer()
                StatusCaps(text: "Mac", color: Palette.passSecondary)
            }
            Image(systemName: "qrcode")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color(hex: 0x111113))
                .padding(18)
                .frame(width: 170, height: 170)
                .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.white))
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(LinearGradient(colors: [Palette.green.opacity(0), Palette.green, Palette.green.opacity(0)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(height: 2)
                        .shadow(color: Palette.green, radius: 6)
                        .padding(.horizontal, 10)
                        .offset(y: sweep ? 150 : 18)
                }
                .padding(.top, 18)
            Text("Scan the code shown on your Mac")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.top, 14)
        }
        .padding(22)
        .passCard()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { sweep = true }
        }
    }
}
