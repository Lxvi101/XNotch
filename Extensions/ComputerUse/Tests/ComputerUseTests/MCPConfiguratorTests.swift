import XCTest
@testable import ComputerUse

final class MCPConfiguratorTests: XCTestCase {
    private var home: URL!
    private var configurator: MCPConfigurator!
    private let command = URL(fileURLWithPath: "/Users/me/Library/Application Support/Wink/wink-cua")

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-tests-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        configurator = MCPConfigurator(home: home, searchPaths: [])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func client(_ id: String) -> MCPClient { MCPClient.all.first { $0.id == id }! }

    func testAddsAndRemovesAJSONEntryKeepingTheRest() throws {
        let url = home.appendingPathComponent(".cursor/mcp.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"mcpServers": {"other": {"command": "x"}}, "theme": "dark"}"#.utf8).write(to: url)

        let cursor = client("cursor")
        XCTAssertTrue(configurator.isInstalled(cursor))
        XCTAssertFalse(configurator.isConfigured(cursor))
        try configurator.add(cursor, command: command)
        XCTAssertTrue(configurator.isConfigured(cursor))

        let root = try XCTUnwrap(configurator.readJSON(url))
        let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["other"])
        XCTAssertEqual((servers["wink-cua"] as? [String: Any])?["command"] as? String, command.path)
        XCTAssertEqual(root["theme"] as? String, "dark")

        try configurator.remove(cursor)
        XCTAssertFalse(configurator.isConfigured(cursor))
        XCTAssertNotNil((try configurator.readJSON(url))?["mcpServers"].flatMap { $0 as? [String: Any] }?["other"])
    }

    func testVSCodeEntriesAreTypedAndAnEmptyFileIsFine() throws {
        let url = home.appendingPathComponent("Library/Application Support/Code/User/mcp.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
        try configurator.add(client("vscode"), command: command)
        let entry = try XCTUnwrap(configurator.readJSON(url)?["servers"] as? [String: Any])["wink-cua"] as? [String: Any]
        XCTAssertEqual(entry?["type"] as? String, "stdio")
    }

    func testLeavesFilesWithCommentsAlone() throws {
        let url = home.appendingPathComponent(".cursor/mcp.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("{ // mine\n \"mcpServers\": {} }".utf8)
        try original.write(to: url)
        XCTAssertThrowsError(try configurator.add(client("cursor"), command: command))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testReadsCodexTOML() throws {
        let url = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("model = \"x\"\n\n[mcp_servers.other]\ncommand = \"y\"\n".utf8).write(to: url)
        XCTAssertFalse(configurator.isConfigured(client("codex")))
        try Data("[mcp_servers.wink-cua]\ncommand = \"/w\"\n".utf8).write(to: url)
        XCTAssertTrue(configurator.isConfigured(client("codex")))
        try Data("[mcp_servers.\"wink-cua\"]\ncommand = \"/w\"\n".utf8).write(to: url)
        XCTAssertTrue(configurator.isConfigured(client("codex")))
    }

    func testCLIClientsUseTheirCommand() throws {
        // A fake `claude` that records its arguments.
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let log = home.appendingPathComponent("calls.txt")
        let script = bin.appendingPathComponent("claude")
        try Data("#!/bin/sh\necho \"$@\" >> '\(log.path)'\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        configurator = MCPConfigurator(home: home, searchPaths: [bin.path])

        let claude = client("claude-code")
        XCTAssertTrue(configurator.isInstalled(claude))
        try configurator.add(claude, command: command)
        let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(calls, ["mcp remove --scope user wink-cua",
                               "mcp add --scope user wink-cua -- \(command.path)"])
    }

    func testRunReadsLongOutputAndStopsAtTheTimeout() throws {
        let long = try configurator.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "yes | head -c 200000"])
        XCTAssertEqual(long.status, 0)
        XCTAssertEqual(long.output.count, 199_999)

        let start = Date()
        let slow = try configurator.run(URL(fileURLWithPath: "/bin/sleep"), ["10"], timeout: 0.3)
        XCTAssertNotEqual(slow.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
}
