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
    /// Shows an alert in the closed notch's wings for a few seconds, as
    /// XNotch does when headphones connect (API 1.4.0). An alert that arrives
    /// while the notch is open waits until it closes; a newer one replaces it.
    func showAlert(_ alert: NotchAlert)
}

/// A moment in the closed notch: a symbol and a word or two beside the camera
/// on the left, a short value (and optionally a ring) on the right. Each side
/// has room for about ten characters.
public struct NotchAlert: Sendable, Hashable {
    public var symbol: String
    /// Hex colour of the symbol and ring, e.g. "#FF6359"; white when nil.
    public var tint: String?
    /// Beside the symbol: "Disk".
    public var title: String
    /// On the right: "24 GB".
    public var value: String
    /// Fills a ring beside the value, 0…1; nil hides the ring.
    public var progress: Double?
    /// The page a click on the notch opens while the alert shows; nil opens
    /// the notch as usual.
    public var page: String?

    public init(symbol: String, tint: String? = nil, title: String, value: String, progress: Double? = nil,
                page: String? = nil) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.value = value
        self.progress = progress
        self.page = page
    }
}

/// How serious an alert is, for showing it with the notch's eyes (API 1.5.0).
public enum NotchAlertSeverity: Sendable, Hashable {
    /// Worth a look: the eyes glance nervously side to side.
    case caution
    /// Needs attention now: the eyes grow wide and round, their pupils darting.
    case critical
}

/// Shows an alert as a warning sign and its title on the left, with the
/// notch's eyes reacting on the right instead of the value (API 1.5.0).
/// XNotch's `NotchControl` adopts it: `host.notch as? NotchEyesAlerting`.
@MainActor
public protocol NotchEyesAlerting: AnyObject {
    func showAlert(_ alert: NotchAlert, eyes severity: NotchAlertSeverity)
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
