import SwiftUI
import XNotchKit

/// The open shelf. The top band flanks the camera housing, so its two groups
/// sit either side of a spacer as wide as the physical notch.
struct ShelfView: View {
    @ObservedObject var store: ShelfStore
    let extensions: ExtensionManager
    let notchSize: CGSize
    /// Hidden when the page switcher occupies the header's leading side.
    let showsTitle: Bool
    /// The page switcher continues right of the camera: the buttons fold
    /// into one menu to leave it room.
    let foldsButtons: Bool
    let onDragOut: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: notchSize.height)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, NotchMetrics.shelfTopCornerRadius + MediaLayout.inset)
        .padding(.bottom, 10)
        .frame(width: NotchMetrics.shelf.outerWidth, height: NotchMetrics.shelf.height)
        .environmentObject(extensions.pointer)
        .environment(\.shelfExtensionMenuItems) { [weak extensions] files in
            extensions?.notchShelfMenuItems(for: files) ?? []
        }
    }

    private var accessoryContext: ShelfContext {
        ShelfContext { [weak store] in
            guard let store else { return [] }
            let selected = store.items.filter { store.selection.contains($0.id) }
            return (selected.isEmpty ? store.items : selected).map(\.url)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                Text("Shelf")
                    .foregroundStyle(.white.opacity(0.92))
                if !store.items.isEmpty {
                    Text("\(store.items.count)")
                        .foregroundStyle(.white.opacity(0.4))
                        .contentTransition(.numericText())
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .opacity(showsTitle ? 1 : 0)
            Spacer(minLength: notchSize.width + 12)
            if !store.items.isEmpty && foldsButtons {
                HeaderButton(symbol: "ellipsis") {}
                    .notchMenu { menuItems }
                    .environment(\.shelfHeaderButtonSize, 24)
                    .help("Share or clear the shelf")
            } else if !store.items.isEmpty {
                let providers = extensions.shelfAccessoryProviders
                // Extension buttons make the row tighter, so it stays beside the camera, not under it.
                HStack(spacing: providers.isEmpty ? 6 : 3) {
                    ForEach(Array(providers.enumerated()), id: \.offset) { _, provider in
                        provider.makeShelfAccessory(context: accessoryContext)
                    }
                    HeaderButton(symbol: "dot.radiowaves.left.and.right") {
                        ShelfActions.airDrop(store.items.map(\.url))
                    }
                    HeaderButton(symbol: "trash") {
                        withAnimation(Motion.content) { store.removeAll() }
                    }
                }
                .environment(\.shelfHeaderButtonSize, providers.isEmpty ? 24 : 22)
            }
        }
        .padding(.top, 2)
    }

    /// The header's buttons as a menu: what extensions offer for the files,
    /// then AirDrop and clearing the shelf.
    private var menuItems: [NotchMenuItem] {
        let targets = accessoryContext.targets
        var items = extensions.notchShelfMenuItems(for: targets)
        if !items.isEmpty { items.append(.separator) }
        items.append(.action("AirDrop", symbol: "dot.radiowaves.left.and.right") {
            ShelfActions.airDrop(store.items.map(\.url))
        })
        items.append(.separator)
        items.append(.action("Clear Shelf", symbol: "trash", isDestructive: true) {
            withAnimation(Motion.content) { store.removeAll() }
        })
        return items
    }

    @ViewBuilder
    private var content: some View {
        if store.items.isEmpty {
            EmptyShelfHint()
                .padding(.top, 6)
                .transition(.asymmetric(
                    insertion: .modifier(active: RevealModifier(progress: 0, hiddenScale: 0.94, travel: 0),
                                         identity: RevealModifier(progress: 1)),
                    removal: .opacity.animation(.easeOut(duration: 0.08))
                ))
        } else {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(store.items) { item in
                            ShelfTile(item: item, store: store, onDragOut: onDragOut)
                                .id(item.id)
                                .transition(.asymmetric(
                                    insertion: .modifier(
                                        active: RevealModifier(progress: 0, hiddenScale: 0.55, maxBlur: 8, travel: -18),
                                        identity: RevealModifier(progress: 1)),
                                    removal: .modifier(
                                        active: RevealModifier(progress: 0, hiddenScale: 0.7, maxBlur: 6, travel: 0),
                                        identity: RevealModifier(progress: 1))
                                ))
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .onChange(of: store.items.last?.id) { _, last in
                    guard let last else { return }
                    withAnimation(Motion.content) { proxy.scrollTo(last, anchor: .trailing) }
                }
            }
            .transition(.modifier(active: RevealModifier(progress: 0, hiddenScale: 0.94, travel: 0),
                                  identity: RevealModifier(progress: 1)))
        }
    }
}

private struct HeaderButton: View {
    let symbol: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.shelfHeaderButtonSize) private var size

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.6))
                .frame(width: size, height: size)
                .background(Circle().fill(.white.opacity(hovering ? 0.16 : 0.08)))
                .scaleEffect(hovering ? 1.06 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(Motion.content) { hovering = inside } }
    }
}

private struct EmptyShelfHint: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(.white.opacity(0.16), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .overlay {
                HStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Drop files here")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.42))
            }
    }
}

/// Tile frames in the notch canvas, for pointer hit-testing.
struct ShelfTileFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct ShelfTile: View {
    let item: ShelfItem
    @ObservedObject var store: ShelfStore
    let onDragOut: (Bool) -> Void

    @State private var thumbnail: NSImage?
    @Environment(\.shelfExtensionMenuItems) private var extensionMenuItems

    init(item: ShelfItem, store: ShelfStore, onDragOut: @escaping (Bool) -> Void) {
        self.item = item
        self.store = store
        self.onDragOut = onDragOut
        _thumbnail = State(initialValue: FileIcons.thumbnail(for: item.path))
    }

    private var isSelected: Bool { store.selection.contains(item.id) }
    private var hovering: Bool { store.hoveredID == item.id }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Image(nsImage: FileIcons.icon(for: item.path))
                    .resizable()
                    .scaledToFit()
                    .opacity(thumbnail == nil ? 1 : 0)
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .transition(.modifier(active: RevealModifier(progress: 0, hiddenScale: 0.92, maxBlur: 6, travel: 0),
                                              identity: RevealModifier(progress: 1)))
                }
            }
            .frame(width: 46, height: 46)
            .shadow(color: .black.opacity(0.4), radius: 3, y: 1.5)

            Text(item.name)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(isSelected ? 1 : 0.82))
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .frame(width: 66, height: 26, alignment: .top)
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
        .frame(width: 74)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(isSelected ? 0.15 : hovering ? 0.07 : 0))
        }
        .scaleEffect(hovering ? 1.04 : 1)
        .animation(Motion.content, value: hovering)
        .animation(Motion.content, value: isSelected)
        .overlay {
            ShelfItemInteraction(item: item, store: store, dragImage: thumbnail, onDragOut: onDragOut,
                                 extensionMenuItems: extensionMenuItems)
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: ShelfTileFramesKey.self,
                                       value: [item.id: proxy.frame(in: .named(NotchShellView.canvasSpace))])
            }
        }
        .task(id: item.path) {
            guard thumbnail == nil else { return }
            let image = await ThumbnailService.shared.thumbnail(for: item.url, size: CGSize(width: 92, height: 92))
            FileIcons.setThumbnail(image, for: item.path)
            withAnimation(Motion.content) { thumbnail = image }
        }
    }
}

/// Extensions' entries for a shelf file's right-click menu.
private struct ShelfExtensionMenuItemsKey: EnvironmentKey {
    static let defaultValue: @MainActor ([URL]) -> [NotchMenuItem] = { _ in [] }
}

extension EnvironmentValues {
    var shelfExtensionMenuItems: @MainActor ([URL]) -> [NotchMenuItem] {
        get { self[ShelfExtensionMenuItemsKey.self] }
        set { self[ShelfExtensionMenuItemsKey.self] = newValue }
    }
}
