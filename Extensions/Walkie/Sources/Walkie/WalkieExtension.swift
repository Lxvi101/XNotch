import AVFoundation
import Combine
import AppKit
import SwiftUI
import XNotchKit

@objc(WalkiePrincipal)
public final class WalkiePrincipal: NSObject, XNotchExtensionPrincipal {
    public override init() { super.init() }

    @MainActor public func makeExtension() -> AnyObject { WalkieExtension() }
}

@MainActor
final class WalkieExtension: XNotchExtension, NotchPageProviding, SettingsPaneProviding, NotchDropTargetProviding,
    PermissionRequesting, NotchAlertResponding {
    static let id: ExtensionID = "walkie"
    static let pageID = "walkie"

    private var host: ExtensionHost?
    private var store: WalkieStore?
    private var ui: WalkieUI?
    private var faceCache: [String: Data] = [:]
    private var menuBar: MenuBarController?
    private var menuBarSetting: AnyCancellable?
    /// Whose conversation a click on the showing alert opens. Each alert
    /// replaces the last, so only the newest needs remembering.
    private var alertConversation: (alert: NotchAlert, box: String)?
    private var messageConversation: (message: NotchMessage, box: String)?
    private var pushToTalk: PushToTalkKey?
    private var shortcutSetting: AnyCancellable?
    /// Held keys with nobody to hear you live: a voice note for these people.
    private var keyNoteTo: [Contact] = []

    func activate(host: ExtensionHost) throws {
        self.host = host
        let store = try WalkieStore(defaults: host.storage.defaults, directory: host.storage.directory, log: host.log)
        let ui = WalkieUI()
        ui.onHeightChange = { [weak host] in host?.notch.pagesDidChange() }
        store.onContactsChanged = { [weak self, weak host] in
            self?.faceCache.removeAll()
            host?.notch.pagesDidChange()
        }
        store.isQuiet = { [weak self] in self?.focusOn ?? false }
        store.onIncoming = { [weak self] contact, item in
            // A Focus keeps it to the unread dot: no tick, no banner.
            guard let self, !self.focusOn else { return }
            self.host?.feedback.tick()
            self.showMessage(about: item, from: contact)
        }
        store.onTalking = { [weak self, weak host] contact, active in
            guard active, let self, let host, !host.notch.isOpen else { return }
            let live = self.store?.talkingLive.contains(contact.box) == true
            // Someone you live with may still talk through a Focus; nothing else rings.
            guard live || !self.focusOn else { return }
            self.showAlert(NotchAlert(symbol: live ? "dot.radiowaves.left.and.right" : "mic.fill",
                                      tint: FacePalette.tintHex(for: contact.box), title: contact.firstName,
                                      value: live ? "live" : "talking", page: Self.pageID), about: contact.box)
        }
        store.onFilesReceived = { [weak host] urls in host?.shelf.add(urls) }
        store.onReminder = { [weak self] contact, item in
            guard self?.focusOn == false else { return }
            self?.showAlert(NotchAlert(symbol: "bell.fill", tint: "#FFB340",
                                       title: contact?.firstName ?? "To-do",
                                       value: String((item.text ?? "To-do").prefix(10)), page: Self.pageID),
                            about: contact?.box)
        }
        store.start()
        menuBarSetting = store.$menuBarFaces.removeDuplicates().sink { [weak self, weak host, weak store] on in
            guard let self, let store else { return }
            if on, self.menuBar == nil {
                let menuBar = MenuBarController(store: store, openSettings: { host?.notch.openSettings() }, tick: { host?.feedback.tick() })
                menuBar.onDropToSelf = { urls in host?.shelf.add(urls) }
                self.menuBar = menuBar
            } else if !on {
                self.menuBar?.remove()
                self.menuBar = nil
            }
        }
        self.store = store
        self.ui = ui
        let key = PushToTalkKey(onPress: { [weak self] in self?.keyPressed() },
                                onRelease: { [weak self] in self?.keyReleased() })
        shortcutSetting = store.$talkShortcut.removeDuplicates().sink { [weak store, weak key] shortcut in
            store?.talkShortcutTaken = key?.register(shortcut) == false
        }
        pushToTalk = key
    }

    func deactivate() {
        shortcutSetting = nil
        pushToTalk?.unregister()
        pushToTalk = nil
        keyNoteTo = []
        menuBarSetting = nil
        menuBar?.remove()
        menuBar = nil
        store?.stop()
        store = nil
        ui = nil
        host = nil
        alertConversation = nil
        messageConversation = nil
        faceCache.removeAll()
    }

    // MARK: Page

    var pages: [NotchPageDescriptor] {
        guard let store, let ui else { return [] }
        let unread = store.unread.values.reduce(0, +)
        return [NotchPageDescriptor(id: Self.pageID, title: "Walkie", symbol: "waveform",
                                    contentHeight: ui.contentHeight, badge: unread)]
    }

    func makePageView(for page: NotchPageDescriptor, context: NotchPageContext) -> AnyView {
        guard let store, let ui else {
            return AnyView(EmptyView())
        }
        return AnyView(WalkiePage(store: store, ui: ui, isActive: context.isActive,
                                  openSettings: { [weak host] in host?.notch.openSettings() },
                                  tick: { [weak host] in host?.feedback.tick() }))
    }

    // MARK: Drop targets

    var dropTargets: [NotchDropTarget] {
        guard let store else { return [] }
        return store.contacts.filter(\.accepted).map { contact in
            let image = faceCache[contact.box] ?? FaceImage.png(name: contact.name, seed: contact.box, avatar: contact.avatar)
            faceCache[contact.box] = image
            return NotchDropTarget(id: contact.box, title: contact.firstName, image: image,
                                   tint: FacePalette.tintHex(for: contact.box))
        }
    }

    func performDrop(_ urls: [URL], on target: String) {
        guard let store, let contact = store.contact(target) else { return }
        store.sendFiles(urls, to: contact)
        showAlert(NotchAlert(symbol: "paperplane.fill", tint: FacePalette.tintHex(for: contact.box),
                             title: contact.firstName,
                             value: urls.count == 1 ? "sent" : "\(urls.count) sent", page: Self.pageID),
                  about: contact.box)
    }

    // MARK: Talk keys

    /// Live to everyone in the menu bar who has you in theirs; with nobody
    /// live, a voice note to everyone in the menu bar instead.
    private func keyPressed() {
        guard let store, let host, !store.isTalkingLive, !store.recorder.isRecording else { return }
        guard store.recorder.micAuthorized else {
            Task { _ = await VoiceRecorder.requestMic() }
            return
        }
        if store.beginLive() {
            host.feedback.tick()
            let listening = store.menuBarPeople.filter { store.liveTo.contains($0.box) }
            host.notch.showAlert(NotchAlert(symbol: "dot.radiowaves.left.and.right", tint: "#FF6A3D", title: "Live",
                                            value: listening.count == 1 ? listening[0].firstName : "\(listening.count) people"))
            return
        }
        let people = store.menuBarPeople
        guard !people.isEmpty else {
            host.notch.showAlert(NotchAlert(symbol: "menubar.rectangle", tint: "#FF6A3D", title: "Walkie", value: "no one",
                                            page: Self.pageID))
            return
        }
        do {
            try store.recorder.start(directory: FileManager.default.temporaryDirectory.appendingPathComponent("XNotchWalkie"),
                                     transcribe: store.transcribe) { [weak self] in self?.keyReleased() }
        } catch {
            store.lastError = error.localizedDescription
            return
        }
        keyNoteTo = people
        host.feedback.tick()
        store.player.stop()
        for person in people { store.signalTalking(true, to: person) }
        host.notch.showAlert(NotchAlert(symbol: "mic.fill", tint: "#FF6A3D", title: "Note",
                                        value: people.count == 1 ? people[0].firstName : "\(people.count) people"))
    }

    private func keyReleased() {
        guard let store else { return }
        if store.isTalkingLive {
            store.endLive()
            host?.feedback.tick()
            return
        }
        let people = keyNoteTo
        keyNoteTo = []
        guard !people.isEmpty, store.recorder.isRecording else { return }
        for person in people { store.signalTalking(false, to: person) }
        Task {
            guard let take = await store.recorder.stop() else { return }
            host?.feedback.tick()
            store.sendVoice(take, to: people)
        }
    }

    // MARK: Alerts

    private var focusOn: Bool { (host as? FocusReading)?.isFocusOn ?? false }

    /// A banner like a phone's: their face, their name, the start of it.
    private func showMessage(about item: ChatItem, from contact: Contact) {
        let tint = FacePalette.tintHex(for: contact.box)
        let (symbol, text): (String, String)
        switch item.kind {
        case .voice:
            let transcript = item.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            symbol = "waveform"
            text = transcript.isEmpty ? "Voice note · \(Durations.clock(item.duration ?? 0))" : transcript
        case .files:
            let files = item.files ?? []
            symbol = "doc.fill"
            text = files.count == 1 ? files[0].name : "\(files.count) files"
        case .text:
            symbol = "text.bubble.fill"
            text = item.text ?? ""
        case .todo:
            symbol = "checklist"
            text = "To-do: \(item.text ?? "")"
        }
        guard let notch = host?.notch as? NotchMessageAlerting else {
            // An older XNotch: the wings it knows.
            showAlert(NotchAlert(symbol: symbol, tint: tint, title: contact.firstName, value: "message", page: Self.pageID),
                      about: contact.box)
            return
        }
        let message = NotchMessage(sender: contact.name, text: text, image: contact.avatar, tint: tint, symbol: symbol,
                                   page: Self.pageID)
        messageConversation = (message, contact.box)
        notch.showMessage(message)
    }

    func didOpen(_ message: NotchMessage) {
        guard let target = messageConversation, target.message == message else { return }
        messageConversation = nil
        openConversation(target.box)
    }

    private func showAlert(_ alert: NotchAlert, about box: String?) {
        alertConversation = box.map { (alert, $0) }
        host?.notch.showAlert(alert)
    }

    /// A click on the alert opens the conversation it's about, not the faces.
    func didOpen(_ alert: NotchAlert) {
        guard let target = alertConversation, target.alert == alert else { return }
        alertConversation = nil
        openConversation(target.box)
    }

    private func openConversation(_ box: String) {
        guard let store, let ui, store.contact(box) != nil else { return }
        store.markRead(box)
        ui.show(.chat(box), animated: false)
    }

    // MARK: Settings

    func makeSettingsPane() -> AnyView {
        guard let store else { return AnyView(EmptyView()) }
        return AnyView(WalkieSettingsPane(store: store))
    }

    // MARK: Permissions

    var pendingPermissions: [ExtensionPermission] {
        guard store != nil, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return [] }
        return [ExtensionPermission(id: "microphone", title: "Talk with Walkie", detail: "Microphone",
                                    reason: "Walkie records a voice note only while you hold someone's face, and sends it end-to-end encrypted.",
                                    symbol: "mic.fill", tint: "#FF6A3D")]
    }

    func requestPermission(_ id: String) async -> Bool {
        guard id == "microphone" else { return false }
        let granted = await VoiceRecorder.requestMic()
        if granted { _ = await VoiceRecorder.requestSpeech() }
        return granted
    }
}
