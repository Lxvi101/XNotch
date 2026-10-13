import AppKit
import CoreServices
import Network
import Security
import XNotchLink
import os

/// Reaches paired iPhones and iPads by every route at once: USB, the local
/// network (or peer-to-peer Wi-Fi nearby), the internet through a relay, and
/// Bluetooth. Files they send land in the received-files folder and on the
/// shelf; text goes to the clipboard. Sending back uses each device's fastest
/// route.
@MainActor
final class CompanionServer: ObservableObject {
    enum ListenerState: Equatable {
        case stopped, starting, listening, failed(String)
    }

    /// One phone or iPad, with a session on each route it's connected by.
    struct Device: Identifiable {
        var id: String { info.id }
        let info: LinkDevice
        var sessions: [LinkRoute: LinkSession]

        var route: LinkRoute { sessions.keys.min() ?? .bluetooth }
        var session: LinkSession? { sessions[route] }
        var routeTitle: String { session?.routeTitle ?? route.title }
    }

    struct Activity: Identifiable {
        let id = UUID()
        let date = Date()
        let symbol: String
        let text: String
    }

    enum Transfer: Equatable {
        case idle
        case sending(Double)
        case sent
        case failed(String)
    }

    /// The internet route's state, for Settings.
    enum RelayState: Equatable {
        case off, connecting, ready, failed(String)
    }

    @Published private(set) var state: ListenerState = .stopped
    @Published private(set) var devices: [Device] = []
    @Published private(set) var pairing: LinkPairing
    @Published private(set) var recent: [Activity] = []
    @Published private(set) var transfer: Transfer = .idle
    @Published private(set) var relayState: RelayState = .off
    @Published private(set) var bluetoothStatus: String?
    @Published private(set) var usbDevices = 0
    @Published var destination: URL {
        didSet { defaults.set(destination.path, forKey: Keys.destination) }
    }
    /// Applied a moment after the last edit: no Apply button to forget.
    @Published var relayServer: String {
        didSet { scheduleRelayApply() }
    }
    @Published var relayToken: String {
        didSet { scheduleRelayApply() }
    }
    @Published var bluetoothEnabled: Bool {
        didSet {
            defaults.set(bluetoothEnabled, forKey: Keys.bluetooth)
            restartBluetooth()
        }
    }

    /// Called with each received file, already in `destination`.
    var onFiles: (([URL]) -> Void)?
    var onText: (() -> Void)?

    private let defaults: UserDefaults
    private let store: PairingStore
    private let incoming: URL
    private let log: Logger
    private let macName: String
    private let relayTokenService: String
    private var listener: NWListener?
    private var restartWork: DispatchWorkItem?
    private var usbTask: Task<Void, Never>?
    private var relayTask: Task<Void, Never>?
    private var bluetooth: LinkBluetoothPeripheral?
    private var transferReset: DispatchWorkItem?
    private var relayApplyWork: DispatchWorkItem?
    /// The relay the room is registered with, to leave it when that changes.
    private var registeredRelay: (server: URL, token: String, room: String)?
    private var shelfBatch: [URL] = []
    private var shelfBatchWork: DispatchWorkItem?
    private var transferGeneration = 0
    private var isRunning = false
    /// Why the pairing key couldn't be loaded; nothing starts while set.
    private var keyFailure: String?
    /// Handshakes still running, so switching off can cut them short.
    private var pendingAccepts: [UUID: (task: Task<Void, Never>, transport: LinkTransport)] = [:]

    private enum Keys {
        static let destination = "destination", relay = "relayServer", bluetooth = "bluetooth"
    }

    init(defaults: UserDefaults, directory: URL, log: Logger, keychainService: String = "dev.levi.XNotch.companion") {
        self.defaults = defaults
        self.log = log
        macName = Host.current().localizedName ?? "Mac"
        store = PairingStore(defaults: defaults, service: keychainService)
        relayTokenService = keychainService + ".relay"
        do {
            pairing = try store.load(macName: macName)
        } catch {
            // Nothing runs on a stand-in key: phones would see a stranger.
            pairing = LinkPairing(id: "unavailable", name: macName, key: LinkPairing.generateKey())
            keyFailure = error.localizedDescription
        }
        incoming = directory.appendingPathComponent("Incoming", isDirectory: true)
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        destination = defaults.string(forKey: Keys.destination).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? downloads
        relayServer = defaults.string(forKey: Keys.relay) ?? ""
        relayToken = Keychain.read(service: keychainService + ".relay") ?? ""
        bluetoothEnabled = defaults.object(forKey: Keys.bluetooth) as? Bool ?? true
        try? FileManager.default.removeItem(at: incoming)
        pairing.relay = relayURL
    }

    var me: LinkDevice { LinkDevice(id: pairing.id, name: macName, kind: .mac) }

    /// http(s) and a token, or nil: the internet route is off. "drop.example.com" means https.
    var relayURL: URL? {
        var trimmed = relayServer.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !relayToken.isEmpty, !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard let url = URL(string: trimmed), ["https", "http"].contains(url.scheme), url.host != nil else { return nil }
        return url
    }

    /// Typed in, but not usable: shown instead of "Off".
    var relayProblem: String? {
        let typed = !relayServer.trimmingCharacters(in: .whitespaces).isEmpty
        if typed && relayToken.isEmpty { return "Add the server's access token." }
        if typed && relayURL == nil { return "That server address isn't a valid URL." }
        return nil
    }

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        if let keyFailure {
            state = .failed(keyFailure)
            return
        }
        isRunning = true
        startListener()
        startUSB()
        startRelay()
        restartBluetooth()
    }

    func stop() {
        isRunning = false
        restartWork?.cancel()
        listener?.cancel()
        listener = nil
        usbTask?.cancel()
        usbTask = nil
        relayTask?.cancel()
        relayTask = nil
        relayState = .off
        bluetooth?.stop()
        bluetooth = nil
        for pending in pendingAccepts.values {
            pending.task.cancel()
            pending.transport.close()
        }
        pendingAccepts = [:]
        for device in devices {
            for session in device.sessions.values { Task { await session.close() } }
        }
        devices = []
        state = .stopped
    }

    /// A new key: every paired device has to scan the new code.
    func resetPairing() {
        let oldRoom = LinkRelay.room(for: pairing)
        if let relay = relayURL {
            let token = relayToken
            Task { await LinkRelay.unregister(oldRoom, server: relay, token: token) }
        }
        stop()
        do {
            pairing = try store.reset(macName: macName)
            keyFailure = nil
        } catch {
            keyFailure = error.localizedDescription
        }
        pairing.relay = relayURL
        log.info("Pairing reset")
        start()
    }

    private func scheduleRelayApply() {
        relayApplyWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applyRelaySettings() }
        relayApplyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Saves the relay settings and reconnects with them.
    func applyRelaySettings() {
        relayApplyWork?.cancel()
        defaults.set(relayServer, forKey: Keys.relay)
        Keychain.write(relayToken, service: relayTokenService)
        pairing.relay = relayURL
        if let old = registeredRelay, old.server != relayURL || old.token != relayToken {
            registeredRelay = nil
            Task { await LinkRelay.unregister(old.room, server: old.server, token: old.token) }
        }
        guard isRunning else { return }
        relayTask?.cancel()
        relayTask = nil
        startRelay()
    }

    // MARK: Local network

    private func startListener() {
        guard listener == nil else { return }
        state = .starting
        do {
            let listener = try NWListener(using: LinkNetwork.parameters())
            listener.service = NWListener.Service(name: macName, type: LinkService.type,
                                                  txtRecord: NWTXTRecord([LinkService.idKey: pairing.id]))
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    // A late word from a listener that's already been replaced.
                    guard let self, let listener, self.listener === listener else { return }
                    self.listenerChanged(state)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.acceptIncoming(NetworkTransport(connection, route: .local)) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            state = .failed(error.localizedDescription)
            scheduleListenerRestart()
        }
    }

    private func listenerChanged(_ newState: NWListener.State) {
        switch newState {
        case .ready:
            state = .listening
        case .failed(let error):
            state = .failed(error.localizedDescription)
            log.error("Listener failed: \(error.localizedDescription, privacy: .public)")
            listener?.cancel()
            listener = nil
            scheduleListenerRestart()
        case .waiting(let error):
            state = .failed(error.localizedDescription)
        default:
            break
        }
    }

    private func scheduleListenerRestart() {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, isRunning else { return }
            startListener()
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    /// The phone connected to us (local network, relay, Bluetooth): it starts the handshake.
    private func acceptIncoming(_ transport: LinkTransport) {
        guard isRunning else { return transport.close() }
        let pairing = self.pairing
        let me = self.me
        let id = UUID()
        let task = Task {
            defer { pendingAccepts[id] = nil }
            do {
                if let network = transport as? NetworkTransport { try await network.start() }
                let session = try await LinkClient.accept(transport, as: me, incomingDirectory: incoming, relay: pairing.relay) { id in
                    id == pairing.id ? pairing.key : nil
                }
                adopt(session)
            } catch {
                transport.close()
            }
        }
        pendingAccepts[id] = (task, transport)
    }

    // MARK: USB

    /// usbmuxd reports cabled iPhones; while one is attached, keep trying its
    /// port, which opens whenever the XNotch app is in front.
    private func startUSB() {
        usbTask = Task { [weak self] in
            var watchers: [String: Task<Void, Never>] = [:]
            defer { watchers.values.forEach { $0.cancel() } }
            while !Task.isCancelled {
                do {
                    for try await (device, attached) in USBMux().devices() {
                        if attached {
                            watchers[device.serial]?.cancel()
                            watchers[device.serial] = Task { [weak self] in await self?.dialUSB(device) }
                        } else {
                            watchers.removeValue(forKey: device.serial)?.cancel()
                        }
                        self?.usbDevices = watchers.count
                    }
                } catch {
                    // usbmuxd restarted or isn't there: try again shortly.
                }
                watchers.values.forEach { $0.cancel() }
                watchers.removeAll()
                self?.usbDevices = 0
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func dialUSB(_ device: USBMux.Device) async {
        while !Task.isCancelled {
            if let transport = try? await USBMux().connect(to: device, port: LinkUSB.port) {
                do {
                    let session = try await LinkClient.open(transport, pairing: pairing, as: me,
                                                            incomingDirectory: incoming, relay: pairing.relay)
                    // Dial again only once this USB session has ended.
                    await withTaskCancellationHandler {
                        await adopt(session).value
                    } onCancel: {
                        Task { await session.close() }
                    }
                } catch {
                    transport.close()
                }
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    // MARK: Internet

    /// Keeps one socket waiting in the relay room; when a phone joins it,
    /// the next one opens.
    private func startRelay() {
        guard relayTask == nil, let server = relayURL else {
            relayState = .off
            return
        }
        let token = relayToken
        relayState = .connecting
        relayTask = Task { [weak self] in
            var delay: UInt64 = 2
            var registered = false
            while !Task.isCancelled, let self {
                let room = LinkRelay.room(for: pairing)
                do {
                    if !registered {
                        try await LinkRelay.register(room, server: server, token: token)
                        registered = true
                        registeredRelay = (server, token, room)
                    }
                    relayState = .ready
                    let transport = try await LinkRelay.connect(room, server: server, as: .mac)
                    delay = 2
                    acceptIncoming(transport)
                } catch is CancellationError {
                    return
                } catch LinkError.timedOut {
                    // A routine refresh of the waiting socket.
                    continue
                } catch {
                    guard !Task.isCancelled else { return }
                    // The server may have forgotten the room (a reset, a new volume): register again.
                    registered = false
                    relayState = .failed(error.localizedDescription)
                    try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                    delay = min(delay * 2, 60)
                }
            }
        }
    }

    // MARK: Bluetooth

    private func restartBluetooth() {
        bluetooth?.stop()
        bluetooth = nil
        bluetoothStatus = nil
        // Only once allowed: creating the manager earlier would show macOS's prompt unasked.
        guard isRunning, bluetoothEnabled, LinkBluetooth.isAllowed else { return }
        startBluetooth()
    }

    /// Shows macOS's Bluetooth prompt if it hasn't been answered.
    func startBluetooth() {
        guard bluetooth == nil, isRunning else { return }
        let peripheral = LinkBluetoothPeripheral(pairing: pairing)
        peripheral.onChannel = { [weak self] transport in
            Task { @MainActor in self?.acceptIncoming(transport) }
        }
        peripheral.onStatus = { [weak self] status in
            Task { @MainActor in self?.bluetoothStatus = status }
        }
        peripheral.start()
        bluetooth = peripheral
    }

    // MARK: Devices

    /// Runs the session until it ends; the task finishes then.
    @discardableResult
    private func adopt(_ session: LinkSession) -> Task<Void, Never> {
        Task {
            // Switched off while this one was connecting: let it go.
            guard isRunning, let info = await session.peer else { return await session.close() }
            let route = session.route
            if let index = devices.firstIndex(where: { $0.id == info.id }) {
                if let old = devices[index].sessions[route] { Task { await old.close() } }
                devices[index].sessions[route] = session
            } else {
                devices.append(Device(info: info, sessions: [route: session]))
            }
            log.info("\(info.name, privacy: .public) connected by \(route.title, privacy: .public)")
            await session.run(onReceive: { [weak self] item in
                try await self?.receive(item, from: info)
            })
            if let index = devices.firstIndex(where: { $0.id == info.id }), devices[index].sessions[route] === session {
                devices[index].sessions[route] = nil
                if devices[index].sessions.isEmpty { devices.remove(at: index) }
            }
        }
    }

    // MARK: Receiving

    private func receive(_ item: LinkSession.Incoming, from device: LinkDevice) throws {
        switch item {
        case .file(let temporary, let name):
            var target = linkUniqueURL(for: name, in: destination)
            do {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: temporary, to: target)
            } catch {
                note("exclamationmark.triangle.fill", "Couldn't save \(name) from \(device.name): \(error.localizedDescription)")
                throw error
            }
            // Like AirDrop: Gatekeeper checks it before it can run.
            var values = URLResourceValues()
            values.quarantineProperties = [kLSQuarantineAgentNameKey as String: "XNotch",
                                           kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload]
            try? target.setResourceValues(values)
            note("arrow.down.circle.fill", "\(target.lastPathComponent) from \(device.name)")
            addToShelf(target)
        case .text(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            let preview = text.count > 40 ? text.prefix(40) + "…" : Substring(text)
            note("doc.on.clipboard.fill", "Copied “\(preview)” from \(device.name)")
            onText?()
        }
    }

    /// Files arriving close together land on the shelf as one batch: the
    /// notch opens once, not once per photo.
    private func addToShelf(_ url: URL) {
        shelfBatch.append(url)
        shelfBatchWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !shelfBatch.isEmpty else { return }
            let batch = shelfBatch
            shelfBatch = []
            onFiles?(batch)
        }
        shelfBatchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func note(_ symbol: String, _ text: String) {
        recent.insert(Activity(symbol: symbol, text: text), at: 0)
        if recent.count > 8 { recent.removeLast(recent.count - 8) }
    }

    // MARK: Sending

    /// Over the device's fastest route at the time each file starts.
    func send(_ urls: [URL], to device: Device) {
        guard !urls.isEmpty, !isSending else { return }
        transferGeneration += 1
        let generation = transferGeneration
        let id = device.id
        setTransfer(.sending(0))
        Task {
            do {
                let total = Double(urls.count)
                for (index, url) in urls.enumerated() {
                    guard let session = devices.first(where: { $0.id == id })?.session else { throw LinkError.closed }
                    let prepared = try await PreparedFile.make(for: url)
                    defer { prepared.cleanUp() }
                    let throttle = ProgressThrottle()
                    try await session.sendFile(prepared.url, name: prepared.name) { fraction in
                        guard throttle.shouldReport(fraction) else { return }
                        Task { @MainActor in
                            // Progress may still be in flight after the transfer ended.
                            guard self.transferGeneration == generation, self.isSending else { return }
                            self.transfer = .sending((Double(index) + fraction) / total)
                        }
                    }
                }
                note("arrow.up.circle.fill", urls.count == 1
                     ? "Sent \(urls[0].lastPathComponent) to \(device.info.name)"
                     : "Sent \(urls.count) files to \(device.info.name)")
                setTransfer(.sent)
            } catch {
                setTransfer(.failed(error.localizedDescription))
            }
        }
    }

    var isSending: Bool {
        if case .sending = transfer { return true }
        return false
    }

    /// Finished states show for a moment, then the button rests again.
    private func setTransfer(_ value: Transfer) {
        transferReset?.cancel()
        transfer = value
        if case .sending = value { return }
        let work = DispatchWorkItem { [weak self] in self?.transfer = .idle }
        transferReset = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    // MARK: Cloud Links

    /// The Cloud Links extension's server, if it has one: the same server relays.
    var cloudLinksServer: (url: String, token: String)? {
        guard let url = UserDefaults(suiteName: "dev.levi.XNotch.ext.cloud")?.string(forKey: "server"), !url.isEmpty,
              let token = Keychain.read(service: "dev.levi.XNotch.cloud", account: "api-token") else { return nil }
        return (url, token)
    }
}

/// A file ready to send: folders are zipped first.
struct PreparedFile {
    let url: URL
    let name: String
    private let temporary: URL?

    static func make(for url: URL) async throws -> PreparedFile {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard isDirectory.boolValue else { return PreparedFile(url: url, name: url.lastPathComponent, temporary: nil) }
        let zip = try await Task.detached { try zipped(url) }.value
        return PreparedFile(url: zip, name: url.lastPathComponent + ".zip", temporary: zip.deletingLastPathComponent())
    }

    /// The coordinator's `.forUploading` read hands back a zip of a folder.
    private static func zipped(_ folder: URL) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var coordinationError: NSError?
        var result: Result<URL, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinationError) { zip in
            let target = directory.appendingPathComponent(folder.lastPathComponent + ".zip")
            result = Result { try FileManager.default.copyItem(at: zip, to: target); return target }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    func cleanUp() {
        if let temporary { try? FileManager.default.removeItem(at: temporary) }
    }
}

/// Generic passwords in the login Keychain.
enum Keychain {
    static func read(service: String, account: String = "token") -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, service: String, account: String = "token") {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrLabel as String] = "XNotch iPhone & iPad relay token"
        SecItemAdd(item as CFDictionary, nil)
    }
}

/// Lets progress through once per whole percent, from any thread.
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1.0

    func shouldReport(_ fraction: Double) -> Bool {
        lock.withLock {
            guard fraction - last >= 0.01 || (fraction >= 1 && last < 1) else { return false }
            last = fraction
            return true
        }
    }
}
