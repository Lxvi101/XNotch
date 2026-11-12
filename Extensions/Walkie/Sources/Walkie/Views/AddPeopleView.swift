import AppKit
import SwiftUI
import XNotchKit

/// Two ways to add someone: swap invites, or pick from your own server's people.
struct AddPeopleView: View {
    @ObservedObject var store: WalkieStore
    @ObservedObject var ui: WalkieUI
    @State private var pasted = ""
    @State private var adding = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !store.directory.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    sectionTitle("On your server")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(store.directory, id: \.box) { listed in
                                DirectoryFace(listed: listed) { add(listed) }
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("Paste their invite")
                HStack(spacing: 8) {
                    TextField("xnotch-walkie:…", text: $pasted)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white)
                        .onSubmit(addPasted)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.08)))
                    Button(action: addPasted) {
                        if adding { ProgressView().controlSize(.mini) } else { Text("Add") }
                    }
                    .buttonStyle(PillButtonStyle(fill: KitStyle.green, text: .black))
                    .disabled(WalkieInvite(text: pasted) == nil || adding)
                    .opacity(WalkieInvite(text: pasted) == nil ? 0.5 : 1)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("Your invite")
                HStack(spacing: 8) {
                    Text(store.invite?.text ?? "Connect a server first")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        guard let text = store.invite?.text else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        withAnimation(.smooth(duration: 0.34, extraBounce: 0.12)) { copied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation { copied = false } }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(PillButtonStyle(fill: .white.opacity(0.14), text: .white))
                    .disabled(store.invite == nil)
                }
                Text("Send it however you like. It carries no secrets: it only lets them write to you, and pins your keys so the server can't swap them.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.32))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 2)
        .onAppear {
            store.refreshDirectory()
            if let text = NSPasteboard.general.string(forType: .string), WalkieInvite(text: text) != nil,
               WalkieInvite(text: text)?.box != store.mailbox.box {
                pasted = text
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(.white.opacity(0.35))
    }

    private func addPasted() {
        guard let invite = WalkieInvite(text: pasted), !adding else { return }
        adding = true
        Task {
            defer { adding = false }
            do {
                try await store.add(invite: invite)
                pasted = ""
                ui.show(.hint)
            } catch {
                ui.flash(error.localizedDescription)
            }
        }
    }

    private func add(_ listed: WalkieClient.Listed) {
        do {
            try withAnimation(.smooth(duration: 0.52, extraBounce: 0.12)) { try store.add(listed: listed) }
        } catch {
            ui.flash(error.localizedDescription)
        }
    }
}

private struct DirectoryFace: View {
    let listed: WalkieClient.Listed
    let action: () -> Void

    private var card: WalkieCrypto.Card? {
        WalkieCrypto.SignedCard(base64: listed.card).flatMap { try? $0.open() }
    }

    var body: some View {
        if let card {
            NotchHoverReader { hovering in
                Button(action: action) {
                    VStack(spacing: 4) {
                        FaceImage(name: card.name, seed: card.box, avatar: card.avatar)
                            .frame(width: 34, height: 34)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.white, KitStyle.green)
                                    .background(Circle().fill(.black).padding(1))
                                    .offset(x: 3, y: 3)
                                    .scaleEffect(hovering ? 1.15 : 1)
                            }
                        Text(card.name.split(separator: " ").first.map(String.init) ?? card.name)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(hovering ? 0.9 : 0.55))
                            .lineLimit(1)
                            .frame(maxWidth: 56)
                    }
                    .scaleEffect(hovering ? 1.08 : 1)
                    .animation(.smooth(duration: 0.34, extraBounce: 0.12), value: hovering)
                }
                .buttonStyle(PressScaleStyle(scale: 0.9))
                .help("Add \(card.name)")
            }
        }
    }
}
