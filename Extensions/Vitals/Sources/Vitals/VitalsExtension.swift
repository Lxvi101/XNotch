import AppKit
import SwiftUI
import XNotchKit

@objc(VitalsPrincipal)
public final class VitalsPrincipal: NSObject, XNotchExtensionPrincipal {
    public override init() { super.init() }

    @MainActor public func makeExtension() -> AnyObject { VitalsExtension() }
}

@MainActor
final class VitalsExtension: XNotchExtension {
    static let id: ExtensionID = "vitals"
    nonisolated static let pageID = "vitals"

    let model = VitalsModel()
    private var host: ExtensionHost?
    /// The descriptor XNotch last read, so it's only told about real changes.
    private var lastPage: NotchPageDescriptor?

    func activate(host: ExtensionHost) throws {
        self.host = host
        model.load(defaults: host.storage.defaults)
        model.onAlert = { [weak self] alert in self?.show(alert) }
        model.onLayoutChange = { [weak self] in self?.pageMayHaveChanged() }
        model.start()
        host.log.info("Vitals activated")
    }

    func deactivate() {
        model.stop()
        model.onAlert = nil
        model.onLayoutChange = nil
        model.expanded = nil
        lastPage = nil
        host = nil
    }

    /// With eyes when the user picked them, and this XNotch can draw them.
    private func show(_ alert: NotchAlert) {
        guard let host else { return }
        if model.settings.alertsShowEyes, let eyes = host.notch as? NotchEyesAlerting {
            eyes.showAlert(alert, eyes: alert.tint == AlertMonitor.criticalTint ? .critical : .caution)
        } else {
            host.notch.showAlert(alert)
        }
    }

    func openActivityMonitor() {
        guard let host,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") else { return }
        host.feedback.tick()
        host.workspace.open(url)
        host.notch.close()
    }

    /// The trackpad tick, for a tile picked up or passing a slot.
    func tick() {
        host?.feedback.tick()
    }

    func customize() {
        host?.notch.openSettings()
    }

    /// A breakdown opening or growing reshapes the notch.
    private func pageMayHaveChanged() {
        guard let page = pages.first, page != lastPage else { return }
        lastPage = page
        host?.notch.pagesDidChange()
    }
}

extension VitalsExtension: NotchPageProviding {
    var pages: [NotchPageDescriptor] {
        [NotchPageDescriptor(id: Self.pageID, title: "Vitals", symbol: "waveform.path.ecg",
                             contentHeight: VitalsPage.height(for: model))]
    }

    func makePageView(for page: NotchPageDescriptor, context: NotchPageContext) -> AnyView {
        AnyView(VitalsPage(model: model, extension: self, size: context.size, isActive: context.isActive))
    }
}

extension VitalsExtension: SettingsPaneProviding {
    func makeSettingsPane() -> AnyView {
        AnyView(VitalsSettingsPane(model: model, extension: self))
    }
}
