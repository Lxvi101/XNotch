import AppKit
import SwiftUI

/// Where things sit on a shelf, shared by the SwiftUI drawing and the AppKit
/// drop target, which hit-tests the bolt and the action tiles itself.
/// Top-left origin, like SwiftUI, relative to the shelf (not its window).
enum ShelfGeometry {
    static let compact = CGSize(width: 180, height: 180)
    static let expanded = CGSize(width: 340, height: 300)
    static let cornerRadius: CGFloat = 20
    /// Transparent border around the shelf inside its window, for the shadow
    /// SwiftUI draws: it scales with the shelf, where a window shadow would pop.
    static let margin: CGFloat = 22
    static let boltSide: CGFloat = 34
    static let boltInset: CGFloat = 12
    static let gridInset: CGFloat = 10
    static let gridSpacing: CGFloat = 8

    static func boltFrame(in size: CGSize) -> CGRect {
        CGRect(x: size.width - boltInset - boltSide, y: size.height - boltInset - boltSide, width: boltSide, height: boltSide)
    }

    /// Two columns up to four actions, three beyond.
    static func actionFrames(count: Int, in size: CGSize) -> [CGRect] {
        guard count > 0 else { return [] }
        let columns = count == 1 ? 1 : count <= 4 ? 2 : 3
        let rows = (count + columns - 1) / columns
        let width = (size.width - gridInset * 2 - gridSpacing * CGFloat(columns - 1)) / CGFloat(columns)
        let height = (size.height - gridInset * 2 - gridSpacing * CGFloat(rows - 1)) / CGFloat(rows)
        return (0..<count).map { index in
            CGRect(x: gridInset + CGFloat(index % columns) * (width + gridSpacing),
                   y: gridInset + CGFloat(index / columns) * (height + gridSpacing),
                   width: width, height: height)
        }
    }

    static func windowFrame(forShelf rect: CGRect) -> CGRect { rect.insetBy(dx: -margin, dy: -margin) }
    static func shelfFrame(inWindow rect: CGRect) -> CGRect { rect.insetBy(dx: margin, dy: margin) }
}

/// A borderless panel that floats over everything without activating XNotch.
/// It can still become key, for Quick Look's space bar and the shelf's keys.
final class ShelfPanel: NSPanel {
    var onKeyDown: ((NSEvent) -> Bool)?

    init(shelfSize: CGSize) {
        super.init(contentRect: ShelfGeometry.windowFrame(forShelf: CGRect(origin: .zero, size: shelfSize)),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Keys go to the shelf before the hosting view, which would swallow the space bar.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKeyDown?(event) == true { return }
        super.sendEvent(event)
    }
}

/// The name of the action under the drag, rising out of the top of the shelf.
final class ActionLabelPanel: NSPanel {
    static let size = CGSize(width: 260, height: 52)
    let model = Label()

    @MainActor @Observable final class Label {
        var title = ""
        var isVisible = false
    }

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        contentView = NSHostingView(rootView: ActionLabel(model: model))
    }

    private struct ActionLabel: View {
        let model: Label

        var body: some View {
            let visible = model.isVisible
            Text(model.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.interpolate)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color(red: 0.04, green: 0.52, blue: 1)))
                .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
                .scaleEffect(visible ? 1 : 0.6, anchor: .bottom)
                .offset(y: visible ? 0 : 14)
                .blur(radius: visible ? 0 : 5)
                .opacity(visible ? 1 : 0)
                .animation(ShelfMotion.hover, value: visible)
                .animation(ShelfMotion.content, value: model.title)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 4)
        }
    }
}

/// The panel's content view: takes drops for the shelf and for its
/// instant actions, and tells the shelf when the pointer is over it. Only
/// the shelf counts, not the transparent margin around it.
final class ShelfDropView: NSView {
    weak var controller: ShelfController?

    override var isFlipped: Bool { true }

    private var shelfRect: CGRect { bounds.insetBy(dx: ShelfGeometry.margin, dy: ShelfGeometry.margin) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(PasteboardReader.readableTypes)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: shelfRect, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        MainActor.assumeIsolated { controller?.setHovered(true) }
    }

    override func mouseExited(with event: NSEvent) {
        MainActor.assumeIsolated { controller?.setHovered(false) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        update(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        update(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        MainActor.assumeIsolated { controller?.dragLeft() }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let point = shelfPoint(sender)
        guard CGRect(origin: .zero, size: shelfRect.size).contains(point) else { return false }
        return MainActor.assumeIsolated {
            controller?.drop(sender.draggingPasteboard, at: point, isOwn: isOwn(sender)) ?? false
        }
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        MainActor.assumeIsolated { controller?.dragLeft() }
    }

    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = shelfPoint(sender)
        let size = shelfRect.size
        return MainActor.assumeIsolated {
            guard CGRect(origin: .zero, size: size).contains(point) else {
                controller?.dragLeft()
                return []
            }
            return controller?.dragMoved(to: point, in: size, isOwn: isOwn(sender)) ?? []
        }
    }

    private func shelfPoint(_ sender: NSDraggingInfo) -> CGPoint {
        let point = convert(sender.draggingLocation, from: nil)
        return CGPoint(x: point.x - shelfRect.minX, y: point.y - shelfRect.minY)
    }

    private func isOwn(_ sender: NSDraggingInfo) -> Bool {
        MainActor.assumeIsolated { (sender.draggingSource as AnyObject?) === controller }
    }
}

/// SwiftUI hosting that takes the first click, so a shelf that isn't key
/// still reacts at once, and leaves drops to `ShelfDropView`.
final class ShelfHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        unregisterDraggedTypes()
    }

    @MainActor required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
