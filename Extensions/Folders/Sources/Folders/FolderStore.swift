import AppKit
import SwiftUI

struct FolderShortcut: Codable, Identifiable, Hashable {
    var id = UUID()
    var path: String
    /// A custom label; nil shows the folder's own (localized) name.
    var name: String?

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    var customName: String? {
        guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return name
    }
}

/// The folder list, plus the Finder names, icons and existence of each
/// folder. Those are file-system and Launch Services lookups, so they're
/// cached here and refreshed when the page opens rather than read on render.
@MainActor
final class FolderStore: ObservableObject {
    @Published private(set) var folders: [FolderShortcut] = []
    @Published private(set) var missing: Set<String> = []
    @Published var showsAddTile = true {
        didSet { defaults?.set(showsAddTile, forKey: Self.showsAddTileKey) }
    }

    private var fileURL: URL?
    private var defaults: UserDefaults?
    private var icons: [String: NSImage] = [:]
    private var systemNames: [String: String] = [:]

    private static let showsAddTileKey = "showsAddTile"

    func load(from directory: URL, defaults: UserDefaults) {
        self.defaults = defaults
        showsAddTile = defaults.object(forKey: Self.showsAddTileKey) as? Bool ?? true
        let url = directory.appendingPathComponent("folders.json")
        fileURL = url
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([FolderShortcut].self, from: data) {
            folders = saved
        } else {
            folders = Self.starterFolders
            save()
        }
        refresh()
    }

    /// Re-checks which folders still exist, and optionally their Finder names.
    func refresh(names: Bool = false) {
        if names { systemNames.removeAll() }
        let gone = Set(folders.map(\.path).filter { !Self.isDirectory($0) })
        if gone != missing { missing = gone }
    }

    func exists(_ folder: FolderShortcut) -> Bool { !missing.contains(folder.path) }

    func displayName(of folder: FolderShortcut) -> String {
        folder.customName ?? systemName(of: folder)
    }

    func systemName(of folder: FolderShortcut) -> String {
        if let name = systemNames[folder.path] { return name }
        let name = FileManager.default.displayName(atPath: folder.path)
        systemNames[folder.path] = name
        return name
    }

    /// Finder's icon for the folder, which carries the glyph of special
    /// folders (Downloads, Desktop, Documents…).
    func icon(for folder: FolderShortcut) -> NSImage {
        if let icon = icons[folder.path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: folder.path)
        icons[folder.path] = icon
        return icon
    }

    func add(_ urls: [URL]) {
        let known = Set(folders.map(\.path))
        let added = urls.map(\.standardizedFileURL.path).filter { !known.contains($0) }
        guard !added.isEmpty else { return }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            folders += added.map { FolderShortcut(path: $0) }
        }
        save()
        refresh()
    }

    func remove(_ id: FolderShortcut.ID) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            folders.removeAll { $0.id == id }
        }
        save()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        folders.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func rename(_ id: FolderShortcut.ID, to name: String) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].name = name.isEmpty ? nil : name
        save()
    }

    private func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(folders) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static var starterFolders: [FolderShortcut] {
        let manager = FileManager.default
        let directories: [FileManager.SearchPathDirectory] = [.downloadsDirectory, .desktopDirectory, .documentDirectory]
        var paths = directories.compactMap { manager.urls(for: $0, in: .userDomainMask).first?.path }
        paths.append(manager.homeDirectoryForCurrentUser.path)
        return paths.map { FolderShortcut(path: $0) }
    }
}
