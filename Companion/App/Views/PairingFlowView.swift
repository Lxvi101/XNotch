import SwiftUI
import VisionKit
import XNotchLink

/// The whole pairing, full screen: the camera, then each step as it
/// happens, then Done, or what went wrong and what to do about it.
struct PairingFlowView: View {
    @EnvironmentObject private var flow: PairingFlow

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            if flow.phase == .scanning {
                ScanStep()
                    .transition(.opacity)
            } else {
                ProgressStep()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.9), value: flow.phase == .scanning)
        .preferredColorScheme(.dark)
    }
}

// MARK: Scanning

private struct ScanStep: View {
    @EnvironmentObject private var flow: PairingFlow
    @State private var pasteFailed = false

    var body: some View {
        ZStack(alignment: .top) {
            if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                QRScanner { flow.scanned($0) }
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
                Button { flow.dismiss() } label: { CircleButtonLabel(symbol: "xmark", size: 44) }
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
            VStack(spacing: 10) {
                Text("XNotch Settings → Extensions → iPhone & iPad")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                Button(pasteFailed ? "No pairing link on the clipboard" : "Paste Pairing Link", action: paste)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(pasteFailed ? .orange : Palette.cyan)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 20)
            .background(Capsule().fill(.black.opacity(0.55)))
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 24)
        }
    }

    private func paste() {
        guard let text = UIPasteboard.general.string,
              let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let pairing = LinkPairing(url: url) else {
            withAnimation { pasteFailed = true }
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        flow.scanned(pairing)
    }
}

/// The camera, for QR codes only, without the extra tracking work.
private struct QRScanner: UIViewControllerRepresentable {
    let onPair: (LinkPairing) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced, recognizesMultipleItems: false,
                                                isHighFrameRateTrackingEnabled: false, isPinchToZoomEnabled: false,
                                                isGuidanceEnabled: false, isHighlightingEnabled: false)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning, !context.coordinator.done { try? scanner.startScanning() }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPair: onPair) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onPair: (LinkPairing) -> Void
        var done = false

        init(onPair: @escaping (LinkPairing) -> Void) {
            self.onPair = onPair
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for item in addedItems {
                guard !done, case .barcode(let code) = item, let text = code.payloadStringValue,
                      let url = URL(string: text), let pairing = LinkPairing(url: url) else { continue }
                // Stop the camera first; the progress screen replaces it.
                done = true
                dataScanner.stopScanning()
                onPair(pairing)
            }
        }
    }
}

// MARK: Progress

private struct ProgressStep: View {
    @EnvironmentObject private var flow: PairingFlow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(title)
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    if let name = flow.pairing?.name, !title.contains(name) {
                        Text(name)
                            .font(.system(size: 19))
                            .foregroundStyle(Palette.secondary)
                    }
                }
                Spacer()
                if flow.phase == .connecting {
                    Button { flow.dismiss() } label: { CircleButtonLabel(symbol: "xmark", size: 40) }
                }
            }
            .padding(.top, 40)

            VStack(spacing: 0) {
                StepRow(title: "Code scanned", detail: "Paired with this Mac's key", state: .done)
                StepRow(title: "Finding your Mac", detail: findingDetail, detailIsWarning: flow.waitingForLocalNetwork,
                        state: findingState)
                StepRow(title: "Securing the connection",
                        detail: flow.failure?.needsNewCode == true ? "Your Mac didn't accept this code" : "End-to-end encrypted",
                        state: securingState)
                StepRow(title: "Connected", detail: flow.connectedRoute.map { "Over \($0)" } ?? "Ready to send",
                        state: flow.phase == .connected ? .done : .pending, isLast: true)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 18)
            .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Palette.card))
            .padding(.top, 32)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: findingState)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: securingState)

            if let failure = flow.failure, flow.phase == .failed {
                Text(failure.message)
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 24)
                    .transition(.opacity)
            }

            Spacer(minLength: 24)
            actions
        }
        .padding(.horizontal, 26)
        .padding(.bottom, 12)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.45, dampingFraction: 0.9), value: flow.phase)
    }

    private var title: String {
        switch flow.phase {
        case .connected: "Connected"
        case .failed: flow.failure?.title ?? "Couldn't connect"
        default: "Connecting"
        }
    }

    private var findingDetail: String {
        if flow.waitingForLocalNetwork { return "Allow Local Network when iOS asks" }
        if let route = flow.securing { return "Found over \(route.title)" }
        var places: [String] = []
        if flow.searching.contains(.local) || flow.searching.isEmpty { places.append("Wi-Fi") }
        if flow.searching.contains(.internet) { places.append("the internet") }
        if flow.phase == .failed {
            return "Not found on " + places.joined(separator: " or ")
        }
        return "Looking on " + ListFormatter.localizedString(byJoining: places + (places.first == "Wi-Fi" ? ["nearby"] : []))
    }

    private var findingState: StepRow.State {
        if flow.securing != nil || flow.phase == .connected { return .done }
        return flow.phase == .failed ? .failed : .active
    }

    private var securingState: StepRow.State {
        if flow.phase == .connected { return .done }
        guard flow.securing != nil else { return .pending }
        return flow.phase == .failed ? .failed : .active
    }

    @ViewBuilder
    private var actions: some View {
        switch flow.phase {
        case .connected:
            Button("Done") { flow.dismiss() }
                .buttonStyle(PillButtonStyle(prominent: true))
        case .failed:
            VStack(spacing: 12) {
                if flow.failure?.needsNewCode == true {
                    Button("Scan Again") { flow.scanAgain() }.buttonStyle(PillButtonStyle(prominent: true))
                } else if flow.failure?.opensSettings == true {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .buttonStyle(PillButtonStyle(prominent: true))
                    Button("Try Again") { flow.retry() }.buttonStyle(PillButtonStyle())
                } else {
                    Button("Try Again") { flow.retry() }.buttonStyle(PillButtonStyle(prominent: true))
                }
                HStack {
                    if flow.failure?.needsNewCode != true {
                        Button("Scan Again") { flow.scanAgain() }
                    }
                    Spacer()
                    if flow.failure?.needsNewCode != true {
                        Button("Save, Connect Later") { flow.saveForLater() }
                    }
                }
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Palette.secondary)
                .padding(.horizontal, 8)
                .frame(height: 40)
            }
        default:
            Text("This takes a few seconds")
                .font(.system(size: 15))
                .foregroundStyle(Palette.tertiary)
                .frame(maxWidth: .infinity)
                .frame(height: 60)
        }
    }
}

/// One step: pending, working, done or failed, with a line of detail.
private struct StepRow: View {
    enum State: Equatable {
        case pending, active, done, failed
    }

    let title: String
    let detail: String
    var detailIsWarning = false
    let state: State
    var isLast = false

    var body: some View {
        HStack(spacing: 14) {
            indicator
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(state == .pending ? Palette.tertiary : .white)
                Text(detail)
                    .font(.system(size: 14))
                    .foregroundStyle(detailIsWarning ? .orange : Palette.secondary)
                    .opacity(state == .pending ? 0.5 : 1)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) {
            if !isLast { Rectangle().fill(.white.opacity(0.06)).frame(height: 1).padding(.leading, 42) }
        }
    }

    @ViewBuilder
    private var indicator: some View {
        switch state {
        case .pending:
            Circle().strokeBorder(Palette.tertiary.opacity(0.6), lineWidth: 2)
        case .active:
            ProgressView().tint(.white)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(Palette.green)
                .transition(.scale.combined(with: .opacity))
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.red)
                .transition(.scale.combined(with: .opacity))
        }
    }
}
