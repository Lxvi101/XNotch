import AppKit
import Observation

struct FiledItem: Codable, Hashable, Identifiable {
    /// BarItem.id
    var id: String
    var name: String
    var bundleID: String?
}

struct BarFolder: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var items: [FiledItem] = []
    /// An SF Symbol for the folder's face; nil shows the icons inside it.
    var symbol: String?
}

/// The folders and what's in them, plus the last picture of each item.
@MainActor @Observable
final class FolderStore {
    private(set) var folders: [BarFolder] = []
    /// Keyed by BarItem.id. Kept on disk so a folder draws before its items
    /// have been captured this launch.
    private(set) var images: [String: NSImage] = [:]

    @ObservationIgnored private var defaults: UserDefaults?
    @ObservationIgnored private var imageDirectory: URL?
    private static let key = "folders"

    func load(defaults: UserDefaults, directory: URL) {
        self.defaults = defaults
        imageDirectory = directory.appendingPathComponent("Icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: imageDirectory!, withIntermediateDirectories: true)
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([BarFolder].self, from: data) {
            folders = saved
        }
        if folders.isEmpty {
            // Saved now: the folder's ID names its status item, and with it
            // the item's place in the menu bar.
            folders = [BarFolder(name: "Folder")]
            save()
        }
        for item in folders.flatMap(\.items) {
            if let url = imageURL(for: item.id), let image = NSImage(contentsOf: url),
               let pixels = image.representations.first {
                // Saved at the screen's pixel size; shown at its point size.
                let scale = NSScreen.main?.backingScaleFactor ?? 2
                image.size = NSSize(width: CGFloat(pixels.pixelsWide) / scale, height: CGFloat(pixels.pixelsHigh) / scale)
                images[item.id] = image
            }
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(folders) else { return }
        defaults?.set(data, forKey: Self.key)
    }

    var filedIDs: Set<String> { Set(folders.flatMap { $0.items.map(\.id) }) }

    func folder(containing itemID: String) -> BarFolder? {
        folders.first { $0.items.contains { $0.id == itemID } }
    }

    @discardableResult
    func addFolder(named name: String = "Folder") -> BarFolder {
        let folder = BarFolder(name: name)
        folders.append(folder)
        save()
        return folder
    }

    /// Returns the items that were inside, which go back to the menu bar.
    func removeFolder(_ id: UUID) -> [FiledItem] {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return [] }
        let items = folders.remove(at: index).items
        save()
        return items
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].name = name.trimmingCharacters(in: .whitespaces).isEmpty ? "Folder" : name
        save()
    }

    func setSymbol(_ id: UUID, to symbol: String?) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].symbol = symbol
        save()
    }

    func file(_ item: BarItem, in folderID: UUID) {
        unfile(item.id, persist: false)
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else { return }
        folders[index].items.append(FiledItem(id: item.id, name: item.name, bundleID: item.bundleID))
        save()
    }

    func unfile(_ itemID: String, persist: Bool = true) {
        for index in folders.indices {
            folders[index].items.removeAll { $0.id == itemID }
        }
        if persist { save() }
    }

    func moveItem(in folderID: UUID, from source: IndexSet, to destination: Int) {
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else { return }
        folders[index].items.move(fromOffsets: source, toOffset: destination)
        save()
    }

    // MARK: Pictures

    /// Captures the item's icon. Off the main thread for the capture itself.
    func capture(_ items: [BarItem]) async {
        let targets = items.map { ($0.id, $0.windowID, $0.bounds.size) }
        let captured: [(String, CGImage, CGSize)] = await Task.detached(priority: .userInitiated) {
            targets.compactMap { id, window, size in
                guard let image = WindowServer.image(of: window), let trimmed = Self.trimmed(image) else { return nil }
                let scale = CGFloat(image.width) / max(size.width, 1)
                return (id, trimmed, CGSize(width: CGFloat(trimmed.width) / scale, height: CGFloat(trimmed.height) / scale))
            }
        }.value
        for (id, cgImage, size) in captured {
            let image = NSImage(cgImage: cgImage, size: size)
            images[id] = image
            if let url = imageURL(for: id), let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) {
                try? data.write(to: url)
            }
        }
    }

    /// Crops the item's window to the icon inside it. The window carries the
    /// bar's full height and padding either side; the icon is all that's
    /// wanted in a folder. Nil when nothing is drawn, which is what a capture
    /// without Screen Recording comes back as.
    nonisolated private static func trimmed(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 12 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return nil }
        // A pixel of air keeps antialiased edges whole.
        let rect = CGRect(x: max(minX - 1, 0), y: max(minY - 1, 0),
                          width: min(maxX - minX + 3, width), height: min(maxY - minY + 3, height))
        return image.cropping(to: rect)
    }

    func image(for item: FiledItem) -> NSImage {
        if let image = images[item.id] { return image }
        if let bundleID = item.bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "questionmark.square.dashed", accessibilityDescription: nil) ?? NSImage()
    }

    private func imageURL(for id: String) -> URL? {
        let safe = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
        return imageDirectory?.appendingPathComponent(safe).appendingPathExtension("png")
    }
}
