import SwiftUI
import VisionKit
import XNotchLink

/// Scan the code XNotch shows on the Mac.
struct PairView: View {
    /// The first pairing fills the screen; later ones arrive in a sheet.
    let isStandalone: Bool
    @EnvironmentObject private var link: MacLink
    @Environment(\.dismiss) private var dismiss
    @State private var scanning = false
    @State private var message: String?

    var body: some View {
        StepLayout(title: "Pair with your Mac",
                   subtitle: "On your Mac, open XNotch Settings → Extensions → iPhone & iPad, then scan the code.",
                   footer: message ?? "You can also point the Camera app at the code") {
            PairingIllustration()
        } actions: {
            VStack(spacing: 12) {
                Button("Scan Code") { scanning = true }
                    .buttonStyle(PillButtonStyle(prominent: true))
                Button("Paste Pairing Link", action: pasteLink)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Palette.secondary)
                    .frame(height: 36)
            }
        }
        .fullScreenCover(isPresented: $scanning) {
            ScannerScreen { pairing in
                scanning = false
                accept(pairing)
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
        accept(pairing)
    }

    private func accept(_ pairing: LinkPairing) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        link.pair(pairing)
        if !isStandalone { dismiss() }
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

/// The camera, looking for the pairing QR code.
private struct ScannerScreen: View {
    let onPair: (LinkPairing) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                QRScanner(onPair: onPair)
                    .ignoresSafeArea()
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .strokeBorder(.white.opacity(0.85), lineWidth: 3)
                    .frame(width: 250, height: 250)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "camera.fill").font(.system(size: 40)).foregroundStyle(Palette.secondary)
                    Text("This device can't scan here")
                        .font(.system(size: 22, weight: .bold))
                    Text("Point the Camera app at the code instead, or copy the pairing link on your Mac and paste it.")
                        .foregroundStyle(Palette.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Text("Scan the code on your Mac")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Button { dismiss() } label: { CircleButtonLabel(symbol: "xmark", size: 44) }
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
        }
    }
}

private struct QRScanner: UIViewControllerRepresentable {
    let onPair: (LinkPairing) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced, isHighlightingEnabled: false)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPair: onPair) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onPair: (LinkPairing) -> Void
        private var done = false

        init(onPair: @escaping (LinkPairing) -> Void) {
            self.onPair = onPair
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for item in addedItems {
                guard !done, case .barcode(let code) = item, let text = code.payloadStringValue,
                      let url = URL(string: text), let pairing = LinkPairing(url: url) else { continue }
                done = true
                dataScanner.stopScanning()
                onPair(pairing)
            }
        }
    }
}
