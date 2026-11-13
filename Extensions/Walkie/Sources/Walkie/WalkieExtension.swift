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
    PermissionRequesting {
    static let id: ExtensionID = "walkie"
    static let pageID = "walkie"

    private var host: ExtensionHost?
    private var store: WalkieStore?
    private var ui: WalkieUI?
    private var faceCache: [String: Data] = [:]
    private var menuBar: MenuBarController?
    private var menuBarSetting: AnyCancellable?

    func activate(host: ExtensionHost) throws {
        self.host = host
        let store = try WalkieStore(defaults: host.storage.defaults, directory: host.storage.directory, log: host.log)
        let ui = WalkieUI()
        ui.onHeightChange = { [weak host] in host?.notch.pagesDidChange() }
        store.onContactsChanged = { [weak self, weak host] in
            self?.faceCache.removeAll()
            host?.notch.pagesDidChange()
        }
        store.onIncoming = { [weak host] contact, item in
            guard let host else { return }
            host.feedback.tick()
            let (symbol, value): (String, String) = switch item.kind {
            case .voice: ("waveform", Durations.clock(item.duration ?? 0))
            case .files: ("doc.fill", (item.files?.count ?? 0) == 1 ? "1 file" : "\(item.files?.count ?? 0) files")
            case .text: ("text.bubble.fill", "message")
            case .todo: ("checklist", "to-do")
            }
            host.notch.showAlert(NotchAlert(symbol: symbol, tint: FacePalette.tintHex(for: contact.box),
                                            title: contact.firstName, value: value, page: Self.pageID))
        }
        store.onTalking = { [weak host] contact, active in
            guard active, let host, !host.notch.isOpen else { return }
            host.notch.showAlert(NotchAlert(symbol: "mic.fill", tint: FacePalette.tintHex(for: contact.box),
                                            title: contact.firstName, value: "talking", page: Self.pageID))
        }
        store.onFilesReceived = { [weak host] urls in host?.shelf.add(urls) }
        store.onReminder = { [weak host] contact, item in
            host?.notch.showAlert(NotchAlert(symbol: "bell.fill", tint: "#FFB340",
                                             title: contact?.firstName ?? "To-do",
                                             value: String((item.text ?? "To-do").prefix(10)), page: Self.pageID))
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
    }

    func deactivate() {
        menuBarSetting = nil
        menuBar?.remove()
        menuBar = nil
        store?.stop()
        store = nil
        ui = nil
        host = nil
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
        host?.notch.showAlert(NotchAlert(symbol: "paperplane.fill", tint: FacePalette.tintHex(for: contact.box),
                                         title: contact.firstName,
                                         value: urls.count == 1 ? "sent" : "\(urls.count) sent", page: Self.pageID))
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
