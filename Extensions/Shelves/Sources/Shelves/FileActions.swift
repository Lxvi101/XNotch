import AppKit
import Quartz
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Turns whatever is dragged or copied into files: file URLs as they are,
/// file promises (Mail, Photos, browsers) received into storage, links
/// downloaded by a rule or kept as link files, and images or text written
/// out as files.
@MainActor
enum PasteboardReader {
    static let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    static let readableTypes: [NSPasteboard.PasteboardType] =
        [.fileURL] + promiseTypes + [.png, .tiff, .string, .URL]
    /// Where Firefox keeps the data a page sets on a drag itself. ChatGPT
    /// drags its generated images with nothing else.
    static let pageDataType = NSPasteboard.PasteboardType("org.mozilla.custom-clipdata")
    /// The types a shelf listens for; `canRead` tells which drags it takes.
    static let draggedTypes = readableTypes + [pageDataType]

    static func canRead(_ pasteboard: NSPasteboard) -> Bool {
        guard let types = pasteboard.types else { return false }
        return types.contains(where: readableTypes.contains)
            || types.contains(pageDataType) && hasPageImage(pasteboard)
    }

    private static var checkedPageData: (name: NSPasteboard.Name, changeCount: Int, hasImage: Bool)?

    /// Whether a page's own drag data holds an image. Looked into once per drag.
    private static func hasPageImage(_ pasteboard: NSPasteboard) -> Bool {
        if let checked = checkedPageData, checked.name == pasteboard.name, checked.changeCount == pasteboard.changeCount {
            return checked.hasImage
        }
        let hasImage = pasteboard.data(forType: pageDataType).map(PageDragData.hasImage) ?? false
        checkedPageData = (pasteboard.name, pasteboard.changeCount, hasImage)
        return hasImage
    }

    /// Calls back with the files and which of them were made here. `links`
    /// are the rules that turn links into files.
    static func read(_ pasteboard: NSPasteboard, into directory: URL, links: [LinkRule] = [],
                     completion: @escaping @MainActor (_ urls: [URL], _ owned: Set<URL>) -> Void) {
        // Promises come first: Photos also offers a file URL, but to a small
        // preview inside its library, while the promise is the original.
        let promises = (pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver]) ?? []
        if !promises.isEmpty {
            let changeCount = pasteboard.changeCount
            // Browsers cancel promises they can't keep, but carry the image
            // itself too, and only while the drag lasts.
            let ownImage = promises.count == 1 ? imageData(on: pasteboard) : nil
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
                MainActor.assumeIsolated {
                    if received.isEmpty, let ownImage, let url = imageFile(from: ownImage, into: directory) {
                        completion([url], [url])
                    } else if received.isEmpty && pasteboard.changeCount == changeCount {
                        readContents(pasteboard, into: directory, links: links, completion: completion)
                    } else {
                        completion(received, Set(received))
                    }
                }
            }
            return
        }
        readContents(pasteboard, into: directory, links: links, completion: completion)
    }

    /// What's on the pasteboard besides promises: file URLs, an image, a link, text.
    private static func readContents(_ pasteboard: NSPasteboard, into directory: URL, links: [LinkRule],
                                     completion: @escaping @MainActor (_ urls: [URL], _ owned: Set<URL>) -> Void) {
        let files = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !files.isEmpty { return completion(files, []) }

        if let url = imageFile(from: pasteboard, into: directory) { return completion([url], [url]) }

        // Read now, while the browser still serves it; decoded off the main thread.
        if pasteboard.types?.contains(pageDataType) == true, hasPageImage(pasteboard),
           let data = pasteboard.data(forType: pageDataType) {
            Task.detached(priority: .userInitiated) {
                let url = PageDragData.image(in: data).flatMap { imageFile(from: $0.data, named: $0.name, into: directory) }
                await completion(url.map { [$0] } ?? [], Set(url.map { [$0] } ?? []))
            }
            return
        }

        if let link = webLink(on: pasteboard) {
            let folder = freshFolder(in: directory)
            guard let rule = LinkResolver.rule(for: link.url, in: links) else {
                let url = linkFile(for: link.url, title: link.title, in: folder)
                return completion(url.map { [$0] } ?? [], Set(url.map { [$0] } ?? []))
            }
            Task {
                let file = try? await LinkResolver.download(link.url, with: rule, into: folder)
                let url = file ?? linkFile(for: link.url, title: link.title, in: folder)
                completion(url.map { [$0] } ?? [], Set(url.map { [$0] } ?? []))
            }
            return
        }

        if let text = pasteboard.string(forType: .string) ?? pasteboard.string(forType: .URL),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let url = freshFolder(in: directory).appendingPathComponent(textFileName(for: text))
            if (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil { return completion([url], [url]) }
        }
        completion([], [])
    }

    /// A web address on the pasteboard, from a dragged link or as the whole of
    /// its text, with the link's title when there is one.
    static func webLink(on pasteboard: NSPasteboard) -> (url: URL, title: String?)? {
        guard let text = (pasteboard.string(forType: .URL) ?? pasteboard.string(forType: .string))?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.contains(where: \.isWhitespace), let url = URL(string: text),
              ["http", "https"].contains(url.scheme?.lowercased()), url.host() != nil else { return nil }
        let title = pasteboard.string(forType: .init("public.url-name"))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (url, title?.isEmpty == false ? title : nil)
    }

    /// A link file, which opens the address, named after its title or host.
    static func linkFile(for url: URL, title: String?, in folder: URL) -> URL? {
        let name = (title ?? url.host() ?? "Link").replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let file = folder.appendingPathComponent(String(name.prefix(60)) + ".webloc")
        guard let data = try? PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0),
              (try? data.write(to: file)) != nil else { return nil }
        return file
    }

    /// The image dragged for a drop's first item.
    static func preview(in info: NSDraggingInfo) -> NSImage? {
        var found: NSImage?
        info.enumerateDraggingItems(options: [], for: nil, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, _, stop in
            let components = item.imageComponents ?? []
            found = image(from: (components.first { $0.key == .icon } ?? components.first)?.contents)
            stop.pointee = true
        }
        return found
    }

    /// The pasteboard's image as PNG or TIFF data; nil when it has none.
    /// Browsers serve a dragged image only until the drag is over, so a drop
    /// that might need it reads it before letting go.
    static func imageData(on pasteboard: NSPasteboard) -> Data? {
        pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
    }

    /// The pasteboard's image written as a PNG into a fresh folder in
    /// `directory`; nil when it has none.
    static func imageFile(from pasteboard: NSPasteboard, into directory: URL) -> URL? {
        imageData(on: pasteboard).flatMap { imageFile(from: $0, into: directory) }
    }

    /// PNG or TIFF data written as a PNG into a fresh folder in `directory`.
    nonisolated static func imageFile(from data: Data, into directory: URL) -> URL? {
        let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
        guard let png = isPNG ? data : NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
        else { return nil }
        let url = freshFolder(in: directory).appendingPathComponent("Image.png")
        return (try? png.write(to: url)) != nil ? url : nil
    }

    /// An image file as it came, `name` with its extension, into a fresh
    /// folder in `directory`.
    nonisolated static func imageFile(from data: Data, named name: String, into directory: URL) -> URL? {
        let url = freshFolder(in: directory).appendingPathComponent(name)
        return (try? data.write(to: url)) != nil ? url : nil
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

    /// A drop's file URLs, from Finder and the like, each with the image that
    /// was dragged for it; empty when there are none.
    static func files(in info: NSDraggingInfo) -> [(url: URL, preview: NSImage?)] {
        var found: [(url: URL, preview: NSImage?)] = []
        info.enumerateDraggingItems(options: [], for: nil, classes: [NSURL.self],
                                    searchOptions: [.urlReadingFileURLsOnly: true]) { item, _, _ in
            guard let url = item.item as? URL else { return }
            let components = item.imageComponents ?? []
            let contents = (components.first { $0.key == .icon } ?? components.first)?.contents
            found.append((url, image(from: contents)))
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

    nonisolated static func freshFolder(in directory: URL) -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

/// The data a web page sets on a drag itself, as Firefox carries it: entries
/// of a big-endian UInt32 kind (0 ends them), then a type and a value, each a
/// big-endian UInt32 byte count and UTF-16 text.
enum PageDragData {
    static func entries(in data: Data) -> [(type: String, value: String)] {
        let bytes = [UInt8](data)
        var offset = 0
        func uint32() -> Int? {
            guard offset + 4 <= bytes.count else { return nil }
            defer { offset += 4 }
            return bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
        }
        func text() -> String? {
            guard let count = uint32(), offset + count <= bytes.count else { return nil }
            defer { offset += count }
            return String(data: Data(bytes[offset..<offset + count]), encoding: .utf16LittleEndian)
        }
        var entries: [(type: String, value: String)] = []
        while let kind = uint32(), kind != 0, let type = text(), let value = text() {
            entries.append((type, value))
        }
        return entries
    }

    private static let marker = Data("data:image/".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })

    /// Whether the data carries an image, without decoding it.
    static func hasImage(_ data: Data) -> Bool {
        data.range(of: marker) != nil
    }

    /// The first image in the data, from a data URL that is a value or a
    /// field of one, with a file name: the one the page gave it, or "Image".
    static func image(in data: Data) -> (data: Data, name: String)? {
        for entry in entries(in: data) {
            let object = (try? JSONSerialization.jsonObject(with: Data(entry.value.utf8))) as? [String: Any]
            let strings = object.map { Array($0.values.compactMap { $0 as? String }) } ?? [entry.value]
            guard let image = strings.lazy.compactMap(decode).first else { continue }
            let given = (object?["filename"] ?? object?["name"]) as? String
            let base = (given.map { ($0 as NSString).deletingPathExtension } ?? "")
                .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            return (image.data, (base.isEmpty ? "Image" : String(base.prefix(60))) + "." + image.ext)
        }
        return nil
    }

    /// A base64 `data:image/…` URL's bytes and file extension.
    private static func decode(_ url: String) -> (data: Data, ext: String)? {
        guard url.hasPrefix("data:image/"), let comma = url.firstIndex(of: ",") else { return nil }
        let header = url[url.index(url.startIndex, offsetBy: 5)..<comma].split(separator: ";")
        guard header.contains("base64"), let mime = header.first,
              let data = Data(base64Encoded: String(url[url.index(after: comma)...]), options: .ignoreUnknownCharacters)
        else { return nil }
        return (data, UTType(mimeType: String(mime))?.preferredFilenameExtension ?? "png")
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

    /// Returns once every file has its thumbnail and icon, or after `limit`
    /// seconds for slow ones; at once when they're all made already.
    static func prepare(_ paths: [String], limit: TimeInterval = 0.35) async {
        let missing = paths.filter { thumbnails[$0] == nil }
        guard !missing.isEmpty else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var isDone = false
            let finish = {
                guard !isDone else { return }
                isDone = true
                continuation.resume()
            }
            Task {
                await withTaskGroup(of: Void.self) { group in
                    for path in missing {
                        group.addTask { _ = await thumbnail(for: path) }
                        // The icon is the fallback while there's no thumbnail.
                        group.addTask { await loadIcon(path) }
                    }
                }
                finish()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + limit) { MainActor.assumeIsolated { finish() } }
        }
    }

    /// Fetches the icon off the main thread: on a network volume it's a round trip.
    private static func loadIcon(_ path: String) async {
        guard icons[path] == nil else { return }
        let icon = await Task.detached(priority: .userInitiated) { NSWorkspace.shared.icon(forFile: path) }.value
        if icons[path] == nil { icons[path] = icon }
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
