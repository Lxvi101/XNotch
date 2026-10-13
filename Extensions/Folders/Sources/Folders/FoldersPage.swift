import AppKit
import SwiftUI
import XNotchKit

/// The notch page: a row of folder tiles, each with its number key.
struct FoldersPage: View {
    @ObservedObject var store: FolderStore
    let `extension`: FoldersExtension
    let size: CGSize
    let isActive: Bool

    var body: some View {
        Group {
            if store.folders.isEmpty && !store.showsAddTile {
                Text("No folders yet. Add some in XNotch Settings → Folders.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(KitStyle.tertiaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                tiles
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .onAppear { if isActive { store.refresh() } }
        .onChange(of: isActive) { _, active in
            if active { store.refresh() }
        }
    }

    private var tiles: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(store.folders.enumerated()), id: \.element.id) { index, folder in
                    FolderTile(name: store.displayName(of: folder), path: folder.path, icon: store.icon(for: folder),
                               exists: store.exists(folder), shortcut: index < 9 ? index + 1 : nil) {
                        `extension`.open(folder)
                    }
                    .notchContextMenu { menu(for: folder) }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                if store.showsAddTile {
                    AddFolderTile { `extension`.addFolders() }
                        .notchContextMenu {
                            [.action("Add Folder…", symbol: "plus") { `extension`.addFolders() },
                             .separator,
                             .action("Hide Add Tile", symbol: "eye.slash") {
                                 withAnimation(KitMotion.content) { store.showsAddTile = false }
                             }]
                        }
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func menu(for folder: FolderShortcut) -> [NotchMenuItem] {
        var items: [NotchMenuItem] = [
            .action("Open", symbol: "folder") { `extension`.open(folder) },
            .action("Show in Finder", symbol: "magnifyingglass") { `extension`.reveal(folder) },
            .action("Copy Path", symbol: "doc.on.doc") { `extension`.copyPath(folder) },
            .separator,
        ]
        if !store.showsAddTile {
            items.append(.action("Add Folder…", symbol: "plus") { `extension`.addFolders() })
        }
        items.append(.action("Remove from Folders", symbol: "minus.circle", isDestructive: true) {
            store.remove(folder.id)
        })
        return items
    }
}

private struct FolderTile: View {
    let name: String
    let path: String
    let icon: NSImage
    let exists: Bool
    let shortcut: Int?
    let action: () -> Void

    var body: some View {
        NotchHoverReader { hovered in
            Button(action: action) {
                VStack(spacing: 5) {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 46, height: 46)
                        .shadow(color: .black.opacity(0.4), radius: 3, y: 1.5)
                        .saturation(exists ? 1 : 0)
                        .opacity(exists ? 1 : 0.45)
                    Text(name)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(hovered ? 1 : 0.82))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 66)
                }
                .padding(.top, 8)
                .padding(.bottom, 8)
                .frame(width: 74)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.white.opacity(hovered ? 0.07 : 0))
                }
                .overlay(alignment: .topTrailing) {
                    if let shortcut {
                        KeyCap(label: "\(shortcut)", isLit: hovered)
                            .offset(x: -7, y: 5)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(PressScaleStyle(scale: 0.94))
            .scaleEffect(hovered ? 1.04 : 1)
            .animation(KitMotion.content, value: hovered)
            .help(path)
        }
    }
}

private struct AddFolderTile: View {
    let action: () -> Void

    var body: some View {
        NotchHoverReader { hovered in
            Button(action: action) {
                VStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(.white.opacity(hovered ? 0.4 : 0.22), style: StrokeStyle(lineWidth: 1.2, dash: [3.5, 3]))
                        .frame(width: 40, height: 40)
                        .overlay {
                            Image(systemName: "plus")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white.opacity(hovered ? 0.9 : 0.5))
                        }
                        .frame(width: 46, height: 46)
                    Text("Add")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(hovered ? 0.82 : 0.45))
                }
                .padding(.vertical, 8)
                .frame(width: 74)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleStyle(scale: 0.94))
            .animation(KitMotion.content, value: hovered)
        }
    }
}

private struct KeyCap: View {
    let label: String
    let isLit: Bool

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(isLit ? 0.95 : 0.6))
            .frame(minWidth: 14, minHeight: 14)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.black.opacity(0.55))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.white.opacity(isLit ? 0.2 : 0.12)))
            }
    }
}
