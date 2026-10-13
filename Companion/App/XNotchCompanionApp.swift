import SwiftUI
import XNotchLink

@main
struct XNotchCompanionApp: App {
    @StateObject private var link = MacLink()
    @StateObject private var flow = PairingFlow()
    @AppStorage("didOnboard") private var didOnboard = false
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView(didOnboard: $didOnboard)
                .environmentObject(link)
                .environmentObject(flow)
                .preferredColorScheme(.dark)
                .tint(.white)
                // The Camera app opens the Mac's code as an xnotchlink:// link.
                .onOpenURL { url in
                    guard let pairing = LinkPairing(url: url) else { return }
                    didOnboard = true
                    flow.begin(with: pairing)
                }
                // Only real background counts: Control Center or a system alert
                // make the app inactive for a moment, and that mustn't drop the link.
                .onChange(of: phase, initial: true) { _, phase in
                    switch phase {
                    case .active: link.setActive(true)
                    case .background: link.setActive(false)
                    default: break
                    }
                }
                .onAppear {
                    flow.onStart = { [weak link] in link?.pauseForPairing() }
                    flow.onEnd = { [weak link] in link?.resumeAfterPairing() }
                    flow.onConnected = { [weak link] pairing, session in link?.pair(pairing, session: session) }
                    flow.onSaveForLater = { [weak link] pairing in link?.pair(pairing) }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var link: MacLink
    @EnvironmentObject private var flow: PairingFlow
    @Environment(\.scenePhase) private var phase
    @Binding var didOnboard: Bool

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            if !didOnboard {
                OnboardingView { didOnboard = true }
                    .transition(.opacity)
            } else if link.mac == nil {
                PairView()
                    .transition(.opacity)
            } else {
                HomeView()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.9), value: didOnboard)
        .animation(.spring(response: 0.5, dampingFraction: 0.9), value: link.mac?.id)
        // Nothing animates behind the pairing screen or while the app is in the background.
        .environment(\.dotGridPaused, flow.isPresented || phase != .active)
        .fullScreenCover(isPresented: $flow.isPresented, onDismiss: { flow.dismiss() }) {
            PairingFlowView()
                .environmentObject(flow)
        }
    }
}
