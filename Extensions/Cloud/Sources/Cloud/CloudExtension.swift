import AppKit
import SwiftUI
import XNotchKit

@objc(CloudPrincipal)
public final class CloudPrincipal: NSObject, XNotchExtensionPrincipal {
    public override init() { super.init() }

    @MainActor public func makeExtension() -> AnyObject { CloudExtension() }
}

@MainActor
final class CloudExtension: XNotchExtension, SettingsPaneProviding, ShelfAccessoryProviding {
    static let id: ExtensionID = "cloud"

    private var links: CloudLinks?
    private var host: ExtensionHost?

    func activate(host: ExtensionHost) throws {
        self.host = host
        let links = CloudLinks(defaults: host.storage.defaults, log: host.log)
        links.onCopied = { [weak host] in host?.feedback.tick() }
        self.links = links
    }

    func deactivate() {
        links = nil
        host = nil
    }

    func makeSettingsPane() -> AnyView {
        guard let links else { return AnyView(EmptyView()) }
        return AnyView(CloudSettingsPane(links: links))
    }

    func makeShelfAccessory(context: ShelfContext) -> AnyView? {
        guard let links else { return nil }
        return AnyView(CloudButton(links: links, context: context, openSettings: { [weak host] in host?.notch.openSettings() }))
    }

    func shelfMenuItems(for files: [URL]) -> [NotchMenuItem] {
        guard let links, links.isConfigured, !links.isUploading else { return [] }
        return [.action("Copy Cloud Link (\(CloudLinks.title(for: links.defaultExpiry)))", symbol: "link") {
            links.share(files, expiresIn: links.defaultExpiry)
        }]
    }
}

/// The shelf header's cloud: a click offers how long the link lives.
struct CloudButton: View {
    @ObservedObject var links: CloudLinks
    let context: ShelfContext
    let openSettings: () -> Void

    var body: some View {
        ShelfHeaderButton(action: {}) {
            CloudGlyph(transfer: links.transfer)
        }
        .notchMenu { menu }
        .help(help)
    }

    private var menu: [NotchMenuItem] {
        guard links.isConfigured else {
            return [.action("Set Up Cloud Links…", symbol: "gearshape", handler: openSettings)]
        }
        guard !links.isUploading else { return [] }
        var items: [NotchMenuItem] = links.availableExpiries.map { choice in
            .action("Link for \(choice.title)", symbol: choice.seconds == links.defaultExpiry ? "link" : nil) {
                links.share(context.targets, expiresIn: choice.seconds)
            }
        }
        items.append(.separator)
        items.append(.action("Cloud Links Settings…", symbol: "gearshape", handler: openSettings))
        return items
    }

    private var help: String {
        switch links.transfer {
        case .failed(let reason): reason
        case .copied: "Link copied"
        case .uploading: "Uploading…"
        case .idle: links.isConfigured ? "Share as a link" : "Set up Cloud Links"
        }
    }
}

struct CloudGlyph: View {
    let transfer: CloudLinks.Transfer

    var body: some View {
        ZStack {
            switch transfer {
            case .idle:
                Image(systemName: "icloud.and.arrow.up")
            case .uploading(let fraction):
                Circle().stroke(.white.opacity(0.18), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: max(0.04, fraction))
                    .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.2), value: fraction)
            case .copied:
                Image(systemName: "link").foregroundStyle(KitStyle.green)
            case .failed:
                Image(systemName: "exclamationmark.icloud").foregroundStyle(.red)
            }
        }
        .frame(width: 14, height: 14)
        .animation(KitMotion.content, value: transfer)
    }
}
