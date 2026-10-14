import AppKit
import SwiftUI

struct CloudSettingsPane: View {
    @ObservedObject var links: CloudLinks

    var body: some View {
        Form {
            Section {
                TextField("Server URL", text: $links.server, prompt: Text("https://drop.example.com"))
                SecureField("Access token", text: $links.token, prompt: Text("API_TOKEN from the server"))
                if links.server.lowercased().hasPrefix("http://"), links.client == nil, !links.token.isEmpty {
                    Label("Use https: plain http is only for servers on your own network.", systemImage: "lock.slash")
                        .foregroundStyle(.orange)
                }
                HStack {
                    checkStatus
                    Spacer()
                    Button("Test Connection", action: links.testConnection)
                        .disabled(links.check == .checking)
                }
            } header: {
                Text("Server")
            } footer: {
                Text("Run the XNotch Cloud server from this repository's Server folder on a VPS or Raspberry Pi, for example with Dokploy. Files go only to your server.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Links expire after", selection: $links.defaultExpiry) {
                    ForEach(links.availableExpiries, id: \.seconds) { choice in
                        Text(choice.title).tag(choice.seconds)
                    }
                }
            } footer: {
                Text("Click the cloud on the shelf to pick a time for each link, or to lock one with a password. Right-click a file for a link with this default.")
                    .foregroundStyle(.secondary)
            }

            Section {
                if let failure = links.revokeFailure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                let active = links.links.filter { !$0.isExpired }
                if active.isEmpty {
                    Text("Links you create appear here until they expire.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(active) { link in
                        LinkRow(link: link, onCopy: { links.copy(link) }, onRevoke: { links.revoke(link) })
                    }
                }
            } header: {
                Text("Your Links")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var checkStatus: some View {
        switch links.check {
        case .none:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
        case .ok(let message):
            Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .lineLimit(2)
        }
    }
}

private struct LinkRow: View {
    let link: CloudLinks.SharedLink
    let onCopy: () -> Void
    let onRevoke: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: link.fileCount > 1 ? "doc.on.doc.fill" : "doc.fill")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(link.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    if link.isProtected == true {
                        Image(systemName: "lock.fill").help("Needs a password")
                    }
                    Text(link.url.absoluteString)
                    Text("·")
                    Text("expires \(link.expiresAt, format: .relative(presentation: .named))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            Button(action: onCopy) { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("Copy link")
            Button { NSWorkspace.shared.open(link.url) } label: { Image(systemName: "safari") }
                .buttonStyle(.borderless)
                .help("Open in browser")
            Button(role: .destructive, action: onRevoke) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete now: the link stops working")
        }
    }
}
