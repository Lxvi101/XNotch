import Foundation
import XNotchKit

/// Installs Wink.app, which ships inside this extension, adds its `wink-cua`
/// server to the MCP clients on the Mac, and walks the user through Wink's
/// permissions; or takes it all away again.
@MainActor
final class WinkInstaller: ObservableObject {
    struct ClientState: Equatable {
        var isInstalled = false
        var isConfigured = false
        var error: String?
    }

    /// Wink's own grants, as the app itself reports them; nil until asked.
    struct Grants: Equatable {
        var accessibility: Bool
        var screenRecording: Bool

        func has(_ permission: GuidedPermission) -> Bool {
            switch permission {
            case .accessibility: accessibility
            case .screenRecording: screenRecording
            }
        }
    }

    /// Where Wink lives once installed: outside XNotch, so moving or updating
    /// the app never breaks the clients' configs.
    let destination: URL
    /// The copy bundled with the extension.
    let bundled: URL?
    let clients: [MCPClient]
    private let configurator: MCPConfigurator
    /// Where 0.9.0 put a bare `wink-cua`, which borrowed each client's permissions.
    private let legacyBinary: URL

    @Published private(set) var isInstalled = false
    @Published private(set) var states: [String: ClientState] = [:]
    @Published private(set) var busy: Set<String> = []
    @Published private(set) var isWorking = false
    @Published private(set) var hasRefreshed = false
    @Published private(set) var grants: Grants?
    @Published private(set) var guiding: GuidedPermission?
    @Published var error: String?

    init(bundled: URL?, directory: URL? = nil, clients: [MCPClient] = MCPClient.all,
         configurator: MCPConfigurator = MCPConfigurator()) {
        let directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Wink")
        self.bundled = bundled
        destination = directory.appendingPathComponent("Wink.app")
        legacyBinary = directory.appendingPathComponent("wink-cua")
        self.clients = clients
        self.configurator = configurator
    }

    /// The server the clients run.
    var command: URL { destination.appendingPathComponent("Contents/MacOS/wink-cua") }

    var installedClients: [MCPClient] { clients.filter { states[$0.id]?.isInstalled == true } }

    var missingPermissions: [GuidedPermission] {
        guard isInstalled, let grants else { return [] }
        return GuidedPermission.allCases.filter { !grants.has($0) }
    }

    /// Reads what's installed, set up and granted. Brings an installed Wink up
    /// to date with the bundled one, and moves 0.9.0's bare server into it.
    func refresh() async {
        updateIfNeeded()
        isInstalled = FileManager.default.isExecutableFile(atPath: command.path)
        let configurator = configurator
        let clients = clients
        let found = await Task.detached {
            clients.map { client in
                let installed = configurator.isInstalled(client)
                return (client.id, ClientState(isInstalled: installed,
                                               isConfigured: installed && configurator.isConfigured(client)))
            }
        }.value
        var states = self.states
        for (id, state) in found {
            states[id] = ClientState(isInstalled: state.isInstalled, isConfigured: state.isConfigured,
                                     error: states[id]?.error)
        }
        self.states = states
        hasRefreshed = true
        await migrateLegacyBinary()
        await refreshGrants()
    }

    func refreshGrants() async {
        grants = isInstalled ? await Self.grants(of: command) : nil
    }

    /// Asks Wink itself: its server disclaims XNotch, so it answers for its own grants.
    nonisolated static func grants(of command: URL) async -> Grants? {
        await Task.detached {
            let result = try? MCPConfigurator().run(command, ["permissions"], timeout: 10)
            guard let output = result?.output, let data = output.split(separator: "\n").last.map({ Data($0.utf8) }),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return Grants(accessibility: json["accessibility"] as? Bool ?? false,
                          screenRecording: json["screenRecording"] as? Bool ?? false)
        }.value
    }

    /// Copies Wink into place, adds it to every client found, then asks for its permissions.
    func install(guide: PermissionGuiding?) async {
        isWorking = true
        error = nil
        do {
            try copyApp()
        } catch {
            self.error = "Couldn't install Wink: \(error.localizedDescription)"
            isWorking = false
            return
        }
        isInstalled = true
        await refresh()
        for client in installedClients where states[client.id]?.isConfigured != true {
            await setConfigured(true, for: client)
        }
        isWorking = false
        if let guide {
            for permission in missingPermissions { _ = await request(permission, guide: guide) }
        }
    }

    /// Takes Wink out of every client, then deletes it.
    func uninstall() async {
        isWorking = true
        defer { isWorking = false }
        error = nil
        await refresh()
        for client in clients where states[client.id]?.isConfigured == true {
            await setConfigured(false, for: client)
        }
        guard !clients.contains(where: { states[$0.id]?.isConfigured == true }) else {
            error = "Some apps still list Wink, so it was kept. See the errors below."
            return
        }
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.removeItem(at: legacyBinary)
        isInstalled = false
        grants = nil
    }

    func setConfigured(_ on: Bool, for client: MCPClient) async {
        guard !busy.contains(client.id) else { return }
        if on, !isInstalled {
            do { try copyApp() } catch {
                states[client.id, default: ClientState()].error = error.localizedDescription
                return
            }
            isInstalled = true
        }
        busy.insert(client.id)
        defer { busy.remove(client.id) }
        let configurator = configurator
        let command = command
        let result: Result<Bool, Error> = await Task.detached {
            do {
                if on { try configurator.add(client, command: command) } else { try configurator.remove(client) }
                return .success(configurator.isConfigured(client))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case let .success(configured):
            states[client.id, default: ClientState()].isConfigured = configured
            states[client.id, default: ClientState()].error = configured == on ? nil
                : "\(client.name) didn't take the change."
        case let .failure(error):
            states[client.id, default: ClientState()].error = error.localizedDescription
        }
    }

    /// XNotch's guide, with Wink's icon to drag into the list.
    func request(_ permission: GuidedPermission, guide: PermissionGuiding) async -> Bool {
        guard isInstalled, guiding == nil else { return false }
        guiding = permission
        defer { guiding = nil }
        let command = command
        let granted = await guide.guide(permission, for: destination) {
            await Self.grants(of: command)?.has(permission) ?? false
        }
        await refreshGrants()
        return granted
    }

    // MARK: The app

    private func copyApp() throws {
        guard let bundled else { throw MCPSetupError("This build of Computer Use doesn't include Wink.") }
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = destination.deletingLastPathComponent().appendingPathComponent("Wink.new.app")
        try? fm.removeItem(at: staging)
        try fm.copyItem(at: bundled, to: staging)
        // Swap in place: a running server keeps its files until it exits.
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: destination)
        }
    }

    /// A newer XNotch brings a newer Wink: swap it in where it's installed.
    private func updateIfNeeded() {
        guard let bundled, FileManager.default.isExecutableFile(atPath: command.path) else { return }
        let bundledServer = bundled.appendingPathComponent("Contents/MacOS/wink-cua")
        guard !FileManager.default.contentsEqual(atPath: bundledServer.path, andPath: command.path) else { return }
        try? copyApp()
    }

    /// 0.9.0 installed a bare server, which ran with each client's permissions
    /// instead of its own. Install Wink.app and point the clients at it.
    private func migrateLegacyBinary() async {
        guard FileManager.default.fileExists(atPath: legacyBinary.path) else { return }
        do {
            try copyApp()
        } catch {
            return
        }
        isInstalled = true
        for client in clients where states[client.id]?.isConfigured == true {
            await setConfigured(true, for: client)
        }
        if !clients.contains(where: { states[$0.id]?.error != nil }) {
            try? FileManager.default.removeItem(at: legacyBinary)
        }
    }
}
