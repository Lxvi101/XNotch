import AppKit
import Darwin

/// One agent driving the Mac through a `wink-cua` server.
struct AgentSession: Identifiable, Equatable {
    let id: String
    let pid: pid_t
    /// The process that launched the server: "claude", "codex", …
    var client: String?
    var app: String?
    var tool: String?
    /// Where the agent's cursor is, in AppKit screen coordinates; nil until it first moves.
    var cursor: CGPoint?
    /// The middle of the window the agent last read.
    var window: CGPoint?
    var actions = 0
    let started: Date
    var lastEvent: Date

    /// "Claude Code", "Codex", or nil when the launcher isn't one we know.
    var clientName: String? {
        switch client?.lowercased() {
        case "claude", "claude-code": "Claude Code"
        case "codex": "Codex"
        case "cursor", "cursor-agent": "Cursor"
        case let name?: name.isEmpty ? nil : name
        case nil: nil
        }
    }
}

/// Follows the sessions `wink-cua` announces with distributed notifications:
/// `dev.wink.cua.session.start`, `.action` and `.end`.
@MainActor
final class AgentSessions: ObservableObject {
    static let startName = Notification.Name("dev.wink.cua.session.start")
    static let actionName = Notification.Name("dev.wink.cua.session.action")
    static let endName = Notification.Name("dev.wink.cua.session.end")

    /// How long a session may go without a word before it's taken for gone.
    /// The server ends idle sessions after 20 s itself; this covers one that crashed.
    static let staleAfter: TimeInterval = 5 * 60

    @Published private(set) var sessions: [String: AgentSession] = [:]
    /// A session ended on its own (idle or exit) rather than vanishing.
    private(set) var lastEndWasClean = true

    /// The session that acted last: the one worth watching.
    var current: AgentSession? { sessions.values.max { $0.lastEvent < $1.lastEvent } }

    func handle(_ name: Notification.Name, _ info: [AnyHashable: Any], now: Date = Date()) {
        guard let id = info["session"] as? String, let pid = (info["pid"] as? NSNumber)?.int32Value else { return }
        switch name {
        case Self.startName:
            var session = sessions[id] ?? AgentSession(id: id, pid: pid, started: now, lastEvent: now)
            session.client = info["client"] as? String ?? session.client
            session.app = info["app"] as? String ?? session.app
            session.lastEvent = now
            sessions[id] = session
        case Self.actionName:
            var session = sessions[id] ?? AgentSession(id: id, pid: pid, started: now, lastEvent: now)
            session.app = info["app"] as? String ?? session.app
            session.tool = info["tool"] as? String
            if let point = Self.point(info, "x", "y") { session.cursor = point }
            if let point = Self.point(info, "windowX", "windowY") { session.window = point }
            session.actions += 1
            session.lastEvent = now
            sessions[id] = session
        case Self.endName:
            guard sessions.removeValue(forKey: id) != nil else { return }
            lastEndWasClean = true
        default:
            break
        }
    }

    /// Drops sessions whose server died without saying goodbye.
    func prune(now: Date = Date(), isAlive: (pid_t) -> Bool = AgentSessions.isAlive) {
        let gone = sessions.values.filter { !isAlive($0.pid) || now.timeIntervalSince($0.lastEvent) > Self.staleAfter }
        guard !gone.isEmpty else { return }
        for session in gone { sessions[session.id] = nil }
        lastEndWasClean = false
    }

    private static func point(_ info: [AnyHashable: Any], _ x: String, _ y: String) -> CGPoint? {
        guard let x = (info[x] as? NSNumber)?.doubleValue, let y = (info[y] as? NSNumber)?.doubleValue else { return nil }
        return CGPoint(x: x, y: y)
    }

    nonisolated static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
