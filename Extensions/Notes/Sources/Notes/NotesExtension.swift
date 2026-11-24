import AppKit
import Combine
import SwiftUI
import XNotchKit

@objc(NotesPrincipal)
public final class NotesPrincipal: NSObject, XNotchExtensionPrincipal {
    public override init() { super.init() }

    @MainActor public func makeExtension() -> AnyObject { NotesExtension() }
}

/// Mote-style markdown sticky notes: each floats on its own, keeps a bucket
/// of files, and belongs to a space you switch between from the notch.
@MainActor
final class NotesExtension: XNotchExtension {
    static let id: ExtensionID = "notes"
    static let pageID = "notes"

    private var host: ExtensionHost?
    private var preferences: NotesPreferences?
    private var library: NoteLibrary?
    private var observers: Set<AnyCancellable> = []
    private var terminationObserver: NSObjectProtocol?
    private var hotKey: GlobalHotKey?
    private var isGuiding = false

    func activate(host: ExtensionHost) throws {
        self.host = host
        let preferences = NotesPreferences(defaults: host.storage.defaults)
        let library = NoteLibrary(root: host.storage.directory, preferences: preferences)
        library.tick = { [weak host] in host?.feedback.tick() }
        library.openSettings = { [weak host] in host?.notch.openSettings() }
        library.sendToTray = { [weak host] urls in host?.shelf.add(urls) }
        library.load()
        library.restore()
        library.startCloud()

        preferences.objectWillChange.sink { [weak library] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { library?.applyWindowPreferences() } }
        }.store(in: &observers)
        preferences.$syncICloud.dropFirst().removeDuplicates().sink { [weak library] on in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { on ? library?.startCloud() : library?.stopCloud() }
            }
        }.store(in: &observers)

        let hotKey = GlobalHotKey { [weak library, weak host] in
            library?.toggleVisibility(focusing: true)
            host?.feedback.tick()
        }
        hotKey.onRecovered = { [weak preferences] in preferences?.toggleShortcutProblem = nil }
        preferences.$toggleShortcut.removeDuplicates().sink { [weak preferences, weak hotKey] shortcut in
            let problem = hotKey?.register(shortcut)
            if preferences?.toggleShortcutProblem != problem { preferences?.toggleShortcutProblem = problem }
        }.store(in: &observers)
        preferences.requestAccessibility = { [weak self] in
            Task { @MainActor in _ = await self?.requestPermission("accessibility") }
        }
        self.hotKey = hotKey
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                     object: nil, queue: .main) { [weak library] _ in
            MainActor.assumeIsolated { library?.saveNow() }
        }

        self.preferences = preferences
        self.library = library
        host.log.info("Notes activated with \(library.notes.count) notes in \(library.spaces.count) spaces")
    }

    func deactivate() {
        hotKey?.unregister()
        hotKey = nil
        library?.dismissAll()
        library?.stopCloud()
        observers.removeAll()
        terminationObserver.map(NotificationCenter.default.removeObserver)
        terminationObserver = nil
        library = nil
        preferences = nil
        host = nil
    }
}

extension NotesExtension: PermissionRequesting {
    /// Only a right-side shortcut needs Accessibility; the usual ones don't.
    var pendingPermissions: [ExtensionPermission] {
        guard preferences?.toggleShortcut?.isSideSpecific == true, !AXIsProcessTrusted() else { return [] }
        return [ExtensionPermission(id: "accessibility", title: "Right-side shortcut", detail: "Accessibility",
                                    reason: "Your notes shortcut uses a key on the right side of the keyboard. Telling right from left means reading key presses, which macOS allows only with Accessibility.",
                                    symbol: "keyboard", tint: "#FFD60A")]
    }

    func requestPermission(_ id: String) async -> Bool {
        guard id == "accessibility" else { return false }
        if AXIsProcessTrusted() { return true }
        if let guide = host as? PermissionGuiding {
            guard !isGuiding else { return false }
            isGuiding = true
            defer { isGuiding = false }
            return await guide.guide(.accessibility, for: Bundle.main.bundleURL) { AXIsProcessTrusted() }
        }
        return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
}

extension NotesExtension: NotchPageProviding {
    var pages: [NotchPageDescriptor] {
        [NotchPageDescriptor(id: Self.pageID, title: "Notes", symbol: "note.text", contentHeight: 108)]
    }

    func makePageView(for page: NotchPageDescriptor, context: NotchPageContext) -> AnyView {
        guard let library else { return AnyView(EmptyView()) }
        return AnyView(NotesPage(library: library, size: context.size, close: { [weak host] in host?.notch.close() }))
    }
}

extension NotesExtension: SettingsPaneProviding {
    func makeSettingsPane() -> AnyView {
        guard let preferences, let library else { return AnyView(EmptyView()) }
        return AnyView(NotesSettingsPane(preferences: preferences, library: library))
    }
}

extension NotesExtension: ShelfAccessoryProviding {
    func makeShelfAccessory(context: ShelfContext) -> AnyView? { nil }

    /// Tray files can go into an open note's bucket.
    func shelfMenuItems(for files: [URL]) -> [NotchMenuItem] {
        guard let library else { return [] }
        return library.openControllers.prefix(4).map { controller in
            .action("Add to “\(controller.note.displayTitle)” Bucket", symbol: "tray.and.arrow.down") {
                controller.attach(files)
                controller.bringToFront(focus: false)
            }
        }
    }
}
