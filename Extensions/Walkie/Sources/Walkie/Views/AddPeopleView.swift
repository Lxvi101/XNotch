import AppKit
import SwiftUI

/// Invite sharing and server discovery live in the Walkie Settings form.
struct AddPeopleView: View {
    @ObservedObject var store: WalkieStore
    @State private var pasted = ""
    @State private var adding = false
    @State private var copied = false
    @State private var error: String?

    var body: some View {
        Group {
            Section {
                TextField("Their invite", text: $pasted, prompt: Text("xnotch-walkie:…"))
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(addPasted)
                HStack {
                    Button("Paste") {
                        pasted = NSPasteboard.general.string(forType: .string) ?? ""
                        error = nil
                    }
                    Spacer()
                    if adding { ProgressView().controlSize(.small) }
                    Button("Add Person", action: addPasted)
                        .disabled(WalkieInvite(text: pasted) == nil || adding)
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Add Someone")
            } footer: {
                Text("Paste the invite they shared with you, then add them to Walkie.")
            }

            Section {
                HStack {
                    Text(store.invite?.text ?? "Connect a server to create your invite.")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button(copied ? "Copied" : "Copy Invite") {
                        guard let text = store.invite?.text else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        copied = true
                    }
                    .disabled(store.invite == nil)
                }
            } header: {
                Text("Your Invite")
            } footer: {
                Text("Share your invite with someone so they can add you. It lets them send to you and verifies your encryption keys.")
            }

            Section {
                if store.directory.isEmpty {
                    Text("No new people found on your server.").foregroundStyle(.secondary)
                }
                ForEach(store.directory, id: \.box) { listed in
                    if let card = WalkieCrypto.SignedCard(base64: listed.card).flatMap({ try? $0.open() }) {
                        HStack(spacing: 10) {
                            FaceImage(name: card.name, seed: card.box, avatar: card.avatar)
                                .frame(width: 28, height: 28)
                            Text(card.name)
                            Spacer()
                            Button("Add") { add(listed) }
                        }
                    }
                }
                Button("Refresh People", action: store.refreshDirectory)
            } header: {
                Text("On Your Server")
            }
        }
        .onAppear { store.refreshDirectory() }
        .onChange(of: pasted) { _, _ in error = nil }
        .onChange(of: store.invite) { _, _ in copied = false }
    }

    private func addPasted() {
        guard let invite = WalkieInvite(text: pasted), !adding else { return }
        adding = true
        error = nil
        Task {
            defer { adding = false }
            do {
                try await store.add(invite: invite)
                pasted = ""
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func add(_ listed: WalkieClient.Listed) {
        do {
            try store.add(listed: listed)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
