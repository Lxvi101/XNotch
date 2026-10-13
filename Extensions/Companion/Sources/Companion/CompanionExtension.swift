import AppKit
import SwiftUI
import XNotchKit
import XNotchLink

@objc(CompanionPrincipal)
public final class CompanionPrincipal: NSObject, XNotchExtensionPrincipal {
    public override init() { super.init() }

    @MainActor public func makeExtension() -> AnyObject { CompanionExtension() }
}

@MainActor
final class CompanionExtension: XNotchExtension, SettingsPaneProviding, ShelfAccessoryProviding, PermissionRequesting {
    static let id: ExtensionID = "companion"

    private var server: CompanionServer?
    private var host: ExtensionHost?

    func activate(host: ExtensionHost) throws {
        self.host = host
        let server = CompanionServer(defaults: host.storage.defaults, directory: host.storage.directory, log: host.log)
        server.onFiles = { [weak host] urls in
            host?.feedback.tick()
            host?.shelf.add(urls)
        }
        server.onText = { [weak host] in host?.feedback.tick() }
        server.start()
        self.server = server
    }

    func deactivate() {
        server?.stop()
        server = nil
        host = nil
    }

    // MARK: Permissions

    /// Bluetooth is the route that works without any Wi-Fi; macOS asks once.
    var pendingPermissions: [ExtensionPermission] {
        guard server?.bluetoothEnabled == true, LinkBluetooth.isUndetermined else { return [] }
        return [ExtensionPermission(id: "bluetooth", title: "iPhone over Bluetooth", detail: "Bluetooth",
                                    reason: "With no Wi-Fi around, your iPhone can still reach this Mac over Bluetooth. Slower, but it works anywhere.",
                                    symbol: "dot.radiowaves.left.and.right", tint: "#0A84FF")]
    }

    func requestPermission(_ id: String) async -> Bool {
        server?.startBluetooth()
        for _ in 0..<240 where LinkBluetooth.isUndetermined {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return LinkBluetooth.isAllowed
    }

    func makeSettingsPane() -> AnyView {
        guard let server else { return AnyView(EmptyView()) }
        return AnyView(CompanionSettingsPane(server: server))
    }

    func makeShelfAccessory(context: ShelfContext) -> AnyView? {
        guard let server else { return nil }
        return AnyView(SendToDeviceButton(server: server, context: context))
    }

    func shelfMenuItems(for files: [URL]) -> [NotchMenuItem] {
        guard let server, !server.isSending else { return [] }
        return server.devices.map { device in
            .action("Send to \(device.info.name)", symbol: device.info.kind == .iPad ? "ipad" : "iphone") {
                server.send(files, to: device)
            }
        }
    }
}

/// Shown in the shelf header while an iPhone or iPad is connected.
struct SendToDeviceButton: View {
    @ObservedObject var server: CompanionServer
    let context: ShelfContext

    var body: some View {
        if !server.devices.isEmpty || server.transfer != .idle {
            Group {
                if server.devices.count > 1 {
                    // Several devices: the click opens a menu to pick one.
                    label.notchMenu {
                        server.devices.map { device in
                            .action("Send to \(device.info.name)", symbol: symbol(for: device)) {
                                server.send(context.targets, to: device)
                            }
                        }
                    }
                } else {
                    label
                }
            }
            .help(help)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
    }

    private var label: some View {
        ShelfHeaderButton(action: {
            guard server.devices.count == 1, let device = server.devices.first else { return }
            server.send(context.targets, to: device)
        }, label: {
            TransferGlyph(transfer: server.transfer, symbol: server.devices.first.map(symbol(for:)) ?? "iphone")
        })
    }

    private var help: String {
        switch server.transfer {
        case .failed(let reason): return reason
        default:
            guard let device = server.devices.first else { return "" }
            return server.devices.count == 1 ? "Send to \(device.info.name) · \(device.routeTitle)" : "Send to a device"
        }
    }

    private func symbol(for device: CompanionServer.Device) -> String {
        device.info.kind == .iPad ? "ipad" : "iphone"
    }
}

/// The header glyph: the device, a progress ring, then a check or a cross.
struct TransferGlyph: View {
    let transfer: CompanionServer.Transfer
    let symbol: String

    var body: some View {
        ZStack {
            switch transfer {
            case .idle:
                Image(systemName: symbol)
            case .sending(let fraction):
                Circle().stroke(.white.opacity(0.18), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: max(0.04, fraction))
                    .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.2), value: fraction)
            case .sent:
                Image(systemName: "checkmark").foregroundStyle(KitStyle.green)
            case .failed:
                Image(systemName: "exclamationmark").foregroundStyle(.red)
            }
        }
        .frame(width: 13, height: 13)
        .contentTransition(.symbolEffect(.replace))
        .animation(KitMotion.content, value: transfer)
    }
}
