import AppKit
import SwiftUI
import XNotchKit

/// Everything the onboarding draws. One notch, the "hero", carries the whole
/// experience: it flies in, snaps into the real notch's place, grows a face,
/// opens into the tutorial and folds back into the real notch at the end.
@MainActor
final class OnboardingState: ObservableObject {
    enum Step: Int, CaseIterable {
        case hello, shelf, music, pills, access, extensions, extensionAccess, done
    }

    enum Access {
        case asking, guiding, granted
    }

    /// The hero's resting shapes: the physical notch, a face big enough for
    /// its eyes, and the tutorial panel.
    enum Form {
        case docked, face, panel
    }

    /// The screen dims behind the hero, with a glow from the top.
    @Published var dim: CGFloat = 0
    /// Light on the hero's rim while it travels; drained by the snap.
    @Published var glow: CGFloat = 0
    /// The ring of light the snap sends out, 0...1.
    @Published var ring: CGFloat = 0
    @Published var flightX: CGFloat = 0
    @Published var flightY: CGFloat = 0
    /// 1 = right in front of the viewer, 0 = at the screen.
    @Published var depth: CGFloat = 0
    @Published var presence: CGFloat = 0
    @Published var form: Form = .docked
    @Published var impact = NotchDeformation()
    @Published var step: Step = .hello
    @Published var demo = 0
    @Published var fileX: CGFloat = 0
    @Published var fileY: CGFloat = 0
    @Published var fileTilt: CGFloat = 0
    @Published var access: Access = .asking
    @Published var launchAtLogin = true
    /// The tour's steps. Picking extensions joins when there are any; their permissions join once
    /// the picked ones have loaded.
    @Published var steps: [Step] = [.hello, .shelf, .music, .pills, .access, .done]
    @Published var offeredExtensions: [ExtensionManifest] = []
    @Published var chosenExtensions: Set<ExtensionID> = []
    /// What was already on when the tour started, so a replay only "adds" what's new.
    var enabledExtensions: Set<ExtensionID> = []

    var newlyChosenExtensions: [ExtensionManifest] {
        offeredExtensions.filter { chosenExtensions.contains($0.id) && !enabledExtensions.contains($0.id) }
    }
    @Published var extensionPermissions: [ExtensionManager.PendingPermission] = []
    @Published var grantedPermissions: Set<String> = []
    @Published var extensionAccess: Access = .asking

    let permission = Permission.fullDiskAccess
    let notchSize: CGSize

    init(notchSize: CGSize) {
        self.notchSize = notchSize
    }

    static let panelWidth: CGFloat = 470
    static let panelTopRadius: CGFloat = 24
    static let eyesUnit: CGFloat = 58
    static let eyesHeight: CGFloat = 56
    static let textHeight: CGFloat = 86
    static let footerHeight: CGFloat = 62
    static let inset: CGFloat = panelTopRadius + 24

    var eyesTop: CGFloat { notchSize.height + 4 }
    var contentTop: CGFloat { notchSize.height + 66 }
    var panelOuterWidth: CGFloat { Self.panelWidth + 2 * Self.panelTopRadius }

    static let permissionRowHeight: CGFloat = 56
    static let permissionRowSpacing: CGFloat = 8

    func demoHeight(_ step: Step) -> CGFloat {
        switch step {
        case .hello: 0
        case .shelf: 82
        case .music: 84
        case .pills: 0
        case .access: 64
        case .extensions:
            CGFloat(offeredExtensions.count) * (Self.permissionRowHeight + Self.permissionRowSpacing)
        case .extensionAccess:
            CGFloat(extensionPermissions.count) * (Self.permissionRowHeight + Self.permissionRowSpacing)
        case .done: 30
        }
    }

    func panelHeight(_ step: Step) -> CGFloat {
        contentTop + Self.textHeight + demoHeight(step) + Self.footerHeight
    }

    func isGranted(_ pending: ExtensionManager.PendingPermission) -> Bool {
        grantedPermissions.contains(pending.key)
    }

    var geometry: NotchShellGeometry {
        switch form {
        case .docked:
            NotchMetrics.closed(notchSize)
        case .face:
            NotchShellGeometry(width: notchSize.width + 76, height: notchSize.height + 64,
                               topCornerRadius: 14, bottomRadius: 30)
        case .panel:
            NotchShellGeometry(width: Self.panelWidth, height: panelHeight(step),
                               topCornerRadius: Self.panelTopRadius, bottomRadius: 40)
        }
    }

    var showsEyes: Bool { form != .docked }
    var showsContent: Bool { form == .panel }

    /// Where the file in the shelf demo lands, in panel coordinates.
    var shelfSlot: CGPoint {
        CGPoint(x: Self.inset + 2 * (ShelfDemo.tileSize.width + ShelfDemo.spacing), y: contentTop + Self.textHeight)
    }
}

/// Runs the onboarding: the script, the steps, the permission request, and
/// handing the notch back at the end.
@MainActor
final class OnboardingController {
    /// Called once the Full Disk Access step is behind the user, so services
    /// that read files can start without macOS asking folder by folder.
    var onSettled: (() -> Void)?

    private let model: NotchViewModel
    private let preferences: Preferences
    private var window: OnboardingWindow?
    private var state: OnboardingState?
    private var script: Task<Void, Never>?
    private var keyMonitor: Any?
    private var faceMonitors: [Any] = []

    /// Set while the permission step is in progress, so a "Quit & Reopen"
    /// from System Settings comes back to it.
    private static let resumeKey = "onboardingResumesAtPermission"

    init(model: NotchViewModel, preferences: Preferences) {
        self.model = model
        self.preferences = preferences
    }

    var isRunning: Bool { window != nil }
    private var eyes: NotchEyes { model.eyes }

    /// Starts the onboarding on first run; returns whether it did.
    @discardableResult
    func startIfNeeded() -> Bool {
        guard !preferences.hasCompletedOnboarding else { return false }
        start(at: UserDefaults.standard.bool(forKey: Self.resumeKey) ? .access : .hello)
        return isRunning
    }

    func start(at firstStep: OnboardingState.Step = .hello) {
        guard window == nil, let screen = NotchWindowController.preferredScreen() else { return }
        let state = OnboardingState(notchSize: model.notchSize)
        // Manifests only: nothing runs until the user adds it.
        model.extensions.discover()
        state.offeredExtensions = model.extensions.offerable
        state.enabledExtensions = Set(state.offeredExtensions.map(\.id).filter(model.extensions.isEnabled))
        state.chosenExtensions = state.enabledExtensions
        if !state.offeredExtensions.isEmpty, let done = state.steps.firstIndex(of: .done) {
            state.steps.insert(.extensions, at: done)
        }
        let window = OnboardingWindow(screen: screen)
        let actions = OnboardingView.Actions(
            primary: { [weak self] in self?.primaryAction() },
            secondary: { [weak self] in self?.secondaryAction() },
            poke: { [weak self] in self?.poke() }
        )
        let host = NSHostingView(rootView: OnboardingView(state: state, eyes: model.eyes, actions: actions))
        host.frame = NSRect(origin: .zero, size: screen.frame.size)
        window.contentView = host
        self.state = state
        self.window = window

        model.setPresentingOnboarding(true)
        eyes.focus = nil
        eyes.expression = .asleep
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return handled ? nil : event
        }
        run { try await $0.arrive(thenOpen: firstStep) }
    }

    // MARK: Script

    private func run(_ body: @escaping @MainActor (OnboardingController) async throws -> Void) {
        script?.cancel()
        script = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await body(self)
        }
    }

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }

    private func set(_ body: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, body)
    }

    /// The screen dims; the notch comes from in front of the screen, arcs in
    /// glowing, snaps into place; grows a face and wakes; opens the tutorial.
    private func arrive(thenOpen firstStep: OnboardingState.Step) async throws {
        guard let state, let size = window?.frame.size else { return }
        withAnimation(.easeOut(duration: 0.8)) { state.dim = 1 }
        try await pause(0.45)

        if Motion.reduceMotion {
            withAnimation(.easeOut(duration: 0.5)) { state.presence = 1 }
            try await pause(0.6)
        } else {
            set {
                state.flightX = size.width * 0.24
                state.flightY = size.height * 0.62
                state.depth = 1
                state.glow = 1
            }
            // Independent springs per axis: the vertical one is stiffer, so
            // the path arcs instead of running straight at the notch.
            withAnimation(.easeOut(duration: 0.35)) { state.presence = 1 }
            withAnimation(.spring(response: 1.1, dampingFraction: 0.88)) { state.flightX = 0 }
            withAnimation(.spring(response: 0.9, dampingFraction: 0.8)) { state.flightY = 0 }
            withAnimation(.spring(response: 0.95, dampingFraction: 1)) { state.depth = 0 }
            try await pause(0.82)
            snap()
            try await pause(0.75)
        }

        withAnimation(.spring(response: 0.55, dampingFraction: 0.8)) { state.form = .face }
        try await pause(0.55)
        eyes.expression = .neutral
        try await pause(0.9)
        eyes.flash(.happy, for: 0.9)
        try await pause(0.5)
        open(firstStep)
    }

    /// The notch locks in: a squash along the impact, a rebound, a ring of
    /// light, and the glow drains away.
    private func snap() {
        guard let state else { return }
        Haptics.tap()
        withAnimation(Motion.impact) { state.impact = NotchDeformation(width: 18, height: -5) }
        withAnimation(.easeOut(duration: 0.9)) { state.ring = 1 }
        withAnimation(.easeOut(duration: 1.1)) { state.glow = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
            withAnimation(Motion.rebound) { state.impact = .zero }
        }
    }

    /// A smaller squash for things arriving in the panel.
    private func absorb(_ strength: CGFloat = 1) {
        guard let state, !Motion.reduceMotion else { return }
        withAnimation(Motion.impact) { state.impact = NotchDeformation(width: 10 * strength, height: -4 * strength) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(Motion.rebound) { state.impact = .zero }
        }
    }

    private func poke() {
        eyes.flash(.happy, for: 0.8)
        absorb(0.6)
        Haptics.tap()
    }

    // MARK: Steps

    private func open(_ step: OnboardingState.Step) {
        guard let state else { return }
        if step == .access { prepareAccess() }
        withAnimation(.spring(response: 0.55, dampingFraction: 0.84)) {
            state.form = .panel
            state.step = step
        }
        play(step)
    }

    private func go(to step: OnboardingState.Step) {
        guard let state, state.step != step else { return }
        if step == .access { prepareAccess() }
        if step == .shelf {
            set {
                state.fileX = state.shelfSlot.x + 150
                state.fileY = state.panelHeight(.shelf) + 70
                state.fileTilt = 14
            }
        }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) {
            state.step = step
            state.demo = 0
        }
        play(step)
    }

    /// Each step's small demonstration, and where the eyes look.
    private func play(_ step: OnboardingState.Step) {
        guard let state else { return }
        eyes.focus = nil
        switch step {
        case .hello:
            eyes.expression = .happy
            run { controller in
                try await controller.pause(1.1)
                controller.eyes.expression = .neutral
            }
        case .shelf:
            eyes.expression = .curious
            run { controller in
                controller.eyes.focus = controller.screenPoint(CGPoint(x: state.fileX, y: state.fileY))
                try await controller.pause(0.45)
                let slot = state.shelfSlot
                controller.eyes.focus = controller.screenPoint(CGPoint(x: slot.x + 32, y: slot.y + 30))
                withAnimation(.spring(response: 0.62, dampingFraction: 0.86)) { state.fileX = slot.x }
                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                    state.fileY = slot.y
                    state.fileTilt = 0
                }
                try await controller.pause(0.42)
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { state.demo = 1 }
                controller.absorb()
                Haptics.tap()
                controller.eyes.flash(.happy, for: 1.0)
                try await controller.pause(1.0)
                controller.eyes.focus = nil
            }
        case .music:
            eyes.expression = .attentive
            run { controller in
                try await controller.pause(0.3)
                withAnimation(.spring(response: 0.6, dampingFraction: 0.86)) { state.demo = 1 }
                controller.eyes.expression = .excited
                try await controller.pause(1.2)
                controller.eyes.expression = .neutral
            }
        case .pills:
            eyes.expression = .attentive
            run { controller in
                try await controller.pause(0.35)
                withAnimation(.spring(response: 0.45, dampingFraction: 0.76)) { state.demo = 1 }
                let below = state.panelHeight(.pills) + 30
                controller.eyes.focus = controller.screenPoint(CGPoint(x: state.panelOuterWidth / 2, y: below))
                try await controller.pause(1.0)
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { state.demo = 2 }
                Haptics.tap()
                try await controller.pause(1.2)
                controller.eyes.focus = nil
            }
        case .access:
            eyes.expression = state.access == .granted ? .happy : .attentive
        case .extensions:
            eyes.expression = .curious
        case .extensionAccess:
            eyes.expression = state.extensionAccess == .granted ? .happy : .attentive
        case .done:
            eyes.expression = .happy
            settle()
        }
    }

    /// Converts a point in the hero panel's coordinates to the screen.
    private func screenPoint(_ point: CGPoint) -> CGPoint {
        guard let frame = window?.frame, let state else { return .zero }
        return CGPoint(x: frame.midX - state.panelOuterWidth / 2 + point.x, y: frame.maxY - point.y)
    }

    private func primaryAction() {
        guard let state, state.form == .panel else { return }
        switch state.step {
        case .access:
            switch state.access {
            case .asking: requestAccess()
            case .guiding: break
            case .granted: leaveAccess()
            }
        case .extensions:
            addChosenExtensions()
        case .extensionAccess:
            switch state.extensionAccess {
            case .asking: requestExtensionPermissions()
            case .guiding: break
            case .granted: go(to: .done)
            }
        case .done:
            finish()
        default:
            if let index = state.steps.firstIndex(of: state.step), index + 1 < state.steps.count {
                go(to: state.steps[index + 1])
            }
        }
    }

    private func secondaryAction() {
        guard let state, state.form == .panel else { return }
        switch state.step {
        case .access: leaveAccess()
        case .extensions: break
        case .extensionAccess: go(to: .done)
        case .done: break
        default: go(to: .access)
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let state, event.window === window else { return false }
        switch event.keyCode {
        case 36, 76: // Return, Enter
            primaryAction()
            return true
        case 53: // Escape
            if state.step.rawValue < OnboardingState.Step.access.rawValue { secondaryAction() }
            return true
        default:
            return false
        }
    }

    // MARK: Full Disk Access

    private func prepareAccess() {
        guard let state else { return }
        UserDefaults.standard.set(true, forKey: Self.resumeKey)
        PermissionCenter.shared.refresh()
        state.access = PermissionCenter.shared.isGranted(state.permission) ? .granted : .asking
    }

    /// The panel folds back into a face and the screen clears for System
    /// Settings; the guide card flies out of the notch, and the eyes watch it.
    private func requestAccess() {
        guard let state, let window else { return }
        script?.cancel()
        withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) {
            state.access = .guiding
            state.form = .face
            state.dim = 0
        }
        window.ignoresMouseEvents = true
        watchFace()
        PermissionCenter.shared.request(state.permission, from: faceFrame) { [weak self] granted in
            self?.accessRequestEnded(granted: granted)
        }
    }

    /// The hero's face on screen, while it waits for System Settings.
    private var faceFrame: NSRect {
        guard let state, let window else { return .zero }
        let face = state.geometry
        return NSRect(x: window.frame.midX - face.outerWidth / 2, y: window.frame.maxY - face.height,
                      width: face.outerWidth, height: face.height)
    }

    /// Clicks go through to System Settings while it's up, except on the face:
    /// clicking it calls the request off and brings back "Not Now", so changing
    /// your mind never leaves the tour stuck waiting for a grant.
    private func watchFace() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { _ = self?.handleFaceEvent(event) }
        }) {
            faceMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleFaceEvent(event) ?? false }
            return handled ? nil : event
        }) {
            faceMonitors.append(local)
        }
    }

    private func unwatchFace() {
        faceMonitors.forEach(NSEvent.removeMonitor)
        faceMonitors = []
    }

    private func handleFaceEvent(_ event: NSEvent) -> Bool {
        guard let state, let window, state.access == .guiding else { return false }
        let onFace = faceFrame.contains(NSEvent.mouseLocation)
        window.ignoresMouseEvents = !onFace
        guard onFace, event.type == .leftMouseDown else { return false }
        PermissionCenter.shared.cancel()
        return true
    }

    private func accessRequestEnded(granted: Bool) {
        unwatchFace()
        guard let state, let window else { return }
        window.ignoresMouseEvents = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        eyes.focus = nil
        if granted {
            // The guide flew back into the notch.
            absorb(1.3)
            Haptics.tap()
            eyes.expression = .happy
        } else {
            eyes.expression = .neutral
        }
        withAnimation(.spring(response: 0.55, dampingFraction: 0.84)) {
            state.access = granted ? .granted : .asking
            state.form = .panel
            state.dim = 1
        }
        guard granted else { return }
        run { controller in
            try await controller.pause(1.5)
            controller.leaveAccess()
        }
    }

    /// Full Disk Access is settled, so services and extensions can start; offer extensions next.
    private func leaveAccess() {
        guard let state else { return }
        settle()
        if state.steps.contains(.extensions) { go(to: .extensions) } else { leaveExtensions() }
    }

    /// Switches on exactly the extensions the user picked.
    private func addChosenExtensions() {
        guard let state else { return }
        for manifest in state.offeredExtensions {
            let chosen = state.chosenExtensions.contains(manifest.id)
            if model.extensions.isEnabled(manifest.id) != chosen { model.extensions.setEnabled(chosen, for: manifest.id) }
        }
        if !state.newlyChosenExtensions.isEmpty {
            absorb(0.8)
            Haptics.tap()
        }
        leaveExtensions()
    }

    /// Ask for what the added extensions need, if anything.
    private func leaveExtensions() {
        guard let state else { return }
        let pending = model.extensions.pendingPermissions
        guard !pending.isEmpty else { return go(to: .done) }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) {
            state.extensionPermissions = pending
            state.grantedPermissions = []
            state.extensionAccess = .asking
            if !state.steps.contains(.extensionAccess), let done = state.steps.firstIndex(of: .done) {
                state.steps.insert(.extensionAccess, at: done)
            }
        }
        go(to: .extensionAccess)
    }

    // MARK: Extension permissions

    /// Like Full Disk Access: the panel folds into a face and steps back so macOS's own prompt is in
    /// front, and the eyes watch it. Each permission is asked in turn.
    private func requestExtensionPermissions() {
        guard let state, let window else { return }
        script?.cancel()
        withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) {
            state.extensionAccess = .guiding
            state.form = .face
            state.dim = 0
        }
        window.ignoresMouseEvents = true
        let level = window.level
        // Keychain prompts come from another process; make sure they aren't under the tour.
        window.level = .normal
        eyes.expression = .attentive
        eyes.focus = CGPoint(x: window.frame.midX, y: window.frame.midY)
        run { controller in
            for pending in state.extensionPermissions where !state.isGranted(pending) {
                if await pending.requester.requestPermission(pending.permission.id) {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        _ = state.grantedPermissions.insert(pending.key)
                    }
                }
            }
            controller.extensionRequestsEnded(restoring: level)
        }
    }

    private func extensionRequestsEnded(restoring level: NSWindow.Level) {
        guard let state, let window else { return }
        window.level = level
        window.ignoresMouseEvents = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        eyes.focus = nil
        let allGranted = state.extensionPermissions.allSatisfy(state.isGranted)
        if allGranted {
            absorb(1.3)
            Haptics.tap()
            eyes.expression = .happy
        } else {
            eyes.expression = .neutral
        }
        withAnimation(.spring(response: 0.55, dampingFraction: 0.84)) {
            state.extensionAccess = allGranted ? .granted : .asking
            state.form = .panel
            state.dim = 1
        }
        guard allGranted else { return }
        run { controller in
            try await controller.pause(1.5)
            controller.go(to: .done)
        }
    }

    private func settle() {
        UserDefaults.standard.removeObject(forKey: Self.resumeKey)
        onSettled?()
        onSettled = nil
    }

    // MARK: Finish

    /// Everything folds back the way it came: the panel into the face, the
    /// face into the notch, the dim away. The hero then sits exactly on the
    /// real notch, which takes over.
    private func finish() {
        guard let state else { return }
        if state.launchAtLogin && !preferences.launchesAtLogin { preferences.setLaunchesAtLogin(true) }
        preferences.hasCompletedOnboarding = true
        settle()
        window?.ignoresMouseEvents = true
        run { controller in
            withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) { state.form = .face }
            controller.eyes.flash(.happy, for: 0.9)
            try await controller.pause(0.9)
            controller.eyes.expression = .asleep
            try await controller.pause(0.2)
            withAnimation(.spring(response: 0.45, dampingFraction: 1)) { state.form = .docked }
            withAnimation(.easeInOut(duration: 0.7)) { state.dim = 0 }
            try await controller.pause(0.75)
            controller.model.setPresentingOnboarding(false)
            controller.eyes.expression = .neutral
            try await controller.pause(0.05)
            controller.tearDown()
        }
    }

    private func tearDown() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        unwatchFace()
        window?.orderOut(nil)
        window = nil
        state = nil
    }
}

/// Borderless and screen-sized, above the menu bar so the dim covers it.
/// The real notch window sits above this one; while the onboarding runs it
/// hides its own shell and the hero takes its place.
final class OnboardingWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
