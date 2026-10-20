import AppKit
import SwiftUI

private let accentBlue = Color(red: 0.04, green: 0.52, blue: 1)
private let shelfShape = RoundedRectangle(cornerRadius: ShelfGeometry.cornerRadius, style: .continuous)

/// The shelf in its window. Every subview reads only the shelf properties it
/// draws, so a hover or a drag update redraws a button, not the whole shelf.
struct ShelfView: View {
    let shelf: Shelf
    let library: ShelfLibrary
    let controller: ShelfController

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                BackgroundArea(controller: controller)
                ShelfContent(shelf: shelf, library: library, controller: controller)
                BoltTile(shelf: shelf, size: size)
                ActionGrid(shelf: shelf, size: size)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .background { ShelfBackground(shelf: shelf) }
        .clipShape(shelfShape)
        .background { ShelfShadow() }
        .modifier(Presence(shelf: shelf))
        .padding(ShelfGeometry.margin)
    }
}

// MARK: Presence

/// Grows the shelf out of the pointer, lifts it under a drag, and makes it
/// flinch when files land, squashing more than it stretches.
private struct Presence: ViewModifier {
    let shelf: Shelf

    func body(content: Content) -> some View {
        let presented = shelf.isPresented
        let reduced = ShelfMotion.reduced
        let scale: CGFloat = presented ? (shelf.isDropTarget && !shelf.showsActions ? 1.025 : 1) : (reduced ? 1 : 0.35)
        content
            // Carried over another shelf, it draws in, ready to go inside.
            .scaleEffect(shelf.isOverShelf && !reduced ? 0.9 : 1)
            .opacity(shelf.isOverShelf ? 0.92 : 1)
            .scaleEffect(scale, anchor: shelf.presenceAnchor)
            .opacity(presented ? 1 : 0)
            .keyframeAnimator(initialValue: CGFloat(1), trigger: shelf.landings) { content, squash in
                content.scaleEffect(x: 1 + (1 - squash) * 0.5, y: squash, anchor: .bottom)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(reduced ? 1 : 0.955, duration: 0.07)
                    SpringKeyframe(1, duration: 0.5, spring: .init(response: 0.32, dampingRatio: 0.55))
                }
            }
    }
}

// MARK: Content

/// The files, compact or expanded. It sinks into a blur while the shelf
/// shows its actions, and comes into focus as the shelf appears.
private struct ShelfContent: View {
    let shelf: Shelf
    let library: ShelfLibrary
    let controller: ShelfController

    var body: some View {
        let receded = shelf.showsActions
        ZStack(alignment: .topLeading) {
            if shelf.isExpanded {
                ExpandedShelf(shelf: shelf, controller: controller)
                    .frame(width: ShelfGeometry.expanded.width, height: ShelfGeometry.expanded.height, alignment: .topLeading)
                    .transition(.focus)
            } else {
                CompactShelf(shelf: shelf, library: library, controller: controller)
                    .frame(width: ShelfGeometry.compact.width, height: ShelfGeometry.compact.height, alignment: .topLeading)
                    .transition(.focus)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .blur(radius: receded ? 10 : (shelf.isPresented ? 0 : 6))
        .scaleEffect(receded ? 0.92 : 1)
        .opacity(receded ? 0 : 1)
        .allowsHitTesting(!receded)
    }
}

private struct CompactShelf: View {
    let shelf: Shelf
    let library: ShelfLibrary
    let controller: ShelfController

    /// The middle of the file stack, where landing files head.
    static let stackCenter = CGPoint(x: 90, y: 76)

    var body: some View {
        ZStack(alignment: .topLeading) {
            if shelf.files.isEmpty {
                Text("Drop files here")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: ShelfGeometry.compact.width, height: ShelfGeometry.compact.height)
                    .transition(.focus)
            } else {
                FileStack(shelf: shelf)
                    .frame(width: 112, height: 96)
                    .overlay(FileItemArea(controller: controller, file: nil))
                    .position(Self.stackCenter)
                NamePill(shelf: shelf, controller: controller)
                    .position(x: 90, y: 150)
                    .transition(.focus)
            }
            CompactControls(shelf: shelf, library: library, controller: controller)
        }
    }
}

/// Close, and restore or the menu, in the top corners.
private struct CompactControls: View {
    let shelf: Shelf
    let library: ShelfLibrary
    let controller: ShelfController

    var body: some View {
        let isEmpty = shelf.files.isEmpty
        let visible = isEmpty || shelf.isHovered
        HStack {
            CircleButton(symbol: "xmark", help: "Close the shelf (hold ⌥ to clear it)") {
                controller.close(clearing: NSEvent.modifierFlags.contains(.option))
            }
            Spacer()
            // Nothing to restore or choose mid-drag: it steps aside until the drag leaves.
            let dragging = shelf.isDragInside
            Group {
                if isEmpty {
                    RestoreButton(library: library, controller: controller)
                } else {
                    MenuButton(controller: controller)
                        .transition(.focus)
                }
            }
            .modifier(Focus(amount: dragging ? 1 : 0))
            .allowsHitTesting(!dragging)
        }
        .padding(10)
        .frame(width: ShelfGeometry.compact.width)
        .opacity(visible ? 1 : 0)
        .scaleEffect(visible ? 1 : 0.9)
    }
}

private struct RestoreButton: View {
    @ObservedObject var library: ShelfLibrary
    let controller: ShelfController

    var body: some View {
        if library.canRestore {
            CircleButton(symbol: "arrow.uturn.backward", help: "Restore the files from the last closed shelf") {
                library.restore(into: controller)
            }
            .transition(.focus)
        }
    }
}

/// Up to three thumbnails, fanned like a stack of paper. New ones fly in
/// from where they were dropped.
private struct FileStack: View {
    let shelf: Shelf

    var body: some View {
        let files = shelf.files
        let shown = Array(files.suffix(3))
        // Captured when a file is inserted: its landing starts at the drop.
        let from = shelf.lastDrop.map {
            CGSize(width: $0.x - CompactShelf.stackCenter.x, height: $0.y - CompactShelf.stackCenter.y)
        } ?? CGSize(width: 0, height: 24)
        ZStack {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, file in
                let depth = shown.count - 1 - index
                FileThumbnail(path: file.path, side: 76)
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 1.5)
                    .rotationEffect(.degrees(Double(depth) * (depth % 2 == 0 ? 7 : -7)))
                    .offset(y: CGFloat(-depth) * 3)
                    .transition(.asymmetric(insertion: .landing(from: from), removal: .focus))
            }
            if files.count > 1 {
                Text("\(files.count)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .padding(.horizontal, 6)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(Capsule().fill(accentBlue))
                    .offset(x: 42, y: -38)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
    }
}

private struct NamePill: View {
    let shelf: Shelf
    let controller: ShelfController

    var body: some View {
        // The bolt takes this corner while something is dragged over the shelf.
        let hidden = shelf.isDragInside && !shelf.actions.isEmpty
        Button { controller.setExpanded(true) } label: {
            HStack(spacing: 3) {
                if shelf.isPinned {
                    Image(systemName: "pin.fill").font(.system(size: 8, weight: .bold))
                }
                Text(shelf.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentTransition(.interpolate)
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .frame(maxWidth: 146)
            .background(Capsule().fill(.white.opacity(0.12)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .help(shelf.name)
        .opacity(hidden ? 0 : 1)
        .blur(radius: hidden ? 3 : 0)
    }
}

// MARK: Expanded

private struct ExpandedShelf: View {
    let shelf: Shelf
    let controller: ShelfController

    var body: some View {
        VStack(spacing: 0) {
            ExpandedHeader(shelf: shelf, controller: controller)
            Group {
                if shelf.files.isEmpty {
                    Text("Drop files here")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.focus)
                } else if shelf.layout == .grid {
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(96), spacing: 6), count: 3), spacing: 6) {
                            ForEach(shelf.files) { file in
                                GridTile(shelf: shelf, file: file)
                                    .overlay(FileItemArea(controller: controller, file: file))
                                    .transition(.focus)
                            }
                        }
                        .padding(10)
                    }
                    .transition(.focus)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(shelf.files) { file in
                                ListRow(shelf: shelf, file: file)
                                    .overlay(FileItemArea(controller: controller, file: file))
                                    .transition(.focus)
                            }
                        }
                        .padding(8)
                    }
                    .transition(.focus)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ExpandedHeader: View {
    let shelf: Shelf
    let controller: ShelfController

    var body: some View {
        HStack(spacing: 8) {
            CircleButton(symbol: "chevron.left", help: "Back") { controller.setExpanded(false) }
            VStack(alignment: .leading, spacing: 1) {
                Text(shelf.customName ?? ShelfSummary.count(for: shelf.files))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .contentTransition(.interpolate)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .contentTransition(.interpolate)
            }
            Spacer(minLength: 4)
            LayoutButton(symbol: "square.grid.2x2", isOn: shelf.layout == .grid) {
                withAnimation(ShelfMotion.content) { shelf.layout = .grid }
            }
            LayoutButton(symbol: "list.bullet", isOn: shelf.layout == .list) {
                withAnimation(ShelfMotion.content) { shelf.layout = .list }
            }
            MenuButton(controller: controller)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var subtitle: String {
        let selected = shelf.files.filter { shelf.selection.contains($0.id) }
        if !selected.isEmpty {
            return "Selected: " + [ShelfSummary.count(for: selected), ShelfSummary.size(for: selected)].compactMap { $0 }.joined(separator: " · ")
        }
        let count = shelf.customName == nil ? nil : ShelfSummary.count(for: shelf.files)
        return [count, ShelfSummary.size(for: shelf.files)].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct GridTile: View {
    let shelf: Shelf
    let file: ShelfFile

    var body: some View {
        let isSelected = shelf.selection.contains(file.id)
        VStack(spacing: 4) {
            FileThumbnail(path: file.path, side: 52)
            Text(file.name)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
            if let size = file.size {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(isSelected ? 0.8 : 0.5))
            }
        }
        .padding(6)
        .frame(width: 96, height: 106, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isSelected ? accentBlue : .clear))
    }
}

private struct ListRow: View {
    let shelf: Shelf
    let file: ShelfFile

    var body: some View {
        let isSelected = shelf.selection.contains(file.id)
        HStack(spacing: 8) {
            FileThumbnail(path: file.path, side: 22)
            Text(file.name)
                .font(.system(size: 11.5))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if let size = file.size {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(isSelected ? 0.8 : 0.5))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isSelected ? accentBlue : .clear))
    }
}

// MARK: Instant actions

/// The bolt in the corner, while the shelf is empty or something is dragged over it.
private struct BoltTile: View {
    let shelf: Shelf
    let size: CGSize

    var body: some View {
        let shown = !shelf.actions.isEmpty && (shelf.files.isEmpty || shelf.isDragInside) && !shelf.showsActions
        let frame = ShelfGeometry.boltFrame(in: size)
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(.white.opacity(0.08))
            .overlay {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(width: frame.width, height: frame.height)
            .scaleEffect(shown ? 1 : 0.5)
            .opacity(shown ? 1 : 0)
            .offset(x: frame.minX, y: frame.minY)
            .allowsHitTesting(false)
    }
}

/// The shelf turned into its actions. Every tile grows out of the bolt, a
/// moment after the one before, and folds back into it when the drag leaves.
private struct ActionGrid: View {
    let shelf: Shelf
    let size: CGSize

    var body: some View {
        let actions = shelf.actions
        let open = shelf.showsActions
        let hovered = shelf.hoveredAction
        let frames = ShelfGeometry.actionFrames(count: actions.count, in: size)
        let bolt = ShelfGeometry.boltFrame(in: size)
        ZStack(alignment: .topLeading) {
            ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                // The tile nearest the bolt leads; folding back, it's last home.
                let order = open ? actions.count - 1 - index : index
                ActionTile(action: action, frame: open ? frames[index] : bolt, isOpen: open, isHovered: hovered == action)
                    .animation(ShelfMotion.bloom(index: order), value: open)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

private struct ActionTile: View {
    let action: InstantAction
    let frame: CGRect
    let isOpen: Bool
    let isHovered: Bool

    var body: some View {
        let side = min(46, min(frame.width, frame.height) * 0.6)
        RoundedRectangle(cornerRadius: isOpen ? 14 : 9, style: .continuous)
            .fill(isHovered ? accentBlue : .white.opacity(0.08))
            .overlay {
                Image(nsImage: action.icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: side, height: side)
                    .scaleEffect(isOpen ? (isHovered ? 1.1 : 1) : 0.4)
                    .blur(radius: isOpen ? 0 : 4)
                    .animation(ShelfMotion.hover, value: isHovered)
            }
            .frame(width: frame.width, height: frame.height)
            .scaleEffect(isHovered ? 1.03 : 1)
            .animation(ShelfMotion.hover, value: isHovered)
            .opacity(isOpen ? 1 : 0)
            .offset(x: frame.minX, y: frame.minY)
    }
}

// MARK: Surface

private struct ShelfBackground: View {
    let shelf: Shelf

    var body: some View {
        let isTarget = shelf.isDropTarget && !shelf.showsActions
        ZStack {
            VisualEffect()
            Color.black.opacity(0.18)
            shelfShape.strokeBorder(isTarget ? accentBlue : .white.opacity(0.14), lineWidth: isTarget ? 2 : 1)
        }
    }
}

/// The shelf's shadow, only outside its shape so it never shows through the glass.
private struct ShelfShadow: View {
    var body: some View {
        shelfShape
            .fill(.black.opacity(0.5))
            .blur(radius: 12)
            .offset(y: 6)
            .mask {
                ZStack {
                    Rectangle().padding(-ShelfGeometry.margin)
                    shelfShape.blendMode(.destinationOut)
                }
                .compositingGroup()
            }
            .allowsHitTesting(false)
    }
}

private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// MARK: Pieces

private struct CircleButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.black.opacity(0.62))
                .frame(width: 20, height: 20)
                .background(Circle().fill(.white.opacity(hovered ? 0.85 : 0.65)))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovered = $0 }
        .animation(ShelfMotion.hover, value: hovered)
        .help(help)
    }
}

private struct LayoutButton: View {
    let symbol: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(isOn ? 0.95 : 0.5))
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(isOn ? 0.16 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}

/// The chevron that opens the shelf's menu.
private struct MenuButton: View {
    let controller: ShelfController

    var body: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.black.opacity(0.62))
            .frame(width: 20, height: 20)
            .background(Circle().fill(.white.opacity(0.65)))
            .overlay(MenuAnchor(controller: controller))
            .help("Do things with the files on this shelf")
    }
}

private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.9), value: configuration.isPressed)
    }
}

// MARK: Transitions

/// Arriving content comes into focus; leaving content goes out of it.
private struct Focus: ViewModifier {
    let amount: CGFloat

    func body(content: Content) -> some View {
        content
            .blur(radius: 6 * amount)
            .scaleEffect(1 - 0.06 * amount)
            .opacity(1 - amount)
    }
}

/// A file flying in from where it was dropped, a little smaller, as the drag image was.
private struct Landing: ViewModifier {
    let offset: CGSize
    let progress: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(0.7 + 0.3 * progress)
            .offset(x: offset.width * (1 - progress), y: offset.height * (1 - progress))
            .opacity(0.4 + 0.6 * progress)
    }
}

private extension AnyTransition {
    static var focus: AnyTransition {
        ShelfMotion.reduced ? .opacity : .modifier(active: Focus(amount: 1), identity: Focus(amount: 0))
    }

    static func landing(from offset: CGSize) -> AnyTransition {
        ShelfMotion.reduced ? .opacity
            : .modifier(active: Landing(offset: offset, progress: 0), identity: Landing(offset: offset, progress: 1))
    }
}

/// A file icon that turns into its Quick Look thumbnail once one is made.
struct FileThumbnail: View {
    let path: String
    let side: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Image(nsImage: image ?? Thumbnails.image(for: path))
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: side, height: side)
            .task(id: path) {
                guard image == nil else { return }
                if let thumbnail = await Thumbnails.thumbnail(for: path) {
                    withAnimation(ShelfMotion.hover) { image = thumbnail }
                }
            }
    }
}
