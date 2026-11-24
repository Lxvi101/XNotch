import AppKit
import CryptoKit
import Combine
import Foundation
import os

/// Walkie's state and everything that talks to the server.
@MainActor
final class WalkieStore: ObservableObject {
    enum Status: Equatable {
        case needsServer
        case connecting
        case online
        case offline(String)
    }

    @Published private(set) var contacts: [Contact] = []
    @Published private(set) var chats: [String: [ChatItem]] = [:]
    @Published private(set) var status: Status = .needsServer
    @Published private(set) var online: Set<String> = []
    /// When each contact last listened, from the server's presence.
    @Published private(set) var lastSeen: [String: Date] = [:]
    /// Contacts holding our face right now.
    @Published private(set) var talking: Set<String> = []
    @Published private(set) var unread: [String: Int] = [:]
    @Published private(set) var directory: [WalkieClient.Listed] = []
    @Published var lastError: String?

    // Settings
    @Published var displayName: String { didSet { defaults.set(displayName, forKey: "name"); scheduleRegister() } }
    @Published var avatar: Data? { didSet { defaults.set(avatar, forKey: "avatar"); scheduleRegister() } }
    @Published var server: String { didSet { defaults.set(server, forKey: "server"); scheduleReconnect() } }
    @Published var token: String { didSet { WalkieKeychain.writeOwnToken(token); scheduleReconnect() } }
    @Published var listed: Bool { didSet { defaults.set(listed, forKey: "listed"); scheduleRegister() } }
    @Published var autoPlay: Bool { didSet { defaults.set(autoPlay, forKey: "autoPlay") } }
    @Published var filesToTray: Bool { didSet { defaults.set(filesToTray, forKey: "filesToTray") } }
    @Published var transcribe: Bool { didSet { defaults.set(transcribe, forKey: "transcribe") } }
    @Published var menuBarFaces: Bool { didSet { defaults.set(menuBarFaces, forKey: "menuBarFaces") } }
    /// Held anywhere to talk live to your menu bar; nil turns the keys off.
    @Published var talkShortcut: TalkShortcut? {
        didSet { defaults.set(talkShortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: "talkShortcut") }
    }
    /// Another app holds the talk keys.
    @Published var talkShortcutTaken = false
    /// Who hears you live right now.
    @Published private(set) var liveTo: Set<String> = []

    let player = VoicePlayer()
    let recorder = VoiceRecorder()
    let livePlayer = LivePlayer()
    private var liveCapture: LiveCapture?
    let disk: WalkieDisk

    /// Wired by the extension.
    var onIncoming: ((Contact, ChatItem) -> Void)?
    var onTalking: ((Contact, Bool) -> Void)?
    var onFilesReceived: (([URL]) -> Void)?
    var onReminder: ((Contact?, ChatItem) -> Void)?
    var onContactsChanged: (() -> Void)?
    /// A Focus is on: nothing plays by itself.
    var isQuiet: () -> Bool = { false }

    private let defaults: UserDefaults
    private let log: Logger
    private var identity: WalkieCrypto.Identity
    private(set) var mailbox: MailboxKeys
    private var listener: MailboxListener?
    private var presenceTimer: Timer?
    private var registerWork: DispatchWorkItem?
    private var reminderTimers: [String: Timer] = [:]
    private var talkingExpiry: [String: DispatchWorkItem] = [:]
    private var fetching: Set<String> = []
    private var maxMessage = 32 * 1024 * 1024

    convenience init(defaults: UserDefaults, directory: URL, log: Logger) throws {
        let (identity, mailbox) = try Self.loadOrCreateKeys()
        self.init(defaults: defaults, directory: directory, log: log, identity: identity, mailbox: mailbox)
    }

    private static func loadOrCreateKeys() throws -> (WalkieCrypto.Identity, MailboxKeys) {
        if let secrets = try WalkieKeychain.read() {
            let seeds = try JSONDecoder().decode(WalkieCrypto.Seeds.self, from: secrets.seeds)
            return (try WalkieCrypto.Identity(seeds: seeds), secrets.mailbox)
        }
        // First run only: `read` throws rather than return nil when the Keychain is unavailable.
        let identity = try WalkieCrypto.Identity.generate()
        let mailbox = MailboxKeys.generate()
        let seeds = try JSONEncoder().encode(identity.seeds)
        guard WalkieKeychain.write(OwnSecrets(seeds: seeds, mailbox: mailbox)) else {
            throw WalkieKeychain.ReadError.unavailable(errSecNotAvailable)
        }
        return (identity, mailbox)
    }

    private init(defaults: UserDefaults, directory: URL, log: Logger, identity: WalkieCrypto.Identity,
                 mailbox: MailboxKeys) {
        self.defaults = defaults
        self.log = log
        disk = WalkieDisk(root: directory)
        self.identity = identity
        self.mailbox = mailbox
        displayName = defaults.string(forKey: "name") ?? NSFullUserName()
        avatar = defaults.data(forKey: "avatar")
        server = defaults.string(forKey: "server") ?? ""
        token = WalkieKeychain.ownToken()
        listed = defaults.object(forKey: "listed") as? Bool ?? true
        autoPlay = defaults.object(forKey: "autoPlay") as? Bool ?? true
        filesToTray = defaults.object(forKey: "filesToTray") as? Bool ?? true
        transcribe = defaults.object(forKey: "transcribe") as? Bool ?? true
        menuBarFaces = defaults.object(forKey: "menuBarFaces") as? Bool ?? true
        if let saved = defaults.data(forKey: "talkShortcut") {
            talkShortcut = saved.isEmpty ? nil : (try? JSONDecoder().decode(TalkShortcut.self, from: saved)) ?? .standard
        } else {
            talkShortcut = .standard
        }
        contacts = disk.loadContacts().sorted { $0.addedAt < $1.addedAt }
        for contact in contacts { chats[contact.box] = disk.loadChat(contact.box) }
        unread = defaults.dictionary(forKey: "unread") as? [String: Int] ?? [:]
        player.onFinish = { [weak self] id in self?.markHeard(id) }
        livePlayer.onEnd = { [weak self] box in self?.setTalking(box, false) }
        scheduleReminders()
    }

    // MARK: Connection

    /// The server, falling back to Cloud Links' settings.
    var effectiveServer: String {
        if !server.isEmpty { return server }
        return UserDefaults(suiteName: "dev.levi.XNotch.ext.cloud")?.string(forKey: "server") ?? ""
    }

    var effectiveToken: String { token.isEmpty ? (WalkieKeychain.cloudToken() ?? "") : token }

    var usesCloudServer: Bool { server.isEmpty && !effectiveServer.isEmpty }

    private var client: WalkieClient? { WalkieClient(server: effectiveServer) }

    /// Sample people instead of a server: for trying the faces and the panel
    /// without contacts. In memory only; nothing is sent, saved or read.
    private(set) var samples = false

    func start() {
        if defaults.bool(forKey: "samplePeople") {
            loadSamples()
            return
        }
        reconnect()
    }

    func stop() {
        listener?.stop()
        listener = nil
        presenceTimer?.invalidate()
        presenceTimer = nil
        reminderTimers.values.forEach { $0.invalidate() }
        reminderTimers.removeAll()
        player.stop()
        recorder.cancel()
        endLive()
        livePlayer.stopAll()
    }

    func reconnect() {
        listener?.stop()
        listener = nil
        guard let client, !effectiveToken.isEmpty else {
            status = .needsServer
            return
        }
        status = .connecting
        Task {
            do {
                let info = try await client.info(apiToken: effectiveToken)
                guard info.walkie == true else {
                    status = .offline("This server has no Walkie yet. Update it from the Server folder.")
                    return
                }
                maxMessage = info.walkieMaxMessage ?? maxMessage
                try await register(client)
                listen(client)
                refreshDirectory()
                tellMenuBar()
            } catch {
                status = .offline(error.localizedDescription)
            }
        }
    }

    private var reconnectWork: DispatchWorkItem?

    /// Settings fields change on every keystroke; connect once typing settles.
    private func scheduleReconnect() {
        reconnectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reconnect() }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func register(_ client: WalkieClient) async throws {
        try await client.register(mailbox, card: try ownCard().base64, listed: listed, apiToken: effectiveToken)
    }

    private func scheduleRegister() {
        registerWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let client = self.client, !self.effectiveToken.isEmpty else { return }
            Task {
                try? await self.register(client)
                self.refreshDirectory()
            }
        }
        registerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func listen(_ client: WalkieClient) {
        let listener = MailboxListener(client: client, mailbox: mailbox) { [weak self] event in
            guard let self else { return }
            switch event {
            case .connected(let up):
                self.status = up ? .online : (self.status == .online ? .connecting : self.status)
            case .message(let id):
                self.fetch(id)
            case .resync:
                self.fetchAll()
            case .signal(let data):
                self.handleSignal(data)
            }
        }
        self.listener = listener
        listener.start()
        presenceTimer?.invalidate()
        presenceTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPresence() }
        }
        refreshPresence()
    }

    func refreshPresence() {
        guard !samples else { return }
        let byServer = Dictionary(grouping: contacts.filter(\.accepted), by: \.server)
        for (server, group) in byServer {
            guard let client = WalkieClient(server: server) else { continue }
            Task {
                guard let answers = try? await client.presence(of: group.map { ($0.box, $0.postToken) }) else { return }
                let parse = ISO8601DateFormatter()
                for answer in answers {
                    if answer.online { online.insert(answer.box) } else { online.remove(answer.box) }
                    if let text = answer.lastSeen, let date = parse.date(from: text) { lastSeen[answer.box] = date }
                }
            }
        }
    }

    func refreshDirectory() {
        guard !samples, let client, !effectiveToken.isEmpty else { return }
        Task {
            let listed = (try? await client.directory(apiToken: effectiveToken)) ?? []
            directory = listed.filter { $0.box != mailbox.box && !contacts.map(\.box).contains($0.box) }
        }
    }

    // MARK: Samples

    private func loadSamples() {
        samples = true
        status = .online
        let keys = WalkieCrypto.PublicKeys(kem: Data(), mldsa: Data(), ed: Data())
        func person(_ name: String, _ seed: String) -> Contact {
            let box = Data(SHA256.hash(data: Data("sample \(seed)".utf8))).hex
            return Contact(box: box, server: "https://sample.invalid", postToken: Data(count: 32), name: name, avatar: nil,
                           keys: keys, verified: true, accepted: true, knowsUs: true, addedAt: Date(), lastActivity: Date())
        }
        let mira = person("Mira Lindqvist", "mira"), jonas = person("Jonas Weber", "jonas")
        let aiko = person("Aiko Tanaka", "aiko"), sam = person("Sam Okafor", "sam")
        contacts = [mira, jonas, aiko, sam]
        online = [mira.box, aiko.box]
        lastSeen = [jonas.box: Date().addingTimeInterval(-2 * 3600), sam.box: Date().addingTimeInterval(-86_400)]
        let now = Date()
        func levels(_ seconds: Double) -> [UInt8] {
            (0..<Int(seconds * 24)).map { i in
                let t = Double(i) / 24
                return UInt8(max(10, min(255, 140 + 110 * sin(t * 5.3) * sin(t * 1.7 + 0.4))))
            }
        }
        chats[aiko.box] = [
            ChatItem(id: "s1", fromMe: false, at: now.addingTimeInterval(-7200), kind: .text, text: "Landed! Coffee tomorrow?"),
            ChatItem(id: "s2", fromMe: true, at: now.addingTimeInterval(-7100), kind: .voice,
                     text: "Yes! The usual place, around nine.", duration: 3.4, levels: levels(3.4), audio: "sample", delivery: .sent),
            ChatItem(id: "s3", fromMe: false, at: now.addingTimeInterval(-60), kind: .text,
                     text: "can you send me the deck before lunch?")
        ]
        chats[mira.box] = [
            ChatItem(id: "s4", fromMe: false, at: now.addingTimeInterval(-3600), kind: .todo,
                     text: "Book the big room for Friday", remindAt: now.addingTimeInterval(16 * 3600), done: false)
        ]
        chats[jonas.box] = []
        chats[sam.box] = []
        unread = [aiko.box: 1]
        onContactsChanged?()
    }

    // MARK: Strip

    /// The faces in the menu bar: you first (dropping on yourself keeps the
    /// files in your tray), then the people you work with right now.
    var stripPeople: [Contact] { [selfContact] + menuBarPeople }

    var menuBarPeople: [Contact] { contacts.filter(\.isInMenuBar) }

    // MARK: Menu bar

    /// Puts someone in your menu bar or takes them out, before `before` when
    /// given, and tells them: two people who have each other there can talk live.
    func setInMenuBar(_ box: String, _ inMenuBar: Bool, before: String? = nil) {
        guard let index = contacts.firstIndex(where: { $0.box == box }), contacts[index].accepted else { return }
        var contact = contacts.remove(at: index)
        contact.inMenuBar = inMenuBar
        let target = before.flatMap { b in contacts.firstIndex { $0.box == b } } ?? contacts.endIndex
        contacts.insert(contact, at: target)
        saveContacts()
        tellMenuBar()
    }

    /// Lets everyone whose place in our menu bar changed since we last said so know.
    private func tellMenuBar() {
        guard !samples, status == .online || status == .connecting else { return }
        for contact in contacts where contact.accepted && contact.toldMenuBar != contact.isInMenuBar {
            let inMenuBar = contact.isInMenuBar
            guard telling[contact.box] != inMenuBar else { continue }
            telling[contact.box] = inMenuBar
            var message = WireMessage(kind: .menuBar)
            message.active = inMenuBar
            deliver(message, to: contact, item: nil) { [weak self] sent in
                guard let self else { return }
                if self.telling[contact.box] == inMenuBar { self.telling[contact.box] = nil }
                if sent { self.update(contact.box) { $0.toldMenuBar = inMenuBar } }
                // Changed again while that was on its way.
                if self.contact(contact.box).map({ $0.isInMenuBar != inMenuBar }) == true { self.tellMenuBar() }
            }
        }
    }

    /// Menu bar news on its way, so a quick change doesn't send it twice.
    private var telling: [String: Bool] = [:]

    // MARK: Live

    /// Starts talking live to everyone in the menu bar who has you in theirs
    /// (or just `only`). False when nobody can hear you live.
    @discardableResult
    func beginLive(only: Contact? = nil) -> Bool {
        guard liveCapture == nil, !samples else { return false }
        let people = (only.map { [$0] } ?? menuBarPeople).filter(\.isLive)
        guard !people.isEmpty, recorder.micAuthorized else { return false }
        let identity = identity, box = mailbox.box
        struct Listener: Sendable {
            let contact: Contact
            let client: WalkieClient
            let session: Data
            let key: SymmetricKey
        }
        let listeners: [Listener] = people.compactMap { contact in
            guard let client = WalkieClient(server: contact.server) else { return nil }
            return Listener(contact: contact, client: client, session: Data((0..<LiveFrame.sessionBytes).map { _ in UInt8.random(in: 0...255) }),
                            key: SymmetricKey(size: .bits256))
        }
        for listener in listeners {
            var message = WireMessage(kind: .live)
            message.ref = listener.session.hex
            message.key = listener.key.withUnsafeBytes { Data($0) }
            message.active = true
            Task.detached(priority: .userInitiated) {
                guard let body = try? WireCodec.encode(message),
                      let sealed = try? WalkieCrypto.seal(body, from: identity, senderBox: box, to: listener.contact.keys,
                                                          recipientBox: listener.contact.box) else { return }
                try? await listener.client.signal(sealed, to: listener.contact.box, postToken: listener.contact.postToken)
            }
        }
        let capture: LiveCapture
        do {
            capture = try LiveCapture { packets, seq, last in
                for listener in listeners {
                    guard let frame = try? LiveFrame.seal(packets, session: listener.session, seq: seq, last: last,
                                                          key: listener.key) else { continue }
                    Task { try? await listener.client.signal(frame, to: listener.contact.box, postToken: listener.contact.postToken) }
                }
            }
            try capture.start()
        } catch {
            lastError = error.localizedDescription
            return false
        }
        liveCapture = capture
        player.stop()
        liveTo = Set(listeners.map(\.contact.box))
        return true
    }

    func endLive() {
        liveCapture?.stop()
        liveCapture = nil
        liveTo = []
    }

    var isTalkingLive: Bool { liveCapture != nil }

    static let selfBox = "walkie.me"

    var selfContact: Contact {
        Contact(box: Self.selfBox, server: "", postToken: Data(), name: displayName.isEmpty ? "Me" : displayName,
                avatar: avatar, keys: WalkieCrypto.PublicKeys(kem: Data(), mldsa: Data(), ed: Data()), verified: true,
                accepted: true, knowsUs: true, addedAt: .distantPast, lastActivity: .distantPast)
    }

    /// A contact, or you.
    func stripContact(_ box: String) -> Contact? { box == Self.selfBox ? selfContact : contact(box) }

    // MARK: Identity

    var fingerprint: Data { identity.publicKeys.fingerprint }

    func ownCard() throws -> WalkieCrypto.SignedCard {
        let card = WalkieCrypto.Card(name: displayName.isEmpty ? "XNotch" : displayName, avatar: avatar,
                                     server: client?.baseURL.absoluteString ?? effectiveServer, box: mailbox.box,
                                     keys: identity.publicKeys, created: Date())
        return try .make(card, identity: identity)
    }

    var invite: WalkieInvite? {
        guard let client else { return nil }
        return WalkieInvite(server: client.baseURL.absoluteString, box: mailbox.box, postToken: mailbox.postToken,
                            fingerprint: fingerprint)
    }

    func safetyNumber(with contact: Contact) -> String {
        WalkieCrypto.safetyNumber(fingerprint, contact.keys.fingerprint)
    }

    // MARK: Contacts

    func add(invite: WalkieInvite) async throws {
        guard invite.box != mailbox.box else { throw StoreError.ownInvite }
        guard let client = WalkieClient(server: invite.server) else { throw WalkieClient.Failure.badURL }
        let encoded = try await client.card(box: invite.box, postToken: invite.postToken)
        guard let signed = WalkieCrypto.SignedCard(base64: encoded) else { throw StoreError.badCard }
        // The invite's fingerprint pins the keys: a server can't swap them.
        let card = try signed.open(expecting: invite.fingerprint)
        guard card.box == invite.box else { throw StoreError.badCard }
        upsert(card: card, postToken: invite.postToken, verified: true, accepted: true, knowsUs: false)
    }

    func add(listed: WalkieClient.Listed) throws {
        guard let signed = WalkieCrypto.SignedCard(base64: listed.card), let token = Data(hex: listed.postToken),
              token.count == 32 else { throw StoreError.badCard }
        let card = try signed.open()
        guard card.box == listed.box else { throw StoreError.badCard }
        upsert(card: card, postToken: token, verified: false, accepted: true, knowsUs: false)
        directory.removeAll { $0.box == listed.box }
    }

    private func upsert(card: WalkieCrypto.Card, postToken: Data, verified: Bool, accepted: Bool, knowsUs: Bool) {
        if let index = contacts.firstIndex(where: { $0.box == card.box }) {
            // Keys are pinned on first sight; a card with new keys is someone else.
            guard contacts[index].keys == card.keys else { return }
            contacts[index].name = card.name
            contacts[index].avatar = card.avatar
            contacts[index].server = card.server
            contacts[index].postToken = postToken
            contacts[index].verified = contacts[index].verified || verified
            contacts[index].accepted = contacts[index].accepted || accepted
        } else {
            contacts.append(Contact(box: card.box, server: card.server, postToken: postToken, name: card.name,
                                    avatar: card.avatar, keys: card.keys, verified: verified, accepted: accepted,
                                    knowsUs: knowsUs, addedAt: Date(), lastActivity: Date()))
            chats[card.box] = chats[card.box] ?? []
        }
        saveContacts()
        refreshPresence()
        tellMenuBar()
    }

    func accept(_ contact: Contact) {
        update(contact.box) { $0.accepted = true }
        tellMenuBar()
    }

    func markVerified(_ contact: Contact) {
        update(contact.box) { $0.verified = true }
    }

    func remove(_ contact: Contact) {
        contacts.removeAll { $0.box == contact.box }
        chats[contact.box] = nil
        unread[contact.box] = nil
        disk.removeChat(contact.box)
        saveContacts()
        saveUnread()
    }

    func move(_ contact: Contact, to index: Int) {
        guard let from = contacts.firstIndex(of: contact) else { return }
        let item = contacts.remove(at: from)
        contacts.insert(item, at: min(max(0, index), contacts.count))
        saveContacts()
    }

    func contact(_ box: String) -> Contact? { contacts.first { $0.box == box } }

    private func update(_ box: String, _ change: (inout Contact) -> Void) {
        guard let index = contacts.firstIndex(where: { $0.box == box }) else { return }
        change(&contacts[index])
        saveContacts()
    }

    private func saveContacts() {
        if !samples { disk.save(contacts) }
        onContactsChanged?()
    }

    func markRead(_ box: String) {
        guard unread[box] != nil else { return }
        unread[box] = nil
        saveUnread()
        onContactsChanged?()
    }

    private func saveUnread() {
        guard !samples else { return }
        defaults.set(unread, forKey: "unread")
    }

    // MARK: Sending

    /// One take for several people: each gets their own sealed copy.
    func sendVoice(_ take: VoiceRecorder.Take, to people: [Contact]) {
        guard let audio = try? Data(contentsOf: take.url) else { return }
        for (index, contact) in people.enumerated() {
            if index == people.count - 1 {
                sendVoice(take, to: contact)
            } else {
                let copy = take.url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".m4a")
                guard (try? audio.write(to: copy)) != nil else { continue }
                sendVoice(VoiceRecorder.Take(url: copy, duration: take.duration, levels: take.levels, transcript: take.transcript),
                          to: contact)
            }
        }
    }

    func sendVoice(_ take: VoiceRecorder.Take, to contact: Contact) {
        var message = WireMessage(kind: .voice)
        message.duration = take.duration
        message.levels = take.levels
        message.text = take.transcript.isEmpty ? nil : take.transcript
        guard let audio = try? Data(contentsOf: take.url),
              let stored = try? disk.store(audio, box: contact.box, folder: message.id, name: "voice.m4a") else { return }
        try? FileManager.default.removeItem(at: take.url)
        let item = ChatItem(id: message.id, fromMe: true, at: message.at, kind: .voice, text: message.text,
                            duration: take.duration, levels: take.levels, audio: stored, delivery: .sending)
        append(item, to: contact.box)
        deliver(message, attachments: [audio], to: contact, item: item.id)
    }

    func sendFiles(_ urls: [URL], to contact: Contact) {
        var message = WireMessage(kind: .files)
        var attachments: [Data] = []
        var stored: [ChatItem.StoredFile] = []
        var files: [WireMessage.File] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            let name = url.lastPathComponent
            files.append(.init(name: name, size: data.count))
            attachments.append(data)
            if let path = try? disk.store(data, box: contact.box, folder: message.id, name: name) {
                stored.append(.init(name: name, size: data.count, path: path))
            }
        }
        guard !files.isEmpty else {
            lastError = "Folders can't go by Walkie yet. Zip it first, or use a Cloud link."
            return
        }
        let total = attachments.reduce(0) { $0 + $1.count }
        guard total < maxMessage - 64 * 1024 else {
            lastError = "That's more than your server takes in one message (\(ByteCountFormatter.string(fromByteCount: Int64(maxMessage), countStyle: .file))). Use a Cloud link instead."
            return
        }
        message.files = files
        let item = ChatItem(id: message.id, fromMe: true, at: message.at, kind: .files, files: stored, delivery: .sending)
        append(item, to: contact.box)
        deliver(message, attachments: attachments, to: contact, item: item.id)
    }

    func sendText(_ text: String, to contact: Contact) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var message = WireMessage(kind: .text)
        message.text = String(trimmed.prefix(4_000))
        let item = ChatItem(id: message.id, fromMe: true, at: message.at, kind: .text, text: message.text, delivery: .sending)
        append(item, to: contact.box)
        deliver(message, to: contact, item: item.id)
    }

    func sendTodo(_ text: String, remindAt: Date?, to contact: Contact) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var message = WireMessage(kind: .todo)
        message.text = String(trimmed.prefix(500))
        message.remindAt = remindAt
        let item = ChatItem(id: message.id, fromMe: true, at: message.at, kind: .todo, text: message.text,
                            remindAt: remindAt, done: false, delivery: .sending)
        append(item, to: contact.box)
        deliver(message, to: contact, item: item.id)
    }

    /// Ticks a to-do they handed us, and tells them.
    func toggleTodo(_ item: ChatItem, of contact: Contact) {
        let done = !(item.done ?? false)
        mutate(item.id, in: contact.box) { $0.done = done }
        if done { reminderTimers[item.id]?.invalidate() }
        var message = WireMessage(kind: .todoDone)
        message.ref = item.id
        message.done = done
        deliver(message, to: contact, item: nil)
    }

    /// Lets them see we're talking to them, before the note arrives.
    func signalTalking(_ active: Bool, to contact: Contact) {
        guard let client = WalkieClient(server: contact.server) else { return }
        var message = WireMessage(kind: .talking)
        message.active = active
        let identity = identity, box = mailbox.box
        Task.detached {
            guard let body = try? WireCodec.encode(message),
                  let sealed = try? WalkieCrypto.seal(body, from: identity, senderBox: box, to: contact.keys,
                                                      recipientBox: contact.box) else { return }
            try? await client.signal(sealed, to: contact.box, postToken: contact.postToken)
        }
    }

    func retry(_ item: ChatItem, to contact: Contact) {
        mutate(item.id, in: contact.box) { $0.delivery = .sending }
        var message = WireMessage(kind: WireMessage.Kind(rawValue: item.kind.rawValue) ?? .text, id: item.id, at: item.at)
        message.text = item.text
        message.duration = item.duration
        message.levels = item.levels
        message.remindAt = item.remindAt
        var attachments: [Data] = []
        if let audio = item.audio, let data = try? Data(contentsOf: disk.url(forMedia: audio)) { attachments = [data] }
        if let files = item.files {
            let loaded = files.compactMap { file in (try? Data(contentsOf: disk.url(forMedia: file.path))).map { (file, $0) } }
            message.files = loaded.map { .init(name: $0.0.name, size: $0.1.count) }
            attachments = loaded.map(\.1)
        }
        deliver(message, attachments: attachments, to: contact, item: item.id)
    }

    private func deliver(_ message: WireMessage, attachments: [Data] = [], to contact: Contact, item: String?,
                         onSent: ((Bool) -> Void)? = nil) {
        if samples {
            // Nobody on the other end: just mark it sent, a beat later.
            if let item {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    self?.mutate(item, in: contact.box) { $0.delivery = .sent }
                }
            }
            return
        }
        guard let client = WalkieClient(server: contact.server) else {
            onSent?(false)
            if let item { mutate(item, in: contact.box) { $0.delivery = .failed } }
            return
        }
        var message = message
        if !contact.knowsUs { message.intro = try? WireMessage.Introduction(card: ownCard().base64, postToken: mailbox.postToken.hex) }
        let identity = identity, box = mailbox.box
        let sealing = Task.detached(priority: .userInitiated) { () throws -> Data in
            let body = try WireCodec.encode(message, attachments: attachments)
            return try WalkieCrypto.seal(body, from: identity, senderBox: box, to: contact.keys, recipientBox: contact.box)
        }
        Task {
            do {
                let sealed = try await sealing.value
                try await client.post(sealed, to: contact.box, postToken: contact.postToken)
                if let item { mutate(item, in: contact.box) { if $0.delivery == .sending { $0.delivery = .sent } } }
                if let onSent {
                    onSent(true)
                } else {
                    update(contact.box) { $0.lastActivity = Date() }
                }
            } catch {
                log.error("walkie send failed: \(error.localizedDescription, privacy: .public)")
                if let item { mutate(item, in: contact.box) { $0.delivery = .failed } }
                if let onSent {
                    // Quiet: it goes again on the next connect.
                    onSent(false)
                } else {
                    lastError = error.localizedDescription
                }
            }
        }
    }

    // MARK: Receiving

    private func fetchAll() {
        guard let client else { return }
        Task {
            guard let waiting = try? await client.waiting(mailbox) else { return }
            for message in waiting { fetch(message.id) }
        }
    }

    private func fetch(_ id: String) {
        guard let client, !fetching.contains(id) else { return }
        fetching.insert(id)
        let identity = identity, mailbox = mailbox
        Task {
            defer { fetching.remove(id) }
            guard let sealed = try? await client.fetch(id, from: mailbox) else { return }
            let opened = await Task.detached { try? WalkieCrypto.open(sealed, as: identity, recipientBox: mailbox.box) }.value
            if let opened { receive(opened) } else { log.error("walkie: dropped a message that didn't open") }
            // Opened or not, it's done: anything that failed to open never will.
            try? await client.delete(id, from: mailbox)
        }
    }

    /// Checks who sent it and applies it. Unknown senders need a valid introduction.
    private func receive(_ opened: WalkieCrypto.Opened) {
        guard let (message, attachments) = try? WireCodec.decode(opened.body) else { return }
        var sender = contact(opened.senderBox)
        if sender == nil {
            guard let intro = message.intro, let signed = WalkieCrypto.SignedCard(base64: intro.card),
                  let card = try? signed.open(), card.box == opened.senderBox, opened.verify(with: card.keys),
                  let token = Data(hex: intro.postToken), token.count == 32 else { return }
            upsert(card: card, postToken: token, verified: false, accepted: false, knowsUs: true)
            sender = contact(opened.senderBox)
        }
        guard let contact = sender, opened.verify(with: contact.keys) else {
            log.error("walkie: dropped a message with a bad signature")
            return
        }
        if !contact.knowsUs { update(contact.box) { $0.knowsUs = true } }
        // A fresh intro refreshes their name, picture and server.
        if let intro = message.intro, let signed = WalkieCrypto.SignedCard(base64: intro.card),
           let card = try? signed.open(expecting: contact.keys.fingerprint), card.box == contact.box,
           let token = Data(hex: intro.postToken), token.count == 32 {
            upsert(card: card, postToken: token, verified: false, accepted: false, knowsUs: true)
        }
        apply(message, attachments: attachments, from: contact)
    }

    private func apply(_ message: WireMessage, attachments: [Data], from contact: Contact) {
        let box = contact.box
        if chats[box]?.contains(where: { $0.id == message.id && !$0.fromMe }) == true { return }
        var item: ChatItem
        switch message.kind {
        case .talking, .live:
            return
        case .menuBar:
            update(box) { $0.hasUsInMenuBar = message.active ?? false }
            return
        case .todoDone:
            guard let ref = message.ref else { return }
            mutate(ref, in: box) { if $0.fromMe { $0.done = message.done ?? true } }
            return
        case .voice:
            guard let audio = attachments.first,
                  let path = try? disk.store(audio, box: box, folder: message.id, name: "voice.m4a") else { return }
            item = ChatItem(id: message.id, fromMe: false, at: message.at, kind: .voice, text: message.text,
                            duration: message.duration, levels: message.levels, audio: path, heard: false)
        case .files:
            var stored: [ChatItem.StoredFile] = []
            for (file, data) in zip(message.files ?? [], attachments) {
                if let path = try? disk.store(data, box: box, folder: message.id, name: file.name) {
                    stored.append(.init(name: WalkieDisk.safeName(file.name), size: data.count, path: path))
                }
            }
            item = ChatItem(id: message.id, fromMe: false, at: message.at, kind: .files, files: stored)
            if filesToTray, contact.accepted { onFilesReceived?(stored.map { disk.url(forMedia: $0.path) }) }
        case .text:
            item = ChatItem(id: message.id, fromMe: false, at: message.at, kind: .text, text: message.text)
        case .todo:
            item = ChatItem(id: message.id, fromMe: false, at: message.at, kind: .todo, text: message.text,
                            remindAt: message.remindAt, done: false)
        }
        // Their clock isn't ours: order by arrival, keep their time for display.
        item.at = min(item.at, Date())
        append(item, to: box)
        setTalking(box, false)
        unread[box, default: 0] += 1
        saveUnread()
        update(box) { $0.lastActivity = Date() }
        if item.kind == .todo { scheduleReminder(item, box: box) }
        if item.kind == .voice, autoPlay, contact.accepted, !isQuiet(), let audio = item.audio {
            player.enqueue(item.id, url: disk.url(forMedia: audio))
        }
        if contact.accepted { onIncoming?(self.contact(box) ?? contact, item) }
    }

    private func handleSignal(_ data: Data) {
        if LiveFrame.isFrame(data) {
            livePlayer.receive(data)
            return
        }
        let identity = identity, box = mailbox.box
        guard let opened = try? WalkieCrypto.open(data, as: identity, recipientBox: box),
              let contact = contact(opened.senderBox), contact.accepted, opened.verify(with: contact.keys),
              let (message, _) = try? WireCodec.decode(opened.body),
              abs(message.at.timeIntervalSinceNow) < 120 else { return }
        online.insert(contact.box)
        switch message.kind {
        case .talking:
            setTalking(contact.box, message.active ?? false)
        case .live:
            // Only someone in your menu bar plays out loud; anyone else stays quiet.
            guard contact.isInMenuBar, let ref = message.ref, let session = Data(hex: ref),
                  session.count == LiveFrame.sessionBytes, let key = message.key else { return }
            if contact.hasUsInMenuBar != true { update(contact.box) { $0.hasUsInMenuBar = true } }
            livePlayer.begin(session: session, key: key, box: contact.box)
            setTalking(contact.box, true, live: true)
        default:
            break
        }
    }

    /// Their face ripples while they talk to you; a live talk also says so in the notch.
    private(set) var talkingLive: Set<String> = []

    private func setTalking(_ box: String, _ active: Bool, live: Bool = false) {
        talkingExpiry[box]?.cancel()
        if active, live { talkingLive.insert(box) } else if !active { talkingLive.remove(box) }
        guard active != talking.contains(box) else { return }
        if active {
            talking.insert(box)
            // A lost "stopped" signal doesn't leave them talking forever.
            let work = DispatchWorkItem { [weak self] in self?.setTalking(box, false) }
            talkingExpiry[box] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + VoiceRecorder.maxDuration + 10, execute: work)
        } else {
            talking.remove(box)
        }
        if let contact = contact(box) { onTalking?(contact, active) }
    }

    func markHeard(_ id: String) {
        for (box, items) in chats {
            if let index = items.firstIndex(where: { $0.id == id && !$0.fromMe }) {
                chats[box]?[index].heard = true
                disk.save(chats[box] ?? [], for: box)
            }
        }
    }

    // MARK: Chats

    private func append(_ item: ChatItem, to box: String) {
        var chat = chats[box] ?? []
        chat.append(item)
        // Plenty for a notch; older lines go, their files stay on disk until the contact is removed.
        if chat.count > 400 { chat.removeFirst(chat.count - 400) }
        chats[box] = chat
        if !samples { disk.save(chat, for: box) }
    }

    private func mutate(_ id: String, in box: String, _ change: (inout ChatItem) -> Void) {
        guard let index = chats[box]?.firstIndex(where: { $0.id == id }) else { return }
        change(&chats[box]![index])
        if !samples { disk.save(chats[box] ?? [], for: box) }
    }

    func mediaURL(_ path: String) -> URL { disk.url(forMedia: path) }

    // MARK: Reminders

    private func scheduleReminders() {
        for (box, items) in chats {
            for item in items where item.kind == .todo && !(item.done ?? false) && !item.fromMe {
                scheduleReminder(item, box: box)
            }
        }
    }

    private func scheduleReminder(_ item: ChatItem, box: String) {
        guard let at = item.remindAt, at > Date().addingTimeInterval(-60) else { return }
        reminderTimers[item.id]?.invalidate()
        let timer = Timer(fire: max(at, Date().addingTimeInterval(1)), interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, let current = self.chats[box]?.first(where: { $0.id == item.id }),
                      !(current.done ?? false) else { return }
                self.onReminder?(self.contact(box), current)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        reminderTimers[item.id] = timer
    }

    enum StoreError: LocalizedError {
        case ownInvite, badCard

        var errorDescription: String? {
            switch self {
            case .ownInvite: "That's your own invite. Send it to someone else."
            case .badCard: "That invite's card didn't check out. Ask for a new invite."
            }
        }
    }
}

#if DEBUG
// MARK: Demo

/// Scripted state for recordings and previews: no Keychain, no server.
extension WalkieStore {
    static func demo(directory: URL) throws -> WalkieStore {
        let defaults = UserDefaults(suiteName: "dev.levi.XNotch.walkie.demo") ?? .standard
        defaults.removePersistentDomain(forName: "dev.levi.XNotch.walkie.demo")
        let store = WalkieStore(defaults: defaults, directory: directory, log: Logger(subsystem: "walkie", category: "demo"),
                                identity: try .generate(), mailbox: .generate())
        store.status = .online
        return store
    }

    func demoSet(contacts: [Contact]) { self.contacts = contacts }
    func demoSet(online: Set<String>) { self.online = online }
    func demoSet(status: Status) { self.status = status }
    func demoSet(talking: Set<String>) { self.talking = talking }
    func demoSet(lastSeen: [String: Date]) { self.lastSeen = lastSeen }
    func demoSet(unread: [String: Int]) { self.unread = unread }
    func demoSet(chat: [ChatItem], for box: String) { chats[box] = chat }
    func demoAppend(_ item: ChatItem, to box: String) { chats[box, default: []].append(item) }
    func demoUpdate(_ id: String, in box: String, _ change: (inout ChatItem) -> Void) {
        guard let index = chats[box]?.firstIndex(where: { $0.id == id }) else { return }
        change(&chats[box]![index])
    }
}
#endif
