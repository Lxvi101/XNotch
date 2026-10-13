import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import XNotchLink

struct HomeView: View {
    @EnvironmentObject private var link: MacLink
    @State private var text = ""
    @State private var picksPhotos = false
    @State private var picksFiles = false
    @State private var photoItems: [PhotosPickerItem] = []
    @EnvironmentObject private var flow: PairingFlow
    @State private var confirmsForget = false
    @State private var preview: URL?
    @State private var stagingFailure: String?
    @FocusState private var composing: Bool

    var body: some View {
        VStack(spacing: 14) {
            MacCard(name: link.mac?.name ?? "Mac", status: link.status)
            BasketView(onAdd: { picksFiles = true })
                .frame(maxHeight: .infinity)
            if !link.received.isEmpty {
                ReceivedStrip(items: link.received, preview: $preview)
            }
            composer
            bottomBar
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(maxWidth: 640)
        .photosPicker(isPresented: $picksPhotos, selection: $photoItems, matching: .any(of: [.images, .videos]),
                      preferredItemEncoding: .current, photoLibrary: .shared())
        .fileImporter(isPresented: $picksFiles, allowedContentTypes: [.item, .folder], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task {
                let staged = await MacLink.stage(urls)
                link.send(files: staged.files)
                if !staged.failed.isEmpty {
                    stagingFailure = "XNotch couldn't read \(ListFormatter.localizedString(byJoining: staged.failed)). If it's in iCloud, open it in Files once so it downloads, then try again."
                }
            }
        }
        .alert("Couldn't add a file", isPresented: Binding(get: { stagingFailure != nil }, set: { if !$0 { stagingFailure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(stagingFailure ?? "")
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task {
                var staged: [URL] = []
                for item in items {
                    if let file = try? await item.loadTransferable(type: PickedFile.self) { staged.append(file.url) }
                }
                link.send(files: staged)
            }
        }
        .confirmationDialog("Forget \(link.mac?.name ?? "this Mac")?", isPresented: $confirmsForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) { if let id = link.mac?.id { link.forget(id) } }
        } message: {
            Text("To send to it again, scan its code again.")
        }
        .quickLookPreview($preview, in: link.received.map(\.url))
    }

    // MARK: Text

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Text for your Mac's clipboard", text: $text, axis: .vertical)
                .lineLimit(1...4)
                .font(.system(size: 17))
                .focused($composing)
                .padding(.horizontal, 18)
                .padding(.vertical, 15)
                .submitLabel(.send)
                .onSubmit(sendText)
            Button(action: sendText) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(canSendText ? .black : Palette.tertiary)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(canSendText ? Color.white : Palette.raised))
            }
            .disabled(!canSendText)
            .padding(.trailing, 8)
            .padding(.bottom, 8)
            .animation(.spring(response: 0.3), value: canSendText)
        }
        .background(RoundedRectangle(cornerRadius: 27, style: .continuous).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 27, style: .continuous).strokeBorder(.white.opacity(0.07)))
    }

    private var canSendText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func sendText() {
        guard canSendText else { return }
        link.send(text: text)
        text = ""
        composing = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            // PasteButton reads the clipboard without iOS asking each time. It
            // can't be sized freely, so it sits in a circle like its neighbours.
            PasteButton(payloadType: String.self) { strings in
                Task { @MainActor in
                    link.send(text: strings.joined(separator: "\n"))
                }
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.circle)
            .tint(Palette.card)
            .controlSize(.large)
            .frame(width: 54, height: 54)
            .background(Circle().fill(Palette.card))
            .overlay(Circle().strokeBorder(.white.opacity(0.07), lineWidth: 1).allowsHitTesting(false))

            Menu {
                if link.stored.pairings.count > 1 {
                    Picker("Send to", selection: Binding(get: { link.mac?.id ?? "" }, set: { link.select($0) })) {
                        ForEach(link.stored.pairings) { mac in
                            Label(mac.name, systemImage: "laptopcomputer").tag(mac.id)
                        }
                    }
                }
                Button { flow.beginScanning() } label: { Label("Pair Another Mac", systemImage: "qrcode.viewfinder") }
                if LinkBluetooth.isUndetermined {
                    Button { Task { await link.enableBluetooth() } } label: {
                        Label("Use Bluetooth When There's No Wi-Fi", systemImage: "dot.radiowaves.left.and.right")
                    }
                }
                Button(role: .destructive) { confirmsForget = true } label: { Label("Forget This Mac", systemImage: "trash") }
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(link.status.isConnected ? Palette.green : Palette.tertiary)
                        .frame(width: 8, height: 8)
                    Text(link.mac?.name ?? "Mac")
                        .font(.system(size: 17, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(Capsule().fill(Palette.card))
                .overlay(Capsule().strokeBorder(.white.opacity(0.07)))
            }

            Menu {
                Button { picksPhotos = true } label: { Label("Photos & Videos", systemImage: "photo.on.rectangle") }
                Button { picksFiles = true } label: { Label("Files", systemImage: "folder") }
            } label: {
                CircleButtonLabel(symbol: "plus")
            }
        }
    }
}

/// The Mac being sent to, as in "CONNECTED".
private struct MacCard: View {
    let name: String
    let status: MacLink.Status

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(Circle().fill(Palette.raised))
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                statusLine
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(.white.opacity(0.07)))
        .animation(.spring(response: 0.4), value: status)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status {
        case .connected(let route, let title):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.green)
                StatusCaps(text: "Connected", color: Palette.green)
                Text("·").foregroundStyle(Palette.tertiary)
                Label(title, systemImage: route.symbol)
                    .labelStyle(RouteLabelStyle())
            }
            .contentTransition(.opacity)
        case .searching, .unpaired:
            HStack(spacing: 7) {
                ProgressView().controlSize(.mini).tint(Palette.secondary)
                StatusCaps(text: "Looking for your Mac", color: Palette.secondary)
            }
        case .failed(let reason):
            Text(reason)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.orange)
                .lineLimit(2)
        }
    }
}

/// A photo or video from the picker, copied somewhere the app owns.
struct PickedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            PickedFile(url: try MacLink.stage(received.file))
        }
    }
}

/// "USB" with its glyph, quieter than the status beside it.
private struct RouteLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 11, weight: .semibold))
            configuration.title.font(.system(size: 13, weight: .bold)).tracking(0.8).textCase(.uppercase)
        }
        .foregroundStyle(Palette.secondary)
    }
}
