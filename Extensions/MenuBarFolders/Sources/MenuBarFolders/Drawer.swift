import AppKit
import SwiftUI
import XNotchKit

// MARK: Shape

/// A drawer hanging from the bottom of the menu bar: concave shoulders where
/// it leaves the bar, so it reads as the bar flowing down, and continuous
/// rounded corners at the bottom.
struct DrawerShape: Shape {
    var shoulder: CGFloat = DrawerModel.shoulder
    var corner: CGFloat = DrawerModel.corner

    /// The radii never change. DrawerBody keeps the rect at least
    /// `DrawerModel.minimumHeight` tall and wide enough for both.
    func path(in rect: CGRect) -> Path {
        let s = shoulder, c = corner
        let left = rect.minX + s, right = rect.maxX - s
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: left, y: rect.minY + s), control: CGPoint(x: left, y: rect.minY))
        path.addLine(to: CGPoint(x: left, y: rect.maxY - c))
        path.addCurve(to: CGPoint(x: left + c, y: rect.maxY),
                      control1: CGPoint(x: left, y: rect.maxY - c * 0.45),
                      control2: CGPoint(x: left + c * 0.45, y: rect.maxY))
        path.addLine(to: CGPoint(x: right - c, y: rect.maxY))
        path.addCurve(to: CGPoint(x: right, y: rect.maxY - c),
                      control1: CGPoint(x: right - c * 0.45, y: rect.maxY),
                      control2: CGPoint(x: right, y: rect.maxY - c * 0.45))
        path.addLine(to: CGPoint(x: right, y: rect.minY + s))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: right, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// The drawer's whole body driven by one spring value, so size, position and
/// shadow can never drift apart. `progress` runs 0 (tucked into the folder
/// icon) to 1 (open) and past 1 while the spring overshoots, which stretches
/// the drawer a little further down and out before it settles.
///
/// The corners keep their radii throughout. While the drawer is shorter than
/// its own corners it slides up behind the bar's edge (the panel's top) rather
/// than shrinking them, so it emerges from the bar.
private struct DrawerBody<Content: View>: View, Animatable {
    var progress: CGFloat
    var fullWidth: CGFloat
    var centerX: CGFloat
    let anchorX: CGFloat
    let anchorWidth: CGFloat
    let content: Content

    init(progress: CGFloat, fullWidth: CGFloat, centerX: CGFloat, anchorX: CGFloat, anchorWidth: CGFloat,
         @ViewBuilder content: () -> Content) {
        self.progress = progress
        self.fullWidth = fullWidth
        self.centerX = centerX
        self.anchorX = anchorX
        self.anchorWidth = anchorWidth
        self.content = content()
    }

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(progress, AnimatablePair(fullWidth, centerX)) }
        set {
            progress = newValue.first
            fullWidth = newValue.second.first
            centerX = newValue.second.second
        }
    }

    var body: some View {
        let p = max(progress, 0)
        let minimumWidth = 2 * (DrawerModel.shoulder + DrawerModel.corner) + 4
        let closedWidth = max(anchorWidth + 2 * DrawerModel.shoulder, minimumWidth)
        let width = max(closedWidth + (fullWidth - closedWidth) * p, minimumWidth)
        // Position doesn't overshoot, only size does: a drawer that swings
        // sideways past its folder reads as loose.
        let along = min(p, 1)
        let midX = anchorX + (centerX - anchorX) * along
        let visible = DrawerModel.height * p
        let height = max(visible, DrawerModel.minimumHeight)

        ZStack(alignment: .top) {
            DrawerShape().fill(Color.black)
                .shadow(color: .black.opacity(0.3 * along), radius: 12, y: 5)
            content
                .frame(width: fullWidth, height: DrawerModel.height, alignment: .top)
                .frame(width: width, height: height, alignment: .top)
                .clipShape(DrawerShape())
        }
        .frame(width: width, height: height, alignment: .top)
        .offset(x: midX - width / 2, y: visible - height)
    }
}

// MARK: Model

@MainActor @Observable
final class DrawerModel {
    var folderID: UUID?
    var isOpen = false
    var hovered: String?
    /// Where the folder's icon sits, in the panel's coordinates (x of its centre).
    var anchorX: CGFloat = 0
    var anchorWidth: CGFloat = 24
    /// An icon is being Command-dragged over the folder.
    var isDropTarget = false
    /// A tile being dragged inside the drawer, and how far it has moved.
    var draggingID: String?
    var dragOffset: CGSize = .zero
    /// Out of the drawer: the floating preview has taken over from the tile.
    var draggedOut = false

    nonisolated static let shoulder: CGFloat = 10
    nonisolated static let corner: CGFloat = 16
    static let tileHeight: CGFloat = 30
    static let captionHeight: CGFloat = 16
    static let padding: CGFloat = 10

    static var height: CGFloat { 6 + tileHeight + 2 + captionHeight + padding }
    /// The least height that fits the shoulders and the bottom corners.
    static var minimumHeight: CGFloat { shoulder + corner + 2 }

    static func tileWidth(for image: NSImage) -> CGFloat {
        let h: CGFloat = 18
        let w = image.size.height > 0 ? image.size.width * h / image.size.height : h
        return min(max(w, 16), 48) + 14
    }
}

// MARK: Controller

/// The panel under the menu bar that holds a folder's drawer.
@MainActor
final class DrawerController {
    let model = DrawerModel()
    private let store: FolderStore
    private let panel: NSPanel
    private var anchor: NSRect = .zero
    private var pointerTimer: Timer?
    private var outsideSince: Date?
    private var dwell: DispatchWorkItem?
    private var orderOutWork: DispatchWorkItem?

    var openFolder: UUID? { model.isOpen ? model.folderID : nil }
    var isDropTarget: Bool { model.isOpen && model.isDropTarget }
    /// Clicked open: stays out when the pointer leaves, until a click elsewhere.
    private(set) var isPinned = false

    func pin() {
        guard model.isOpen else { return }
        isPinned = true
        outsideSince = nil
    }

    /// Whether `point`, in global display coordinates (top-left origin), is
    /// on the open drawer, with a little margin.
    func contains(globalPoint point: CGPoint) -> Bool {
        guard model.isOpen, let top = NSScreen.screens.first?.frame.maxY else { return false }
        return drawerRect.insetBy(dx: -10, dy: -10).contains(NSPoint(x: point.x, y: top - point.y))
    }

    /// The panel is sized for the widest drawer up front so opening never
    /// resizes a window mid-spring.
    private static let panelSize = NSSize(width: 900, height: DrawerModel.height + 30)

    var onOpen: (FiledItem, UUID) -> Void = { _, _ in }
    var onAdd: (UUID, NSPoint) -> Void = { _, _ in }
    var onReorder: (UUID, Int, Int) -> Void = { _, _, _ in }
    /// An icon dragged out of the drawer, and where it was let go (global
    /// display coordinates, top-left origin).
    var onDragOut: (String, CGPoint) -> Void = { _, _ in }
    private let preview = DragPreview()

    init(store: FolderStore) {
        self.store = store
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = true

        let actions = DrawerActions(
            open: { [weak self] item, folder in self?.onOpen(item, folder) },
            add: { [weak self] folder, localPoint in
                guard let self else { return }
                // SwiftUI's y runs down from the top of the panel.
                self.onAdd(folder, NSPoint(x: self.panel.frame.minX + localPoint.x, y: self.panel.frame.maxY - localPoint.y))
            },
            dragChanged: { [weak self] id, translation in self?.dragChanged(id, translation: translation) },
            dragEnded: { [weak self] id in self?.dragEnded(id) })
        let host = FirstClickHostingView(rootView: DrawerView(model: model, store: store, actions: actions))
        host.frame = NSRect(origin: .zero, size: Self.panelSize)
        panel.contentView = host
    }

    // MARK: Hover from the folder's icon

    func anchorHovered(_ folder: UUID, open: @escaping () -> Void) {
        dwell?.cancel()
        if model.isOpen {
            // Already out: slide straight over to the neighbouring folder.
            if model.folderID != folder { open() }
            return
        }
        let work = DispatchWorkItem(block: open)
        dwell = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
    }

    func anchorUnhovered(_ folder: UUID) {
        dwell?.cancel()
    }

    // MARK: Open and close

    func open(_ folder: UUID, under anchor: NSRect, asDropTarget: Bool = false) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main else { return }
        self.anchor = anchor
        orderOutWork?.cancel()
        let wasOpen = model.isOpen

        // Centre the panel on the icon, kept on screen; the drawer then
        // grows out of wherever the icon sits inside it.
        var frame = NSRect(origin: .zero, size: Self.panelSize)
        frame.origin.x = min(max(anchor.midX - frame.width / 2, screen.frame.minX), screen.frame.maxX - frame.width)
        frame.origin.y = anchor.minY - frame.height
        let moved = panel.frame.origin != frame.origin

        panel.ignoresMouseEvents = false
        withAnimation(KitMotion.content) { model.isDropTarget = asDropTarget }
        if wasOpen {
            // Already out: the drawer glides over to the neighbouring folder
            // and reshapes to fit it, staying open the whole way.
            if moved {
                // Keep it where it is on screen across the panel's move.
                let shift = panel.frame.minX - frame.minX
                panel.setFrame(frame, display: false)
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { model.anchorX += shift }
            }
            withAnimation(Self.glide) {
                model.anchorX = anchor.midX - frame.minX
                model.anchorWidth = anchor.width
                model.folderID = folder
            }
        } else {
            // Closed (or still closing): start from the icon, then spring out.
            // A drawer caught mid-retract reverses from where it is.
            if model.folderID != folder || !panel.isVisible {
                panel.setFrame(frame, display: false)
                model.anchorX = anchor.midX - frame.minX
                model.anchorWidth = anchor.width
                model.folderID = folder
            }
            panel.orderFrontRegardless()
            withAnimation(Self.spring(opening: true)) { model.isOpen = true }
        }
        startWatchingPointer()
    }

    func close(animated: Bool) {
        dwell?.cancel()
        stopWatchingPointer()
        isPinned = false
        guard model.isOpen else { return }
        panel.ignoresMouseEvents = true
        if animated {
            withAnimation(Self.spring(opening: false)) {
                model.isOpen = false
                model.hovered = nil
            }
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.model.isOpen else { return }
                self.panel.orderOut(nil)
            }
            orderOutWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        } else {
            model.isOpen = false
            model.hovered = nil
            panel.orderOut(nil)
        }
        model.isDropTarget = false
    }

    /// The dragged icon landed in the folder: the drawer stops asking for it
    /// and shows it among the others.
    func dropLanded() {
        withAnimation(Self.spring(opening: true)) { model.isDropTarget = false }
    }

    static func spring(opening: Bool) -> Animation {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            return .easeOut(duration: 0.18)
        }
        // Out: quick with a real bounce, the drawer overshooting and settling.
        // In: a fast, clean retract into the bar, no wobble.
        return opening ? .spring(response: 0.36, dampingFraction: 0.64) : .spring(response: 0.24, dampingFraction: 0.9)
    }

    /// Sliding the open drawer over to a neighbouring folder.
    static var glide: Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .easeOut(duration: 0.18) : .spring(response: 0.32, dampingFraction: 0.74)
    }

    // MARK: Pointer

    /// Runs only while a drawer is out: closes it once the pointer has left
    /// both the icon and the drawer for a moment.
    private func startWatchingPointer() {
        outsideSince = nil
        guard pointerTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPointer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    private func stopWatchingPointer() {
        pointerTimer?.invalidate()
        pointerTimer = nil
    }

    private func checkPointer() {
        let mouse = NSEvent.mouseLocation
        let width = drawerWidth
        let drawer = NSRect(x: panel.frame.minX + drawerMinX(width: width), y: panel.frame.maxY - DrawerModel.height,
                            width: width, height: DrawerModel.height)
        let inside = anchor.insetBy(dx: -3, dy: -3).contains(mouse) || drawer.insetBy(dx: -4, dy: -4).contains(mouse)
        updateHoveredTile(mouse: mouse, drawer: drawer)
        if inside || isPinned || model.draggingID != nil {
            outsideSince = nil
        } else if let since = outsideSince {
            if Date().timeIntervalSince(since) > 0.24 { close(animated: true) }
        } else {
            outsideSince = Date()
        }
    }

    /// The panel never becomes key, so SwiftUI's hover is unreliable in it;
    /// the tile under the pointer comes from the layout instead.
    private func updateHoveredTile(mouse: NSPoint, drawer: NSRect) {
        guard let folder = store.folders.first(where: { $0.id == model.folderID }) else { return }
        var hit: String?
        let tilesTop = drawer.maxY - 6
        if mouse.y <= tilesTop, mouse.y >= tilesTop - DrawerModel.tileHeight {
            let widths = folder.items.map { DrawerModel.tileWidth(for: store.image(for: $0)) }
            var x = drawer.midX - widths.reduce(0, +) / 2
            for (item, width) in zip(folder.items, widths) {
                if mouse.x >= x, mouse.x < x + width { hit = item.id; break }
                x += width
            }
        }
        if hit != model.hovered {
            withAnimation(KitMotion.content) { model.hovered = hit }
        }
    }

    private var drawerRect: NSRect {
        let width = drawerWidth
        return NSRect(x: panel.frame.minX + drawerMinX(width: width), y: panel.frame.maxY - DrawerModel.height,
                      width: width, height: DrawerModel.height)
    }

    // MARK: Dragging tiles

    /// The tile follows the pointer 1:1 inside the drawer. Past its edge a
    /// floating copy takes over, since the panel can't draw over the bar.
    private func dragChanged(_ id: String, translation: CGSize) {
        let mouse = NSEvent.mouseLocation
        let outside = !drawerRect.insetBy(dx: -2, dy: -2).contains(mouse)
        if model.draggingID != id {
            model.draggingID = id
            if let item = store.folders.flatMap(\.items).first(where: { $0.id == id }) {
                preview.prepare(image: store.image(for: item))
            }
        }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { model.dragOffset = translation }
        if outside != model.draggedOut {
            withAnimation(KitMotion.content) { model.draggedOut = outside }
        }
        if outside { preview.show(at: mouse) } else { preview.hide(animated: true) }
    }

    private func dragEnded(_ id: String) {
        let mouse = NSEvent.mouseLocation
        guard let folder = store.folders.first(where: { $0.id == model.folderID }) else { return }
        if model.draggedOut {
            preview.drop()
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            onDragOut(id, CGPoint(x: mouse.x, y: top - mouse.y))
            model.draggingID = nil
            model.dragOffset = .zero
            model.draggedOut = false
            return
        }
        // Back inside: drop it into the gap under the pointer.
        let others = folder.items.filter { $0.id != id }
        var x = drawerRect.midX - folder.items.map { DrawerModel.tileWidth(for: store.image(for: $0)) }.reduce(0, +) / 2
        var index = 0
        for item in others {
            let width = DrawerModel.tileWidth(for: store.image(for: item))
            if mouse.x > x + width / 2 { index += 1 }
            x += width
        }
        let from = folder.items.firstIndex { $0.id == id } ?? index
        withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) {
            if index != from { onReorder(folder.id, from, index > from ? index + 1 : index) }
            model.draggingID = nil
            model.dragOffset = .zero
        }
    }

    private var drawerWidth: CGFloat {
        guard let folder = store.folders.first(where: { $0.id == model.folderID }) else { return 160 }
        return DrawerView.width(for: folder, store: store, dropTarget: model.isDropTarget)
    }

    private func drawerMinX(width: CGFloat) -> CGFloat {
        DrawerView.clampedMinX(anchorX: model.anchorX, width: width, panelWidth: Self.panelSize.width)
    }
}

/// Takes the click that brings a non-activating panel forward.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: View

/// What the drawer's views can ask of their controller.
struct DrawerActions {
    var open: (FiledItem, UUID) -> Void
    var add: (UUID, CGPoint) -> Void
    var dragChanged: (String, CGSize) -> Void
    var dragEnded: (String) -> Void
}

struct DrawerView: View {
    let model: DrawerModel
    let store: FolderStore
    let actions: DrawerActions

    static let slotWidth: CGFloat = 34

    static func width(for folder: BarFolder, store: FolderStore, dropTarget: Bool = false) -> CGFloat {
        let tiles = folder.items.reduce(CGFloat(0)) { $0 + DrawerModel.tileWidth(for: store.image(for: $1)) }
        let slot: CGFloat = folder.items.isEmpty || dropTarget ? slotWidth : 0
        return max(150, tiles + slot + DrawerModel.padding * 2) + DrawerModel.shoulder * 2
    }

    static func clampedMinX(anchorX: CGFloat, width: CGFloat, panelWidth: CGFloat) -> CGFloat {
        min(max(anchorX - width / 2, 0), panelWidth - width)
    }

    private var folder: BarFolder? { store.folders.first { $0.id == model.folderID } }

    var body: some View {
        let open = model.isOpen
        let fullWidth = folder.map { Self.width(for: $0, store: store, dropTarget: model.isDropTarget) } ?? 160
        let minX = Self.clampedMinX(anchorX: model.anchorX, width: fullWidth, panelWidth: 900)

        DrawerBody(progress: open ? 1 : 0, fullWidth: fullWidth, centerX: minX + fullWidth / 2,
                   anchorX: model.anchorX, anchorWidth: model.anchorWidth) {
            if let folder {
                // Plain values, not the model: the panel's hosting view drew
                // this once and never again when it read the model.
                DrawerContent(folder: folder, isOpen: open, hovered: model.hovered, store: store,
                              isDropTarget: model.isDropTarget, draggingID: model.draggingID,
                              dragOffset: model.dragOffset, draggedOut: model.draggedOut, actions: actions)
                    .padding(.horizontal, DrawerModel.shoulder + DrawerModel.padding)
                    .padding(.top, 6)
                    .id(folder.id)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -6)),
                                            removal: .opacity))
            }
        }
        .frame(width: 900, height: DrawerModel.height + 30, alignment: .topLeading)
    }
}

private struct DrawerContent: View {
    let folder: BarFolder
    let isOpen: Bool
    let hovered: String?
    let store: FolderStore
    let isDropTarget: Bool
    let draggingID: String?
    let dragOffset: CGSize
    let draggedOut: Bool
    let actions: DrawerActions

    var body: some View {
        let open = isOpen
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                ForEach(Array(folder.items.enumerated()), id: \.element.id) { index, item in
                    let dragging = draggingID == item.id
                    Tile(image: store.image(for: item), isHovered: hovered == item.id && draggingID == nil,
                         isLifted: dragging)
                        .help(item.name)
                        // Glued to the pointer while dragged, no easing.
                        .offset(dragging ? dragOffset : .zero)
                        .opacity(dragging && draggedOut ? 0 : 1)
                        .zIndex(dragging ? 1 : 0)
                        .onTapGesture { actions.open(item, folder.id) }
                        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                            .onChanged { actions.dragChanged(item.id, $0.translation) }
                            .onEnded { _ in actions.dragEnded(item.id) })
                        // Icons drop out of the bar and come into focus, middle
                        // ones first, each on a springier copy of the drawer's
                        // spring so they land with a little bounce of their own.
                        .blur(radius: open || reduceMotion ? 0 : 6)
                        .scaleEffect(open || reduceMotion ? 1 : 0.55, anchor: .top)
                        .offset(y: open || reduceMotion ? 0 : -14)
                        .opacity(open ? 1 : 0)
                        .transaction { t in
                            guard open, !reduceMotion, t.animation != nil else { return }
                            t.animation = .spring(response: 0.38, dampingFraction: 0.58)
                                .delay(stagger(index, of: folder.items.count))
                        }
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
                if folder.items.isEmpty || isDropTarget {
                    Slot(isDropTarget: isDropTarget) { point in actions.add(folder.id, point) }
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
            .frame(height: DrawerModel.tileHeight)

            Text(caption)
                .font(.system(size: 11, weight: hovered == nil ? .medium : .semibold))
                .foregroundStyle(hovered == nil && !isDropTarget ? KitStyle.secondaryText : KitStyle.primaryText)
                .lineLimit(1)
                .contentTransition(.opacity)
                .frame(height: DrawerModel.captionHeight)
                .blur(radius: open || reduceMotion ? 0 : 4)
                .offset(y: open || reduceMotion ? 0 : -8)
                .opacity(open ? 1 : 0)
                .transaction { $0.animation = $0.animation?.delay(open ? 0.06 : 0) }
        }
    }

    private var caption: String {
        if isDropTarget { return "Drop in “\(folder.name)”" }
        if draggedOut { return "Drop on the menu bar to take out" }
        if let hovered, let item = folder.items.first(where: { $0.id == hovered }) { return item.name }
        return folder.items.isEmpty ? "⌘-drag icons here" : folder.name
    }

    private func stagger(_ index: Int, of count: Int) -> Double {
        let middle = Double(count - 1) / 2
        return abs(Double(index) - middle) * 0.025
    }
}

private struct Tile: View {
    let image: NSImage
    let isHovered: Bool
    let isLifted: Bool

    var body: some View {
        DrawerIcon(image: image)
            .frame(width: DrawerModel.tileWidth(for: image) - 14, height: 18)
            .frame(width: DrawerModel.tileWidth(for: image), height: DrawerModel.tileHeight)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(isLifted ? 0.2 : isHovered ? 0.14 : 0))
                    .padding(.vertical, 2)
                    .padding(.horizontal, 1)
            }
            // Picked up: it rises toward the pointer.
            .scaleEffect(isLifted ? 1.12 : 1)
            .shadow(color: .black.opacity(isLifted ? 0.5 : 0), radius: 6, y: 3)
            .animation(.spring(response: 0.26, dampingFraction: 0.7), value: isLifted)
            .contentShape(Rectangle())
    }
}

/// The empty folder's add button, and the gap a dragged icon will drop into.
private struct Slot: View {
    let isDropTarget: Bool
    let onTap: (CGPoint) -> Void
    @State private var breathe = false

    var body: some View {
        GeometryReader { geometry in
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isDropTarget ? KitStyle.primaryText : KitStyle.secondaryText)
                .frame(width: 30, height: 24)
                .background {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(isDropTarget ? 0.55 : 0), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                        .background(Capsule(style: .continuous).fill(isDropTarget ? Color.white.opacity(0.08) : KitStyle.fill))
                }
                .scaleEffect(isDropTarget && breathe ? 1.08 : 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !isDropTarget else { return }
                    let frame = geometry.frame(in: .global)
                    onTap(CGPoint(x: frame.minX, y: frame.maxY + 4))
                }
        }
        .frame(width: DrawerView.slotWidth, height: DrawerModel.tileHeight)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}

/// The icon under the pointer once it has been dragged out of the drawer,
/// drawn in its own window so it can travel over the menu bar.
@MainActor
final class DragPreview {
    private let window: NSPanel
    private let imageView = NSImageView()
    private static let size = NSSize(width: 40, height: 32)

    init() {
        window = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let pill = NSView(frame: NSRect(origin: .zero, size: Self.size))
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
        pill.layer?.cornerRadius = Self.size.height / 2
        pill.layer?.cornerCurve = .continuous
        imageView.frame = pill.bounds.insetBy(dx: 9, dy: 7)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.contentTintColor = .white
        pill.addSubview(imageView)
        window.contentView = pill
    }

    func prepare(image: NSImage) {
        let copy = image.copy() as? NSImage ?? image
        copy.isTemplate = MonochromeCache.isMonochrome(image)
        imageView.image = copy
    }

    func show(at point: NSPoint) {
        window.setFrameOrigin(NSPoint(x: point.x - Self.size.width / 2, y: point.y - Self.size.height / 2))
        if !window.isVisible {
            window.alphaValue = 0
            window.orderFrontRegardless()
        }
        if window.alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; window.animator().alphaValue = 1 }
        }
    }

    func hide(animated: Bool) {
        guard window.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = animated ? 0.12 : 0; window.animator().alphaValue = 0 }) {
            MainActor.assumeIsolated { if self.window.alphaValue == 0 { self.window.orderOut(nil) } }
        }
    }

    /// Let go on the bar: it sinks into place as the real icon moves there.
    func drop() {
        guard window.isVisible else { return }
        let frame = window.frame
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
            window.animator().setFrame(frame.insetBy(dx: frame.width * 0.25, dy: frame.height * 0.25), display: true)
        }) {
            MainActor.assumeIsolated { self.window.orderOut(nil) }
        }
    }
}

/// Menu bar icons are usually black or white glyphs drawn for the bar. On the
/// black drawer they're shown white; colourful ones keep their colours.
private struct DrawerIcon: View {
    let image: NSImage

    var body: some View {
        if MonochromeCache.isMonochrome(image) {
            Image(nsImage: image).renderingMode(.template).resizable().scaledToFit().foregroundStyle(.white)
        } else {
            Image(nsImage: image).resizable().scaledToFit()
        }
    }
}

/// Whether an image has no colour of its own, measured once per image.
@MainActor
enum MonochromeCache {
    private static var cache: [ObjectIdentifier: Bool] = [:]

    static func isMonochrome(_ image: NSImage) -> Bool {
        let key = ObjectIdentifier(image)
        if let known = cache[key] { return known }
        let result = measure(image)
        cache[key] = result
        return result
    }

    private static func measure(_ image: NSImage) -> Bool {
        if image.isTemplate { return true }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        var inked = 0, colourful = 0
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] > 40 {
            inked += 1
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            if max(r, g, b) - min(r, g, b) > 40 { colourful += 1 }
        }
        return inked > 0 && Double(colourful) / Double(inked) < 0.08
    }
}
