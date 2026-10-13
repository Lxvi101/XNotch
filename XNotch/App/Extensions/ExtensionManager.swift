import AppKit
import XNotchKit
import os
import SwiftUI

/// What the extension host needs from the notch.
@MainActor
protocol ExtensionNotchDriver: AnyObject {
    var isOpen: Bool { get }
    func open(page: OpenPage)
    func close()
    var shelfFiles: [URL] { get }
    func openSettings(extension id: ExtensionID)
    func addToShelf(_ urls: [URL])
}

/// Discovers `.xnext` bundles (built into the app, and in
/// ~/Library/Application Support/XNotch/Extensions), reads their manifests
/// without running their code, and loads and activates the enabled ones.
@MainActor
final class ExtensionManager: ObservableObject {
    struct Entry: Identifiable {
        let manifest: ExtensionManifest
        let bundleURL: URL
        let isBuiltIn: Bool
        fileprivate(set) var instance: XNotchExtension?
        fileprivate(set) var isActive = false
        /// Why the extension can't run; nil when it can.
        fileprivate(set) var failure: String?

        var id: ExtensionID { manifest.id }
    }

    @Published private(set) var entries: [Entry] = []
    /// Bumped whenever the set of extension pages, or one of their
    /// descriptors, may have changed.
    @Published private(set) var pagesRevision = 0
    let pointer = NotchPointer()
    weak var driver: ExtensionNotchDriver?

    private var hosts: [ExtensionID: HostBridge] = [:]
    private let preferences = Preferences.shared

    static var userDirectory: URL { supportDirectory.appendingPathComponent("Extensions", isDirectory: true) }
    private static var dataRoot: URL { supportDirectory.appendingPathComponent("ExtensionData", isDirectory: true) }
    private static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XNotch", isDirectory: true)
    }

    private var hasDiscovered = false

    /// Reads every extension's manifest without running its code. Extensions seen for the first time
    /// start switched off, for the user to add from the welcome tour or Settings.
    func discover() {
        guard !hasDiscovered else { return }
        hasDiscovered = true
        try? FileManager.default.createDirectory(at: Self.userDirectory, withIntermediateDirectories: true)
        var candidates: [(URL, Bool)] = []
        if let plugIns = Bundle.main.builtInPlugInsURL {
            candidates += bundles(in: plugIns).map { ($0, true) }
        }
        candidates += bundles(in: Self.userDirectory).map { ($0, false) }
        for (url, isBuiltIn) in candidates {
            register(url, isBuiltIn: isBuiltIn)
        }
        let new = Set(entries.map(\.id)).subtracting(preferences.knownExtensions)
        if !new.isEmpty {
            preferences.disabledExtensions.formUnion(new)
            preferences.knownExtensions.formUnion(new)
        }
    }

    func loadAll() {
        discover()
        for entry in entries where entry.failure == nil && !preferences.disabledExtensions.contains(entry.id) {
            activate(entry.id)
        }
    }

    /// Extensions that can run, for the welcome tour to offer.
    var offerable: [ExtensionManifest] {
        entries.filter { $0.failure == nil }.map(\.manifest)
    }

    func isEnabled(_ id: ExtensionID) -> Bool { !preferences.disabledExtensions.contains(id) }

    func setEnabled(_ enabled: Bool, for id: ExtensionID) {
        if enabled {
            preferences.disabledExtensions.remove(id)
            activate(id)
        } else {
            preferences.disabledExtensions.insert(id)
            deactivate(id)
        }
    }

    var pageProviders: [(ExtensionID, NotchPageProviding)] {
        entries.compactMap { entry in
            guard entry.isActive, let provider = entry.instance as? NotchPageProviding else { return nil }
            return (entry.id, provider)
        }
    }

    struct PendingPermission {
        let extensionID: ExtensionID
        let extensionName: String
        let requester: PermissionRequesting
        let permission: ExtensionPermission

        var key: String { "\(extensionID)/\(permission.id)" }
    }

    /// Permissions active extensions still need, for the welcome tour.
    var pendingPermissions: [PendingPermission] {
        entries.flatMap { entry -> [PendingPermission] in
            guard entry.isActive, let requester = entry.instance as? PermissionRequesting else { return [] }
            return requester.pendingPermissions.map {
                PendingPermission(extensionID: entry.id, extensionName: entry.manifest.name, requester: requester, permission: $0)
            }
        }
    }

    /// Active extensions' shelf controls, in load order.
    var shelfAccessoryProviders: [ShelfAccessoryProviding] {
        entries.compactMap { entry in
            guard entry.isActive else { return nil }
            return entry.instance as? ShelfAccessoryProviding
        }
    }

    func settingsPane(for id: ExtensionID) -> AnyView? {
        guard let entry = entries.first(where: { $0.id == id }), entry.isActive,
              let provider = entry.instance as? SettingsPaneProviding else { return nil }
        return provider.makeSettingsPane()
    }

    fileprivate func pagesDidChange() {
        pagesRevision += 1
    }

    // MARK: Loading

    private func bundles(in directory: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { $0.pathExtension == "xnext" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func register(_ url: URL, isBuiltIn: Bool) {
        guard let bundle = Bundle(url: url),
              let manifestURL = bundle.url(forResource: "extension", withExtension: "json"),
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(ExtensionManifest.self, from: data) else {
            NSLog("XNotch: \(url.lastPathComponent) has no readable extension.json")
            return
        }
        guard !entries.contains(where: { $0.id == manifest.id }) else {
            NSLog("XNotch: ignoring \(url.path), extension \(manifest.id) is already installed")
            return
        }
        var entry = Entry(manifest: manifest, bundleURL: url, isBuiltIn: isBuiltIn)
        if manifest.kit.abi != XNotchKit.abi {
            entry.failure = "Built for XNotchKit ABI \(manifest.kit.abi); this XNotch uses ABI \(XNotchKit.abi)."
        } else if manifest.kit.minAPI.compare(XNotchKit.apiVersion, options: .numeric) == .orderedDescending {
            entry.failure = "Needs XNotchKit \(manifest.kit.minAPI); this XNotch has \(XNotchKit.apiVersion)."
        } else if bundle.object(forInfoDictionaryKey: "XNotchExtensionID") as? String != manifest.id {
            entry.failure = "Info.plist's XNotchExtensionID doesn't match extension.json."
        }
        entries.append(entry)
    }

    private func activate(_ id: ExtensionID) {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              entries[index].failure == nil, !entries[index].isActive else { return }
        do {
            let instance = try entries[index].instance ?? instantiate(entries[index])
            entries[index].instance = instance
            let host = HostBridge(id: id, manager: self, dataRoot: Self.dataRoot)
            hosts[id] = host
            try instance.activate(host: host)
            entries[index].isActive = true
        } catch {
            hosts[id] = nil
            entries[index].failure = error.localizedDescription
            NSLog("XNotch: extension \(id) failed to activate: \(error.localizedDescription)")
        }
        pagesDidChange()
    }

    private func deactivate(_ id: ExtensionID) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].isActive else { return }
        entries[index].instance?.deactivate()
        entries[index].isActive = false
        hosts[id] = nil
        pagesDidChange()
    }

    private func instantiate(_ entry: Entry) throws -> XNotchExtension {
        guard let bundle = Bundle(url: entry.bundleURL) else { throw LoadError("The bundle can't be opened.") }
        try bundle.loadAndReturnError()
        guard let principal = bundle.principalClass as? XNotchExtensionPrincipal.Type else {
            throw LoadError("NSPrincipalClass doesn't conform to XNotchExtensionPrincipal.")
        }
        guard let instance = principal.init().makeExtension() as? XNotchExtension else {
            throw LoadError("makeExtension() didn't return a XNotchExtension.")
        }
        guard type(of: instance).id == entry.id else {
            throw LoadError("The extension's id (\(type(of: instance).id)) doesn't match its manifest.")
        }
        return instance
    }

    private struct LoadError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}

/// One extension's view of the host.
@MainActor
private final class HostBridge: ExtensionHost, NotchControl, ShelfAccess {
    let extensionID: ExtensionID
    let storage: ExtensionStorage
    let workspace = ExtensionWorkspace()
    let feedback = ExtensionFeedback { Preferences.shared.hapticsEnabled }
    let log: Logger
    private weak var manager: ExtensionManager?

    init(id: ExtensionID, manager: ExtensionManager, dataRoot: URL) {
        extensionID = id
        storage = ExtensionStorage(id: id, root: dataRoot)
        log = Logger(subsystem: "dev.levi.XNotch.extension", category: id)
        self.manager = manager
    }

    var notch: NotchControl { self }
    var shelf: ShelfAccess { self }

    var files: [URL] { manager?.driver?.shelfFiles ?? [] }

    func add(_ urls: [URL]) {
        manager?.driver?.addToShelf(urls)
    }

    var isOpen: Bool { manager?.driver?.isOpen ?? false }

    func open(page: String) {
        manager?.driver?.open(page: .extensionPage(extensionID, page))
    }

    func close() {
        manager?.driver?.close()
    }

    func pagesDidChange() {
        manager?.pagesDidChange()
    }

    func openSettings() {
        manager?.driver?.openSettings(extension: extensionID)
    }
}
