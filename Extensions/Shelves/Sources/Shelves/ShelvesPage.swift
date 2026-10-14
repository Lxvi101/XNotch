import AppKit
import SwiftUI
import XNotchKit

/// The notch page: a new shelf, then recent shelves to open again.
struct ShelvesPage: View {
    @ObservedObject var library: ShelfLibrary
    let size: CGSize
    let isActive: Bool
    let close: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                NewShelfTile {
                    library.newShelfUnderNotch()
                    close()
                }
                .notchContextMenu {
                    [.action("New Shelf", symbol: "plus") { library.newShelfUnderNotch(); close() },
                     .action("New Shelf from Clipboard", symbol: "doc.on.clipboard") { library.newShelfFromClipboard(); close() }]
                }
                ForEach(library.recent) { record in
                    RecentTile(name: record.name, date: record.updatedAt, image: library.preview(for: record),
                               isOpen: library.isOpen(record.id)) {
                        library.reopen(record)
                        close()
                    }
                    .notchContextMenu {
                        [.action("Open Shelf", symbol: "tray.full") { library.reopen(record); close() },
                         .action("Show in Finder", symbol: "folder") { FileActions.reveal(record.files.map(\.url)); close() },
                         .separator,
                         .action("Remove from Recent Shelves", symbol: "minus.circle", isDestructive: true) {
                             withAnimation(KitMotion.content) { library.remove(record.id) }
                         }]
                    }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                if library.recent.isEmpty {
                    Text("Shake the pointer while dragging files to drop them on a shelf.")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(KitStyle.tertiaryText)
                        .frame(width: 240)
                        .padding(.leading, 8)
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .onAppear { if isActive { library.refreshPreviews() } }
        .onChange(of: isActive) { _, active in
            if active { library.refreshPreviews() }
        }
    }
}

private struct NewShelfTile: View {
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
                    Text("New Shelf")
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

private struct RecentTile: View {
    let name: String
    let date: Date
    let image: NSImage?
    let isOpen: Bool
    let action: () -> Void

    var body: some View {
        NotchHoverReader { hovered in
            Button(action: action) {
                VStack(spacing: 3) {
                    Group {
                        if let image {
                            Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                        } else {
                            Image(systemName: "doc.fill").font(.system(size: 26)).foregroundStyle(KitStyle.tertiaryText)
                        }
                    }
                    .frame(width: 40, height: 40)
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1.5)
                    .overlay(alignment: .bottomTrailing) {
                        if isOpen {
                            Circle().fill(KitStyle.green).frame(width: 7, height: 7).offset(x: 2, y: 1)
                        }
                    }
                    Text(name)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(hovered ? 1 : 0.82))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 70)
                    Text(date, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                        .font(.system(size: 9))
                        .foregroundStyle(KitStyle.tertiaryText)
                        .lineLimit(1)
                }
                .padding(.vertical, 6)
                .frame(width: 78)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(hovered ? 0.07 : 0))
                }
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(PressScaleStyle(scale: 0.94))
            .scaleEffect(hovered ? 1.04 : 1)
            .animation(KitMotion.content, value: hovered)
        }
    }
}
