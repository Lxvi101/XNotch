import AppKit
import Foundation

struct ShelfItem: Codable, Identifiable, Hashable {
    let id: UUID
    var path: String
    var bookmark: Data?
    let dateAdded: Date

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
}

/// Files kept on the shelf. Items are references, not copies: a bookmark is
/// stored alongside the path so moved or renamed files are found again.
@MainActor
final class ShelfStore: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    @Published var selection: Set<UUID> = []
    /// Single source of hover so a missed mouse-exit can never leave two tiles lit.
    @Published var hoveredID: UUID?

    private let fileURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XNotch", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("shelf.json")
    }

    static var receivedFilesDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XNotch/Received", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Adds files not already on the shelf and returns the ones added.
    @discardableResult
    func add(_ urls: [URL]) -> [ShelfItem] {
        let existing = Set(items.map(\.path))
        var seen = existing
        let added: [ShelfItem] = urls.compactMap { url in
            let path = url.standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: path), seen.insert(path).inserted else { return nil }
            return ShelfItem(
                id: UUID(),
                path: path,
                bookmark: try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil),
                dateAdded: Date()
            )
        }
        guard !added.isEmpty else { return [] }
        items.append(contentsOf: added)
        save()
        return added
    }

    func remove(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        save()
    }

    func removeAll() {
        items.removeAll()
        selection.removeAll()
        save()
    }

    /// The selected items if `item` is part of a multi-selection, else `item` alone.
    func actionTargets(for item: ShelfItem) -> [ShelfItem] {
        guard selection.contains(item.id), selection.count > 1 else { return [item] }
        return items.filter { selection.contains($0.id) }
    }

    // MARK: Persistence

    /// Checks every saved item still exists, which touches the folders they live in.
    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ShelfItem].self, from: data) else { return }
        items = decoded.compactMap(Self.resolved)
        if items != decoded { save() }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Follows the bookmark when the file is no longer at its recorded path.
    private static func resolved(_ item: ShelfItem) -> ShelfItem? {
        if FileManager.default.fileExists(atPath: item.path) { return item }
        guard let bookmark = item.bookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutMounting],
                                 relativeTo: nil, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        var moved = item
        moved.path = url.standardizedFileURL.path
        if stale {
            moved.bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        return moved
    }
}
