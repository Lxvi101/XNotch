import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WalkieSettingsPane: View {
    @ObservedObject var store: WalkieStore
    @State private var revealed: String?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    FaceImage(name: store.displayName, seed: store.mailbox.box, avatar: store.avatar)
                        .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Name", text: $store.displayName, prompt: Text("Your name"))
                        HStack {
                            Button("Choose Photo…", action: choosePhoto)
                            if store.avatar != nil {
                                Button("Remove Photo") { store.avatar = nil }
                            }
                        }
                    }
                }
            } header: {
                Text("You")
            } footer: {
                Text("This is what the people you add see on their face for you.")
                    .foregroundStyle(.secondary)
            }

            Section {
                statusRow
                TextField("Server URL", text: $store.server,
                          prompt: Text(store.usesCloudServer ? "Same as Cloud Links" : "https://drop.example.com"))
                SecureField("Access token", text: $store.token,
                            prompt: Text(store.usesCloudServer ? "Same as Cloud Links" : "API_TOKEN from the server"))
                Toggle("Show me to others on this server", isOn: $store.listed)
            } header: {
                Text("Server")
            } footer: {
                Text("Walkie uses your XNotch Cloud server, the same one as Cloud Links. Leave these empty to share its settings. People on other servers can still reach you with your invite.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show faces in the menu bar", isOn: $store.menuBarFaces)
                Toggle("Play voice notes as they arrive", isOn: $store.autoPlay)
                Toggle("Put received files in the tray", isOn: $store.filesToTray)
                Toggle("Write down what I say (on this Mac)", isOn: $store.transcribe)
                    .onChange(of: store.transcribe) { _, on in
                        if on { Task { _ = await VoiceRecorder.requestSpeech() } }
                    }
            } header: {
                Text("Talking")
            }

            Section {
                if store.contacts.isEmpty {
                    Text("People you add appear here.").foregroundStyle(.secondary)
                }
                ForEach(store.contacts) { contact in
                    ContactRow(store: store, contact: contact, revealed: $revealed)
                }
            } header: {
                Text("People")
            } footer: {
                Text("To check that nobody sits in the middle, compare the safety number with the other person, in person or on a call. If both see the same numbers, mark them verified.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Encryption", value: "X-Wing (ML-KEM-768 + X25519), AES-256-GCM")
                LabeledContent("Signatures", value: "ML-DSA-65 + Ed25519")
                LabeledContent("Your fingerprint") {
                    Text(store.fingerprint.prefix(10).hex.uppercased().chunked(4))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            } header: {
                Text("Security")
            } footer: {
                Text("Voice notes, transcripts, files and to-dos are sealed on this Mac for one person and signed by you. Your server only stores ciphertext, and it deletes messages after they're fetched or after a week. It can still see who writes to whom, when, and how much.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack {
            switch store.status {
            case .needsServer:
                Label("Add a server here or in Cloud Links", systemImage: "server.rack").foregroundStyle(.secondary)
            case .connecting:
                ProgressView().controlSize(.small)
                Text("Connecting…")
            case .online:
                Label("Connected, listening for messages", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .offline(let reason):
                Label(reason, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(2)
            }
            Spacer()
            Button("Reconnect", action: store.reconnect)
        }
    }

    private func choosePhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.prompt = "Use Photo"
        let store = store
        panel.presentAboveOverlays { urls in
            guard let url = urls.first, let image = NSImage(contentsOf: url) else { return }
            store.avatar = Self.avatarJPEG(image)
        }
    }

    /// A centred square, 160 px, JPEG: small enough to ride along in every card.
    static func avatarJPEG(_ image: NSImage) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = min(cg.width, cg.height)
        guard let square = cg.cropping(to: CGRect(x: (cg.width - side) / 2, y: (cg.height - side) / 2, width: side, height: side)) else { return nil }
        let size = 160
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.78])
    }
}

private struct ContactRow: View {
    @ObservedObject var store: WalkieStore
    let contact: Contact
    @Binding var revealed: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                FaceImage(name: contact.name, seed: contact.box, avatar: contact.avatar)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(contact.name)
                    Text(contact.verified ? "Verified" : contact.accepted ? "Not verified" : "Wants to talk")
                        .font(.caption)
                        .foregroundStyle(contact.verified ? .green : .secondary)
                }
                Spacer()
                if !contact.accepted {
                    Button("Accept") { store.accept(contact) }
                }
                Button(revealed == contact.box ? "Hide Safety Number" : "Safety Number") {
                    revealed = revealed == contact.box ? nil : contact.box
                }
                Button(role: .destructive) {
                    store.remove(contact)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove \(contact.firstName) and your conversation")
            }
            if revealed == contact.box {
                HStack(alignment: .top) {
                    Text(store.safetyNumber(with: contact).chunkedLines(groupsPerLine: 4))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    if !contact.verified {
                        Button("They Match") { store.markVerified(contact) }
                    }
                }
                .padding(.leading, 38)
            }
        }
        .padding(.vertical, 2)
    }
}

extension String {
    func chunked(_ size: Int) -> String {
        stride(from: 0, to: count, by: size).map { offset in
            let start = index(startIndex, offsetBy: offset)
            let end = index(start, offsetBy: size, limitedBy: endIndex) ?? endIndex
            return String(self[start..<end])
        }.joined(separator: " ")
    }

    func chunkedLines(groupsPerLine: Int) -> String {
        let groups = split(separator: " ")
        return stride(from: 0, to: groups.count, by: groupsPerLine).map {
            groups[$0..<min($0 + groupsPerLine, groups.count)].joined(separator: " ")
        }.joined(separator: "\n")
    }
}
