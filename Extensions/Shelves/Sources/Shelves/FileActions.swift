import AppKit
import Quartz
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Turns whatever is dragged or copied into files: file URLs as they are,
/// file promises (Mail, Photos, browsers) received into storage, and images
/// or text written out as files.
@MainActor
enum PasteboardReader {
    static let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    static let readableTypes: [NSPasteboard.PasteboardType] =
        [.fileURL] + promiseTypes + [.png, .tiff, .string, .URL]

    static func canRead(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.types?.contains(where: readableTypes.contains) ?? false
    }

    /// Calls back with the files and which of them were made here.
    static func read(_ pasteboard: NSPasteboard, into directory: URL,
                     completion: @escaping @MainActor (_ urls: [URL], _ owned: Set<URL>) -> Void) {
        // Promises come first: Photos also offers a file URL, but to a small
        // preview inside its library, while the promise is the original.
        let promises = (pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver]) ?? []
        if !promises.isEmpty {
            let destination = freshFolder(in: directory)
            let group = DispatchGroup()
            let lock = NSLock()
            var received: [URL] = []
            for promise in promises {
                group.enter()
                promise.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: .init()) { url, error in
                    if error == nil {
                        lock.lock()
                        received.append(url)
                        lock.unlock()
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                MainActor.assumeIsolated { completion(received, Set(received)) }
            }
            return
        }

        let files = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !files.isEmpty { return completion(files, []) }

        if let image = NSImage(pasteboard: pasteboard), pasteboard.availableType(from: [.png, .tiff]) != nil,
           let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            let url = freshFolder(in: directory).appendingPathComponent("Image.png")
            if (try? png.write(to: url)) != nil { return completion([url], [url]) }
        }

        if let text = pasteboard.string(forType: .string) ?? pasteboard.string(forType: .URL),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let url = freshFolder(in: directory).appendingPathComponent(textFileName(for: text))
            if (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil { return completion([url], [url]) }
        }
        completion([], [])
    }

    /// A drop's file promises, each with the image that was dragged for it,
    /// in the order `read` would take them; empty when there are none.
    static func promises(in info: NSDraggingInfo) -> [(receiver: NSFilePromiseReceiver, preview: NSImage?)] {
        var found: [(receiver: NSFilePromiseReceiver, preview: NSImage?)] = []
        info.enumerateDraggingItems(options: [], for: nil, classes: [NSFilePromiseReceiver.self], searchOptions: [:]) { item, _, _ in
            guard let receiver = item.item as? NSFilePromiseReceiver else { return }
            let components = item.imageComponents ?? []
            let contents = (components.first { $0.key == .icon } ?? components.first)?.contents
            found.append((receiver, image(from: contents)))
        }
        return found
    }

    private static func image(from contents: Any?) -> NSImage? {
        if let image = contents as? NSImage { return image }
        guard let contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else { return nil }
        return NSImage(cgImage: contents as! CGImage, size: .zero)
    }

    /// Receives a promise's files into a fresh folder in `directory`, calling
    /// back with each one as it lands, or nil for one the sender couldn't make.
    /// Returns the folder.
    @discardableResult
    static func receive(_ receiver: NSFilePromiseReceiver, into directory: URL,
                        each: @escaping @MainActor (URL?) -> Void) -> URL {
        let destination = freshFolder(in: directory)
        receiver.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: .init()) { url, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { each(error == nil ? url : nil) }
            }
        }
        return destination
    }

    /// The first few words, as a file name.
    static func textFileName(for text: String) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).prefix(5).joined(separator: " ")
        let cleaned = words.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let base = cleaned.isEmpty ? "Text" : String(cleaned.prefix(40))
        return base + ".txt"
    }

    private static func freshFolder(in directory: URL) -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

@MainActor
enum FileActions {
    static func open(_ urls: [URL]) {
        urls.forEach { NSWorkspace.shared.open($0) }
    }

    static func open(_ urls: [URL], with app: URL) {
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    static func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    static func copyToPasteboard(_ urls: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls.map { $0 as NSURL })
    }

    static func copyPaths(_ urls: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    /// Apps that open every one of the files, the default first.
    static func applications(toOpen urls: [URL]) -> [URL] {
        guard let first = urls.first else { return [] }
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: first)
        for url in urls.dropFirst() {
            let others = Set(NSWorkspace.shared.urlsForApplications(toOpen: url))
            apps = apps.filter(others.contains)
        }
        var seen = Set<String>()
        return apps.filter { seen.insert($0.lastPathComponent).inserted }
    }

    static func chooseFolder(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = prompt
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Copies or moves files into a folder, numbering names that are taken.
    /// Returns where each one ended up.
    static func transfer(_ urls: [URL], to folder: URL, move: Bool) -> [URL: URL] {
        var result: [URL: URL] = [:]
        for url in urls {
            let destination = available(folder.appendingPathComponent(url.lastPathComponent))
            do {
                if move {
                    try FileManager.default.moveItem(at: url, to: destination)
                } else {
                    try FileManager.default.copyItem(at: url, to: destination)
                }
                result[url] = destination
            } catch {
                NSSound.beep()
            }
        }
        return result
    }

    private static func available(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        for n in 2... {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let candidate = url.deletingLastPathComponent().appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }
}

/// Finder icons and Quick Look thumbnails, cached by path.
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

    /// The best image there is right now: the thumbnail once made, else the icon.
    static func image(for path: String) -> NSImage {
        thumbnails[path] ?? icon(for: path)
    }

    static func cachedThumbnail(for path: String) -> NSImage? { thumbnails[path] }

    /// Callers asking while one is being made wait for that one.
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

    /// Calls back once every file has its thumbnail, or after `limit` seconds
    /// for slow ones; at once when they're all made already.
    static func prepare(_ paths: [String], limit: TimeInterval = 0.35, then done: @escaping @MainActor () -> Void) {
        let missing = paths.filter { thumbnails[$0] == nil }
        guard !missing.isEmpty else { return done() }
        var isDone = false
        let finish = {
            guard !isDone else { return }
            isDone = true
            done()
        }
        Task {
            await withTaskGroup(of: Void.self) { group in
                for path in missing { group.addTask { _ = await thumbnail(for: path) != nil } }
            }
            finish()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + limit) { MainActor.assumeIsolated { finish() } }
    }

    private static func generate(_ path: String) async -> NSImage? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: 128, height: 128),
                                                   scale: scale, representationTypes: .all)
        request.iconMode = true
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }

    static func forget(_ paths: [String]) {
        paths.forEach { icons[$0] = nil; thumbnails[$0] = nil }
    }
}

/// Drives the shared Quick Look panel directly, since a shelf panel never
/// becomes part of an active responder chain.
@MainActor
final class QuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLook()
    private var urls: [URL] = []
    /// The shelf that opened the panel, which gets the keys back when it closes.
    private weak var origin: NSWindow?
    private var monitor: Any?

    private var isShowing: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
            && QLPreviewPanel.shared().dataSource as AnyObject? === self
    }

    func show(_ urls: [URL], from window: NSWindow? = nil) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        origin = window
        NSApp.activate(ignoringOtherApps: true)
        panel.dataSource = self
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        panel.makeKeyAndOrderFront(nil)
        monitorKeys()
    }

    /// Space opens and closes the panel, as in Finder.
    func toggle(_ urls: [URL], from window: NSWindow?) {
        if isShowing { close() } else { show(urls, from: window) }
    }

    /// Shows what's selected now, while the panel is open.
    func follow(_ urls: [URL]) {
        guard isShowing, !urls.isEmpty, urls != self.urls else { return }
        self.urls = urls
        QLPreviewPanel.shared().reloadData()
        QLPreviewPanel.shared().currentPreviewItemIndex = 0
    }

    private func close() {
        QLPreviewPanel.shared().orderOut(nil)
        origin?.makeKey()
    }

    /// Space and Escape reach the panel itself while it has the keys.
    private func monitorKeys() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 49 || event.keyCode == 53 else { return event }
            let handled = MainActor.assumeIsolated {
                guard let self, self.isShowing, QLPreviewPanel.shared().isKeyWindow else { return false }
                self.close()
                return true
            }
            return handled ? nil : event
        }
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { urls[index] as NSURL }
    }
}
