import Foundation
import ServiceManagement

/// User settings, persisted in standard defaults and observed by the notch.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    @Published var showsDestinationPills: Bool { didSet { defaults.set(showsDestinationPills, forKey: Key.pills) } }
    /// Whether pills drop their names, as picked in Settings. Nil until the
    /// user picks, and XNotch decides (see `PillLabels`).
    @Published var pillsIconOnlyChoice: Bool? {
        didSet {
            if let pillsIconOnlyChoice {
                defaults.set(pillsIconOnlyChoice, forKey: Key.pillsIconOnly)
            } else {
                defaults.removeObject(forKey: Key.pillsIconOnly)
            }
        }
    }
    @Published var hapticsEnabled: Bool { didSet { defaults.set(hapticsEnabled, forKey: Key.haptics) } }
    @Published var showsMediaInNotch: Bool { didSet { defaults.set(showsMediaInNotch, forKey: Key.media) } }
    /// What sits right of the camera while music plays.
    @Published var musicWingIndicator: MusicWingIndicator {
        didSet { defaults.set(musicWingIndicator.rawValue, forKey: Key.musicWingIndicator) }
    }
    @Published var showsHeadphonesInNotch: Bool { didSet { defaults.set(showsHeadphonesInNotch, forKey: Key.headphones) } }
    @Published var lockScreenMediaEnabled: Bool { didSet { defaults.set(lockScreenMediaEnabled, forKey: Key.lockScreen) } }
    @Published var disabledExtensions: Set<String> {
        didSet { defaults.set(Array(disabledExtensions).sorted(), forKey: Key.disabledExtensions) }
    }
    /// Extensions XNotch has come across. One it hasn't starts switched off: every extension is opt-in.
    @Published var knownExtensions: Set<String> {
        didSet { defaults.set(Array(knownExtensions).sorted(), forKey: Key.knownExtensions) }
    }
    @Published var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: Key.onboarding) } }
    /// The user's order of the notch's pages, by `OpenPage.id`. Pages not in it
    /// (new extensions) follow in their usual order.
    @Published var pageOrder: [String] { didSet { defaults.set(pageOrder, forKey: Key.pageOrder) } }
    /// A notch on every connected display, not just the main one.
    @Published var showsOnAllDisplays: Bool { didSet { defaults.set(showsOnAllDisplays, forKey: Key.allDisplays) } }
    /// The display the notch lives on, by `NSScreen.displayID`. Nil picks it
    /// automatically: the built-in notch, else the display with the menu bar.
    @Published var notchDisplay: String? { didSet { defaults.set(notchDisplay, forKey: Key.notchDisplay) } }
    /// How tall the notch XNotch draws on a display without a camera notch is.
    @Published var drawnNotchHeight: DrawnNotchHeight {
        didSet { defaults.set(drawnNotchHeight.rawValue, forKey: Key.drawnNotchHeight) }
    }
    /// Pages the user took out of the pills and switcher, by `OpenPage.id`.
    @Published var hiddenPages: Set<String> {
        didSet { defaults.set(Array(hiddenPages).sorted(), forKey: Key.hiddenPages) }
    }
    @Published private(set) var launchesAtLogin = SMAppService.mainApp.status == .enabled

    private enum Key {
        static let pills = "showsDestinationPills"
        static let pillsIconOnly = "pillsIconOnly"
        static let haptics = "hapticsEnabled"
        static let media = "showsMediaInNotch"
        static let lockScreen = "lockScreenMediaEnabled"
        static let headphones = "showsHeadphonesInNotch"
        static let musicWingIndicator = "musicWingIndicator"
        static let disabledExtensions = "disabledExtensions"
        static let knownExtensions = "knownExtensions"
        static let onboarding = "hasCompletedOnboarding"
        static let pageOrder = "pageOrder"
        static let allDisplays = "showsOnAllDisplays"
        static let notchDisplay = "notchDisplay"
        static let drawnNotchHeight = "drawnNotchHeight"
        static let hiddenPages = "hiddenPages"
    }

    private init() {
        defaults.register(defaults: [
            Key.pills: true, Key.haptics: true, Key.media: true, Key.lockScreen: true,
            Key.headphones: true
        ])
        showsDestinationPills = defaults.bool(forKey: Key.pills)
        // Only ever written by the picker, so it's there only if the user chose.
        pillsIconOnlyChoice = defaults.object(forKey: Key.pillsIconOnly) as? Bool
        hapticsEnabled = defaults.bool(forKey: Key.haptics)
        showsMediaInNotch = defaults.bool(forKey: Key.media)
        lockScreenMediaEnabled = defaults.bool(forKey: Key.lockScreen)
        showsHeadphonesInNotch = defaults.bool(forKey: Key.headphones)
        musicWingIndicator = defaults.string(forKey: Key.musicWingIndicator).flatMap(MusicWingIndicator.init) ?? .visualizer
        disabledExtensions = Set(defaults.stringArray(forKey: Key.disabledExtensions) ?? [])
        hasCompletedOnboarding = defaults.bool(forKey: Key.onboarding)
        pageOrder = defaults.stringArray(forKey: Key.pageOrder) ?? []
        showsOnAllDisplays = defaults.bool(forKey: Key.allDisplays)
        notchDisplay = defaults.string(forKey: Key.notchDisplay)
        drawnNotchHeight = defaults.string(forKey: Key.drawnNotchHeight).flatMap(DrawnNotchHeight.init) ?? .menuBar
        hiddenPages = Set(defaults.stringArray(forKey: Key.hiddenPages) ?? [])
        // Before extensions were opt-in, Folders came switched on; it stays as the user left it.
        knownExtensions = Set(defaults.stringArray(forKey: Key.knownExtensions)
            ?? (defaults.bool(forKey: Key.onboarding) ? ["folders"] : []))
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

/// The closed notch's right side while music plays: moving bars, or a still
/// play/pause symbol for anyone who finds the motion distracting.
enum MusicWingIndicator: String, CaseIterable {
    case visualizer, playPause
}

/// On a display without a camera notch: sit flush with its menu bar, or
/// match the height of a real notch.
enum DrawnNotchHeight: String, CaseIterable {
    case menuBar, notch
}
