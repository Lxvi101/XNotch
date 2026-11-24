import AppKit
import Quartz
import SwiftUI

/// What a file in a conversation does under the pointer: a click previews it
/// in Quick Look, a double-click opens it, dragging takes a copy anywhere,
/// and a right-click offers the rest. Done in AppKit, because the notch and
/// the menu bar panel never activate, and SwiftUI's drags and taps don't
/// reliably start in a window that isn't key.
struct FileInteraction: NSViewRepresentable {
    /// Every file of the message, so the arrow keys step through them in Quick Look.
    let urls: [URL]
    let index: Int
    var dragImage: NSImage?

    func makeNSView(context: Context) -> FileInteractionView {
        let view = FileInteractionView()
        update(view)
        return view
    }

    func updateNSView(_ view: FileInteractionView, context: Context) { update(view) }

    private func update(_ view: FileInteractionView) {
        view.urls = urls
        view.index = index
        view.dragImage = dragImage
    }
}

final class FileInteractionView: NSView {
    var urls: [URL] = []
    var index = 0
    var dragImage: NSImage?
    private var down: NSEvent?

    private var url: URL? { urls.indices.contains(index) ? urls[index] : nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        down = event
        if event.clickCount == 2, let url {
            down = nil
            MainActor.assumeIsolated {
                FilePreview.shared.close()
                NSWorkspace.shared.open(url)
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { down = nil }
        guard let down, down.clickCount == 1 else { return }
        let urls = urls, index = index
        MainActor.assumeIsolated { FilePreview.shared.toggle(urls, at: index) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down, let url else { return }
        let moved = hypot(event.locationInWindow.x - down.locationInWindow.x, event.locationInWindow.y - down.locationInWindow.y)
        guard moved > 3 else { return }
        self.down = nil
        let image = dragImage ?? NSWorkspace.shared.icon(forFile: url.path)
        let side: CGFloat = 64
        let point = convert(event.locationInWindow, from: nil)
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(NSRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side), contents: image)
        // A shared source: the session outlives this view if the notch folds away mid-drag.
        beginDraggingSession(with: [item], event: event, source: FileDragSource.shared)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let url else { return }
        let urls = urls, index = index
        MainActor.assumeIsolated {
            let menu = NSMenu()
            menu.addItem(MenuAction("Quick Look", symbol: "eye") { FilePreview.shared.show(urls, at: index) })
            menu.addItem(MenuAction("Open", symbol: "arrow.up.forward.app") { NSWorkspace.shared.open(url) })
            menu.addItem(MenuAction("Show in Finder", symbol: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
            menu.addItem(.separator())
            menu.addItem(MenuAction("Copy", symbol: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([url as NSURL])
            })
            menu.addItem(MenuAction("Save to Downloads", symbol: "arrow.down.circle") { FileActions.saveToDownloads(url) })
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
}

/// Files leave as copies: Walkie keeps its own, so the conversation still has them.
final class FileDragSource: NSObject, NSDraggingSource {
    static let shared = FileDragSource()

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

enum FileActions {
    /// A copy in Downloads, named like the original (with a number if taken), shown in Finder.
    static func saveToDownloads(_ url: URL) {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var target = downloads.appendingPathComponent(url.lastPathComponent)
        var number = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = downloads.appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        guard (try? FileManager.default.copyItem(at: url, to: target)) != nil else { return }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }
}

private final class MenuAction: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler() }
}

/// Drives the shared Quick Look panel directly: the notch and the menu bar
/// panel are never part of an active responder chain. It floats above both.
@MainActor
final class FilePreview: NSObject, QLPreviewPanelDataSource {
    static let shared = FilePreview()
    private var urls: [URL] = []
    private var monitor: Any?

    private var isShowing: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
            && QLPreviewPanel.shared().dataSource as AnyObject? === self
    }

    /// A second click on the file showing closes it; another file takes its place.
    func toggle(_ urls: [URL], at index: Int) {
        if isShowing, urls == self.urls, QLPreviewPanel.shared().currentPreviewItemIndex == index {
            close()
        } else {
            show(urls, at: index)
        }
    }

    func show(_ urls: [URL], at index: Int) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        NSApp.activate(ignoringOtherApps: true)
        panel.dataSource = self
        panel.reloadData()
        panel.currentPreviewItemIndex = min(max(0, index), urls.count - 1)
        // Above the notch and the menu bar panel, which sit at the status bar's level.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.makeKeyAndOrderFront(nil)
        monitorKeys()
    }

    func close() {
        guard isShowing else { return }
        QLPreviewPanel.shared().orderOut(nil)
    }

    /// Space and Escape close it, as in Finder.
    private func monitorKeys() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 49 || event.keyCode == 53 else { return event }
            let handled = MainActor.assumeIsolated {
                guard FilePreview.shared.isShowing, QLPreviewPanel.shared().isKeyWindow else { return false }
                FilePreview.shared.close()
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
