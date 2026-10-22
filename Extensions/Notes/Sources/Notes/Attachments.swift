import AppKit
import Quartz
import QuickLookThumbnailing

/// A file in a note's bucket. Buckets hold copies, so a note keeps its
/// files when the originals move or go.
struct Attachment: Identifiable, Hashable {
    let url: URL
    var id: String { url.lastPathComponent }
    var name: String { url.lastPathComponent }
    var path: String { url.path }
    let size: Int64
    let added: Date
}

@MainActor
enum Attachments {
    static let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    static let fileTypes: [NSPasteboard.PasteboardType] = [.fileURL] + promiseTypes + [.png, .tiff]

    /// Files, file promises or images: what goes to the bucket rather than into the text.
    static func carriesFiles(_ pasteboard: NSPasteboard) -> Bool {
        guard let types = pasteboard.types else { return false }
        if types.contains(.fileURL) || types.contains(where: promiseTypes.contains) { return true }
        // A copied image, not text that happens to carry a picture of itself.
        return types.contains(where: [.png, .tiff].contains) && !types.contains(.string)
    }

    /// Buckets with files still arriving, so an empty-looking note isn't thrown away mid-copy.
    private static var copying: [URL: Int] = [:]

    static func isCopying(into folder: URL) -> Bool { copying[folder.standardizedFileURL, default: 0] > 0 }

    private static func track(_ folder: URL, _ completion: @escaping @MainActor ([URL]) -> Void) -> @MainActor ([URL]) -> Void {
        let key = folder.standardizedFileURL
        copying[key, default: 0] += 1
        return { urls in
            copying[key, default: 1] -= 1
            if copying[key] == 0 { copying[key] = nil }
            completion(urls)
        }
    }

    /// Copies whatever the pasteboard holds into `folder` and calls back with the copies.
    static func read(_ pasteboard: NSPasteboard, into folder: URL, completion: @escaping @MainActor ([URL]) -> Void) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let completion = track(folder, completion)
        // Promises first: Photos also offers a file URL, but to a small preview.
        let promises = (pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver]) ?? []
        if !promises.isEmpty {
            let staging = folder.appendingPathComponent(".incoming-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let group = DispatchGroup()
            let lock = NSLock()
            var received: [URL] = []
            for promise in promises {
                group.enter()
                promise.receivePromisedFiles(atDestination: staging, options: [:], operationQueue: .init()) { url, error in
                    if error == nil { lock.withLock { received.append(url) } }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                MainActor.assumeIsolated {
                    let moved = received.compactMap { move($0, into: folder) }
                    try? FileManager.default.removeItem(at: staging)
                    completion(moved)
                }
            }
            return
        }

        let files = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !files.isEmpty {
            copyFiles(files, into: folder, completion: completion)
            return
        }

        if let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            let url = available(folder.appendingPathComponent("Image.png"))
            if (try? png.write(to: url)) != nil { return completion([url]) }
        }
        completion([])
    }

    /// Copies off the main thread: a dropped video shouldn't stall the note.
    static func copy(_ urls: [URL], into folder: URL, completion: @escaping @MainActor ([URL]) -> Void) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        copyFiles(urls, into: folder, completion: track(folder, completion))
    }

    private static func copyFiles(_ urls: [URL], into folder: URL, completion: @escaping @MainActor ([URL]) -> Void) {
        // Reserved until the copy lands, so a second drop of the same name gets its own.
        let destinations = urls.map { available(folder.appendingPathComponent($0.lastPathComponent), reserving: true) }
        Task.detached(priority: .userInitiated) {
            let copied = zip(urls, destinations).compactMap { source, destination in
                (try? FileManager.default.copyItem(at: source, to: destination)) != nil ? destination : nil
            }
            await MainActor.run { completion(copied) }
        }
    }

    private static func move(_ url: URL, into folder: URL) -> URL? {
        let destination = available(folder.appendingPathComponent(url.lastPathComponent))
        return (try? FileManager.default.moveItem(at: url, to: destination)) != nil ? destination : nil
    }

    private static var reserved: Set<String> = []

    /// "Report 2.pdf" when "Report.pdf" is taken.
    static func available(_ url: URL, reserving: Bool = false) -> URL {
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var candidate = url
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) || reserved.contains(candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)")
            index += 1
        }
        if reserving {
            reserved.insert(candidate.path)
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { reserved.remove(candidate.path) }
        }
        return candidate
    }

    /// The files in a bucket folder, newest last.
    nonisolated static func list(_ folder: URL) -> [Attachment] {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileSizeKey, .addedToDirectoryDateKey, .creationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return Attachment(url: url, size: Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0),
                              added: values?.addedToDirectoryDate ?? values?.creationDate ?? .distantPast)
        }
        .sorted { $0.added == $1.added ? $0.name < $1.name : $0.added < $1.added }
    }

    static func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: Thumbnails

@MainActor
enum Thumbnails {
    private static var icons: [String: NSImage] = [:]
    private static var thumbnails: [String: NSImage] = [:]
    private static var pending: [String: Task<NSImage?, Never>] = [:]

    static func icon(for path: String) -> NSImage {
        if let icon = icons[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[path] = icon
        return icon
    }

    static func image(for path: String) -> NSImage { thumbnails[path] ?? icon(for: path) }
    static func cached(for path: String) -> NSImage? { thumbnails[path] }

    static func thumbnail(for path: String) async -> NSImage? {
        if let image = thumbnails[path] { return image }
        if let task = pending[path] { return await task.value }
        let task = Task { await generate(path) }
        pending[path] = task
        let image = await task.value
        pending[path] = nil
        if let image { thumbnails[path] = image }
        return image
    }

    private static func generate(_ path: String) async -> NSImage? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: 112, height: 112),
                                                   scale: scale, representationTypes: .all)
        request.iconMode = true
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }

    static func forget(_ paths: [String]) {
        paths.forEach { icons[$0] = nil; thumbnails[$0] = nil }
    }
}

// MARK: Quick Look

/// Drives the shared Quick Look panel directly: note panels never join an
/// active responder chain, since XNotch stays in the background.
@MainActor
final class QuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLook()
    private var urls: [URL] = []

    func toggle(_ urls: [URL]) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible && self.urls == urls {
            panel.orderOut(nil)
            return
        }
        self.urls = urls
        panel.dataSource = self
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { urls[index] as NSURL }
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, symbol: String? = nil, key: String = "", handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
        image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() {
        MainActor.assumeIsolated { handler() }
    }
}
