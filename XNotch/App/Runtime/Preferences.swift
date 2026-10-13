import Foundation
import ServiceManagement

/// User settings, persisted in standard defaults and observed by the notch.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    @Published var showsDestinationPills: Bool { didSet { defaults.set(showsDestinationPills, forKey: Key.pills) } }
    @Published var pillsIconOnly: Bool { didSet { defaults.set(pillsIconOnly, forKey: Key.pillsIconOnly) } }
    @Published var hapticsEnabled: Bool { didSet { defaults.set(hapticsEnabled, forKey: Key.haptics) } }
    @Published var showsMediaInNotch: Bool { didSet { defaults.set(showsMediaInNotch, forKey: Key.media) } }
    @Published var lockScreenMediaEnabled: Bool { didSet { defaults.set(lockScreenMediaEnabled, forKey: Key.lockScreen) } }
    @Published var disabledExtensions: Set<String> {
        didSet { defaults.set(Array(disabledExtensions).sorted(), forKey: Key.disabledExtensions) }
    }
    @Published var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: Key.onboarding) } }
    @Published private(set) var launchesAtLogin = SMAppService.mainApp.status == .enabled

    private enum Key {
        static let pills = "showsDestinationPills"
        static let pillsIconOnly = "pillsIconOnly"
        static let haptics = "hapticsEnabled"
        static let media = "showsMediaInNotch"
        static let lockScreen = "lockScreenMediaEnabled"
        static let disabledExtensions = "disabledExtensions"
        static let onboarding = "hasCompletedOnboarding"
    }

    private init() {
        defaults.register(defaults: [
            Key.pills: true, Key.pillsIconOnly: false, Key.haptics: true, Key.media: true, Key.lockScreen: true
        ])
        showsDestinationPills = defaults.bool(forKey: Key.pills)
        pillsIconOnly = defaults.bool(forKey: Key.pillsIconOnly)
        hapticsEnabled = defaults.bool(forKey: Key.haptics)
        showsMediaInNotch = defaults.bool(forKey: Key.media)
        lockScreenMediaEnabled = defaults.bool(forKey: Key.lockScreen)
        disabledExtensions = Set(defaults.stringArray(forKey: Key.disabledExtensions) ?? [])
        hasCompletedOnboarding = defaults.bool(forKey: Key.onboarding)
    }

    func setLaunchesAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("XNotch: login item change failed: \(error.localizedDescription)")
        }
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }
}
