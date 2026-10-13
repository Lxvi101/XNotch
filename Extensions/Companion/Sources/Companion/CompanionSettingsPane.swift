import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import XNotchLink

struct CompanionSettingsPane: View {
    @ObservedObject var server: CompanionServer
    @State private var confirmsReset = false
    /// The code holds the pairing key: shown on request, hidden again soon.
    @State private var showsCode = false
    @State private var cloudLinks: (url: String, token: String)?

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 18) {
                    if showsCode {
                        PairingCode(url: server.pairing.url)
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Scan with XNotch on your iPhone or iPad")
                            .font(.headline)
                        Text("Then share files and text to “XNotch” from any app. Anyone who scans this code can send to this Mac, so show it only to your own devices.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        status
                        Button(showsCode ? "Hide Code" : "Show Pairing Code") {
                            withAnimation(.easeOut(duration: 0.2)) { showsCode.toggle() }
                        }
                    }
                }
                .padding(.vertical, 6)
                .task(id: showsCode) {
                    guard showsCode else { return }
                    try? await Task.sleep(nanoseconds: 180_000_000_000)
                    withAnimation(.easeOut(duration: 0.2)) { showsCode = false }
                }
            } header: {
                Text("Pair")
            }

            Section {
                if server.devices.isEmpty {
                    Text("No device connected. The app connects while it's open, and so does sharing to XNotch.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(server.devices) { device in
                        HStack {
                            Label(device.info.name, systemImage: device.info.kind == .iPad ? "ipad" : "iphone")
                            Spacer()
                            Label(device.routeTitle, systemImage: device.route.symbol)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Connected")
            }

            Section {
                RouteRow(route: .usb, status: server.usbDevices > 0
                         ? "iPhone or iPad plugged in: connects while XNotch is open on it"
                         : "Plug in an iPhone or iPad with a cable", isOn: server.usbDevices > 0)
                RouteRow(route: .local, status: localStatus, isOn: server.state == .listening)
                RouteRow(route: .internet, status: relayStatus, isOn: server.relayState == .ready)
                RouteRow(route: .bluetooth, status: bluetoothStatus, isOn: server.bluetoothEnabled && LinkBluetooth.isAllowed && server.bluetoothStatus == nil) {
                    Toggle("Bluetooth", isOn: $server.bluetoothEnabled).labelsHidden()
                }
                if server.bluetoothEnabled && LinkBluetooth.isUndetermined {
                    Button("Allow Bluetooth…") { server.startBluetooth() }
                }
            } header: {
                Text("Routes")
            } footer: {
                Text("XNotch uses the fastest route that's up: a cable, then Wi-Fi (or peer-to-peer Wi-Fi when you're near), then the internet, then Bluetooth. Everything is encrypted end to end with the pairing key.")
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("Relay server", text: $server.relayServer, prompt: Text("https://drop.example.com"))
                SecureField("Access token", text: $server.relayToken, prompt: Text("API_TOKEN from the server"))
                HStack {
                    if let cloud = cloudLinks, cloud.url != server.relayServer {
                        Button("Use the Cloud Links Server") {
                            server.relayServer = cloud.url
                            server.relayToken = cloud.token
                            server.applyRelaySettings()
                        }
                    }
                    Spacer()
                }
            } header: {
                Text("Over the Internet")
            } footer: {
                Text("Your XNotch Cloud server passes encrypted bytes between your iPhone and this Mac when they aren't on the same network. It can't read them. After setting it up, open the app on your iPhone once on the same network, or scan the code again, so it learns the server.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Save received files to") {
                    HStack {
                        Text((server.destination.path as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Change…", action: chooseDestination)
                    }
                }
            } footer: {
                Text("Received files also land on the shelf. Text goes straight to the clipboard.")
                    .foregroundStyle(.secondary)
            }

            if !server.recent.isEmpty {
                Section("Recent") {
                    ForEach(server.recent) { activity in
                        HStack {
                            Label(activity.text, systemImage: activity.symbol)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(activity.date, style: .relative)
                                .foregroundStyle(.tertiary)
                                .font(.caption)
                        }
                    }
                }
            }

            Section {
                Button("Reset Pairing…", role: .destructive) { confirmsReset = true }
            } footer: {
                Text("Disconnects every paired device. Each one then has to scan the new code.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Read once: not on every redraw while a transfer updates the pane.
        .onAppear { cloudLinks = server.cloudLinksServer }
        .onDisappear { showsCode = false }
        .confirmationDialog("Reset pairing?", isPresented: $confirmsReset) {
            Button("Reset Pairing", role: .destructive) { server.resetPairing() }
        } message: {
            Text("Every iPhone and iPad paired with this Mac has to scan the new code.")
        }
    }

    private var localStatus: String {
        switch server.state {
        case .listening: "Ready on this network and nearby"
        case .starting, .stopped: "Starting…"
        case .failed(let reason): reason
        }
    }

    private var relayStatus: String {
        switch server.relayState {
        case .off: server.relayProblem ?? "Off. Add your XNotch Cloud server below."
        case .connecting: "Connecting to the relay…"
        case .ready: "Waiting at \(server.relayURL?.host ?? "the relay")"
        case .failed(let reason): reason
        }
    }

    private var bluetoothStatus: String {
        guard server.bluetoothEnabled else { return "Off" }
        if LinkBluetooth.isUndetermined { return "Needs your permission" }
        if !LinkBluetooth.isAllowed { return "Not allowed: turn it on in System Settings → Privacy & Security → Bluetooth" }
        return server.bluetoothStatus ?? "Advertising to your devices"
    }

    @ViewBuilder
    private var status: some View {
        switch server.state {
        case .listening:
            Label("Ready on this network", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .starting, .stopped:
            Label("Starting…", systemImage: "hourglass")
                .foregroundStyle(.secondary)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = server.destination
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { server.destination = url }
    }
}

/// The pairing URL as a QR code, dark on white so any camera reads it.
private struct PairingCode: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
            } else {
                Color.white
            }
        }
        .frame(width: 148, height: 148)
        // Made once per code, not on every redraw.
        .task(id: url) { image = Self.image(for: url.absoluteString) }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }

    private static func image(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}

/// A route, whether it's up, and what it's doing.
private struct RouteRow<Accessory: View>: View {
    let route: LinkRoute
    let status: String
    let isOn: Bool
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: route.symbol)
                .foregroundStyle(isOn ? Color.accentColor : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(route.title)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            accessory
        }
    }
}

extension RouteRow where Accessory == EmptyView {
    init(route: LinkRoute, status: String, isOn: Bool) {
        self.init(route: route, status: status, isOn: isOn) { EmptyView() }
    }
}
