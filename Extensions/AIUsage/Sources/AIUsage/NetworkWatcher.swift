import Foundation
import Network

/// Tells the main actor whether macOS has a usable network path, and when it gets one back. It only
/// knows about the link: a Wi-Fi that's joined but leads nowhere still reports as online.
@MainActor
final class NetworkWatcher {
    private let monitor = NWPathMonitor()
    private var isOnline: Bool?

    /// `onChange(online, cameBack)`: `cameBack` is true only when going from offline to online.
    func start(onChange: @escaping @MainActor (_ online: Bool, _ cameBack: Bool) -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.isOnline != online else { return }
                let cameBack = self.isOnline == false && online
                self.isOnline = online
                onChange(online, cameBack)
            }
        }
        monitor.start(queue: DispatchQueue(label: "XNotch.AIUsage.network", qos: .utility))
    }

    func stop() {
        monitor.pathUpdateHandler = nil
        monitor.cancel()
    }
}
