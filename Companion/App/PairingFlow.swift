import SwiftUI
import UIKit
import XNotchLink

/// Scan → connect → done, or a plain-language error with a way forward.
/// A pairing is only saved once it has actually connected (or the user
/// chooses to save it for later), and that first connection is kept.
@MainActor
final class PairingFlow: ObservableObject {
    enum Phase: Equatable {
        case scanning, connecting, connected, failed
    }

    struct Failure: Equatable {
        let title: String
        let message: String
        var opensSettings = false
        /// Retrying can't help: only a fresh code can.
        var needsNewCode = false
    }

    @Published var isPresented = false
    @Published private(set) var phase: Phase = .scanning
    @Published private(set) var pairing: LinkPairing?
    /// Routes being tried right now.
    @Published private(set) var searching: Set<LinkRoute> = []
    @Published private(set) var waitingForLocalNetwork = false
    /// Set once the Mac answered and the handshake is running.
    @Published private(set) var securing: LinkRoute?
    @Published private(set) var connectedRoute: String?
    @Published private(set) var failure: Failure?

    var onConnected: ((LinkPairing, LinkSession) -> Void)?
    var onSaveForLater: ((LinkPairing) -> Void)?
    /// The app's own connections step aside while pairing, so the two don't compete.
    var onStart: (() -> Void)?
    var onEnd: (() -> Void)?

    private var task: Task<Void, Never>?

    func beginScanning() {
        reset()
        phase = .scanning
        present()
    }

    /// From a pasted link or the Camera app.
    func begin(with pairing: LinkPairing) {
        reset()
        present()
        scanned(pairing)
    }

    func scanned(_ pairing: LinkPairing) {
        self.pairing = pairing
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        connect()
    }

    func retry() {
        connect()
    }

    func scanAgain() {
        reset()
        phase = .scanning
    }

    func saveForLater() {
        if let pairing { onSaveForLater?(pairing) }
        dismiss()
    }

    func dismiss() {
        task?.cancel()
        task = nil
        isPresented = false
        onEnd?()
    }

    private func present() {
        guard !isPresented else { return }
        onStart?()
        isPresented = true
    }

    private func reset() {
        task?.cancel()
        task = nil
        pairing = nil
        searching = []
        waitingForLocalNetwork = false
        securing = nil
        connectedRoute = nil
        failure = nil
    }

    private func connect() {
        guard let pairing else { return }
        task?.cancel()
        phase = .connecting
        searching = []
        waitingForLocalNetwork = false
        securing = nil
        failure = nil
        let device = ThisDevice.link
        let incoming = ThisDevice.incomingDirectory
        task = Task { [weak self] in
            do {
                let session = try await LinkClient.connectBest(to: pairing, as: device, incomingDirectory: incoming,
                                                               routes: Self.routes, timeout: 10) { event in
                    Task { @MainActor [weak self] in self?.handle(event) }
                }
                guard let self, !Task.isCancelled else { await session.close(); return }
                connectedRoute = session.routeTitle
                phase = .connected
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onConnected?(pairing, session)
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled else { return }
                failure = Self.describe(error, pairing: pairing)
                phase = .failed
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private func handle(_ event: LinkProgress) {
        guard phase == .connecting else { return }
        switch event {
        case .searching(let route):
            searching.insert(route)
            if route == .local { waitingForLocalNetwork = false }
        case .waitingForLocalNetwork:
            waitingForLocalNetwork = true
        case .securing(let route):
            securing = route
            waitingForLocalNetwork = false
        }
    }

    // Bluetooth is left out: it's slow to find, and pairing happens next to the Mac anyway.
    #if targetEnvironment(simulator)
    private static let routes: Set<LinkRoute> = [.local, .internet]
    #else
    private static let routes: Set<LinkRoute> = [.usb, .local, .internet]
    #endif

    static func describe(_ error: Error, pairing: LinkPairing) -> Failure {
        let name = pairing.name
        switch error as? LinkError {
        case .localNetworkDenied:
            return Failure(title: "Local Network is off",
                           message: "XNotch finds your Mac on your network. Turn on Local Network for XNotch in Settings, then try again.",
                           opensSettings: true)
        case .notFound:
            return Failure(title: "Couldn't find \(name)",
                           message: pairing.relay == nil
                               ? "Make sure XNotch is running on your Mac with iPhone & iPad switched on in Settings → Extensions, and that your iPhone is on the same Wi-Fi."
                               : "Your Mac didn't answer on this network or over the internet. Make sure XNotch is running on it with iPhone & iPad switched on.")
        case .rejected:
            return Failure(title: "This code is out of date",
                           message: "\(name) has a new pairing code. On your Mac, open XNotch Settings → Extensions → iPhone & iPad and scan the code again.",
                           needsNewCode: true)
        case .unavailable(let reason):
            return Failure(title: "Couldn't connect", message: reason)
        case .timedOut, .connectionFailed, .closed, .protocolViolation:
            return Failure(title: "The connection dropped",
                           message: "\(name) answered, but the connection didn't hold. Check that both are on the same Wi-Fi, then try again.")
        case nil:
            return Failure(title: "Couldn't connect", message: error.localizedDescription)
        }
    }
}
