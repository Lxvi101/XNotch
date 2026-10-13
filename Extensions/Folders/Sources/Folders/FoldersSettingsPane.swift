import AppKit
import SwiftUI

struct FoldersSettingsPane: View {
    @ObservedObject var store: FolderStore
    let onAdd: () -> Void

    var body: some View {
        Form {
            Section {
                ForEach(Array(store.folders.enumerated()), id: \.element.id) { index, folder in
                    FolderRow(folder: folder, systemName: store.systemName(of: folder), icon: store.icon(for: folder),
                              exists: store.exists(folder), shortcut: index < 9 ? index + 1 : nil,
                              onRename: { store.rename(folder.id, to: $0) },
                              onRemove: { store.remove(folder.id) })
                }
                .onMove { store.move(fromOffsets: $0, toOffset: $1) }
                Button("Add Folder…", action: onAdd)
            } header: {
                Text("Folders")
            } footer: {
                Text("While Folders is open in the notch, press 1–9 to open the folder in that position. Drag rows to reorder.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle(isOn: $store.showsAddTile) {
                    Text("Show Add tile in the notch")
                    Text("Without it, add folders here or from a folder's right-click menu in the notch.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { store.refresh(names: true) }
    }
}

private struct FolderRow: View {
    let folder: FolderShortcut
    let systemName: String
    let icon: NSImage
    let exists: Bool
    let shortcut: Int?
    let onRename: (String) -> Void
    let onRemove: () -> Void

    @State private var name = ""

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                TextField("Name", text: $name, prompt: Text(systemName))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.leading)
                    .fontWeight(.medium)
                Text((folder.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(exists ? .secondary : Color.red)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let shortcut {
                Text("\(shortcut)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.quaternary))
            }
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .red)
            }
            .buttonStyle(.borderless)
            .help("Remove from Folders")
        }
        .onAppear { name = folder.customName ?? systemName }
        .onChange(of: name) { _, new in
            onRename(new == systemName ? "" : new)
        }
    }
}
