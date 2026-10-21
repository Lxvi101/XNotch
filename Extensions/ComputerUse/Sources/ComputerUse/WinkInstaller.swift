import Foundation

/// Installs the `wink-cua` server that ships inside this extension and adds it
/// to the MCP clients on the Mac, or takes it all away again.
@MainActor
final class WinkInstaller: ObservableObject {
    struct ClientState: Equatable {
        var isInstalled = false
        var isConfigured = false
        var error: String?
    }

    /// Where the server lives once installed: outside XNotch, so moving or
    /// updating the app never breaks the clients' configs.
    let destination: URL
    /// The copy bundled with the extension.
    let bundled: URL?
    let clients: [MCPClient]
    private let configurator: MCPConfigurator

    @Published private(set) var isInstalled = false
    @Published private(set) var states: [String: ClientState] = [:]
    @Published private(set) var busy: Set<String> = []
    @Published private(set) var isWorking = false
    @Published private(set) var hasRefreshed = false
    @Published var error: String?

    init(bundled: URL?, destination: URL? = nil, clients: [MCPClient] = MCPClient.all,
         configurator: MCPConfigurator = MCPConfigurator()) {
        self.bundled = bundled
        self.destination = destination ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Wink/wink-cua")
        self.clients = clients
        self.configurator = configurator
    }

    var installedClients: [MCPClient] { clients.filter { states[$0.id]?.isInstalled == true } }

    /// Reads what's installed and set up. Keeps an installed server up to date with the bundled one.
    func refresh() async {
        updateBinaryIfNeeded()
        isInstalled = FileManager.default.isExecutableFile(atPath: destination.path)
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
    }

    /// Copies the server into place and adds it to every client found.
    func install() async {
        isWorking = true
        defer { isWorking = false }
        error = nil
        do {
            try copyBinary()
        } catch {
            self.error = "Couldn't install wink-cua: \(error.localizedDescription)"
            return
        }
        isInstalled = true
        await refresh()
        for client in installedClients where states[client.id]?.isConfigured != true {
            await setConfigured(true, for: client)
        }
    }

    /// Takes the server out of every client, then deletes it.
    func uninstall() async {
        isWorking = true
        defer { isWorking = false }
        error = nil
        await refresh()
        for client in clients where states[client.id]?.isConfigured == true {
            await setConfigured(false, for: client)
        }
        guard !clients.contains(where: { states[$0.id]?.isConfigured == true }) else {
            error = "Some apps still list wink-cua, so it was kept. See the errors below."
            return
        }
        try? FileManager.default.removeItem(at: destination)
        isInstalled = false
    }

    func setConfigured(_ on: Bool, for client: MCPClient) async {
        guard !busy.contains(client.id) else { return }
        if on, !isInstalled {
            do { try copyBinary() } catch {
                states[client.id, default: ClientState()].error = error.localizedDescription
                return
            }
            isInstalled = true
        }
        busy.insert(client.id)
        defer { busy.remove(client.id) }
        let configurator = configurator
        let command = destination
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

    // MARK: The binary

    private func copyBinary() throws {
        guard let bundled else { throw MCPSetupError("This build of Computer Use doesn't include wink-cua.") }
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = destination.appendingPathExtension("new")
        try? fm.removeItem(at: staging)
        try fm.copyItem(at: bundled, to: staging)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
        // Swap in place so a running server keeps its file until it exits.
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: destination)
        }
    }

    /// A newer XNotch brings a newer server: swap it in where it's installed.
    private func updateBinaryIfNeeded() {
        guard let bundled, FileManager.default.isExecutableFile(atPath: destination.path),
              !FileManager.default.contentsEqual(atPath: bundled.path, andPath: destination.path) else { return }
        try? copyBinary()
    }
}
