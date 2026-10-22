import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum FileKind: String, Codable {
    case image, movie, audio, document, folder, application, other

    init(url: URL) {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey, .isPackageKey])
        self.init(type: values?.contentType, isFolder: values?.isDirectory == true && values?.isPackage != true)
    }

    /// For a file that isn't here yet, from the type it was promised as.
    init(type: UTType?, isFolder: Bool = false) {
        if type?.conforms(to: .application) == true || type?.conforms(to: .applicationBundle) == true {
            self = .application
        } else if isFolder || type?.conforms(to: .folder) == true {
            self = .folder
        } else if let type {
            if type.conforms(to: .image) { self = .image }
            else if type.conforms(to: .movie) || type.conforms(to: .video) { self = .movie }
            else if type.conforms(to: .audio) { self = .audio }
            else if type.conforms(to: .text) || type.conforms(to: .pdf) || type.conforms(to: .presentation)
                        || type.conforms(to: .spreadsheet) || type.conforms(to: .compositeContent) { self = .document }
            else { self = .other }
        } else {
            self = .other
        }
    }

    func noun(_ count: Int) -> String {
        let one = count == 1
        switch self {
        case .image: return one ? "Image" : "Images"
        case .movie: return one ? "Video" : "Videos"
        case .audio: return one ? "Audio File" : "Audio Files"
        case .document: return one ? "Document" : "Documents"
        case .folder: return one ? "Folder" : "Folders"
        case .application: return one ? "App" : "Apps"
        case .other: return one ? "File" : "Files"
        }
    }
}

/// A file on a shelf: a reference, with a bookmark to find it again after a
/// move. `isOwned` files were made by the shelf (dropped text, images, file
/// promises) and live in its storage, so they're deleted with it.
struct ShelfFile: Codable, Identifiable, Hashable {
    var id = UUID()
    var path: String
    var bookmark: Data?
    var dateAdded = Date()
    var isOwned = false
    var kind: FileKind
    /// Bytes, for files; nil for folders.
    var size: Int64?

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }

    init?(url: URL, isOwned: Bool = false) {
        let url = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        path = url.path
        bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        self.isOwned = isOwned
        kind = FileKind(url: url)
        size = kind == .folder ? nil
            : (try? url.resourceValues(forKeys: [.totalFileSizeKey, .fileSizeKey])).flatMap { values in
                (values.totalFileSize ?? values.fileSize).map(Int64.init)
            }
    }

    /// The file where it is now, following the bookmark when it moved; nil once it's gone.
    func resolved() -> ShelfFile? {
        if FileManager.default.fileExists(atPath: path) { return self }
        guard let bookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutMounting, .withoutUI],
                                 relativeTo: nil, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        var moved = self
        moved.path = url.standardizedFileURL.path
        if stale { moved.bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) }
        return moved
    }
}

/// A file another app promised and is still sending. It's shown as what was
/// dragged until it lands, when it becomes a `ShelfFile` with the same id.
struct IncomingFile: Identifiable {
    let id = UUID()
    let kind: FileKind
    /// The drag image, else the type's icon.
    let preview: NSImage
    /// The sender gave up on it; it shakes, then goes.
    var failed = false
}

/// What a shelf is called and how big it is, from its files.
enum ShelfSummary {
    /// "Report.pdf", "3 Images", "4 Items".
    static func name(for files: [ShelfFile]) -> String {
        guard let first = files.first else { return "Empty Shelf" }
        if files.count == 1 { return first.name }
        let kinds = Set(files.map(\.kind))
        if kinds.count == 1 { return "\(files.count) \(first.kind.noun(files.count))" }
        return "\(files.count) Items"
    }

    /// "1 Document", "3 Items": always counted, unlike `name`.
    static func count(for files: [ShelfFile]) -> String {
        count(of: files.map(\.kind))
    }

    static func count(of kinds: [FileKind]) -> String {
        let distinct = Set(kinds)
        if distinct.count == 1, let kind = distinct.first { return "\(kinds.count) \(kind.noun(kinds.count))" }
        return "\(kinds.count) \(kinds.count == 1 ? "Item" : "Items")"
    }

    static func size(for files: [ShelfFile]) -> String? {
        let sizes = files.compactMap(\.size)
        guard !sizes.isEmpty else { return nil }
        return ByteCountFormatter.string(fromByteCount: sizes.reduce(0, +), countStyle: .file)
    }
}

/// A shelf as it's saved: open or in the recent list.
struct ShelfRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var files: [ShelfFile] = []
    var customName: String?
    var isPinned = false
    var createdAt = Date()
    var updatedAt = Date()

    var name: String { customName ?? ShelfSummary.name(for: files) }
}

/// A shelf on screen. Observable per property, so a view redraws only for
/// what it reads: hovering the shelf doesn't re-render its files.
@MainActor
@Observable
final class Shelf: Identifiable {
    enum Layout: String { case grid, list }

    let id: UUID
    let createdAt: Date
    var files: [ShelfFile]
    var customName: String?
    var isPinned: Bool
    var updatedAt: Date

    // On-screen state, not saved.
    var selection: Set<UUID> = []
    var isExpanded = false
    var layout: Layout = .grid
    /// A drag from elsewhere is over the shelf.
    var isDropTarget = false
    /// A drag of any kind, including this shelf's own files, is over it.
    var isDragInside = false
    var isHovered = false
    /// Being moved over another shelf, to merge into it on release.
    var isOverShelf = false
    /// The shelf has turned into its instant actions.
    var showsActions = false
    var hoveredAction: InstantAction?
    /// The actions it offers, kept by its controller.
    var actions: [InstantAction] = []
    /// False while it grows in, and as it goes away.
    var isPresented = false
    /// Where in the shelf it grows from: under the pointer.
    var presenceAnchor = UnitPoint.center
    /// Bumped when files land, for the shelf's flinch.
    var landings = 0
    /// Where the last drop let go, in shelf coordinates, so files fly in from there.
    var lastDrop: CGPoint?
    /// Files on their way in from another app, after `files`.
    var incoming: [IncomingFile] = []

    init(record: ShelfRecord = ShelfRecord()) {
        id = record.id
        createdAt = record.createdAt
        files = record.files
        customName = record.customName
        isPinned = record.isPinned
        updatedAt = record.updatedAt
    }

    var record: ShelfRecord {
        ShelfRecord(id: id, files: files, customName: customName, isPinned: isPinned, createdAt: createdAt, updatedAt: updatedAt)
    }

    var name: String {
        if let customName { return customName }
        // Names come with the files; until then, what they are.
        if !incoming.isEmpty { return ShelfSummary.count(of: files.map(\.kind) + incoming.map(\.kind)) }
        return ShelfSummary.name(for: files)
    }

    /// No files, and none on the way.
    var isEmpty: Bool { files.isEmpty && incoming.isEmpty }

    /// The selection, or every file when nothing is selected.
    var targets: [ShelfFile] {
        let selected = files.filter { selection.contains($0.id) }
        return selected.isEmpty ? files : selected
    }

    /// `file` and the rest of the selection when it's part of it, else `file` alone.
    func targets(for file: ShelfFile) -> [ShelfFile] {
        guard selection.contains(file.id), selection.count > 1 else { return [file] }
        return files.filter { selection.contains($0.id) }
    }

    /// Adds files not already here; returns how many were added.
    @discardableResult
    func add(_ urls: [URL], owned: Set<URL> = []) -> Int {
        var known = Set(files.map(\.path))
        let added = urls.compactMap { url -> ShelfFile? in
            guard let file = ShelfFile(url: url, isOwned: owned.contains(url)), known.insert(file.path).inserted else { return nil }
            return file
        }
        guard !added.isEmpty else { return 0 }
        files += added
        updatedAt = Date()
        return added.count
    }

    /// Takes another shelf's files, keeping what they know (ownership, bookmarks),
    /// skipping ones already here; returns how many were added.
    @discardableResult
    func merge(_ incoming: [ShelfFile]) -> Int {
        var known = Set(files.map(\.path))
        let added = incoming.filter { known.insert($0.path).inserted }
        guard !added.isEmpty else { return 0 }
        files += added
        updatedAt = Date()
        return added.count
    }

    /// Puts a file that came in where its stand-in was, keeping the stand-in's
    /// id; false when the stand-in is gone or the file is here already.
    @discardableResult
    func land(_ file: ShelfFile) -> Bool {
        guard let index = incoming.firstIndex(where: { $0.id == file.id }) else { return false }
        incoming.remove(at: index)
        guard !files.contains(where: { $0.path == file.path }) else { return false }
        files.append(file)
        updatedAt = Date()
        return true
    }

    func remove(_ ids: Set<UUID>) {
        files.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        updatedAt = Date()
    }

    /// Drops files that are gone and follows ones that moved.
    func refresh() {
        let current = files.compactMap { $0.resolved() }
        if current != files { files = current }
    }
}
