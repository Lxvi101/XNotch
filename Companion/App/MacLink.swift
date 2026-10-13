import Foundation
import SwiftUI
import UIKit
import XNotchLink

/// Keeps the chosen Mac connected while the app is open, and sends the
/// basket's files and text over it in order.
@MainActor
final class MacLink: ObservableObject {
    enum Status: Equatable {
        case unpaired, searching
        /// By the fastest route that's up, titled "USB", "Wi-Fi", "Nearby"…
        case connected(LinkRoute, String)
        case failed(String)

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    struct Outgoing: Identifiable, Equatable {
        enum Content: Equatable {
            case file(URL)
            case text(String)
        }

        enum State: Equatable {
            case waiting, sending(Double), sent, failed(String)
        }

        let id = UUID()
        let name: String
        let content: Content
        var state: State = .waiting
    }

    struct Received: Identifiable, Hashable {
        var id: URL { url }
        let url: URL
        let date: Date
    }

    @Published private(set) var stored = PairingKeychain.load()
    @Published private(set) var status: Status = .unpaired
    @Published private(set) var outgoing: [Outgoing] = []
    @Published private(set) var received: [Received] = []
    @Published private(set) var incomingProgress: (name: String, fraction: Double)?

    /// One session per route that's up; sends use the fastest.
    private var sessions: [LinkRoute: LinkSession] = [:]
    private var routeTasks: [Task<Void, Never>] = []
    private var usb: LinkUSBAcceptor?
    private var queueTask: Task<Void, Never>?
    private var sendingSession: LinkSession?
    private var lastFailure: String?
    private var isPausedForPairing = false
    private var bluetoothTask: Task<Void, Never>?
    private var isActive = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    var mac: LinkPairing? { stored.selected }

    static var receivedDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("From Mac", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    nonisolated private static var outgoingDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Outgoing", isDirectory: true)
    }

    init() {
        loadReceived()
        status = mac == nil ? .unpaired : .searching
    }

    // MARK: Pairing

    /// Saves the pairing and makes it the Mac to send to. `session` is the
    /// connection the pairing screen already opened: kept, not redone.
    func pair(_ pairing: LinkPairing, session: LinkSession? = nil) {
        stored.pairings.removeAll { $0.id == pairing.id }
        stored.pairings.append(pairing)
        stored.selectedID = pairing.id
        PairingKeychain.save(stored)
        disconnect()
        isPausedForPairing = false
        connectIfNeeded()
        if let session { adopt(session) }
        updateStatus()
    }

    /// The pairing screen connects on its own; nothing here competes with it.
    func pauseForPairing() {
        isPausedForPairing = true
        disconnect()
    }

    func resumeAfterPairing() {
        guard isPausedForPairing else { return }
        isPausedForPairing = false
        connectIfNeeded()
    }

    /// Asks for Bluetooth, then adds it as the last fallback.
    func enableBluetooth() async {
        guard await LinkBluetooth.requestAccess() else { return }
        objectWillChange.send()
        guard !routeTasks.isEmpty, bluetoothTask == nil else { return }
        startBluetoothLoop()
    }

    func select(_ id: String) {
        guard id != stored.selectedID else { return }
        stored.selectedID = id
        PairingKeychain.save(stored)
        reconnect()
    }

    func forget(_ id: String) {
        stored.pairings.removeAll { $0.id == id }
        if stored.selectedID == id { stored.selectedID = stored.pairings.first?.id }
        PairingKeychain.save(stored)
        reconnect()
    }

    // MARK: Lifecycle

    /// Connected while the app is in front. Leaving mid-transfer asks iOS
    /// for a little time to finish.
    func setActive(_ active: Bool) {
        isActive = active
        if active {
            endBackgroundTask()
            connectIfNeeded()
        } else if outgoing.contains(where: { $0.state == .waiting || $0.isSending }) {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Send to Mac") { [weak self] in
                self?.disconnect()
                self?.endBackgroundTask()
            }
        } else {
            disconnect()
        }
    }

    private func reconnect() {
        disconnect()
        connectIfNeeded()
        updateStatus()
    }

    private func disconnect() {
        routeTasks.forEach { $0.cancel() }
        routeTasks = []
        bluetoothTask = nil
        usb?.cancel()
        usb = nil
        let open = sessions.values
        sessions = [:]
        for session in open { Task { await session.close() } }
        updateStatus()
    }

    /// The fastest session that's up.
    private var session: LinkSession? { sessions.keys.min().flatMap { sessions[$0] } }

    /// USB waits for the Mac to dial in; Wi-Fi always looks; the internet and
    /// Bluetooth only step in after nothing faster has connected for a moment.
    private func connectIfNeeded() {
        guard isActive, !isPausedForPairing, routeTasks.isEmpty, mac != nil else { return }
        let device = ThisDevice.link
        let incoming = ThisDevice.incomingDirectory
        #if !targetEnvironment(simulator)
        // A simulator has no cable, and its port would sit on the Mac's own loopback.
        usb = try? LinkUSBAcceptor(pairings: { [stored] in stored.pairings }, as: { device }, incomingDirectory: incoming,
                                   onSession: { session in Task { @MainActor [weak self] in self?.adopt(session) } })
        #endif
        routeTasks = [
            Task { [weak self] in
                await self?.routeLoop(.local, after: 0) { try await LinkClient.connectLocal(to: $0, as: device, incomingDirectory: incoming) }
            },
            Task { [weak self] in
                await self?.routeLoop(.internet, after: 1.5) { try await LinkClient.connectInternet(to: $0, as: device, incomingDirectory: incoming) }
            },
        ]
        // Only once allowed: starting it earlier would show iOS's prompt at a random moment.
        if LinkBluetooth.isAllowed { startBluetoothLoop() }
        updateStatus()
    }

    private func startBluetoothLoop() {
        let device = ThisDevice.link
        let incoming = ThisDevice.incomingDirectory
        let task = Task<Void, Never> { [weak self] in
            await self?.routeLoop(.bluetooth, after: 3) { try await LinkClient.connectBluetooth(to: $0, as: device, incomingDirectory: incoming) }
        }
        bluetoothTask = task
        routeTasks.append(task)
    }

    private func routeLoop(_ route: LinkRoute, after delay: Double, connect: @escaping (LinkPairing) async throws -> LinkSession) async {
        var backoff: UInt64 = 1
        var waited = 0.0
        while !Task.isCancelled, isActive, let mac {
            if delay > 0 {
                // A fallback: only while nothing faster is up, and not before `delay`.
                if let best = sessions.keys.min(), best < route {
                    waited = 0
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }
                if waited < delay {
                    waited += 0.5
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }
                if route == .internet, mac.relay == nil {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
            }
            if sessions[route] != nil {
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
            do {
                let session = try await connect(mac)
                guard !Task.isCancelled else { await session.close(); return }
                adopt(session)
                backoff = 1
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                if route == .local { lastFailure = error.localizedDescription }
                updateStatus()
                try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                backoff = min(backoff * 2, 16)
            }
        }
    }

    private func adopt(_ session: LinkSession) {
        guard let mac, session.channel.pairingID == mac.id else {
            Task { await session.close() }
            return
        }
        let route = session.route
        if let old = sessions[route], old !== session { Task { await old.close() } }
        sessions[route] = session
        lastFailure = nil
        updateStatus()
        Task {
            if let relay = await session.peerRelay { learnRelay(relay, for: mac.id) }
        }
        pruneSlowRoutes()
        processQueue()
        Task {
            await session.run(onReceive: { [weak self] item in
                try await self?.receive(item)
            }, onProgress: { [weak self] name, fraction in
                Task { @MainActor in self?.incomingProgress = fraction < 1 ? (name, fraction) : nil }
            })
            if sessions[route] === session { sessions[route] = nil }
            incomingProgress = nil
            updateStatus()
            processQueue()
        }
    }

    /// The internet and Bluetooth step back once something faster is up.
    private func pruneSlowRoutes() {
        guard let best = sessions.keys.min() else { return }
        for (route, session) in sessions where route > best && route >= .internet && session !== sendingSession {
            sessions[route] = nil
            Task { await session.close() }
        }
        updateStatus()
    }

    /// The Mac names its relay in every hello, so it can be set up after pairing.
    private func learnRelay(_ relay: URL, for id: String) {
        guard let index = stored.pairings.firstIndex(where: { $0.id == id }), stored.pairings[index].relay != relay else { return }
        stored.pairings[index].relay = relay
        PairingKeychain.save(stored)
    }

    /// Publishes only real changes, so the screen doesn't redraw for nothing.
    private func updateStatus() {
        let new: Status
        if mac == nil {
            new = .unpaired
        } else if let session {
            new = .connected(session.route, session.routeTitle)
        } else if let lastFailure {
            new = .failed(lastFailure)
        } else {
            new = .searching
        }
        if status != new { status = new }
    }

    // MARK: Sending

    /// Takes ownership of `urls` (copies in a temporary folder) and sends them.
    func send(files urls: [URL]) {
        outgoing += urls.map { Outgoing(name: $0.lastPathComponent, content: .file($0)) }
        processQueue()
    }

    func send(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        outgoing.append(Outgoing(name: trimmed, content: .text(text)))
        processQueue()
    }

    func retry(_ id: UUID) {
        guard let index = outgoing.firstIndex(where: { $0.id == id }) else { return }
        outgoing[index].state = .waiting
        processQueue()
    }

    func clearFinished() {
        for item in outgoing where item.state == .sent { cleanUp(item) }
        outgoing.removeAll { $0.state == .sent }
    }

    func remove(_ id: UUID) {
        guard let item = outgoing.first(where: { $0.id == id }), !item.isSending else { return }
        cleanUp(item)
        outgoing.removeAll { $0.id == id }
    }

    /// Copies picked files somewhere the app owns until they're sent.
    nonisolated static func stage(_ url: URL, named name: String? = nil) throws -> URL {
        let folder = outgoingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = linkSafeFileName(name ?? url.lastPathComponent)
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            let target = folder.appendingPathComponent(name)
            try FileManager.default.copyItem(at: url, to: target)
            return target
        }
        // Folders travel zipped: the coordinator's `.forUploading` read makes the zip.
        let target = folder.appendingPathComponent(name + ".zip")
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .forUploading, error: &coordinationError) { zip in
            do { try FileManager.default.copyItem(at: zip, to: target) } catch { copyError = error }
        }
        if let error = coordinationError ?? copyError { throw error }
        return target
    }

    private func processQueue() {
        guard queueTask == nil, session != nil else { return }
        queueTask = Task { [weak self] in
            await self?.drain()
            self?.queueTask = nil
            self?.pruneSlowRoutes()
            self?.finishBackgroundWorkIfDone()
        }
    }

    /// Each item goes over the fastest route at the moment it starts.
    private func drain() async {
        defer { sendingSession = nil }
        while let index = outgoing.firstIndex(where: { $0.state == .waiting }), let session {
            let item = outgoing[index]
            sendingSession = session
            setState(item.id, .sending(0))
            do {
                switch item.content {
                case .file(let url):
                    try await session.sendFile(url) { fraction in
                        Task { @MainActor [weak self] in
                            guard self?.outgoing.first(where: { $0.id == item.id })?.isSending == true else { return }
                            self?.setState(item.id, .sending(fraction))
                        }
                    }
                case .text(let text):
                    try await session.sendText(text)
                }
                setState(item.id, .sent)
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            } catch LinkError.closed {
                // That route went away: the next one takes it from the start.
                setState(item.id, .waiting)
                if let route = sessions.first(where: { $0.value === session })?.key { sessions[route] = nil }
                updateStatus()
            } catch {
                setState(item.id, .failed(error.localizedDescription))
            }
            pruneSlowRoutes()
        }
    }

    private func setState(_ id: UUID, _ state: Outgoing.State) {
        guard let index = outgoing.firstIndex(where: { $0.id == id }) else { return }
        outgoing[index].state = state
    }

    private func cleanUp(_ item: Outgoing) {
        if case .file(let url) = item.content, url.path.hasPrefix(Self.outgoingDirectory.path) {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }

    private func finishBackgroundWorkIfDone() {
        guard !isActive, !outgoing.contains(where: { $0.state == .waiting || $0.isSending }) else { return }
        disconnect()
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: Receiving

    private func receive(_ item: LinkSession.Incoming) throws {
        switch item {
        case .file(let temporary, let name):
            let target = linkUniqueURL(for: name, in: Self.receivedDirectory)
            try FileManager.default.moveItem(at: temporary, to: target)
            received.insert(Received(url: target, date: Date()), at: 0)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .text(let text):
            UIPasteboard.general.string = text
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    func deleteReceived(_ item: Received) {
        try? FileManager.default.removeItem(at: item.url)
        received.removeAll { $0.url == item.url }
    }

    private func loadReceived() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: Self.receivedDirectory, includingPropertiesForKeys: keys)) ?? []
        received = urls.map { url in
            Received(url: url, date: (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.date > $1.date }
    }
}

extension MacLink.Outgoing {
    var isSending: Bool {
        if case .sending = state { return true }
        return false
    }
}
