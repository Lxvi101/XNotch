import AppKit
import Combine
import XNotchKit

/// What every display's notch shares: one shelf, one player, one set of
/// extensions and headphones.
@MainActor
final class NotchServices {
    let shelf = ShelfStore()
    let media = NowPlayingService()
    let extensions = ExtensionManager()
    let headphones = HeadphonesMonitor()
    private(set) var isStarted = false
    private let preferences = Preferences.shared
    private var cancellables: Set<AnyCancellable> = []

    init() {
        preferences.$showsHeadphonesInNotch
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] shows in
                guard let self else { return }
                if !shows {
                    headphones.stop()
                } else if isStarted {
                    headphones.start()
                }
            }
            .store(in: &cancellables)
    }

    /// Media, the shelf and extensions all read files, some in protected
    /// folders. On first run they wait until the onboarding has asked for
    /// Full Disk Access, so macOS doesn't ask folder by folder first.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        media.start()
        shelf.load()
        extensions.loadAll()
        if preferences.showsHeadphonesInNotch { headphones.start() }
    }
}

/// A notch window per display: the main one, which the onboarding, Settings
/// and lock screen work with, and with "Show on all displays" one more on
/// every other display. Extensions, alerts and toasts go to the display the
/// pointer is on.
@MainActor
final class NotchDisplays {
    let services = NotchServices()
    /// Moves between displays as they come and go, but is never replaced.
    let main: NotchWindowController
    private var others: [String: NotchWindowController] = [:]
    private let preferences = Preferences.shared
    private var cancellables: Set<AnyCancellable> = []

    var onOpenSettings: ((SettingsPane?) -> Void)? {
        didSet { controllers.forEach { $0.model.onOpenSettings = onOpenSettings } }
    }

    var model: NotchViewModel { main.model }
    private var controllers: [NotchWindowController] { [main] + others.values }
    var models: [NotchViewModel] { controllers.map(\.model) }

    init?() {
        guard let screen = Self.mainScreen() else { return nil }
        main = NotchWindowController(screen: screen, services: services)
        services.extensions.driver = self
        services.headphones.onConnect = { [weak self] _ in self?.activeModel.showHeadphonesToast() }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
        Publishers.Merge3(
            preferences.$showsOnAllDisplays.dropFirst().map { _ in () },
            preferences.$notchDisplay.dropFirst().map { _ in () },
            preferences.$drawnNotchHeight.dropFirst().map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.layout() }
        .store(in: &cancellables)
        layout()
    }

    /// The display the main notch belongs on: the one picked in Settings,
    /// else the built-in notch, else the display with the menu bar.
    static func mainScreen() -> NSScreen? {
        let screens = NSScreen.screens
        let picked = Preferences.shared.notchDisplay
        return screens.first { picked != nil && $0.displayID == picked }
            ?? screens.first { $0.safeAreaInsets.top > 0 }
            ?? screens.first
    }

    func startServices() {
        services.start()
        models.forEach { $0.servicesDidStart() }
    }

    func close() {
        models.forEach { $0.close() }
    }

    /// The notch on the display under the pointer, else the main one.
    var activeModel: NotchViewModel {
        guard !main.model.isPresentingOnboarding else { return main.model }
        let pointer = NSEvent.mouseLocation
        // Inclusive edges: the pointer rests on a display's top edge to reach its notch.
        let under = controllers.first {
            let frame = $0.screen.frame
            return (frame.minX...frame.maxX).contains(pointer.x) && (frame.minY...frame.maxY).contains(pointer.y)
        }
        return under?.model ?? main.model
    }

    private func layout() {
        guard let mainScreen = Self.mainScreen() else { return }
        var wanted: [String: NSScreen] = [:]
        if preferences.showsOnAllDisplays {
            for screen in NSScreen.screens {
                if let id = screen.displayID, id != mainScreen.displayID { wanted[id] = screen }
            }
        }
        for (id, controller) in others where wanted[id] == nil {
            controller.tearDown()
            others[id] = nil
        }
        main.move(to: mainScreen)
        for (id, screen) in wanted {
            if let controller = others[id] {
                controller.move(to: screen)
            } else {
                let controller = NotchWindowController(screen: screen, services: services)
                controller.model.onOpenSettings = onOpenSettings
                others[id] = controller
            }
        }
    }
}

extension NotchDisplays: ExtensionNotchDriver {
    var isOpen: Bool { models.contains(where: \.isOpen) }
    var shelfFiles: [URL] { services.shelf.items.map(\.url) }

    func open(page: OpenPage) {
        activeModel.open(page: page)
    }

    func openSettings(extension id: ExtensionID) {
        close()
        onOpenSettings?(.extensionPane(id))
    }

    func addToShelf(_ urls: [URL]) {
        activeModel.addToShelf(urls)
    }

    func showAlert(_ alert: NotchAlert, eyes: NotchAlertSeverity?, from id: ExtensionID) {
        activeModel.showAlert(alert, eyes: eyes, from: id)
    }

    /// The eyes open on the active display; one that stopped being active closes its own.
    func watch(_ point: CGPoint?, mood: NotchEyesMood, from id: ExtensionID) {
        let active = activeModel
        for model in models where model !== active { model.stopWatching(farewell: nil, from: id) }
        active.watch(point, mood: NotchEyes.Expression(mood), from: id)
    }

    func stopWatching(farewell: NotchEyesMood?, from id: ExtensionID) {
        for model in models { model.stopWatching(farewell: farewell.map(NotchEyes.Expression.init), from: id) }
    }
}

extension NotchEyes.Expression {
    init(_ mood: NotchEyesMood) {
        switch mood {
        case .attentive: self = .attentive
        case .curious: self = .curious
        case .happy: self = .happy
        case .excited: self = .excited
        case .sleepy: self = .sleepy
        case .worried: self = .worried
        }
    }
}

extension NSScreen {
    /// Stays the same across launches and reconnects, unlike the display number.
    var displayID: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
