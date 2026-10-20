import AppKit
import SwiftUI

/// Every shelf: the ones on screen, and recent ones that can be opened again.
/// Saved to shelves.json in the extension's storage.
@MainActor
final class ShelfLibrary: ObservableObject {
    /// Newest first; includes the shelves on screen.
    @Published private(set) var recent: [ShelfRecord] = []
    @Published private(set) var open: [ShelfController] = []
    /// The last shelf closed with files, for the empty shelf's restore button.
    @Published private(set) var lastClosedID: UUID?

    let filesDirectory: URL
    var sendToNotchShelf: ([URL]) -> Void = { _ in }
    var openSettings: () -> Void = {}
    var tick: () -> Void = {}

    private let preferences: ShelvesPreferences
    private let fileURL: URL
    private var pendingSaves: [UUID: DispatchWorkItem] = [:]
    private var previews: [UUID: NSImage] = [:]
    private static let recentLimit = 30

    init(directory: URL, preferences: ShelvesPreferences) {
        self.preferences = preferences
        fileURL = directory.appendingPathComponent("shelves.json")
        filesDirectory = directory.appendingPathComponent("Files", isDirectory: true)
        try? FileManager.default.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
    }

    // MARK: Persistence

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        recent = saved.recent.compactMap { record in
            var record = record
            record.files = record.files.compactMap { $0.resolved() }
            return record.files.isEmpty ? nil : record
        }
        lastClosedID = saved.lastClosedID.flatMap { id in recent.contains { $0.id == id } ? id : nil }
        sweepFiles()
    }

    private struct Saved: Codable {
        var recent: [ShelfRecord]
        var lastClosedID: UUID?
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Saved(recent: recent, lastClosedID: lastClosedID)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Deletes files the shelves made that no shelf holds any more.
    private func sweepFiles() {
        let kept = Set(recent.flatMap(\.files).filter(\.isOwned).map { $0.url.deletingLastPathComponent().lastPathComponent })
        let folders = (try? FileManager.default.contentsOfDirectory(at: filesDirectory, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where !kept.contains(folder.lastPathComponent) {
            // Files dropped seconds ago may still be on their way to a shelf.
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if created < Date().addingTimeInterval(-60) { try? FileManager.default.removeItem(at: folder) }
        }
    }

    private func update(_ shelf: Shelf) {
        let record = shelf.record
        recent.removeAll { $0.id == record.id }
        guard !record.files.isEmpty else { return save() }
        recent.insert(record, at: 0)
        if recent.count > Self.recentLimit {
            let openIDs = Set(open.map(\.shelf.id))
            while recent.count > Self.recentLimit, let index = recent.lastIndex(where: { !openIDs.contains($0.id) }) {
                recent.remove(at: index)
            }
        }
        previews[record.id] = nil
        save()
    }

    // MARK: Shelves on screen

    @discardableResult
    func newShelf(centeredAt point: CGPoint, files: [URL] = []) -> ShelfController {
        let controller = makeController(for: Shelf())
        controller.add(files) { controller.show(centeredAt: point) }
        return controller
    }

    /// A new shelf just under the notch, for the notch page and Settings.
    @discardableResult
    func newShelfUnderNotch(files: [URL] = []) -> ShelfController {
        newShelf(centeredAt: Self.underNotch, files: files)
    }

    func newShelfFromClipboard() {
        let controller = newShelfUnderNotch()
        controller.add(from: .general)
    }

    func reopen(_ record: ShelfRecord) {
        if let controller = open.first(where: { $0.shelf.id == record.id }) {
            return controller.bringToFront()
        }
        var record = record
        record.files = record.files.compactMap { $0.resolved() }
        guard !record.files.isEmpty else {
            NSSound.beep()
            return remove(record.id)
        }
        if lastClosedID == record.id { lastClosedID = nil }
        let controller = makeController(for: Shelf(record: record))
        controller.show(centeredAt: Self.underNotch)
    }

    /// Puts new files from a watched folder on that folder's shelf, opening
    /// one in the screen's top-right corner when there's none.
    func show(_ urls: [URL], from folder: WatchedFolder) {
        if let controller = open.first(where: { $0.watchedFolderID == folder.id && !$0.isClosing }) {
            controller.add(urls)
            controller.bringToFront()
            return
        }
        let controller = makeController(for: Shelf())
        controller.watchedFolderID = folder.id
        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let size = ShelfGeometry.compact
        controller.add(urls) {
            controller.show(at: CGPoint(x: visible.maxX - size.width - 20, y: visible.maxY - size.height - 20))
        }
    }

    private func makeController(for shelf: Shelf) -> ShelfController {
        let controller = ShelfController(shelf: shelf, library: self, preferences: preferences)
        open.append(controller)
        observe(shelf)
        if !shelf.files.isEmpty { update(shelf) }
        return controller
    }

    /// Saves a shelf shortly after its files, name or pin change. Hover and
    /// selection aren't read here, so they don't make a shelf recent.
    private func observe(_ shelf: Shelf) {
        withObservationTracking {
            _ = shelf.files
            _ = shelf.customName
            _ = shelf.isPinned
        } onChange: { [weak self, weak shelf] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let shelf, self.open.contains(where: { $0.shelf === shelf }) else { return }
                    self.scheduleSave(shelf)
                    self.observe(shelf)
                }
            }
        }
    }

    private func scheduleSave(_ shelf: Shelf) {
        pendingSaves[shelf.id]?.cancel()
        let item = DispatchWorkItem { [weak self, weak shelf] in
            MainActor.assumeIsolated {
                guard let self, let shelf else { return }
                self.pendingSaves[shelf.id] = nil
                self.update(shelf)
            }
        }
        pendingSaves[shelf.id] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    func didClose(_ controller: ShelfController) {
        open.removeAll { $0 === controller }
        pendingSaves.removeValue(forKey: controller.shelf.id)?.cancel()
        update(controller.shelf)
        if !controller.shelf.files.isEmpty {
            lastClosedID = controller.shelf.id
            save()
        }
        sweepFiles()
    }

    /// Hides every shelf, keeping them in Recent Shelves, as the extension switches off.
    func dismissAll() {
        for controller in open {
            update(controller.shelf)
            controller.dismiss()
        }
        open.removeAll()
        pendingSaves.values.forEach { $0.cancel() }
        pendingSaves.removeAll()
    }

    // MARK: Restoring

    var canRestore: Bool {
        guard let id = lastClosedID else { return false }
        return !open.contains { $0.shelf.id == id } && recent.contains { $0.id == id }
    }

    func restore(into controller: ShelfController) {
        guard let id = lastClosedID, let record = recent.first(where: { $0.id == id }) else { return }
        let files = record.files.compactMap { $0.resolved() }
        let shelf = controller.shelf
        withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
            shelf.files = files
            shelf.customName = record.customName
        }
        lastClosedID = nil
        recent.removeAll { $0.id == id }
        update(shelf)
        tick()
    }

    // MARK: Recent

    func remove(_ id: UUID) {
        recent.removeAll { $0.id == id }
        if lastClosedID == id { lastClosedID = nil }
        save()
        sweepFiles()
    }

    /// Forgets every shelf that isn't on screen.
    func clearRecent() {
        let openIDs = Set(open.map(\.shelf.id))
        recent.removeAll { !openIDs.contains($0.id) }
        lastClosedID = nil
        save()
        sweepFiles()
    }

    var closedRecent: [ShelfRecord] {
        let openIDs = Set(open.map(\.shelf.id))
        return recent.filter { !openIDs.contains($0.id) }
    }

    func isOpen(_ id: UUID) -> Bool { open.contains { $0.shelf.id == id } }

    /// The top file's icon, cached; refreshed with `refreshPreviews()`, not on render.
    func preview(for record: ShelfRecord) -> NSImage? { previews[record.id] }

    func refreshPreviews() {
        for record in recent where previews[record.id] == nil {
            if let file = record.files.last { previews[record.id] = Thumbnails.image(for: file.path) }
        }
        objectWillChange.send()
    }

    /// Bytes of files the shelves made (dropped text, images, promised files).
    func storageSize() -> Int64 {
        let enumerator = FileManager.default.enumerator(at: filesDirectory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        var total: Int64 = 0
        while let url = enumerator?.nextObject() as? URL {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    private static var underNotch: CGPoint {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        let size = ShelfGeometry.compact
        return CGPoint(x: screen.frame.midX, y: screen.visibleFrame.maxY - size.height / 2 - 24)
    }
}

/// Watches folders for new files and hands them to a shelf.
@MainActor
final class FolderMonitor {
    var onNewFiles: (([URL], WatchedFolder) -> Void)?

    private final class Watch {
        let folder: WatchedFolder
        let source: DispatchSourceFileSystemObject
        var known: Set<String>
        var pending: DispatchWorkItem?

        init(folder: WatchedFolder, source: DispatchSourceFileSystemObject, known: Set<String>) {
            self.folder = folder
            self.source = source
            self.known = known
        }
    }

    private var watches: [UUID: Watch] = [:]
    /// Partial downloads, renamed when they finish.
    private static let partialExtensions: Set<String> = ["download", "crdownload", "part", "partial", "tmp", "opdownload"]

    func update(_ folders: [WatchedFolder]) {
        let wanted = Dictionary(folders.filter(\.isEnabled).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, watch) in watches where wanted[id] != watch.folder {
            watch.source.cancel()
            watches[id] = nil
        }
        for (id, folder) in wanted where watches[id] == nil {
            start(folder)
        }
    }

    func stop() {
        watches.values.forEach { $0.source.cancel() }
        watches.removeAll()
    }

    func isActive(_ folder: WatchedFolder) -> Bool { watches[folder.id] != nil }

    private func start(_ folder: WatchedFolder) {
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete],
                                                               queue: .main)
        let watch = Watch(folder: folder, source: source, known: Self.contents(of: folder.url))
        source.setEventHandler { [weak self, weak watch] in
            MainActor.assumeIsolated {
                guard let self, let watch else { return }
                self.schedule(watch)
            }
        }
        source.setCancelHandler { close(descriptor) }
        watches[folder.id] = watch
        source.resume()
    }

    /// Waits for a burst of changes to settle, and for new files to stop growing.
    private func schedule(_ watch: Watch) {
        watch.pending?.cancel()
        let item = DispatchWorkItem { [weak self, weak watch] in
            MainActor.assumeIsolated {
                guard let self, let watch else { return }
                self.check(watch)
            }
        }
        watch.pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: item)
    }

    private func check(_ watch: Watch) {
        let current = Self.contents(of: watch.folder.url)
        let added = current.subtracting(watch.known)
        watch.known = current
        let urls = added.sorted().map { watch.folder.url.appendingPathComponent($0) }
        guard !urls.isEmpty else { return }
        let sizes = urls.map(Self.size)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let settled = zip(urls, sizes).filter { Self.size($0.0) == $0.1 && FileManager.default.fileExists(atPath: $0.0.path) }
                if settled.count < urls.count {
                    // Still growing: look again on the next change, or shortly.
                    let growing = Set(urls.map(\.lastPathComponent)).subtracting(settled.map(\.0.lastPathComponent))
                    watch.known.subtract(growing)
                    self.schedule(watch)
                }
                if !settled.isEmpty { self.onNewFiles?(settled.map(\.0), watch.folder) }
            }
        }
    }

    private static func contents(of folder: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Set(names.filter { !$0.hasPrefix(".") && !partialExtensions.contains(($0 as NSString).pathExtension.lowercased()) })
    }

    private static func size(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1)
    }
}
