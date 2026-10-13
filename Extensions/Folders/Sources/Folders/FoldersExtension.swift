import AppKit
import XNotchKit
import SwiftUI

@objc(FoldersPrincipal)
public final class FoldersPrincipal: NSObject, XNotchExtensionPrincipal {
    public override init() { super.init() }

    @MainActor public func makeExtension() -> AnyObject { FoldersExtension() }
}

@MainActor
final class FoldersExtension: XNotchExtension {
    static let id: ExtensionID = "folders"
    static let pageID = "folders"

    let store = FolderStore()
    private var host: ExtensionHost?

    func activate(host: ExtensionHost) throws {
        self.host = host
        store.load(from: host.storage.directory, defaults: host.storage.defaults)
        host.log.info("Folders activated with \(self.store.folders.count) folders")
    }

    func deactivate() {
        host = nil
    }

    func open(_ folder: FolderShortcut) {
        guard let host else { return }
        store.refresh()
        guard store.exists(folder) else {
            NSSound.beep()
            return
        }
        host.feedback.tick()
        host.workspace.open(folder.url)
        host.notch.close()
    }

    func reveal(_ folder: FolderShortcut) {
        host?.workspace.reveal([folder.url])
        host?.notch.close()
    }

    func copyPath(_ folder: FolderShortcut) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(folder.path, forType: .string)
        host?.feedback.tick()
    }

    func addFolders() {
        guard let host else { return }
        store.add(host.workspace.chooseFolders())
    }
}

extension FoldersExtension: NotchPageProviding {
    var pages: [NotchPageDescriptor] {
        [NotchPageDescriptor(id: Self.pageID, title: "Folders", symbol: "folder.fill")]
    }

    func makePageView(for page: NotchPageDescriptor, context: NotchPageContext) -> AnyView {
        AnyView(FoldersPage(store: store, extension: self, size: context.size, isActive: context.isActive))
    }
}

extension FoldersExtension: NotchKeyHandling {
    /// 1–9 open the folder in that position.
    func handleKey(_ key: NotchKeyPress, on page: String) -> Bool {
        let modifiers = key.modifiers.intersection([.command, .option, .control, .shift])
        guard modifiers.isEmpty, let digit = Int(key.characters), (1...9).contains(digit),
              digit <= store.folders.count else { return false }
        open(store.folders[digit - 1])
        return true
    }
}

extension FoldersExtension: SettingsPaneProviding {
    func makeSettingsPane() -> AnyView {
        AnyView(FoldersSettingsPane(store: store, onAdd: { [weak self] in self?.addFolders() }))
    }
}
