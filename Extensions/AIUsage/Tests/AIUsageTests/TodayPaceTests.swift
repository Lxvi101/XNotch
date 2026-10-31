import XCTest
@testable import AIUsage

final class TodayPaceTests: XCTestCase {
    private let day: TimeInterval = 24 * 3600
    private let resetsAt = referenceDate.addingTimeInterval(7 * 24 * 3600)

    private func weekly(used: Double? = 20, seconds: TimeInterval? = 7 * 24 * 3600) -> QuotaWindow {
        QuotaWindow(id: "claude.weekly", label: "Weekly", percentUsed: used, resetsAt: resetsAt, windowSeconds: seconds)
    }

    /// The moment `elapsed` seconds into the weekly window.
    private func pace(_ window: QuotaWindow? = nil, at elapsed: TimeInterval) -> TodayPace? {
        TodayPace(window: window ?? weekly(), now: resetsAt.addingTimeInterval(elapsed - 7 * day))
    }

    func testEachDayAddsASeventhOfTheWeek() throws {
        for number in 1...7 {
            let pace = try XCTUnwrap(pace(at: Double(number - 1) * day + 3600))
            XCTAssertEqual(pace.day, number)
            XCTAssertEqual(pace.allowance, 100 / 7 * Double(number), accuracy: 0.0001)
            XCTAssertEqual(pace.dayEndsAt, resetsAt.addingTimeInterval(Double(number - 7) * day))
        }
    }

    func testDaysTurnOverAtTheResetTimeNotAtMidnight() {
        XCTAssertEqual(pace(at: 0)?.day, 1)
        XCTAssertEqual(pace(at: day - 1)?.day, 1)
        XCTAssertEqual(pace(at: day)?.day, 2)
        XCTAssertEqual(pace(at: 7 * day - 1)?.day, 7)
    }

    func testLeftTodayIsWhatTheAllowanceStillCovers() throws {
        // The live shape: 56% used on day 6 leaves 29.7% of the week for today.
        let under = try XCTUnwrap(pace(weekly(used: 56), at: 5.5 * day))
        XCTAssertEqual(under.left, 500 / 7 + 100 / 7 - 56, accuracy: 0.0001)
        XCTAssertEqual(under.over, 0)

        let over = try XCTUnwrap(pace(weekly(used: 30), at: 12 * 3600))
        XCTAssertEqual(over.left, 0)
        XCTAssertEqual(over.over, 30 - 100 / 7, accuracy: 0.0001)
    }

    func testMarkerFollowsTheBarsDirection() throws {
        let pace = try XCTUnwrap(pace(at: 2.5 * day))
        XCTAssertEqual(pace.marker(showsRemaining: false), 3 / 7, accuracy: 0.0001)
        XCTAssertEqual(pace.marker(showsRemaining: true), 4 / 7, accuracy: 0.0001)
    }

    func testOnlyAKnownRunningWeeklyWindowHasAPace() {
        XCTAssertNil(pace(weekly(used: nil), at: day), "Unknown usage stays unknown")
        XCTAssertNil(pace(weekly(seconds: 5 * 3600), at: day), "A session isn't a week")
        XCTAssertNil(pace(weekly(seconds: nil), at: day))
        XCTAssertNil(pace(at: 7 * day), "The window has already reset")

        var unreset = weekly()
        unreset.resetsAt = nil
        XCTAssertNil(pace(unreset, at: day))
    }

    func testSnapshotUsesItsFirstWeeklyCoreWindow() {
        var snapshot = makeSnapshot(.claude)
        let session = QuotaWindow(id: "claude.session", label: "Session", percentUsed: 10,
                                  resetsAt: referenceDate.addingTimeInterval(3600), windowSeconds: 5 * 3600)
        let scoped = QuotaWindow(id: "claude.opus", label: "Opus weekly", percentUsed: 10, resetsAt: resetsAt,
                                 windowSeconds: 7 * 24 * 3600, isCore: false)
        snapshot.windows = [session] + snapshot.windows + [scoped]
        XCTAssertEqual(snapshot.todayPace(at: referenceDate)?.windowID, "claude.weekly")

        snapshot.windows = [session, scoped]
        XCTAssertNil(snapshot.todayPace(at: referenceDate))
    }
}
