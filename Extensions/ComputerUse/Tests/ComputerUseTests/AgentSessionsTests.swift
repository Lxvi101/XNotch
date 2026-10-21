import XCTest
@testable import ComputerUse

@MainActor
final class AgentSessionsTests: XCTestCase {
    func testStartActionEnd() {
        let sessions = AgentSessions()
        let start = Date()
        sessions.handle(AgentSessions.startName, ["session": "a", "pid": 42, "client": "claude", "app": "Safari"], now: start)
        XCTAssertEqual(sessions.current?.clientName, "Claude Code")
        XCTAssertNil(sessions.current?.tool)

        sessions.handle(AgentSessions.actionName,
                        ["session": "a", "pid": 42, "tool": "click", "app": "Safari", "x": 100.0, "y": 200.0],
                        now: start.addingTimeInterval(1))
        XCTAssertEqual(sessions.current?.cursor, CGPoint(x: 100, y: 200))

        // Reading a window leaves the cursor where it was.
        sessions.handle(AgentSessions.actionName,
                        ["session": "a", "pid": 42, "tool": "get_app_state", "windowX": 500.0, "windowY": 400.0],
                        now: start.addingTimeInterval(1.5))
        XCTAssertEqual(sessions.current?.cursor, CGPoint(x: 100, y: 200))
        XCTAssertEqual(sessions.current?.window, CGPoint(x: 500, y: 400))
        sessions.handle(AgentSessions.actionName,
                        ["session": "a", "pid": 42, "tool": "click", "x": 100.0, "y": 200.0],
                        now: start.addingTimeInterval(2))
        XCTAssertEqual(sessions.current?.actions, 3)
        XCTAssertEqual(sessions.current.map(ComputerUseExtension.mood(for:)), .attentive)

        sessions.handle(AgentSessions.endName, ["session": "a", "pid": 42, "reason": "idle"])
        XCTAssertNil(sessions.current)
        XCTAssertTrue(sessions.lastEndWasClean)
    }

    func testCurrentIsTheMostRecentlyActive() {
        let sessions = AgentSessions()
        let start = Date()
        sessions.handle(AgentSessions.startName, ["session": "a", "pid": 1], now: start)
        sessions.handle(AgentSessions.startName, ["session": "b", "pid": 2], now: start.addingTimeInterval(1))
        XCTAssertEqual(sessions.current?.id, "b")
        sessions.handle(AgentSessions.actionName, ["session": "a", "pid": 1, "tool": "get_app_state"],
                        now: start.addingTimeInterval(2))
        XCTAssertEqual(sessions.current?.id, "a")
        XCTAssertEqual(sessions.current.map(ComputerUseExtension.mood(for:)), .curious)
    }

    func testIgnoresMalformedEvents() {
        let sessions = AgentSessions()
        sessions.handle(AgentSessions.startName, ["pid": 1])
        sessions.handle(AgentSessions.actionName, ["session": "a"])
        XCTAssertTrue(sessions.sessions.isEmpty)
    }

    func testPruneDropsDeadAndStaleServers() {
        let sessions = AgentSessions()
        let start = Date()
        sessions.handle(AgentSessions.startName, ["session": "dead", "pid": 1], now: start)
        sessions.handle(AgentSessions.startName, ["session": "stale", "pid": 2], now: start)
        sessions.handle(AgentSessions.startName, ["session": "live", "pid": 3],
                        now: start.addingTimeInterval(AgentSessions.staleAfter))
        sessions.prune(now: start.addingTimeInterval(AgentSessions.staleAfter + 1)) { $0 != 1 }
        XCTAssertEqual(Set(sessions.sessions.keys), ["live"])
        XCTAssertFalse(sessions.lastEndWasClean)
    }
}

final class GazePlannerTests: XCTestCase {
    private let cursor = CGPoint(x: 400, y: 300)

    func testRestsNearTheCursor() {
        var planner = GazePlanner()
        for draw in stride(from: 0.0, to: 1.0, by: 0.1) {
            let look = planner.next(cursor: cursor, window: nil, roll: 0.5) { draw }
            let point = try! XCTUnwrap(look.point)
            XCTAssertLessThanOrEqual(hypot(point.x - cursor.x, point.y - cursor.y), GazePlanner.nearRadius + 0.001)
            XCTAssertTrue((0.7...1.8).contains(look.hold))
        }
    }

    func testGlancesAtTheWindowAndAway() {
        var planner = GazePlanner()
        let window = CGPoint(x: 1000, y: 700)
        let atWindow = planner.next(cursor: cursor, window: window, roll: 0.05) { 0 }
        XCTAssertEqual(atWindow.point, window)
        let away = planner.next(cursor: cursor, window: window, roll: 0.2) { 0 }
        XCTAssertEqual(away.point.map { hypot($0.x - cursor.x, $0.y - cursor.y) } ?? 0, 260, accuracy: 0.001)
    }

    func testFollowsThePointerWithoutAnywhereToLook() {
        var planner = GazePlanner()
        XCTAssertNil(planner.next(cursor: nil, window: nil).point)
        XCTAssertNil(planner.look)
    }

    func testNoticesOnlyBigJumps() {
        var planner = GazePlanner()
        XCTAssertTrue(planner.notices(cursor))
        _ = planner.next(cursor: cursor, window: nil, roll: 0.5) { 0 }
        XCTAssertFalse(planner.notices(CGPoint(x: 450, y: 320)))
        XCTAssertTrue(planner.notices(CGPoint(x: 900, y: 300)))
        XCTAssertFalse(planner.notices(nil))
    }
}
