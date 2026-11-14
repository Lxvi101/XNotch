import AppKit
import SwiftUI
import XNotchKit

@objc(MenuBarFoldersPrincipal)
public final class MenuBarFoldersPrincipal: NSObject, XNotchExtensionPrincipal {
    public override init() { super.init() }

    @MainActor public func makeExtension() -> AnyObject { MenuBarFoldersExtension() }
}

@MainActor
final class MenuBarFoldersExtension: XNotchExtension {
    static let id: ExtensionID = "menubarfolders"

    let store = FolderStore()
    private var controller: BarController?
    private weak var host: ExtensionHost?
    private var isGuiding = false

    func activate(host: ExtensionHost) throws {
        DebugLog.url = host.storage.directory.appendingPathComponent("debug.log")
        DebugLog.write("activate: AX trusted=\(AXIsProcessTrusted()) screen=\(CGPreflightScreenCaptureAccess()) bundle=\(Bundle.main.bundlePath)")
        store.load(defaults: host.storage.defaults, directory: host.storage.directory)
        let controller = BarController(store: store, feedback: host.feedback)
        controller.openSettings = { [weak host] in host?.notch.openSettings() }
        controller.requestAccessibility = { [weak self] in
            Task { @MainActor in _ = await self?.requestPermission("accessibility") }
        }
        self.host = host
        controller.start(defaults: host.storage.defaults)
        self.controller = controller
        host.log.info("Menu Bar Folders activated with \(self.store.folders.count) folders")
    }

    func deactivate() {
        controller?.stop()
        controller = nil
    }
}

extension MenuBarFoldersExtension: PermissionRequesting {
    var pendingPermissions: [ExtensionPermission] {
        var missing: [ExtensionPermission] = []
        if !AXIsProcessTrusted() {
            missing.append(ExtensionPermission(id: "accessibility", title: "Moving menu bar icons", detail: "Accessibility",
                                               reason: "Menu Bar Folders moves icons into and out of folders the way you would, with a Command-drag.",
                                               symbol: "hand.point.up.left.fill", tint: "#FF9F0A"))
        }
        if !CGPreflightScreenCaptureAccess() {
            missing.append(ExtensionPermission(id: "screen", title: "Pictures of icons", detail: "Screen Recording",
                                               reason: "Folders show the real icons inside them. Only the menu bar icons are captured.",
                                               symbol: "rectangle.dashed.badge.record", tint: "#FF9F0A"))
        }
        return missing
    }

    func requestPermission(_ id: String) async -> Bool {
        switch id {
        case "accessibility":
            if AXIsProcessTrusted() { return true }
            // XNotch's guide: System Settings opens at the list, with XNotch to drag in.
            if let guide = host as? PermissionGuiding {
                guard !isGuiding else { return false }
                isGuiding = true
                defer { isGuiding = false }
                return await guide.guide(.accessibility, for: Bundle.main.bundleURL) { AXIsProcessTrusted() }
            }
            return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case "screen":
            return CGRequestScreenCaptureAccess()
        default:
            return false
        }
    }
}

extension MenuBarFoldersExtension: SettingsPaneProviding {
    func makeSettingsPane() -> AnyView {
        AnyView(SettingsPane(store: store, controller: controller))
    }
}

private struct SettingsPane: View {
    let store: FolderStore
    let controller: BarController?

    var body: some View {
        Form {
            ForEach(store.folders) { folder in
                Section {
                    FolderNameField(folder: folder) { name in
                        store.rename(folder.id, to: name)
                        controller?.refreshIcons()
                    }
                    FolderIconPicker(folder: folder) { symbol in controller?.setSymbol(symbol, for: folder.id) }
                    if folder.items.isEmpty {
                        Text("Empty. Right-click the folder in the menu bar to add icons.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(folder.items) { item in
                        HStack(spacing: 10) {
                            Image(nsImage: store.image(for: item))
                                .resizable()
                                .scaledToFit()
                                .frame(width: 28, height: 16)
                            Text(item.name)
                            Spacer()
                            Button("Take Out") { controller?.unfile(item.id) }
                                .buttonStyle(.borderless)
                        }
                    }
                } header: {
                    HStack {
                        Text(folder.name)
                        Spacer()
                        if store.folders.count > 1 {
                            Button("Remove Folder", role: .destructive) { controller?.removeFolder(folder.id) }
                                .buttonStyle(.borderless)
                                .font(.callout)
                        }
                    }
                }
            }
            Section {
                Button("New Folder") { controller?.addFolder() }
            } footer: {
                Text("Hover a folder in the menu bar to open it, click an icon inside to use it. Right-click a folder to add icons or rename it. Command-drag a folder to move it along the bar.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// The folder's face: what's inside it, or one of a few symbols.
private struct FolderIconPicker: View {
    let folder: BarFolder
    let onPick: (String?) -> Void

    var body: some View {
        LabeledContent("Icon") {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 4), count: 9), spacing: 4) {
                cell(nil, systemImage: "square.grid.2x2", help: "What's inside")
                ForEach(FolderGlyph.symbols, id: \.name) { symbol in
                    cell(symbol.name, systemImage: symbol.name, help: symbol.title)
                }
            }
        }
    }

    private func cell(_ symbol: String?, systemImage: String, help: String) -> some View {
        let chosen = folder.symbol == symbol
        return Button { onPick(symbol) } label: {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(chosen ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(chosen ? Color.accentColor : .clear, lineWidth: 1.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

private struct FolderNameField: View {
    let folder: BarFolder
    let onCommit: (String) -> Void
    @State private var name = ""

    var body: some View {
        TextField("Name", text: $name)
            .onAppear { name = folder.name }
            .onSubmit { onCommit(name) }
    }
}
