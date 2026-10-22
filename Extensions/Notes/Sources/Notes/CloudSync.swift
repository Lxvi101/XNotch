import CoreServices
import CryptoKit
import Foundation

/// A note as it goes up to iCloud: what it says, where it lives, and its bucket.
struct CloudNote: Sendable {
    let id: UUID
    let folder: String
    let title: String
    let text: String
    var path: String?
    let bucket: URL
    /// Files are still being copied into the bucket: it goes up once they've landed.
    var copying = false
    /// Open in a window: a new title renames the file only once it's held still.
    var editing = false
}

/// What the mirror tells the library, always on the main thread.
enum CloudEvent: Sendable {
    /// A note is in iCloud at `path` with this content.
    case pushed(id: UUID, path: String, hash: String)
    /// A note's file changed elsewhere, or a new one appeared. `id` is the
    /// note it belongs to, when the file says.
    case changed(id: UUID?, path: String, text: String, hash: String)
    /// Versions of a note's file iCloud kept aside when two Macs saved it at once.
    case conflict(path: String, texts: [String])
    /// A note's file moved: renamed, or moved to another space, on another Mac.
    case moved(from: String, to: String)
    /// A note's file is gone from iCloud.
    case removed(path: String)
    /// Files arrived in or left a note's bucket from iCloud.
    case bucketChanged(path: String)
    /// A space's folder was renamed, or couldn't be.
    case folderRenamed(from: String, to: String, ok: Bool)
    case status(CloudStatus)
}

enum CloudStatus: Sendable, Equatable {
    case idle(Date?)
    case syncing
    case unavailable
}

/// Mirrors notes into iCloud Drive as plain Markdown, and brings changes made
/// there back.
///
/// Notes live in a local store the editor reads; this keeps iCloud in step on
/// a queue of its own. Nothing here runs on the main thread or reads a file
/// that hasn't changed: a scan compares dates and sizes against what it saw
/// last, and only changed files are read, through a coordinated read that
/// downloads an evicted file first instead of blocking on it.
///
/// Nothing is deleted on one look: a file has to stay missing across scans
/// a moment apart, longer when a lot goes at once, and a folder that couldn't
/// be listed, or isn't downloaded, counts as unknown rather than empty.
final class CloudSync: @unchecked Sendable {
    /// iCloud Drive, when it's on.
    static var iCloudDrive: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue ? url : nil
    }

    static var defaultRoot: URL? { iCloudDrive?.appendingPathComponent("XNotch Notes", isDirectory: true) }

    /// Syncs with iCloud Drive with the file's other metadata (the "#S" flag),
    /// so a note keeps who it is when it's renamed on another Mac.
    static let idAttribute = "dev.levi.xnotch.note-id#S"

    /// How long a file has to stay missing before it counts as deleted.
    static let deleteDelay: TimeInterval = 2
    /// The same, when much of a folder or many notes go at once.
    static let massDeleteDelay: TimeInterval = 15
    /// How long a new title has to hold before an open note's file follows it.
    static let renameDelay: TimeInterval = 3

    private struct Known: Codable {
        var modified: Double
        var size: Int64
        var hash: String
        var id: String?
        /// A bucket file's local copy, as last synced.
        var localModified: Double?
        var localSize: Int64?
    }

    /// A bucket's folders' dates as last synced, here and in iCloud.
    private struct Stamp: Codable, Equatable {
        var local: Double?
        var remote: Double?
    }

    private struct State: Codable {
        var known: [String: Known] = [:]
        var buckets: [String: String] = [:]
        var bucketDates: [String: Stamp] = [:]

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            known = try container.decode([String: Known].self, forKey: .known)
            buckets = try container.decodeIfPresent([String: String].self, forKey: .buckets) ?? [:]
            bucketDates = try container.decodeIfPresent([String: Stamp].self, forKey: .bucketDates) ?? [:]
        }
    }

    private typealias Values = (modified: Double, size: Int64)

    /// One queue for every instance, so one that's stopping finishes saving
    /// its state before the next one loads it.
    private static let queue = DispatchQueue(label: "dev.levi.xnotch.notes.cloud", qos: .utility)

    let root: URL
    private let stateURL: URL
    private let queue = CloudSync.queue
    private let reads: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
        return queue
    }()
    private let onEvent: @MainActor (CloudEvent) -> Void

    // On the queue.
    private var state = State()
    private var reading: Set<String> = []
    /// Paths that changed again while being read.
    private var stale: Set<String> = []
    private var scanPending = false
    private var confirmAt: Date?
    private var bucketsChecked = false
    private var stream: FSEventStreamRef?
    /// Paths seen missing, and since when.
    private var suspects: [String: Date] = [:]
    /// Pushes still owed: held back by a change in iCloud, or a title still being typed.
    private var pending: [UUID: CloudNote] = [:]
    private var titles: [UUID: (stem: String, since: Date)] = [:]
    private var copying: Set<String> = []

    // Shared with the main thread.
    private let lock = NSLock()
    private var isStopped = false
    /// Paths, and folders as "Name/", deleted here, and when.
    private var removedHere: [String: Date] = [:]

    init(root: URL, stateURL: URL, onEvent: @escaping @MainActor (CloudEvent) -> Void) {
        self.root = root
        self.stateURL = stateURL
        self.onEvent = onEvent
        queue.async { [self] in
            if let data = try? Data(contentsOf: stateURL), let saved = try? JSONDecoder().decode(State.self, from: data) {
                state = saved
            }
        }
    }

    private var stopped: Bool { lock.withLock { isStopped } }

    // MARK: Running

    func start() {
        queue.async { [self] in
            guard !stopped else { return }
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
            guard let stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<CloudSync>.fromOpaque(info).takeUnretainedValue().scanSoon()
            }, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else { return }
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
            self.stream = stream
            scanNow()
        }
    }

    /// Stops at once for the main thread: nothing more is emitted, and work
    /// already queued or reading drops out. The stream is torn down and the
    /// state saved on the queue, without waiting for it.
    func stop() {
        lock.withLock { isStopped = true }
        queue.async { [self] in
            if let stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
            stream = nil
            saveState()
        }
    }

    private func emit(_ event: CloudEvent, readSince started: Date? = nil, then done: (@Sendable () -> Void)? = nil) {
        guard !stopped else { return }
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                // Stopped, or deleted here after this was read: it's old news.
                guard !stopped else { return }
                if let started, let path = event.path, wasRemoved(path, since: started) { return }
                onEvent(event)
                done?()
            }
        }
    }

    // MARK: Deleted here

    private func markRemoved(_ key: String) {
        lock.withLock { removedHere[key] = Date() }
    }

    private func removedDate(_ path: String) -> Date? {
        lock.withLock { [removedHere[path], removedHere[Self.folder(of: path) + "/"]].compactMap { $0 }.max() }
    }

    private func wasRemoved(_ path: String, since date: Date) -> Bool {
        removedDate(path).map { $0 >= date } ?? false
    }

    /// A space's folder deleted here in the last minute, so a file on its
    /// way out doesn't bring the space back.
    func removedRecently(folder: String) -> Bool {
        lock.withLock { removedHere[folder + "/"].map { Date().timeIntervalSince($0) < 60 } ?? false }
    }

    // MARK: Going up

    /// Writes a note to iCloud if it changed, renaming its file to follow its
    /// title and space, and mirrors its bucket.
    func push(_ note: CloudNote) {
        queue.async { [self] in
            guard !stopped else { return }
            pushNow(note)
        }
    }

    private func pushNow(_ note: CloudNote) {
        pending[note.id] = nil
        if let path = note.path {
            if note.copying { copying.insert(path) } else { copying.remove(path) }
        }
        let folder = Self.fileName(note.folder)
        let stem = Self.fileName(note.title)
        let id = note.id.uuidString
        var path = note.path
        // The file at the note's path is another note's now: its own is wherever its id is.
        if let current = path, let owner = state.known[current]?.id, owner != id { path = nil }
        if path == nil { path = self.path(of: id) }
        if let current = path, !exists(current) {
            // Moved here a moment ago, and the main thread hasn't heard yet.
            if let moved = self.path(of: id), moved != current, exists(moved) {
                path = moved
            } else {
                // Gone from iCloud, or not downloaded: never written back. The
                // scan decides, and the library with it.
                let stub = url(current).deletingLastPathComponent().appendingPathComponent("." + url(current).lastPathComponent + ".icloud")
                if FileManager.default.fileExists(atPath: stub.path) { try? FileManager.default.startDownloadingUbiquitousItem(at: url(current)) }
                if state.known[current] != nil { pending[note.id] = note }
                return
            }
        }

        var deferred = false
        if let current = path, Self.folder(of: current) == folder, Self.stem(Self.stem(of: current), matches: stem) {
            // Its name still fits its title: it stays put.
        } else if let current = path, Self.folder(of: current) == folder, note.editing, !titleHeld(note.id, stem) {
            // Still typing the title: the content goes up, the name later.
            deferred = true
        } else {
            try? FileManager.default.createDirectory(at: root.appendingPathComponent(folder, isDirectory: true),
                                                     withIntermediateDirectories: true)
            let target = available(folder: folder, stem: stem, keeping: path)
            if let current = path {
                guard let moved = rename(current, to: target) else {
                    pending[note.id] = note
                    return
                }
                path = moved
            } else {
                path = target
            }
        }
        if !deferred { titles[note.id] = nil }
        guard let path else { return }
        let file = url(path)
        let onDisk = exists(path)
        // Changed in iCloud since we last looked, or never read: the scan
        // sorts that out first, and this goes up after.
        if onDisk, let values = Self.values(file),
           state.known[path].map({ values.modified != $0.modified || values.size != $0.size }) ?? true {
            pending[note.id] = note
            if !reading.contains(path) { scanSoon() }
            return
        }
        let hash = Self.hash(note.text)
        if state.known[path]?.hash != hash || state.known[path]?.id != id || !onDisk {
            emit(.status(.syncing))
            guard write(Data(note.text.utf8), id: note.id, to: file), let values = Self.values(file) else {
                pending[note.id] = note
                return
            }
            state.known[path] = Known(modified: values.modified, size: values.size, hash: hash, id: id)
        }
        state.buckets[path] = note.bucket.path
        if note.copying {
            copying.insert(path)
        } else if state.bucketDates[path] != stamp(path, local: note.bucket) {
            syncBucket(path, local: note.bucket)
        }
        if deferred { pending[note.id] = note }
        saveState()
        emit(.pushed(id: note.id, path: path, hash: hash))
        emit(.status(.idle(Date())))
    }

    /// Whether a new title has held long enough for the file to follow it.
    /// The first time it's seen, a push is booked for when it will have.
    private func titleHeld(_ id: UUID, _ stem: String) -> Bool {
        if titles[id]?.stem != stem {
            titles[id] = (stem, Date())
            queue.asyncAfter(deadline: .now() + Self.renameDelay + 0.1) { [self] in
                guard !stopped, let note = pending[id] else { return }
                pushNow(note)
            }
            return false
        }
        return Date().timeIntervalSince(titles[id]?.since ?? Date()) >= Self.renameDelay
    }

    /// Moves a note's file to `target`, its bucket with it. Nil when it couldn't.
    private func rename(_ old: String, to target: String) -> String? {
        guard old != target else { return old }
        guard coordinatedMove(url(old), to: url(target)) else { return nil }
        follow(old, to: target)
        return target
    }

    /// Moves a note and its bucket to the iCloud Drive trash.
    func remove(path: String) {
        markRemoved(path)
        queue.async { [self] in
            guard !stopped else { return }
            trash(url(path))
            trash(url(Self.bucketFolder(for: path)))
            if let id = state.known[path]?.id.flatMap(UUID.init(uuidString:)) { pending[id] = nil }
            forget(path)
            saveState()
        }
    }

    /// Renames a space's folder, a change of case included, and says whether it moved.
    func renameFolder(from old: String, to new: String) {
        queue.async { [self] in
            guard !stopped else { return }
            let from = Self.fileName(old), to = Self.fileName(new)
            guard from != to else { return }
            let caseOnly = from.lowercased() == to.lowercased()
            let ok = exists(from) && (caseOnly || !exists(to)) && coordinatedMove(url(from), to: url(to))
            if ok {
                rekey(prefix: from + "/", to: to + "/")
                saveState()
            }
            emit(.folderRenamed(from: from, to: to, ok: ok))
        }
    }

    func removeFolder(_ name: String) {
        let folder = Self.fileName(name)
        markRemoved(folder + "/")
        queue.async { [self] in
            guard !stopped else { return }
            trash(url(folder))
            let prefix = folder + "/"
            for key in state.known.keys where key.hasPrefix(prefix) { state.known[key] = nil }
            for key in state.buckets.keys where key.hasPrefix(prefix) { state.buckets[key] = nil }
            for key in state.bucketDates.keys where key.hasPrefix(prefix) { state.bucketDates[key] = nil }
            for key in suspects.keys where key.hasPrefix(prefix) { suspects[key] = nil }
            for (id, note) in pending where note.path?.hasPrefix(prefix) == true { pending[id] = nil }
            saveState()
        }
    }

    /// Tells the mirror where a note that came from iCloud keeps its bucket.
    func register(path: String, bucket: URL) {
        queue.async { [self] in
            guard !stopped else { return }
            state.buckets[path] = bucket.path
            syncBucket(path, local: bucket)
            saveState()
        }
    }

    // MARK: Coming down

    /// Coalesces bursts of file events into one scan.
    func scanSoon() {
        queue.async { [self] in
            guard !stopped, !scanPending else { return }
            scanPending = true
            queue.asyncAfter(deadline: .now() + 0.6) { [self] in
                scanPending = false
                guard !stopped else { return }
                scanNow()
            }
        }
    }

    /// A scan for when deletions seen once are due to be looked at again.
    private func confirmSoon(after delay: TimeInterval) {
        let due = Date().addingTimeInterval(delay + 0.1)
        if let confirmAt, confirmAt > Date(), confirmAt <= due { return }
        confirmAt = due
        queue.asyncAfter(deadline: .now() + delay + 0.1) { [self] in
            guard !stopped else { return }
            if let confirmAt, confirmAt <= Date() { self.confirmAt = nil }
            scanNow()
        }
    }

    /// Compares what's in iCloud with what was there last time, by dates and
    /// sizes alone, and reads only what changed. On the queue.
    private func scanNow() {
        guard FileManager.default.fileExists(atPath: root.path) else { return emit(.status(.unavailable)) }
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
        // Couldn't look: nothing is taken as gone.
        guard let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys,
                                                                          options: [.skipsHiddenFiles]) else { return }
        var present: [String: Values] = [:]
        var stubs: Set<String> = []
        var unlisted: Set<String> = []
        var bucketFolders: [String: Double] = [:]
        for folder in folders where Self.isDirectory(folder) {
            let name = folder.lastPathComponent
            // Not downloaded, or not listable: unknown, not empty.
            guard !Self.isDataless(folder),
                  let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                            options: []) else {
                unlisted.insert(name)
                try? FileManager.default.startDownloadingUbiquitousItem(at: folder)
                continue
            }
            for item in items {
                let itemName = item.lastPathComponent
                // An evicted file on older systems: there, just not here yet.
                if itemName.hasPrefix("."), itemName.hasSuffix(".md.icloud") {
                    let real = name + "/" + String(itemName.dropFirst().dropLast(".icloud".count))
                    try? FileManager.default.startDownloadingUbiquitousItem(at: url(real))
                    stubs.insert(real)
                    continue
                }
                guard !itemName.hasPrefix("."), let values = Self.values(item) else { continue }
                if Self.isDirectory(item) {
                    if itemName.hasSuffix(" Files") { bucketFolders[name + "/" + itemName] = values.modified }
                    continue
                }
                guard item.pathExtension.lowercased() == "md" else { continue }
                let path = name + "/" + itemName
                // Deleted here, and not changed since: on its way out.
                if let removed = removedDate(path), values.modified <= removed.timeIntervalSinceReferenceDate { continue }
                present[path] = values
            }
        }

        // Files that moved keep their identity: a missing file whose note
        // turns up under a new name is a rename, not a delete and a new note.
        let missing = state.known.keys.filter {
            Self.isNotePath($0) && present[$0] == nil && !stubs.contains($0) && !unlisted.contains(Self.folder(of: $0))
        }
        for path in suspects.keys where !missing.contains(path) && Self.isNotePath(path) { suspects[path] = nil }
        var arrivedByID: [String: String] = [:]
        for path in present.keys where state.known[path] == nil {
            if let id = Self.id(of: url(path)) { arrivedByID[id] = path }
        }
        var gone: [String] = []
        for old in missing {
            if let id = state.known[old]?.id, let new = arrivedByID[id] {
                follow(old, to: new)
                emit(.moved(from: old, to: new))
            } else {
                gone.append(old)
            }
        }
        let knownPerFolder = Dictionary(grouping: state.known.keys.filter(Self.isNotePath), by: Self.folder).mapValues(\.count)
        let gonePerFolder = Dictionary(grouping: gone, by: Self.folder).mapValues(\.count)
        let mass = gone.count > 3 || gonePerFolder.contains { $0.value >= 2 && $0.value * 2 > knownPerFolder[$0.key, default: 0] }
        for old in confirmed(gone, mass: mass) {
            if let id = state.known[old]?.id.flatMap(UUID.init(uuidString:)) { pending[id] = nil }
            forget(old)
            emit(.removed(path: old))
        }

        for (path, values) in present {
            if let known = state.known[path], known.modified == values.modified, known.size == values.size { continue }
            read(path)
        }
        // Only buckets whose folder in iCloud changed; every one, once, at start.
        for (path, bucket) in state.buckets where present[path] != nil && !copying.contains(path) {
            if !bucketsChecked || state.bucketDates[path]?.remote != bucketFolders[Self.bucketFolder(for: path)] {
                syncBucket(path, local: URL(fileURLWithPath: bucket))
            }
        }
        bucketsChecked = true
        retryPending()
        saveState()
        emit(.status(.idle(Date())))
    }

    /// Which of `gone` have been missing long enough to count as deleted.
    private func confirmed(_ gone: [String], mass: Bool) -> [String] {
        let now = Date()
        for path in gone where suspects[path] == nil { suspects[path] = now }
        let delay = mass ? Self.massDeleteDelay : Self.deleteDelay
        let due = gone.filter { now.timeIntervalSince(suspects[$0] ?? now) >= delay }
        if due.count < gone.count { confirmSoon(after: delay) }
        for path in due { suspects[path] = nil }
        return due
    }

    /// Pushes held back, tried again once nothing's being read for them.
    private func retryPending(for path: String? = nil, id: String? = nil) {
        for note in Array(pending.values) {
            if let path, note.path != path && note.id.uuidString != id { continue }
            if let current = note.path, reading.contains(current) { continue }
            pushNow(note)
        }
    }

    /// Reads a changed file without blocking: the coordinator downloads it
    /// first if iCloud evicted it, and calls back when it's here.
    private func read(_ path: String) {
        guard !reading.contains(path) else {
            stale.insert(path)
            return
        }
        reading.insert(path)
        let started = Date()
        let file = url(path)
        let intent = NSFileAccessIntent.readingIntent(with: file, options: [.withoutChanges])
        NSFileCoordinator().coordinate(with: [intent], queue: reads) { [self] error in
            guard !stopped else { return }
            // Dates before content: an edit landing mid-read shows up as a change next scan.
            let values = error == nil ? Self.values(intent.url) : nil
            let data = values == nil ? nil : try? Data(contentsOf: intent.url)
            let id = Self.id(of: intent.url)
            let versions = error == nil ? (NSFileVersion.unresolvedConflictVersionsOfItem(at: intent.url) ?? []) : []
            let conflicts = versions.compactMap { version in
                version.hasLocalContents ? (try? Data(contentsOf: version.url)).flatMap { String(data: $0, encoding: .utf8) } : nil
            }
            queue.async { [self] in
                guard !stopped else { return }
                reading.remove(path)
                if stale.remove(path) != nil { scanSoon() }
                guard let values, let data, !wasRemoved(path, since: started) else { return }
                let text = String(data: data, encoding: .utf8)
                // Not text: remembered all the same, so it isn't read again until it changes.
                let hash = text.map(Self.hash) ?? Self.hash(data)
                let known = state.known[path]
                let fileID = id ?? known?.id
                state.known[path] = Known(modified: values.modified, size: values.size, hash: hash, id: fileID)
                saveState()
                if !versions.isEmpty {
                    let others = conflicts.filter { Self.hash($0) != hash }
                    // Resolved only once the library has kept each one, and only if every one was read.
                    let resolve: @Sendable () -> Void = { [self] in
                        if conflicts.count == versions.count { resolveConflicts(versions, at: file) }
                    }
                    if others.isEmpty { resolve() } else { emit(.conflict(path: path, texts: others), readSince: started, then: resolve) }
                }
                guard let text else { return }
                // Only a date that moved, or our own write coming back: nothing
                // new, and anything held back for it can go up now.
                if known?.hash == hash { return retryPending(for: path, id: fileID) }
                for (noteID, note) in pending where note.path == path || noteID.uuidString == fileID { pending[noteID] = nil }
                emit(.changed(id: fileID.flatMap(UUID.init(uuidString:)), path: path, text: text, hash: hash), readSince: started)
            }
        }
    }

    /// Marks conflict versions resolved and lets iCloud drop them, off the main thread.
    private func resolveConflicts(_ versions: [NSFileVersion], at file: URL) {
        reads.addOperation { [self] in
            guard !stopped else { return }
            var error: NSError?
            NSFileCoordinator().coordinate(writingItemAt: file, options: [], error: &error) { url in
                for version in versions { version.isResolved = true }
                // Any that arrived since stay for the next read.
                if (NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []).isEmpty {
                    try? NSFileVersion.removeOtherVersionsOfItem(at: url)
                }
            }
        }
    }

    // MARK: Buckets

    private func stamp(_ path: String, local: URL) -> Stamp {
        Stamp(local: Self.values(local)?.modified, remote: Self.values(url(Self.bucketFolder(for: path)))?.modified)
    }

    /// Two-way mirror of a note's bucket folder, by name, size and date. A
    /// file known from before, now missing on one side and unchanged on the
    /// other, was deleted there; one changed on one side goes across; one
    /// changed on both is left alone on both.
    private func syncBucket(_ path: String, local: URL) {
        let folder = Self.bucketFolder(for: path)
        let remote = url(folder)
        let prefix = folder + "/"
        guard !Self.isDataless(remote), let localFiles = Self.files(in: local), let remoteFiles = Self.files(in: remote) else {
            try? FileManager.default.startDownloadingUbiquitousItem(at: remote)
            state.bucketDates[path] = nil
            return
        }
        // A whole folder gone on one side is no evidence about its files:
        // they're taken as new, and go back across.
        let bothThere = FileManager.default.fileExists(atPath: local.path) && FileManager.default.fileExists(atPath: remote.path)
        if !bothThere { for key in state.known.keys where key.hasPrefix(prefix) { state.known[key] = nil } }

        var changedLocally = false
        var failed = false
        var goneRemotely: [String] = []
        var goneLocally: [String] = []
        for name in Set(localFiles.keys).union(remoteFiles.keys) {
            let key = prefix + name
            let known = state.known[key]
            let source = local.appendingPathComponent(name), destination = remote.appendingPathComponent(name)
            switch (localFiles[name], remoteFiles[name]) {
            case let (here?, nil):
                if let known, known.localModified == here.modified, known.localSize == here.size {
                    goneRemotely.append(name)
                } else {
                    // New here, or changed here since it went from iCloud: it goes up.
                    try? FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
                    if !upload(source, to: destination, key: key, local: here) { failed = true }
                }
            case let (nil, there?):
                if let known, known.modified == there.modified, known.size == there.size {
                    goneLocally.append(name)
                } else {
                    try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
                    download(destination, to: source, key: key, path: path, expecting: nil)
                }
            case let (here?, there?):
                guard let known else {
                    // Both new: the same file when the sizes agree; otherwise both stay as they are.
                    if here.size == there.size {
                        state.known[key] = Known(modified: there.modified, size: there.size, hash: "", id: nil,
                                                 localModified: here.modified, localSize: here.size)
                    }
                    continue
                }
                let changedHere = known.localModified != here.modified || known.localSize != here.size
                let changedThere = known.modified != there.modified || known.size != there.size
                if changedHere && !changedThere, !upload(source, to: destination, key: key, local: here) { failed = true }
                if changedThere && !changedHere { download(destination, to: source, key: key, path: path, expecting: here) }
            case (nil, nil):
                break
            }
        }
        for key in state.known.keys where key.hasPrefix(prefix) {
            let name = String(key.dropFirst(prefix.count))
            if localFiles[name] == nil && remoteFiles[name] == nil { state.known[key] = nil }
        }

        // Deleted in iCloud: the local copy goes only once it's stayed gone.
        let remoteKnown = state.known.keys.filter { $0.hasPrefix(prefix) }.count
        let due = confirmed(goneRemotely.map { prefix + $0 }, mass: goneRemotely.count >= 2 && goneRemotely.count * 2 > remoteKnown)
        for key in suspects.keys where key.hasPrefix(prefix) && !goneRemotely.contains(String(key.dropFirst(prefix.count))) {
            suspects[key] = nil
        }
        for key in due {
            try? FileManager.default.trashItem(at: local.appendingPathComponent(String(key.dropFirst(prefix.count))), resultingItemURL: nil)
            state.known[key] = nil
            changedLocally = true
        }
        // Deleted here, by hand: the user's own disk, so it goes at once.
        for name in goneLocally {
            trash(remote.appendingPathComponent(name))
            state.known[prefix + name] = nil
        }
        // Looked at again next time while deletions wait, or a copy failed.
        state.bucketDates[path] = failed || due.count < goneRemotely.count ? nil : stamp(path, local: local)
        if changedLocally { emit(.bucketChanged(path: path)) }
    }

    /// Copies a file up, and only then counts it as known.
    private func upload(_ source: URL, to destination: URL, key: String, local: Values) -> Bool {
        guard copy(source, to: destination), let values = Self.values(destination) else { return false }
        state.known[key] = Known(modified: values.modified, size: values.size, hash: "", id: nil,
                                 localModified: local.modified, localSize: local.size)
        return true
    }

    /// Brings a file down without blocking, into a hidden name first, and
    /// lands it only if the local copy hasn't changed meanwhile.
    private func download(_ source: URL, to destination: URL, key: String, path: String, expecting: Values?) {
        guard !reading.contains(key) else { return }
        reading.insert(key)
        let started = Date()
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)-" + destination.lastPathComponent)
        let intent = NSFileAccessIntent.readingIntent(with: source, options: [])
        NSFileCoordinator().coordinate(with: [intent], queue: reads) { [self] error in
            guard !stopped else { return }
            let remote = error == nil ? Self.values(intent.url) : nil
            let copied = remote != nil && (try? FileManager.default.copyItem(at: intent.url, to: temp)) != nil
            queue.async { [self] in
                reading.remove(key)
                let current = Self.values(destination)
                guard !stopped, copied, let remote, !wasRemoved(path, since: started),
                      current?.modified == expecting?.modified, current?.size == expecting?.size,
                      Darwin.rename(temp.path, destination.path) == 0, let landed = Self.values(destination) else {
                    try? FileManager.default.removeItem(at: temp)
                    return
                }
                state.known[key] = Known(modified: remote.modified, size: remote.size, hash: "", id: nil,
                                         localModified: landed.modified, localSize: landed.size)
                saveState()
                emit(.bucketChanged(path: path))
            }
        }
    }

    // MARK: Files

    private func url(_ path: String) -> URL { root.appendingPathComponent(path) }

    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: url(path).path) }

    /// Where the mirror last saw a note's file.
    private func path(of id: String) -> String? {
        state.known.first { Self.isNotePath($0.key) && $0.value.id == id }?.key
    }

    /// "Plans 2.md" when "Plans.md" belongs to another note.
    private func available(folder: String, stem: String, keeping current: String?) -> String {
        var candidate = folder + "/" + stem + ".md"
        var index = 2
        // The note's own name, whatever its case.
        while candidate.lowercased() != current?.lowercased(),
              FileManager.default.fileExists(atPath: url(candidate).path) || state.known[candidate] != nil {
            candidate = folder + "/" + stem + " \(index).md"
            index += 1
        }
        return candidate
    }

    /// A note's file moved from `old` to `new`: what's known follows it, and
    /// so does its bucket folder, if it was left behind.
    private func follow(_ old: String, to new: String) {
        state.known[new] = state.known.removeValue(forKey: old)
        if let bucket = state.buckets.removeValue(forKey: old) { state.buckets[new] = bucket }
        state.bucketDates[old] = nil
        suspects[old] = nil
        let from = Self.bucketFolder(for: old), to = Self.bucketFolder(for: new)
        if exists(from), from.lowercased() == to.lowercased() || !exists(to) { coordinatedMove(url(from), to: url(to)) }
        rekey(prefix: from + "/", to: to + "/")
        for (id, note) in pending where note.path == old { pending[id]?.path = new }
    }

    private func rekey(prefix old: String, to new: String) {
        for key in state.known.keys where key.hasPrefix(old) {
            state.known[new + key.dropFirst(old.count)] = state.known.removeValue(forKey: key)
        }
        for key in state.buckets.keys where key.hasPrefix(old) {
            state.buckets[new + key.dropFirst(old.count)] = state.buckets.removeValue(forKey: key)
        }
        for key in state.bucketDates.keys where key.hasPrefix(old) {
            state.bucketDates[new + key.dropFirst(old.count)] = state.bucketDates.removeValue(forKey: key)
        }
        for key in suspects.keys where key.hasPrefix(old) {
            suspects[new + key.dropFirst(old.count)] = suspects.removeValue(forKey: key)
        }
        for (id, note) in pending where note.path?.hasPrefix(old) == true {
            pending[id]?.path = new + note.path!.dropFirst(old.count)
        }
    }

    private func forget(_ path: String) {
        state.known[path] = nil
        state.buckets[path] = nil
        state.bucketDates[path] = nil
        suspects[path] = nil
        let prefix = Self.bucketFolder(for: path) + "/"
        for key in state.known.keys where key.hasPrefix(prefix) { state.known[key] = nil }
        for key in suspects.keys where key.hasPrefix(prefix) { suspects[key] = nil }
    }

    /// Writes beside the file, sets its id there, then swaps it in: the
    /// upload always carries who it is.
    private func write(_ data: Data, id: UUID, to file: URL) -> Bool {
        var error: NSError?
        var written = false
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing, error: &error) { url in
            let temp = Self.temporary(beside: url)
            if (try? data.write(to: temp)) != nil {
                Self.setID(id.uuidString, on: temp)
                written = Darwin.rename(temp.path, url.path) == 0
            }
            if !written { try? FileManager.default.removeItem(at: temp) }
        }
        return written
    }

    private func copy(_ source: URL, to destination: URL) -> Bool {
        var error: NSError?
        var copied = false
        NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing, error: &error) { url in
            let temp = Self.temporary(beside: url)
            copied = (try? FileManager.default.copyItem(at: source, to: temp)) != nil && Darwin.rename(temp.path, url.path) == 0
            if !copied { try? FileManager.default.removeItem(at: temp) }
        }
        return copied
    }

    /// Moves a file or folder; a change of case alone goes through a hidden name.
    @discardableResult
    private func coordinatedMove(_ source: URL, to destination: URL) -> Bool {
        var error: NSError?
        var moved = false
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: source, options: .forMoving, writingItemAt: destination,
                               options: .forReplacing, error: &error) { from, to in
            let files = FileManager.default
            if from.path.lowercased() == to.path.lowercased() {
                let temp = Self.temporary(beside: from)
                if (try? files.moveItem(at: from, to: temp)) != nil {
                    moved = (try? files.moveItem(at: temp, to: to)) != nil
                    if !moved { try? files.moveItem(at: temp, to: from) }
                }
            } else {
                moved = (try? files.moveItem(at: from, to: to)) != nil
            }
            if moved { coordinator.item(at: from, didMoveTo: to) }
        }
        return moved
    }

    private func trash(_ file: URL) {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forDeleting, error: &error) { url in
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    private func saveState() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    // MARK: Helpers

    /// A title or space name as a file name: no slashes or colons, no leading dot.
    static func fileName(_ name: String) -> String {
        var cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = String(cleaned.prefix(80)).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    static func folder(of path: String) -> String { String(path.split(separator: "/").first ?? "") }

    static func stem(of path: String) -> String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }

    /// "Plans" fits "Plans" and "Plans 2".
    static func stem(_ stem: String, matches wanted: String) -> Bool {
        guard stem.hasPrefix(wanted) else { return false }
        let rest = stem.dropFirst(wanted.count)
        return rest.isEmpty || (rest.first == " " && !rest.dropFirst().isEmpty && rest.dropFirst().allSatisfy(\.isNumber))
    }

    static func bucketFolder(for path: String) -> String {
        (path as NSString).deletingPathExtension + " Files"
    }

    /// "Space/Title.md", not a file in a bucket.
    private static func isNotePath(_ path: String) -> Bool {
        path.hasSuffix(".md") && path.split(separator: "/").count == 2
    }

    static func hash(_ text: String) -> String { hash(Data(text.utf8)) }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func temporary(beside url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)-" + url.lastPathComponent)
    }

    /// Fresh each time: a URL keeps what it read before, and a file just written isn't that.
    private static func values(_ file: URL) -> Values? {
        var file = file
        file.removeAllCachedResourceValues()
        guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let date = values.contentModificationDate else { return nil }
        return (date.timeIntervalSinceReferenceDate, Int64(values.fileSize ?? 0))
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    /// A folder iCloud knows about but hasn't brought down: listing it would
    /// wait on the network.
    private static func isDataless(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_flags & 0x4000_0000 != 0 // SF_DATALESS
    }

    /// A folder's files by name, empty when there's no folder, nil when it
    /// couldn't be listed.
    private static func files(in folder: URL) -> [String: Values]? {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [:] }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        var files: [String: Values] = [:]
        for name in names where !name.hasPrefix(".") {
            guard let values = values(folder.appendingPathComponent(name)) else { return nil }
            files[name] = values
        }
        return files
    }

    /// Reading an attribute is metadata: it never downloads the file.
    static func id(of file: URL) -> String? {
        var buffer = [CChar](repeating: 0, count: 64)
        let length = getxattr(file.path, idAttribute, &buffer, buffer.count - 1, 0, 0)
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    static func setID(_ id: String, on file: URL) {
        _ = id.withCString { setxattr(file.path, idAttribute, $0, strlen($0), 0, 0) }
    }
}

private extension CloudEvent {
    /// The note file an event is about, when it's one read from iCloud.
    var path: String? {
        switch self {
        case let .changed(_, path, _, _), let .conflict(path, _): path
        default: nil
        }
    }
}
