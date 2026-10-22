import Foundation

/// An app that runs MCP servers, and how to add Wink's to it. Clients with a
/// CLI of their own (`claude mcp add`, …) are set up through it, so they keep
/// owning their config format; the rest have a JSON file edited in place.
struct MCPClient: Identifiable, Hashable, Sendable {
    enum Setup: Hashable, Sendable {
        /// `<cli> <add…> <name> <path>`, `<cli> <remove…> <name>`; `listed` reads whether it's set up.
        case cli(name: String, add: [String], remove: [String], listed: Listed)
        /// A JSON file with servers under `key`; VS Code's entries also carry `"type": "stdio"`.
        case json(path: String, key: String, typed: Bool)
    }

    /// Where a CLI client keeps its servers, read without running it.
    enum Listed: Hashable, Sendable {
        /// A JSON file with servers under `key`.
        case json(path: String, key: String)
        /// A TOML file with `[<table>.<name>]` sections.
        case toml(path: String, table: String)
        /// The CLI's own `mcp list` output mentions the server.
        case listCommand([String])
    }

    let id: String
    let name: String
    let setup: Setup
    /// Apps whose presence means the client is installed, besides its CLI.
    var apps: [String] = []
    /// Folders whose presence means the client is installed.
    var folders: [String] = []

    static let serverName = "wink-cua"

    static let all: [MCPClient] = [
        MCPClient(id: "claude-code", name: "Claude Code",
                  setup: .cli(name: "claude", add: ["mcp", "add", "--scope", "user"],
                              remove: ["mcp", "remove", "--scope", "user"],
                              listed: .json(path: "~/.claude.json", key: "mcpServers"))),
        MCPClient(id: "codex", name: "Codex",
                  setup: .cli(name: "codex", add: ["mcp", "add"], remove: ["mcp", "remove"],
                              listed: .toml(path: "~/.codex/config.toml", table: "mcp_servers"))),
        MCPClient(id: "antigravity", name: "Antigravity",
                  setup: .cli(name: "agy", add: ["mcp", "add"], remove: ["mcp", "remove"],
                              listed: .listCommand(["mcp", "list"])),
                  apps: ["Antigravity.app"]),
        MCPClient(id: "cursor", name: "Cursor",
                  setup: .json(path: "~/.cursor/mcp.json", key: "mcpServers", typed: false),
                  apps: ["Cursor.app"], folders: ["~/.cursor"]),
        MCPClient(id: "claude-desktop", name: "Claude Desktop",
                  setup: .json(path: "~/Library/Application Support/Claude/claude_desktop_config.json",
                               key: "mcpServers", typed: false),
                  apps: ["Claude.app"]),
        MCPClient(id: "vscode", name: "VS Code",
                  setup: .json(path: "~/Library/Application Support/Code/User/mcp.json", key: "servers", typed: true),
                  apps: ["Visual Studio Code.app"]),
        MCPClient(id: "windsurf", name: "Windsurf",
                  setup: .json(path: "~/.codeium/windsurf/mcp_config.json", key: "mcpServers", typed: false),
                  apps: ["Windsurf.app"], folders: ["~/.codeium/windsurf"]),
        MCPClient(id: "gemini", name: "Gemini CLI",
                  setup: .cli(name: "gemini", add: ["mcp", "add", "--scope", "user"],
                              remove: ["mcp", "remove", "--scope", "user"],
                              listed: .json(path: "~/.gemini/settings.json", key: "mcpServers"))),
    ]
}

struct MCPSetupError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Finds, adds and removes Wink's server in each client. Runs off the main thread.
struct MCPConfigurator: Sendable {
    var home = FileManager.default.homeDirectoryForCurrentUser
    /// Where GUI apps don't look but CLIs get installed.
    var searchPaths = ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "~/.npm-global/bin", "~/.bun/bin",
                       "~/.volta/bin", "~/.cargo/bin", "/usr/bin"]

    func expand(_ path: String) -> URL {
        path.hasPrefix("~/") ? home.appendingPathComponent(String(path.dropFirst(2))) : URL(fileURLWithPath: path)
    }

    func isInstalled(_ client: MCPClient) -> Bool {
        if case let .cli(name, _, _, _) = client.setup, executable(name) != nil { return true }
        let fm = FileManager.default
        let appDirs = ["/Applications", home.appendingPathComponent("Applications").path]
        if client.apps.contains(where: { app in appDirs.contains { fm.fileExists(atPath: "\($0)/\(app)") } }) { return true }
        return client.folders.contains { fm.fileExists(atPath: expand($0).path) }
    }

    func isConfigured(_ client: MCPClient) -> Bool {
        switch client.setup {
        case let .json(path, key, _):
            return (try? readJSON(expand(path)))?[key].flatMap { $0 as? [String: Any] }?[MCPClient.serverName] != nil
        case let .cli(name, _, _, listed):
            switch listed {
            case let .json(path, key):
                return (try? readJSON(expand(path)))?[key].flatMap { $0 as? [String: Any] }?[MCPClient.serverName] != nil
            case let .toml(path, table):
                guard let text = try? String(contentsOf: expand(path), encoding: .utf8) else { return false }
                let name = NSRegularExpression.escapedPattern(for: MCPClient.serverName)
                return text.range(of: #"(?m)^\s*\[\#(table)\.("?)\#(name)\1\]"#, options: .regularExpression) != nil
            case let .listCommand(arguments):
                guard let cli = executable(name), let result = try? run(cli, arguments) else { return false }
                return result.output.contains(MCPClient.serverName)
            }
        }
    }

    func add(_ client: MCPClient, command: URL) throws {
        switch client.setup {
        case let .json(path, key, typed):
            var entry: [String: Any] = ["command": command.path, "args": [String]()]
            if typed { entry["type"] = "stdio" }
            try editJSON(expand(path)) { root in
                var servers = root[key] as? [String: Any] ?? [:]
                servers[MCPClient.serverName] = entry
                root[key] = servers
            }
        case let .cli(name, add, remove, _):
            guard let cli = executable(name) else { throw MCPSetupError("\(client.name)'s \(name) command isn't installed.") }
            // Replace an older entry, which may point somewhere else.
            _ = try? run(cli, remove + [MCPClient.serverName])
            let result = try run(cli, add + [MCPClient.serverName, "--", command.path])
            guard result.status == 0 else { throw MCPSetupError(result.output.isEmpty ? "\(name) failed." : result.output) }
        }
    }

    func remove(_ client: MCPClient) throws {
        switch client.setup {
        case let .json(path, key, _):
            let url = expand(path)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            try editJSON(url) { root in
                guard var servers = root[key] as? [String: Any] else { return }
                servers[MCPClient.serverName] = nil
                root[key] = servers
            }
        case let .cli(name, _, remove, _):
            guard let cli = executable(name) else { return }
            let result = try run(cli, remove + [MCPClient.serverName])
            if result.status != 0, isConfigured(client) {
                throw MCPSetupError(result.output.isEmpty ? "\(name) failed." : result.output)
            }
        }
    }

    // MARK: JSON

    /// nil for a missing or empty file; throws for one that isn't a JSON object (comments, say).
    func readJSON(_ url: URL) throws -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              !data.allSatisfy({ [0x20, 0x0A, 0x0D, 0x09].contains($0) }) else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPSetupError("\(url.path) isn't plain JSON, so it was left alone. Add wink-cua there by hand.")
        }
        return root
    }

    private func editJSON(_ url: URL, _ change: (inout [String: Any]) -> Void) throws {
        var root = try readJSON(url) ?? [:]
        change(&root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
    }

    // MARK: Processes

    func executable(_ name: String) -> URL? {
        let fm = FileManager.default
        for dir in searchPaths {
            let url = expand(dir).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: url.path) { return url }
        }
        // A login shell knows the user's PATH (nvm, asdf, …).
        guard let result = try? run(URL(fileURLWithPath: "/bin/zsh"), ["-lc", "command -v \(name)"], timeout: 5),
              result.status == 0 else { return nil }
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") && fm.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval = 30) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        let extra = searchPaths.map { expand($0).path }.joined(separator: ":")
        environment["PATH"] = [extra, environment["PATH"]].compactMap { $0 }.joined(separator: ":")
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let output = pipe.fileHandleForReading
        var data = Data()
        let reader = DispatchQueue(label: "mcp-configurator.read")
        let done = DispatchSemaphore(value: 0)
        reader.async {
            data = output.readDataToEndOfFile()
            done.signal()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut { process.terminate() }
        _ = done.wait(timeout: .now() + 2)
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, text)
    }
}
