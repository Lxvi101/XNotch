import AppKit
import Combine
import SwiftUI
import XNotchKit

@objc(ComputerUsePrincipal)
public final class ComputerUsePrincipal: NSObject, XNotchExtensionPrincipal {
    public override init() { super.init() }

    @MainActor public func makeExtension() -> AnyObject { ComputerUseExtension() }
}

/// While an agent drives the Mac through Wink's `wink-cua` server, the notch's
/// eyes open and follow its cursor; when the agent is done they squint
/// happily and close.
@MainActor
final class ComputerUseExtension: XNotchExtension, SettingsPaneProviding, PermissionRequesting {
    static let id: ExtensionID = "computer-use"

    private var host: ExtensionHost?
    private let sessions = AgentSessions()
    private var preferences: ComputerUsePreferences?
    private let installer = WinkInstaller(bundled: Bundle(for: ComputerUseExtension.self)
        .url(forResource: "Wink", withExtension: "app"))
    /// When an agent last asked for each permission, so a busy agent doesn't keep reopening the guide.
    private var lastPermissionAsk: [GuidedPermission: Date] = [:]
    private var sink: DistributedSink?
    private var pruneTimer: Timer?
    private var isWatching = false
    private var gaze = GazePlanner()
    /// The next time the eyes choose where to look.
    private var gazeWork: DispatchWorkItem?
    private var observers: Set<AnyCancellable> = []

    func activate(host: ExtensionHost) throws {
        self.host = host
        let preferences = ComputerUsePreferences(defaults: host.storage.defaults)
        self.preferences = preferences
        // Also brings an installed server up to date with the one this XNotch ships.
        Task { await installer.refresh() }
        sink = DistributedSink(names: [AgentSessions.startName, AgentSessions.actionName, AgentSessions.endName,
                                       Self.permissionNeededName]) { [weak self] name, info in
            self?.host?.log.debug("\(name.rawValue, privacy: .public) \(info.count) keys")
            if name == Self.permissionNeededName {
                self?.agentNeeds(info["permission"] as? String)
            } else {
                self?.sessions.handle(name, info)
            }
        }
        sessions.$sessions.dropFirst().sink { [weak self] _ in
            // @Published fires before the change lands.
            DispatchQueue.main.async { self?.update() }
        }.store(in: &observers)
        preferences.$followsCursor.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.update() }
        }.store(in: &observers)
    }

    func deactivate() {
        observers.removeAll()
        sink = nil
        pruneTimer?.invalidate()
        pruneTimer = nil
        gazeWork?.cancel()
        gazeWork = nil
        if isWatching { (host?.notch as? NotchEyesWatching)?.stopWatching(farewell: nil) }
        isWatching = false
        preferences = nil
        host = nil
    }

    func makeSettingsPane() -> AnyView {
        guard let preferences else { return AnyView(EmptyView()) }
        return AnyView(ComputerUseSettingsPane(sessions: sessions, preferences: preferences, installer: installer,
                                               guide: host as? PermissionGuiding))
    }

    // MARK: Permissions

    static let permissionNeededName = Notification.Name("dev.wink.cua.permission.needed")

    var pendingPermissions: [ExtensionPermission] {
        installer.missingPermissions.map(Self.describe)
    }

    func requestPermission(_ id: String) async -> Bool {
        guard let permission = GuidedPermission(rawValue: id), let guide = host as? PermissionGuiding else { return false }
        return await installer.request(permission, guide: guide)
    }

    static func describe(_ permission: GuidedPermission) -> ExtensionPermission {
        switch permission {
        case .accessibility:
            ExtensionPermission(id: permission.rawValue, title: "Wink: Accessibility", detail: "System Settings",
                                reason: "Lets AI agents read and use other apps' windows through Wink, without taking over your mouse or keyboard.",
                                symbol: "accessibility", tint: "#3A82F7")
        case .screenRecording:
            ExtensionPermission(id: permission.rawValue, title: "Wink: Screen Recording", detail: "System Settings",
                                reason: "Lets agents see the windows they work in, so they can check what they did.",
                                symbol: "rectangle.dashed.badge.record", tint: "#FF453A")
        }
    }

    /// An agent hit a permission Wink doesn't have: show the guide, at most every few minutes.
    private func agentNeeds(_ name: String?) {
        guard let name, let permission = GuidedPermission(rawValue: name), let guide = host as? PermissionGuiding,
              installer.isInstalled, installer.guiding == nil else { return }
        if let last = lastPermissionAsk[permission], Date().timeIntervalSince(last) < 5 * 60 { return }
        lastPermissionAsk[permission] = Date()
        host?.log.info("An agent needs \(name, privacy: .public)")
        Task {
            await installer.refreshGrants()
            guard installer.missingPermissions.contains(permission) else { return }
            _ = await installer.request(permission, guide: guide)
        }
    }

    private func update() {
        guard let eyes = host?.notch as? NotchEyesWatching else {
            host?.log.error("This XNotch can't show the eyes for extensions (needs API 1.7.0)")
            return
        }
        guard let session = sessions.current else {
            pruneTimer?.invalidate()
            pruneTimer = nil
            gazeWork?.cancel()
            gazeWork = nil
            if isWatching {
                isWatching = false
                eyes.stopWatching(farewell: sessions.lastEndWasClean ? .happy : .sleepy)
            }
            return
        }
        if pruneTimer == nil {
            pruneTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sessions.prune() }
            }
        }
        let follows = preferences?.followsCursor != false
        if !isWatching {
            host?.log.info("Agent session started: \(session.clientName ?? "unknown", privacy: .public)")
            isWatching = true
            gaze = GazePlanner()
            eyes.watch(nil, mood: Self.mood(for: session))
            if follows { scheduleGaze(after: 0.3) }
            return
        }
        // The mood changes at once; where the eyes look keeps to its own rhythm.
        eyes.watch(follows ? gaze.look : nil, mood: Self.mood(for: session))
        if !follows {
            gazeWork?.cancel()
            gazeWork = nil
        } else if gazeWork == nil || gaze.notices(session.cursor) {
            // The cursor jumped away: notice it a beat later and catch up.
            scheduleGaze(after: .random(in: GazePlanner.reaction))
        }
    }

    private func scheduleGaze(after delay: TimeInterval) {
        gazeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.lookAround() }
        gazeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Chooses the next spot near the agent's cursor and holds it for a moment.
    private func lookAround() {
        gazeWork = nil
        guard let session = sessions.current, preferences?.followsCursor != false,
              let eyes = host?.notch as? NotchEyesWatching else { return }
        let look = gaze.next(cursor: session.cursor, window: session.window)
        eyes.watch(look.point, mood: Self.mood(for: session))
        scheduleGaze(after: look.hold)
    }

    /// Excited as an agent arrives, curious while it reads a window, attentive while it acts.
    static func mood(for session: AgentSession) -> NotchEyesMood {
        switch session.tool {
        case nil: .excited
        case "get_app_state": .curious
        default: .attentive
        }
    }
}

final class ComputerUsePreferences: ObservableObject {
    private let defaults: UserDefaults

    /// Off: the eyes open while an agent works but keep watching the user's pointer.
    @Published var followsCursor: Bool {
        didSet { defaults.set(followsCursor, forKey: "followsCursor") }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        followsCursor = defaults.object(forKey: "followsCursor") as? Bool ?? true
    }
}

/// Observes distributed notifications even while XNotch isn't the active app,
/// which it never is.
private final class DistributedSink: NSObject {
    private let handler: @MainActor (Notification.Name, [AnyHashable: Any]) -> Void

    init(names: [Notification.Name], handler: @escaping @MainActor (Notification.Name, [AnyHashable: Any]) -> Void) {
        self.handler = handler
        super.init()
        let center = DistributedNotificationCenter.default()
        for name in names {
            center.addObserver(self, selector: #selector(receive(_:)), name: name, object: nil,
                               suspensionBehavior: .deliverImmediately)
        }
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func receive(_ note: Notification) {
        let name = note.name
        let info = note.userInfo ?? [:]
        let handler = handler
        DispatchQueue.main.async { MainActor.assumeIsolated { handler(name, info) } }
    }
}
