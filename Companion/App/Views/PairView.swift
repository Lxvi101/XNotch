import SwiftUI
import XNotchLink

/// Before the first pairing: what to open on the Mac, and the way in.
struct PairView: View {
    @EnvironmentObject private var flow: PairingFlow
    @State private var message: String?

    var body: some View {
        StepLayout(title: "Pair with your Mac",
                   subtitle: "On your Mac, open XNotch Settings → Extensions → iPhone & iPad, then scan the code.",
                   footer: message ?? "You can also point the Camera app at the code") {
            PairingIllustration()
        } actions: {
            VStack(spacing: 12) {
                Button("Scan Code") { flow.beginScanning() }
                    .buttonStyle(PillButtonStyle(prominent: true))
                Button("Paste Pairing Link", action: pasteLink)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Palette.secondary)
                    .frame(height: 36)
            }
        }
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

/// A Mac showing its code, with a scan line passing over it.
private struct PairingIllustration: View {
    @State private var sweep = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Palette.card)
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1.5))
                NotchShape()
                    .fill(.black)
                    .frame(width: 92, height: 18)
                    .frame(maxHeight: .infinity, alignment: .top)
                Image(systemName: "qrcode")
                    .font(.system(size: 92, weight: .regular))
                    .foregroundStyle(.white)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.06)))
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(LinearGradient(colors: [Palette.cyan.opacity(0), Palette.cyan, Palette.cyan.opacity(0)],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(height: 2)
                            .shadow(color: Palette.cyan, radius: 6)
                            .offset(y: sweep ? 118 : 2)
                    }
            }
            .frame(width: 280, height: 190)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))
                .frame(width: 330, height: 12)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { sweep = true }
        }
    }
}
