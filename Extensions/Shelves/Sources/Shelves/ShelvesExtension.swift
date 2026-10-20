import AppKit
import Combine
import SwiftUI
import XNotchKit

@objc(ShelvesPrincipal)
public final class ShelvesPrincipal: NSObject, XNotchExtensionPrincipal {
    public override init() { super.init() }

    @MainActor public func makeExtension() -> AnyObject { ShelvesExtension() }
}

/// Dropover-style floating shelves: shake the pointer while dragging files
/// (or hold a modifier key) and a shelf appears under it. Drop files there,
/// drag them out later, or drop them on an instant action.
@MainActor
final class ShelvesExtension: XNotchExtension {
    static let id: ExtensionID = "shelves"
    static let pageID = "recent"

    private var host: ExtensionHost?
    private var preferences: ShelvesPreferences?
    private var library: ShelfLibrary?
    private var dragMonitor: DragMonitor?
    /// The shelf the current drag shook out, until that drag lets go.
    private weak var shakenShelf: ShelfController?
    private let folderMonitor = FolderMonitor()
    private var observers: Set<AnyCancellable> = []

    func activate(host: ExtensionHost) throws {
        self.host = host
        let preferences = ShelvesPreferences(defaults: host.storage.defaults)
        let library = ShelfLibrary(directory: host.storage.directory, preferences: preferences)
        library.sendToNotchShelf = { [weak host] urls in host?.shelf.add(urls) }
        library.openSettings = { [weak host] in host?.notch.openSettings() }
        library.tick = { [weak host] in host?.feedback.tick() }
        library.sharedActions = { [weak host] request in
            (host?.shelf as? ShelfActionSharing)?.sharedShelfActions(for: request) ?? []
        }
        library.load()

        let dragMonitor = DragMonitor(preferences: preferences)
        dragMonitor.onTrigger = { [weak self, weak library, weak host] point in
            self?.shakenShelf = library?.newShelf(centeredAt: point)
            host?.feedback.tick()
        }
        dragMonitor.onTriggeringDragEnded = { [weak self] in
            self?.shakenShelf?.triggeringDragEnded()
            self?.shakenShelf = nil
        }
        dragMonitor.start()

        folderMonitor.onNewFiles = { [weak library] urls, folder in library?.show(urls, from: folder) }
        folderMonitor.update(preferences.watchedFolders)
        preferences.$watchedFolders.dropFirst().sink { [weak self] folders in
            self?.folderMonitor.update(folders)
        }.store(in: &observers)

        self.preferences = preferences
        self.library = library
        self.dragMonitor = dragMonitor
        host.log.info("Shelves activated with \(library.recent.count) recent shelves")
    }

    func deactivate() {
        dragMonitor?.stop()
        folderMonitor.stop()
        library?.dismissAll()
        observers.removeAll()
        dragMonitor = nil
        library = nil
        preferences = nil
        host = nil
    }
}

extension ShelvesExtension: NotchPageProviding {
    var pages: [NotchPageDescriptor] {
        [NotchPageDescriptor(id: Self.pageID, title: "Shelves", symbol: "rectangle.stack.fill")]
    }

    func makePageView(for page: NotchPageDescriptor, context: NotchPageContext) -> AnyView {
        guard let library else { return AnyView(EmptyView()) }
        return AnyView(ShelvesPage(library: library, size: context.size, isActive: context.isActive,
                                   close: { [weak host] in host?.notch.close() }))
    }
}

extension ShelvesExtension: SettingsPaneProviding {
    func makeSettingsPane() -> AnyView {
        guard let preferences, let library else { return AnyView(EmptyView()) }
        return AnyView(ShelvesSettingsPane(preferences: preferences, library: library, folderMonitor: folderMonitor,
                                           chooseFolders: { [weak host] in host?.workspace.chooseFolders(prompt: "Monitor") ?? [] }))
    }
}

extension ShelvesExtension: ShelfAccessoryProviding {
    func makeShelfAccessory(context: ShelfContext) -> AnyView? { nil }

    /// The notch shelf's files can move to a floating shelf.
    func shelfMenuItems(for files: [URL]) -> [NotchMenuItem] {
        guard let library else { return [] }
        return [.action("Open in Floating Shelf", symbol: "rectangle.stack") { [weak host] in
            library.newShelfUnderNotch(files: files)
            host?.notch.close()
        }]
    }
}
