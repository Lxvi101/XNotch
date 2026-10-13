import AppKit
import os

/// What XNotch offers an extension. Handed to `activate(host:)`; keep it for
/// as long as the extension is active.
@MainActor
public protocol ExtensionHost: AnyObject {
    var extensionID: ExtensionID { get }
    var storage: ExtensionStorage { get }
    var notch: NotchControl { get }
    /// The shelf (API 1.3.0).
    var shelf: ShelfAccess { get }
    var workspace: ExtensionWorkspace { get }
    var feedback: ExtensionFeedback { get }
    var log: Logger { get }
}

/// Drives the notch on the extension's behalf.
@MainActor
public protocol NotchControl: AnyObject {
    var isOpen: Bool { get }
    /// Opens the notch on one of this extension's pages.
    func open(page: String)
    func close()
    /// Re-reads `NotchPageProviding.pages`, for a changed title or badge.
    func pagesDidChange()
    /// Opens Settings on this extension's pane (API 1.3.0).
    func openSettings()
}

/// The shelf, for extensions that bring files to it.
@MainActor
public protocol ShelfAccess: AnyObject {
    /// The files on the shelf, in order.
    var files: [URL] { get }
    /// Puts files on the shelf and opens the notch on it, as a drop does.
    /// Files already on the shelf are skipped.
    func add(_ urls: [URL])
}

/// Per-extension persistence: a defaults suite and a private directory.
public struct ExtensionStorage: Sendable {
    public let suiteName: String
    /// `~/Library/Application Support/XNotch/ExtensionData/<id>`, created on demand.
    public let directory: URL

    public init(id: ExtensionID, root: URL) {
        suiteName = "dev.levi.XNotch.ext.\(id)"
        directory = root.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public var defaults: UserDefaults { UserDefaults(suiteName: suiteName) ?? .standard }
}

@MainActor
public struct ExtensionWorkspace {
    public init() {}

    @discardableResult
    public func open(_ url: URL) -> Bool { NSWorkspace.shared.open(url) }

    public func reveal(_ urls: [URL]) { NSWorkspace.shared.activateFileViewerSelecting(urls) }

    /// Presents a folder picker in front of everything and returns the choice.
    public func chooseFolders(prompt: String = "Add", allowsMultiple: Bool = true) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = allowsMultiple
        panel.prompt = prompt
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.urls : []
    }
}

@MainActor
public struct ExtensionFeedback {
    private let isEnabled: () -> Bool

    public init(isEnabled: @escaping () -> Bool) {
        self.isEnabled = isEnabled
    }

    /// The trackpad tick XNotch uses for selection and arrival.
    public func tick() {
        guard isEnabled() else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}
