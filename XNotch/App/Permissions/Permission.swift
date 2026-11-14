import AppKit
import ApplicationServices
import CoreGraphics

/// A privacy permission granted by adding XNotch to a list in System Settings
/// → Privacy & Security. Every request goes through `PermissionCenter`, which
/// opens the pane and docks a guide beside it.
enum Permission: String, CaseIterable, Identifiable {
    case fullDiskAccess
    case accessibility
    case screenRecording

    var id: String { rawValue }

    /// Permissions XNotch asks for today; the others are ready for features that need them.
    static let requested: [Permission] = [.fullDiskAccess]

    var title: String {
        switch self {
        case .fullDiskAccess: "Full Disk Access"
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen & System Audio Recording"
        }
    }

    var symbol: String {
        switch self {
        case .fullDiskAccess: "externaldrive.fill"
        case .accessibility: "accessibility"
        case .screenRecording: "rectangle.dashed.badge.record"
        }
    }

    var tint: NSColor {
        switch self {
        case .fullDiskAccess: .systemGray
        case .accessibility: .systemBlue
        case .screenRecording: .systemRed
        }
    }

    /// Why XNotch wants it, in one sentence.
    var reason: String {
        switch self {
        case .fullDiskAccess:
            "Lets the tray and Folders open, preview and move files anywhere on your Mac, including protected places like Mail, Messages and Safari."
        case .accessibility:
            "Lets XNotch respond to keyboard shortcuts and other apps' windows."
        case .screenRecording:
            "Lets XNotch see what's on screen to match its colours."
        }
    }

    /// macOS applies some grants only after the app restarts.
    var appliesAfterRelaunch: Bool { self == .fullDiskAccess || self == .screenRecording }

    /// The service's name for `tccutil`.
    var tccService: String {
        switch self {
        case .fullDiskAccess: "SystemPolicyAllFiles"
        case .accessibility: "Accessibility"
        case .screenRecording: "ScreenCapture"
        }
    }

    /// Forgets every grant of this permission to `bundleID`, so the app can be
    /// added again. System Settings lists an app once per bundle ID, and keeps
    /// the signature it first saw: a copy signed differently (an older dev
    /// build) leaves a row that shows On but no longer matches, and dragging
    /// the app in again does nothing. Returns whether it worked.
    nonisolated static func reset(_ service: String, bundleID: String) async -> Bool {
        await Task.detached {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            task.arguments = ["reset", service, bundleID]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
                task.waitUntilExit()
                return task.terminationStatus == 0
            } catch {
                return false
            }
        }.value
    }

    var settingsURL: URL {
        let anchor = switch self {
        case .fullDiskAccess: "Privacy_AllFiles"
        case .accessibility: "Privacy_Accessibility"
        case .screenRecording: "Privacy_ScreenCapture"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    var isGranted: Bool {
        switch self {
        case .fullDiskAccess: Self.canOpenProtectedFile()
        case .accessibility: AXIsProcessTrusted()
        case .screenRecording: CGPreflightScreenCaptureAccess()
        }
    }

    /// Without Full Disk Access, opening any of these fails with EPERM. Some
    /// don't exist on every Mac, so any one opening is enough.
    private static func canOpenProtectedFile() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/Library/Application Support/com.apple.TCC/TCC.db",
            "\(home)/Library/Application Support/com.apple.TCC/TCC.db",
            "\(home)/Library/Safari/Bookmarks.plist",
            "\(home)/Library/Safari/CloudTabs.db",
        ]
        return candidates.contains { path in
            let descriptor = open(path, O_RDONLY | O_NONBLOCK)
            guard descriptor >= 0 else { return false }
            close(descriptor)
            return true
        }
    }
}

/// Whose permission a guide asks for: XNotch's own, or another app's, such as
/// a helper an extension installs.
struct PermissionSubject {
    let bundleURL: URL
    let name: String
    let icon: NSImage
    /// XNotch itself: the guide checks where it runs from and offers to relaunch it.
    let isSelf: Bool

    @MainActor static var xnotch: PermissionSubject {
        PermissionSubject(bundleURL: Bundle.main.bundleURL, name: AppIcon.name, icon: AppIcon.image, isSelf: true)
    }

    static func app(at url: URL) -> PermissionSubject {
        let info = Bundle(url: url)?.infoDictionary
        let name = info?["CFBundleDisplayName"] as? String ?? info?["CFBundleName"] as? String
            ?? url.deletingPathExtension().lastPathComponent
        return PermissionSubject(bundleURL: url, name: name, icon: NSWorkspace.shared.icon(forFile: url.path), isSelf: false)
    }
}
