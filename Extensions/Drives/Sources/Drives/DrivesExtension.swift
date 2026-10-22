import AppKit
import SwiftUI
import XNotchKit

@objc(DrivesPrincipal)
public final class DrivesPrincipal: NSObject, XNotchExtensionPrincipal {
    public override init() { super.init() }

    @MainActor public func makeExtension() -> AnyObject { DrivesExtension() }
}

@MainActor
final class DrivesExtension: XNotchExtension {
    static let id: ExtensionID = "drives"
    nonisolated static let pageID = "drives"
    static let tint = "#FF9F0A"

    let monitor = DriveMonitor()
    private var host: ExtensionHost?
    /// Whether XNotch last saw the page: it's only there while a drive is.
    private var showsPage = false

    func activate(host: ExtensionHost) throws {
        self.host = host
        monitor.load(defaults: host.storage.defaults)
        monitor.onChange = { [weak self] in self?.drivesChanged() }
        monitor.onConnect = { [weak self] drive in self?.announce(drive) }
        monitor.onEjected = { [weak self] drive in self?.ejected(drive) }
        monitor.start()
        host.log.info("Drives activated")
    }

    func deactivate() {
        monitor.stop()
        monitor.onChange = nil
        monitor.onConnect = nil
        monitor.onEjected = nil
        showsPage = false
        host = nil
    }

    func open(_ drive: Drive) {
        guard let host else { return }
        host.feedback.tick()
        host.workspace.open(drive.url)
        host.notch.close()
    }

    func reveal(_ drive: Drive) {
        host?.workspace.reveal([drive.url])
        host?.notch.close()
    }

    func eject(_ drive: Drive) {
        host?.feedback.tick()
        monitor.eject(drive)
    }

    func ejectAll() {
        monitor.drives.forEach(eject)
    }

    private func drivesChanged() {
        let hasDrives = !monitor.drives.isEmpty
        guard hasDrives != showsPage else { return }
        showsPage = hasDrives
        // Nothing left to show: close rather than land on another page.
        if !hasDrives, host?.notch.isOpen == true { host?.notch.close() }
        host?.notch.pagesDidChange()
    }

    private func announce(_ drive: Drive) {
        guard monitor.settings.alertsOnConnect else { return }
        let free = drive.free.map { "\(DriveFormat.bytes($0)) free" }
        // Each side of the wings fits about ten characters.
        let value = free.flatMap { $0.count <= 10 ? $0 : drive.free.map(DriveFormat.bytes) } ?? "Connected"
        host?.notch.showAlert(NotchAlert(symbol: drive.kind.symbol, tint: Self.tint, title: Self.short(drive.name),
                                         value: value, progress: drive.freeFraction, page: Self.pageID))
    }

    private func ejected(_ drive: Drive) {
        guard monitor.settings.alertsOnEject else { return }
        // KitStyle.green: it's safe to unplug.
        host?.notch.showAlert(NotchAlert(symbol: "eject.fill", tint: "#5CE68F", title: Self.short(drive.name),
                                         value: "Ejected"))
    }

    private static func short(_ name: String) -> String {
        name.count <= 10 ? name : String(name.prefix(9)) + "…"
    }
}

extension DrivesExtension: NotchPageProviding {
    var pages: [NotchPageDescriptor] {
        guard showsPage else { return [] }
        return [NotchPageDescriptor(id: Self.pageID, title: "Drives", symbol: "externaldrive.fill")]
    }

    func makePageView(for page: NotchPageDescriptor, context: NotchPageContext) -> AnyView {
        AnyView(DrivesPage(monitor: monitor, extension: self, size: context.size, isActive: context.isActive))
    }
}

extension DrivesExtension: SettingsPaneProviding {
    func makeSettingsPane() -> AnyView {
        AnyView(DrivesSettingsPane(monitor: monitor))
    }
}
