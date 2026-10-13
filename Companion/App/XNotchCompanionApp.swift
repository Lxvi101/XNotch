import SwiftUI
import XNotchLink

@main
struct XNotchCompanionApp: App {
    @StateObject private var link = MacLink()
    @AppStorage("didOnboard") private var didOnboard = false
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView(didOnboard: $didOnboard)
                .environmentObject(link)
                .preferredColorScheme(.dark)
                .tint(.white)
                // The Camera app opens the Mac's code as an xnotchlink:// link.
                .onOpenURL { url in
                    guard let pairing = LinkPairing(url: url) else { return }
                    link.pair(pairing)
                    didOnboard = true
                }
                .onChange(of: phase, initial: true) { _, phase in
                    link.setActive(phase == .active)
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var link: MacLink
    @Binding var didOnboard: Bool

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            if !didOnboard {
                OnboardingView { didOnboard = true }
                    .transition(.opacity)
            } else if link.mac == nil {
                PairView(isStandalone: true)
                    .transition(.opacity)
            } else {
                HomeView()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.9), value: didOnboard)
        .animation(.spring(response: 0.5, dampingFraction: 0.9), value: link.mac?.id)
    }
}
