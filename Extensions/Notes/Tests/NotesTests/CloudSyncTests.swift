import XCTest
@testable import Notes

/// The mirror against a plain folder standing in for iCloud Drive.
@MainActor
final class CloudSyncTests: XCTestCase {
    private var root: URL!
    private var cloud: URL!
    private var bucket: URL!
    private var events: [CloudEvent] = []
    private var sync: CloudSync!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudSyncTests-\(UUID().uuidString)")
        cloud = root.appendingPathComponent("iCloud/XNotch Notes")
        bucket = root.appendingPathComponent("bucket")
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bucket, withIntermediateDirectories: true)
        sync = CloudSync(root: cloud, stateURL: root.appendingPathComponent("state.json")) { [weak self] event in
            self?.events.append(event)
        }
    }

    override func tearDown() async throws {
        sync.stop()
        try? FileManager.default.removeItem(at: root)
    }

    /// Runs the main queue until an event matching `match` arrives.
    private func wait(for what: String, timeout: TimeInterval = 5, _ match: (CloudEvent) -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if events.contains(where: match) { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail("No \(what) event; got \(events)")
    }

    private func pushed(_ path: String) -> (CloudEvent) -> Bool {
        { if case .pushed(_, let p, _) = $0 { return p == path }; return false }
    }

    func testPushWritesReadableFilesRenamesWithTheTitleAndMirrorsTheBucket() throws {
        let id = UUID()
        try "x".write(to: bucket.appendingPathComponent("brief.txt"), atomically: true, encoding: .utf8)
        sync.push(CloudNote(id: id, folder: "Work", title: "Plan", text: "# Plan\nbody", path: nil, bucket: bucket))
        wait(for: "first push", pushed("Work/Plan.md"))
        let file = cloud.appendingPathComponent("Work/Plan.md")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "# Plan\nbody")
        XCTAssertEqual(CloudSync.id(of: file), id.uuidString)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloud.appendingPathComponent("Work/Plan Files/brief.txt").path))

        sync.push(CloudNote(id: id, folder: "Work", title: "Launch", text: "# Launch\nbody", path: "Work/Plan.md", bucket: bucket))
        wait(for: "rename", pushed("Work/Launch.md"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloud.appendingPathComponent("Work/Launch Files/brief.txt").path))
    }

    func testEditsMadeElsewhereComeBackOnceAndOwnWritesDont() throws {
        let id = UUID()
        sync.start()
        sync.push(CloudNote(id: id, folder: "Work", title: "Plan", text: "# Plan", path: nil, bucket: bucket))
        wait(for: "push", pushed("Work/Plan.md"))
        events.removeAll()
        // Our own write never comes back as someone else's edit.
        sync.scanSoon()
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        XCTAssertFalse(events.contains { if case .changed = $0 { return true }; return false })

        let file = cloud.appendingPathComponent("Work/Plan.md")
        try "# Plan\nfrom the other Mac".write(to: file, atomically: false, encoding: .utf8)
        sync.scanSoon()
        wait(for: "remote change") {
            if case .changed(let changedID, "Work/Plan.md", "# Plan\nfrom the other Mac", _) = $0 { return changedID == id }
            return false
        }
    }

    func testARenameElsewhereKeepsTheNoteAndADeleteRemovesIt() throws {
        let id = UUID()
        sync.push(CloudNote(id: id, folder: "Work", title: "Plan", text: "# Plan", path: nil, bucket: bucket))
        wait(for: "push", pushed("Work/Plan.md"))
        try FileManager.default.createDirectory(at: cloud.appendingPathComponent("Home"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: cloud.appendingPathComponent("Work/Plan.md"),
                                         to: cloud.appendingPathComponent("Home/Plan.md"))
        sync.scanSoon()
        wait(for: "move") { if case .moved("Work/Plan.md", "Home/Plan.md") = $0 { return true }; return false }

        try FileManager.default.removeItem(at: cloud.appendingPathComponent("Home/Plan.md"))
        sync.scanSoon()
        wait(for: "removal") { if case .removed("Home/Plan.md") = $0 { return true }; return false }
    }

    private func removed(_ path: String) -> (CloudEvent) -> Bool {
        { if case .removed(let p) = $0 { return p == path }; return false }
    }

    private func changed(_ path: String) -> (CloudEvent) -> Bool {
        { if case .changed(_, let p, _, _) = $0 { return p == path }; return false }
    }

    /// Runs the main queue for a while, then checks nothing matching `match` came.
    private func expectNo(_ what: String, for seconds: TimeInterval, _ match: (CloudEvent) -> Bool) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        XCTAssertFalse(events.contains(where: match), "Unexpected \(what): \(events)")
    }

    private func pushPlan(_ text: String = "# Plan", path: String? = nil, id: UUID) {
        sync.push(CloudNote(id: id, folder: "Work", title: "Plan", text: text, path: path, bucket: bucket))
    }

    func testAFileDeletedInICloudIsNotWrittenBackByTheLaunchPushes() throws {
        let id = UUID()
        pushPlan(id: id)
        wait(for: "push", pushed("Work/Plan.md"))
        let file = cloud.appendingPathComponent("Work/Plan.md")
        try FileManager.default.removeItem(at: file)

        // As at launch: a new mirror on the same state scans, then every note is pushed.
        sync.stop()
        events.removeAll()
        sync = CloudSync(root: cloud, stateURL: root.appendingPathComponent("state.json")) { [weak self] event in
            self?.events.append(event)
        }
        sync.start()
        pushPlan(path: "Work/Plan.md", id: id)
        wait(for: "removal", timeout: 10, removed("Work/Plan.md"))
        pushPlan(path: "Work/Plan.md", id: id)
        expectNo("push", for: 1) { if case .pushed = $0 { return true }; return false }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        // Only a note with no file makes one.
        pushPlan(id: id)
        wait(for: "new file", pushed("Work/Plan.md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testADeleteNeedsTwoScansAndUnlistableFoldersAndStubsAreNotDeletions() throws {
        let id = UUID()
        pushPlan(id: id)
        wait(for: "push", pushed("Work/Plan.md"))
        let work = cloud.appendingPathComponent("Work")
        let file = work.appendingPathComponent("Plan.md")

        // A folder that can't be listed says nothing about what's in it.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: work.path)
        sync.scanSoon()
        expectNo("removal", for: 3.5, removed("Work/Plan.md"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: work.path)

        // Evicted on an older system: still there.
        let stub = work.appendingPathComponent(".Plan.md.icloud")
        try FileManager.default.moveItem(at: file, to: stub)
        sync.scanSoon()
        expectNo("removal", for: 3.5, removed("Work/Plan.md"))
        try FileManager.default.moveItem(at: stub, to: file)

        // Really gone: not on the first look, but on the next.
        try FileManager.default.removeItem(at: file)
        sync.scanSoon()
        expectNo("removal", for: 1, removed("Work/Plan.md"))
        wait(for: "removal", timeout: 8, removed("Work/Plan.md"))
    }

    func testManyNotesGoneAtOnceWaitLonger() throws {
        for index in 1...5 {
            sync.push(CloudNote(id: UUID(), folder: "Work", title: "Note \(index)", text: "# Note \(index)", path: nil, bucket: bucket))
            wait(for: "push", pushed("Work/Note \(index).md"))
        }
        try FileManager.default.removeItem(at: cloud.appendingPathComponent("Work"))
        try FileManager.default.createDirectory(at: cloud.appendingPathComponent("Work"), withIntermediateDirectories: true)
        sync.scanSoon()
        expectNo("removal", for: 5) { if case .removed = $0 { return true }; return false }
    }

    func testABucketFileThatFailedToGoUpIsNeverTrashedAndGoesUpLater() throws {
        let local = bucket.appendingPathComponent("brief.txt")
        try "x".write(to: local, atomically: true, encoding: .utf8)
        let remote = cloud.appendingPathComponent("Work/Plan Files")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: remote.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: remote.path) }
        let id = UUID()
        pushPlan(id: id)
        wait(for: "push", pushed("Work/Plan.md"))
        events.removeAll()
        pushPlan("# Plan\nmore", path: "Work/Plan.md", id: id)
        wait(for: "second push", pushed("Work/Plan.md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.path))

        // Still arriving: left alone until it's landed.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: remote.path)
        events.removeAll()
        sync.push(CloudNote(id: id, folder: "Work", title: "Plan", text: "# Plan\nmore", path: "Work/Plan.md", bucket: bucket,
                            copying: true))
        wait(for: "copying push", pushed("Work/Plan.md"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: remote.appendingPathComponent("brief.txt").path))

        events.removeAll()
        pushPlan("# Plan\nmore", path: "Work/Plan.md", id: id)
        wait(for: "third push", pushed("Work/Plan.md"))
        XCTAssertEqual(try String(contentsOf: remote.appendingPathComponent("brief.txt"), encoding: .utf8), "x")
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.path))
    }

    func testAPushHeldBackByATouchedFileGoesUpAfterTheReadAndARealChangeIsNotOverwritten() throws {
        let id = UUID()
        pushPlan(id: id)
        wait(for: "push", pushed("Work/Plan.md"))
        let file = cloud.appendingPathComponent("Work/Plan.md")

        // Touched in iCloud, same content: the held push goes up once it's read.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: file.path)
        events.removeAll()
        pushPlan("# Plan\nlocal", path: "Work/Plan.md", id: id)
        wait(for: "held push") { if case .pushed(_, "Work/Plan.md", CloudSync.hash("# Plan\nlocal")) = $0 { return true }; return false }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "# Plan\nlocal")

        // Changed in iCloud: the library hears of it, and it isn't written over.
        try "# Plan\nremote".write(to: file, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: file.path)
        events.removeAll()
        pushPlan("# Plan\nlocal again", path: "Work/Plan.md", id: id)
        wait(for: "remote change", changed("Work/Plan.md"))
        expectNo("push", for: 1) { if case .pushed = $0 { return true }; return false }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "# Plan\nremote")
    }

    func testAReadFinishingAfterADeleteHereIsDropped() throws {
        let id = UUID()
        pushPlan(id: id)
        wait(for: "push", pushed("Work/Plan.md"))
        let file = cloud.appendingPathComponent("Work/Plan.md")
        try "# Plan\nfrom the other Mac".write(to: file, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: file.path)
        events.removeAll()
        sync.scanSoon()
        // The read finishes while the main thread is busy; then the note's deleted here.
        Thread.sleep(forTimeInterval: 1.5)
        try FileManager.default.removeItem(at: file)
        sync.remove(path: "Work/Plan.md")
        expectNo("change", for: 1, changed("Work/Plan.md"))

        sync.removeFolder("Home")
        XCTAssertTrue(sync.removedRecently(folder: "Home"))
        XCTAssertFalse(sync.removedRecently(folder: "Work"))
    }

    func testAFileThatIsNotTextIsRememberedNotReadAgain() throws {
        try FileManager.default.createDirectory(at: cloud.appendingPathComponent("Work"), withIntermediateDirectories: true)
        try Data([0xFF, 0xFE, 0xFD, 0x00, 0xC3]).write(to: cloud.appendingPathComponent("Work/Odd.md"))
        sync.scanSoon()
        let stateURL = root.appendingPathComponent("state.json")
        let deadline = Date().addingTimeInterval(5)
        var known: [String: Any] = [:]
        while Date() < deadline, known["Work/Odd.md"] == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let json = (try? Data(contentsOf: stateURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            known = json?["known"] as? [String: Any] ?? [:]
        }
        XCTAssertNotNil(known["Work/Odd.md"])
        XCTAssertFalse(events.contains(where: changed("Work/Odd.md")))
    }

    func testCaseOnlyRenamesMoveTheFileAndTheFolder() throws {
        let id = UUID()
        sync.push(CloudNote(id: id, folder: "Work", title: "plan", text: "# plan", path: nil, bucket: bucket))
        wait(for: "push", pushed("Work/plan.md"))
        sync.push(CloudNote(id: id, folder: "Work", title: "Plan", text: "# Plan", path: "Work/plan.md", bucket: bucket))
        wait(for: "rename", pushed("Work/Plan.md"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cloud.appendingPathComponent("Work").path), ["Plan.md"])

        sync.renameFolder(from: "Work", to: "work")
        wait(for: "folder rename") { if case .folderRenamed("Work", "work", true) = $0 { return true }; return false }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: cloud.path).contains("work"))
    }

    func testAnOpenNotesFileFollowsItsTitleOnlyOnceItHolds() throws {
        let id = UUID()
        pushPlan(id: id)
        wait(for: "push", pushed("Work/Plan.md"))
        events.removeAll()
        sync.push(CloudNote(id: id, folder: "Work", title: "Launch", text: "# Launch", path: "Work/Plan.md", bucket: bucket,
                            editing: true))
        wait(for: "content push", pushed("Work/Plan.md"))
        XCTAssertEqual(try String(contentsOf: cloud.appendingPathComponent("Work/Plan.md"), encoding: .utf8), "# Launch")
        wait(for: "rename", timeout: 6, pushed("Work/Launch.md"))
    }

    func testTitlesBecomeSafeFileNamesAndNumberedNamesStayPut() {
        XCTAssertEqual(CloudSync.fileName(" .Plans/Q3: draft "), "Plans-Q3- draft")
        XCTAssertEqual(CloudSync.fileName(""), "Untitled")
        XCTAssertTrue(CloudSync.stem("Plans 2", matches: "Plans"))
        XCTAssertFalse(CloudSync.stem("Plans 2b", matches: "Plans"))
        XCTAssertFalse(CloudSync.stem("Plansx", matches: "Plans"))
    }
}
