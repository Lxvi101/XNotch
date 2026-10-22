import AppKit
import SwiftUI

// MARK: iCloud

extension NoteLibrary {
    /// Starts mirroring to iCloud Drive, when it's on and wanted.
    func startCloud() {
        guard cloud == nil, preferences.syncICloud, let folder = CloudSync.defaultRoot else {
            if CloudSync.defaultRoot == nil { cloudStatus = .unavailable }
            return
        }
        let sync = CloudSync(root: folder, stateURL: root.appendingPathComponent("cloud-state.json")) { [weak self] event in
            self?.handle(event)
        }
        cloud = sync
        cloudStatus = .syncing
        sync.start()
        for note in notes { push(note) }
        // File events are the trigger; this catches anything they miss.
        let timer = Timer(timeInterval: 120, repeats: true) { [weak sync] _ in sync?.scanSoon() }
        RunLoop.main.add(timer, forMode: .common)
        rescanTimer = timer
    }

    func stopCloud() {
        rescanTimer?.invalidate()
        rescanTimer = nil
        cloud?.stop()
        cloud = nil
        cloudStatus = .idle(nil)
    }

    func syncNow() { cloud?.scanSoon() }

    /// A note's file in iCloud Drive, once it's there.
    func cloudFile(for note: Note) -> URL? {
        guard cloud != nil, let path = note.cloudPath, let root = CloudSync.defaultRoot else { return nil }
        let file = root.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// A copy of a note beside it, bucket and all.
    func duplicate(_ note: Note, beside controller: NoteController) {
        let copy = newNote(beside: controller, text: note.text)
        let files = note.attachments.map(\.url)
        guard !files.isEmpty else { return }
        Attachments.copy(files, into: bucketFolder(for: copy)) { [weak self] _ in self?.refreshAttachments(of: copy) }
    }

    /// Sends a note up; blank notes stay local until they say something.
    func push(_ note: Note) {
        guard let cloud, note.hasText || !note.attachments.isEmpty,
              let space = spaces.first(where: { $0.id == note.spaceID }) else { return }
        let bucket = bucketFolder(for: note)
        cloud.push(CloudNote(id: note.id, folder: space.name, title: note.displayTitle, text: note.text,
                             path: note.cloudPath, bucket: bucket, copying: Attachments.isCopying(into: bucket),
                             editing: controllers[note.id] != nil))
    }

    private func handle(_ event: CloudEvent) {
        switch event {
        case let .pushed(id, path, hash):
            guard let note = notes.first(where: { $0.id == id }) else { return }
            note.cloudPath = path
            note.syncedHash = hash
            saveIndexSoon()
        case let .changed(id, path, text, hash):
            receive(text, hash: hash, at: path, id: id)
        case let .conflict(path, texts):
            // Saved on two Macs at once: the version iCloud set aside is kept as a note of its own.
            let note = notes.first { $0.cloudPath == path }
            for text in texts where text != note?.text {
                push(adopt(text, hash: nil, at: nil, in: note?.spaceID))
            }
        case let .moved(from, to):
            guard let note = notes.first(where: { $0.cloudPath == from }) else { return }
            note.cloudPath = to
            let folder = CloudSync.folder(of: to)
            if CloudSync.fileName(spaces.first { $0.id == note.spaceID }?.name ?? "") != folder {
                if let space = space(forFolder: folder) {
                    withAnimation(NoteMotion.content) { note.spaceID = space.id }
                } else {
                    // Into a space deleted here: the note stays, and its file comes back out.
                    push(note)
                }
            }
            saveIndexSoon()
        case let .folderRenamed(from, to, ok):
            // The folder couldn't move: its notes keep their files where they
            // are, and go across one at a time.
            guard !ok, let space = spaces.first(where: { CloudSync.fileName($0.name) == to }) else { return }
            for note in notes where note.spaceID == space.id {
                if let path = note.cloudPath, path.hasPrefix(to + "/") { note.cloudPath = from + path.dropFirst(to.count) }
                push(note)
            }
            saveIndexSoon()
        case let .removed(path):
            guard let note = notes.first(where: { $0.cloudPath == path }) else { return }
            if CloudSync.hash(note.text) != note.syncedHash {
                // Edited here since: it goes back up rather than away.
                note.cloudPath = nil
                push(note)
            } else {
                if let controller = controllers[note.id] {
                    detach(controller)
                    controller.hide(to: NotePlacement.notchPoint)
                }
                trash(note)
                saveIndex()
            }
        case let .bucketChanged(path):
            guard let note = notes.first(where: { $0.cloudPath == path }) else { return }
            withAnimation(NoteMotion.content) { note.attachments = Attachments.list(bucketFolder(for: note)) }
        case let .status(status):
            if cloudStatus != status { cloudStatus = status }
        }
    }

    /// A note's text from iCloud: applied when it wasn't edited here since
    /// the last sync; kept beside it as a note of its own when it was.
    private func receive(_ text: String, hash: String, at path: String, id: UUID?) {
        var match = notes.first { $0.cloudPath == path }
        if let id, let byPath = match, byPath.id != id {
            // The file is another note's now; this one's went elsewhere, and
            // its own file will say where.
            byPath.cloudPath = nil
            match = nil
        }
        if match == nil, let id { match = notes.first { $0.id == id } }
        guard let note = match else {
            adopt(text, hash: hash, at: path, id: id)
            return
        }
        note.cloudPath = path
        let local = CloudSync.hash(note.text)
        if local == hash {
            note.syncedHash = hash
        } else if note.syncedHash != nil, local != note.syncedHash {
            // Both sides changed: nothing is lost. iCloud's version becomes a
            // note of its own, and this one goes up as it is.
            let copy = adopt(text, hash: nil, at: nil, in: note.spaceID)
            copy.isPinned = note.isPinned
            note.syncedHash = hash
            push(note)
            push(copy)
        } else {
            note.update(text: text)
            note.syncedHash = hash
            try? text.write(to: bodyURL(for: note.id), atomically: true, encoding: .utf8)
            note.refreshPreview()
            controllers[note.id]?.showRemoteText(text)
        }
        saveIndexSoon()
    }

    /// A note made on another Mac, or by hand in iCloud Drive.
    /// Keeps the file's id when it has one that's free, so a note is the same
    /// note on every Mac.
    @discardableResult
    private func adopt(_ text: String, hash: String?, at path: String?, id: UUID? = nil, in spaceID: UUID? = nil) -> Note {
        let folderSpace = path.flatMap { space(forFolder: CloudSync.folder(of: $0)) }
        let noteID = id.flatMap { id in notes.contains { $0.id == id } ? nil : id } ?? UUID()
        let record = NoteRecord(id: noteID, spaceID: spaceID ?? folderSpace?.id ?? activeSpaceID, created: Date(), modified: Date(),
                                isPinned: false, isOpen: false, frame: nil, cloudPath: path, syncedHash: hash)
        let note = Note(record: record, text: text)
        try? text.write(to: bodyURL(for: note.id), atomically: true, encoding: .utf8)
        withAnimation(NoteMotion.content) { notes.append(note) }
        if let path {
            cloud?.register(path: path, bucket: bucketFolder(for: note))
            // Its space was deleted here: its file follows it to where it landed.
            if folderSpace == nil { push(note) }
        }
        saveIndexSoon()
        return note
    }

    /// The space for a folder in iCloud, made if it's new; nil for one
    /// deleted here a moment ago, which a file on its way out doesn't bring back.
    private func space(forFolder folder: String) -> NoteSpace? {
        if let space = spaces.first(where: { CloudSync.fileName($0.name) == folder }) { return space }
        if cloud?.removedRecently(folder: folder) == true { return nil }
        return addSpace(named: folder)
    }

    private func saveIndexSoon() {
        indexSaveTask?.cancel()
        indexSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveIndex()
        }
    }
}

