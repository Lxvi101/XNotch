import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Walkie in Settings, top to bottom in the order you need it: whether it can
/// work at all, who you are, adding friends, who asked to talk, your friends,
/// how it behaves. Server and encryption details wait folded at the bottom.
struct WalkieSettingsPane: View {
    @ObservedObject var store: WalkieStore
    @State private var revealed: String?
    @State private var showsServer = false
    @State private var showsSecurity = false

    private var requests: [Contact] { store.contacts.filter { !$0.accepted } }
    private var friends: [Contact] { store.contacts.filter(\.accepted) }

    var body: some View {
        Form {
            if store.status == .needsServer {
                Section {
                    SetupCard()
                    serverFields
                } footer: {
                    Text("Walkie uses your XNotch Cloud server, the same one as Cloud Links. If Cloud Links is set up, Walkie connects by itself.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Section { statusRow }
            }

            Section {
                HStack(spacing: 14) {
                    FaceImage(name: store.displayName, seed: store.mailbox.box, avatar: store.avatar)
                        .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Name", text: $store.displayName, prompt: Text("Your name"))
                            .labelsHidden()
                        HStack {
                            Button("Choose Photo…", action: choosePhoto)
                            if store.avatar != nil {
                                Button("Remove") { store.avatar = nil }
                            }
                        }
                        .controlSize(.small)
                    }
                }
            } header: {
                Text("You")
            } footer: {
                Text("Your friends see this name and photo on your face.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }

            AddFriendsSection(store: store)

            if !requests.isEmpty {
                Section {
                    ForEach(requests) { contact in
                        RequestRow(store: store, contact: contact)
                    }
                } header: {
                    Text("Requests")
                } footer: {
                    Text("They added you. Accept to talk back, or decline to remove them and anything they sent.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Section {
                if friends.isEmpty {
                    Text("No friends yet. Share your invite, or add someone above.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(friends) { contact in
                    FriendRow(store: store, contact: contact, revealed: $revealed)
                }
            } header: {
                Text("Friends")
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

            if store.status != .needsServer {
                Section {
                    DisclosureGroup("Server", isExpanded: $showsServer) { serverFields }
                }
            }

            Section {
                DisclosureGroup("Encryption", isExpanded: $showsSecurity) {
                    LabeledContent("Encryption", value: "X-Wing (ML-KEM-768 + X25519), AES-256-GCM")
                    LabeledContent("Signatures", value: "ML-DSA-65 + Ed25519")
                    LabeledContent("Your fingerprint") {
                        Text(store.fingerprint.prefix(10).hex.uppercased().chunked(4))
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Text("Voice notes, transcripts, files and to-dos are sealed on this Mac for one person and signed by you. Your server only stores ciphertext, and deletes messages once they're fetched or after a week. It can still see who writes to whom, when, and how much.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var serverFields: some View {
        TextField("Server URL", text: $store.server,
                  prompt: Text(store.usesCloudServer ? "Same as Cloud Links" : "https://drop.example.com"))
        SecureField("Access token", text: $store.token,
                    prompt: Text(store.usesCloudServer ? "Same as Cloud Links" : "API_TOKEN from the server"))
        Toggle("Let others on this server find me", isOn: $store.listed)
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 8) {
            switch store.status {
            case .needsServer:
                EmptyView()
            case .connecting:
                ProgressView().controlSize(.small)
                Text("Connecting…")
            case .online:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Connected")
            case .offline(let reason):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(reason).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if store.status != .online {
                Button("Reconnect", action: store.reconnect)
            }
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

/// Shown while there's no server: what's missing and how to fix it.
private struct SetupCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.orange)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text("Connect a server to start")
                    .font(.headline)
                Text("Walkie sends through your own XNotch Cloud server. Enter its address and access token below.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Your invite out, theirs in, and people on your server, in one place.
private struct AddFriendsSection: View {
    @ObservedObject var store: WalkieStore
    @State private var pasted = ""
    @State private var adding = false
    @State private var copied = false
    @State private var message: (text: String, failed: Bool)?
    /// An invite found on the clipboard when Settings opened.
    @State private var clipboardInvite: WalkieInvite?

    /// What gets copied and shared: a line that says what it is, then the invite.
    private var shareText: String? {
        store.invite.map { "Add me on Walkie in XNotch: \($0.text)" }
    }

    var body: some View {
        Section {
            LabeledContent {
                HStack(spacing: 8) {
                    Button(copied ? "Copied" : "Copy") {
                        guard let shareText else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(shareText, forType: .string)
                        withAnimation(.smooth(duration: 0.25)) { copied = true }
                    }
                    if let shareText {
                        ShareLink(item: shareText) { Text("Share…") }
                    }
                }
                .disabled(store.invite == nil)
            } label: {
                Text("Your invite")
                Text(store.invite == nil ? "Ready once a server is connected." : "Send it to a friend. Their Walkie adds you.")
            }

            if let invite = clipboardInvite, invite.text != store.invite?.text {
                HStack {
                    Image(systemName: "doc.on.clipboard").foregroundStyle(.secondary)
                    Text("You copied a Walkie invite.")
                    Spacer()
                    Button("Add Friend") { add(invite) }
                        .buttonStyle(.borderedProminent)
                }
            }

            HStack {
                TextField("Friend's invite", text: $pasted, prompt: Text("Paste a friend's invite"))
                    .labelsHidden()
                    .onSubmit { WalkieInvite(text: pasted).map(add) }
                if adding {
                    ProgressView().controlSize(.small)
                }
            }

            if let message {
                Label(message.text, systemImage: message.failed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(message.failed ? Color.red : Color.green)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(store.directory, id: \.box) { listed in
                if let card = WalkieCrypto.SignedCard(base64: listed.card).flatMap({ try? $0.open() }) {
                    HStack(spacing: 10) {
                        FaceImage(name: card.name, seed: card.box, avatar: card.avatar)
                            .frame(width: 26, height: 26)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(card.name)
                            Text("On your server").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Add") { add(listed, name: card.name) }
                    }
                }
            }
        } header: {
            Text("Add Friends")
        }
        .onAppear {
            store.refreshDirectory()
            // Read once as Settings opens, never polled.
            clipboardInvite = NSPasteboard.general.string(forType: .string).flatMap(WalkieInvite.init(text:))
                .flatMap { invite in store.contact(invite.box) == nil ? invite : nil }
        }
        .onChange(of: pasted) { _, text in
            // A whole invite pasted in is added right away; no button to find.
            if let invite = WalkieInvite(text: text) { add(invite) } else if !text.isEmpty { message = nil }
        }
        .onChange(of: store.invite) { _, _ in copied = false }
    }

    private func add(_ invite: WalkieInvite) {
        guard !adding else { return }
        adding = true
        message = nil
        Task {
            defer { adding = false }
            do {
                try await store.add(invite: invite)
                pasted = ""
                if clipboardInvite == invite { clipboardInvite = nil }
                let name = store.contact(invite.box)?.firstName ?? "Your friend"
                withAnimation(.smooth(duration: 0.3)) { message = ("\(name) is added. Hold their face to talk.", false) }
            } catch {
                withAnimation(.smooth(duration: 0.3)) { message = (error.localizedDescription, true) }
            }
        }
    }

    private func add(_ listed: WalkieClient.Listed, name: String) {
        do {
            try store.add(listed: listed)
            withAnimation(.smooth(duration: 0.3)) { message = ("\(name) is added.", false) }
        } catch {
            withAnimation(.smooth(duration: 0.3)) { message = (error.localizedDescription, true) }
        }
    }
}

/// Someone who added you and is waiting for a yes.
private struct RequestRow: View {
    @ObservedObject var store: WalkieStore
    let contact: Contact

    var body: some View {
        HStack(spacing: 10) {
            FaceImage(name: contact.name, seed: contact.box, avatar: contact.avatar)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(contact.name)
                Text(waiting).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Decline") { store.remove(contact) }
            Button("Accept") { store.accept(contact) }
                .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 2)
    }

    private var waiting: String {
        let count = store.chats[contact.box]?.count ?? 0
        return count == 0 ? "Wants to talk" : count == 1 ? "Sent you a message" : "Sent you \(count) messages"
    }
}

private struct FriendRow: View {
    @ObservedObject var store: WalkieStore
    let contact: Contact
    @Binding var revealed: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                FaceImage(name: contact.name, seed: contact.box, avatar: contact.avatar)
                    .frame(width: 28, height: 28)
                    .overlay(alignment: .bottomTrailing) {
                        if store.online.contains(contact.box) {
                            Circle().fill(.green).frame(width: 8, height: 8)
                                .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                        }
                    }
                HStack(spacing: 4) {
                    Text(contact.name)
                    if contact.verified {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .help("Keys checked")
                    }
                }
                Spacer()
                Menu {
                    Button(revealed == contact.box ? "Hide Safety Number" : "Check Safety Number") {
                        revealed = revealed == contact.box ? nil : contact.box
                    }
                    Divider()
                    Button("Remove \(contact.firstName)", role: .destructive) { store.remove(contact) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            if revealed == contact.box {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Compare these numbers with \(contact.firstName), in person or on a call. If they match, nobody sits in the middle.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .top) {
                        Text(store.safetyNumber(with: contact).chunkedLines(groupsPerLine: 4))
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        if !contact.verified {
                            Button("They Match") { store.markVerified(contact) }
                        }
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
