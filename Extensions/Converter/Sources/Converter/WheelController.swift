import AppKit
import Observation
import QuickLookThumbnailing
import SwiftUI

/// The files the wheel works on, all of one kind: dragged, or from a shelf.
struct WheelFiles {
    let urls: [URL]
    let kind: FileKind
    var offer: Offer

    init(_ urls: [URL], kind: FileKind) {
        self.urls = urls
        self.kind = kind
        offer = Catalog.offer(for: kind, sourceExtensions: urls.map(\.pathExtension))
    }

    /// Read once, when the wheel opens.
    var totalSize: Int64 {
        urls.reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}

/// How the wheel is used: under a drag, dropped on; or opened from a shelf,
/// clicked, with what it makes going back to that shelf.
enum WheelMode {
    case drag
    case click(deliver: @MainActor ([URL]) -> Void)

    var isClick: Bool { if case .click = self { true } else { false } }
}

/// What the wheel draws. Each view reads only what it shows, so a hover
/// redraws two sectors and the hub, not the wheel.
@MainActor @Observable
final class WheelModel {
    let files: WheelFiles
    let geometry: WheelGeometry
    var isPresented = false
    var hovered: WheelGeometry.Hit?
    /// Set on the drop: the wheel becomes this job's progress pill.
    var job: ConversionJob?
    var isPillHovered = false
    /// Operations that would install ffmpeg first.
    var needsFFmpeg: Set<Action> = []
    var thumbnail: NSImage?
    let totalSize: Int64

    init(files: WheelFiles) {
        self.files = files
        totalSize = files.totalSize
        geometry = WheelGeometry(formatCount: files.offer.formats.count, toolCount: files.offer.tools.count)
    }

    func operation(for hit: WheelGeometry.Hit?) -> Action? {
        switch hit {
        case .format(let index): files.offer.formats.indices.contains(index) ? .convert(files.offer.formats[index]) : nil
        case .tool(let index): files.offer.tools.indices.contains(index) ? .tool(files.offer.tools[index]) : nil
        case .hub, nil: nil
        }
    }
}

enum WheelMotion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Opening under a resting pointer: no momentum, so barely any overshoot.
    static var appear: Animation { reduced ? .easeOut(duration: 0.18) : .spring(response: 0.36, dampingFraction: 0.82) }
    static var disappear: Animation { reduced ? .easeIn(duration: 0.14) : .spring(response: 0.24, dampingFraction: 1) }
    static var hover: Animation { reduced ? .easeOut(duration: 0.1) : .spring(response: 0.22, dampingFraction: 0.8) }
    /// The wheel folding into the pill: a shape change, smooth and barely alive.
    static var morph: Animation { reduced ? .easeInOut(duration: 0.2) : .spring(response: 0.44, dampingFraction: 0.86) }
    static var content: Animation { reduced ? .easeInOut(duration: 0.18) : .spring(response: 0.34, dampingFraction: 0.86) }
}

/// A borderless panel above everything, shelves included, that never
/// activates XNotch.
final class WheelPanel: NSPanel {
    init() {
        super.init(contentRect: CGRect(origin: .zero, size: CGSize(width: WheelGeometry.panelSide, height: WheelGeometry.panelSide)),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        appearance = NSAppearance(named: .darkAqua)
    }

    /// A clicked wheel takes the keys, for Escape; a dragged one never needs them.
    var acceptsKeys = false
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { acceptsKeys }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53, let onEscape { return onEscape() }
        super.sendEvent(event)
    }
}

/// One wheel: opened under a drag or from a shelf, then the pill of the job
/// dropped on it or clicked.
@MainActor
final class WheelController: NSObject {
    let model: WheelModel
    let mode: WheelMode
    let panel = WheelPanel()
    var onClose: ((WheelController) -> Void)?
    var start: ((ConversionJob) -> Void)?
    var tick: () -> Void = {}

    /// The wheel's centre on screen.
    private let center: CGPoint
    private var dismissal: DispatchWorkItem?
    private var autoClose: DispatchWorkItem?
    private var hasDropped = false
    /// Clicks elsewhere, which put a clicked wheel away.
    private var clickMonitors: [Any] = []
    private(set) var isClosing = false

    init(files: WheelFiles, at point: CGPoint, needsFFmpeg: Set<Action>, mode: WheelMode = .drag) {
        model = WheelModel(files: files)
        self.mode = mode
        model.needsFFmpeg = needsFFmpeg
        // Whole points, so the pill stays put when the window shrinks around it.
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let visible = screen?.frame ?? CGRect(origin: .zero, size: CGSize(width: 4000, height: 4000))
        let radius = model.geometry.radius
        // Kept on screen, so the far side of the wheel can be reached.
        center = CGPoint(x: min(max(point.x, visible.minX + radius + 8), visible.maxX - radius - 8).rounded(),
                         y: min(max(point.y, visible.minY + radius + 8), visible.maxY - radius - 8).rounded())
        super.init()
        let dropView = WheelDropView(frame: panel.contentLayoutRect, followsPointer: mode.isClick)
        dropView.controller = self
        let hosting = WheelHostingView(rootView: WheelView(model: model, controller: self))
        hosting.sizingOptions = []
        hosting.passesClicks = { [weak model] in model?.job == nil }
        hosting.frame = dropView.bounds
        hosting.autoresizingMask = [.width, .height]
        dropView.addSubview(hosting)
        panel.contentView = dropView
        loadThumbnail()
    }

    // MARK: Showing

    func show() {
        let side = WheelGeometry.panelSide
        panel.setFrame(CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side), display: true)
        panel.orderFrontRegardless()
        if mode.isClick {
            panel.acceptsKeys = true
            panel.onEscape = { [weak self] in self?.dismiss() }
            panel.makeKey()
            watchClicksElsewhere()
        }
        // One frame at rest first, so the spring has somewhere to leave from.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                withAnimation(WheelMotion.appear) { self.model.isPresented = true }
            }
        }
    }

    /// Folds the wheel away, unless it has become a job's pill.
    func dismiss() {
        guard !isClosing, model.job == nil else { return }
        close()
    }

    private func close() {
        guard !isClosing else { return }
        isClosing = true
        stopWatchingClicks()
        dismissal?.cancel()
        autoClose?.cancel()
        withAnimation(model.job == nil ? WheelMotion.disappear : WheelMotion.content) { model.isPresented = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.panel.orderOut(nil)
                self.onClose?(self)
            }
        }
    }

    private func loadThumbnail() {
        guard let url = model.files.urls.first else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 96, height: 96), scale: scale,
                                                   representationTypes: .all)
        request.iconMode = true
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            guard let image = representation?.nsImage else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    withAnimation(WheelMotion.content) { self.model.thumbnail = image }
                }
            }
        }
    }

    // MARK: The drag

    /// Called on every drag update over the panel, with the point relative to
    /// the wheel's centre; changes state only when something changed.
    func dragMoved(to offset: CGPoint) -> NSDragOperation {
        guard model.job == nil, !isClosing else { return [] }
        dismissal?.cancel()
        dismissal = nil
        let hit = model.geometry.hit(offset)
        if hit == nil, hypot(offset.x, offset.y) > model.geometry.radius + WheelGeometry.reach {
            // Off the wheel: the drag is going somewhere else.
            dismiss()
            return []
        }
        if hit != model.hovered {
            withAnimation(WheelMotion.hover) { model.hovered = hit }
            if hit != nil && hit != .hub { tick() }
        }
        return model.operation(for: hit) == nil ? [] : .copy
    }

    /// The drag left the panel, perhaps only for a moment along its edge.
    func dragExited() {
        guard model.job == nil, !isClosing else { return }
        withAnimation(WheelMotion.hover) { model.hovered = nil }
        let item = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissal = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
    }

    func drop(at offset: CGPoint) -> Bool {
        hasDropped = true
        guard model.job == nil, let operation = model.operation(for: model.geometry.hit(offset)) else {
            dismiss()
            return false
        }
        stopWatchingClicks()
        panel.onEscape = nil
        let job = ConversionJob(operation: operation, kind: model.files.kind, sources: model.files.urls)
        if case .click(let deliver) = mode { job.deliver = deliver }
        tick()
        withAnimation(WheelMotion.morph) {
            model.job = job
            model.hovered = nil
        }
        start?(job)
        // Once the wheel has folded into the pill, the window shrinks to it,
        // so it stops covering what's around.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            MainActor.assumeIsolated { self?.shrinkToPill() }
        }
        return true
    }

    /// The drag that opened the wheel let go: dropped anywhere else, the wheel goes.
    func triggeringDragEnded() {
        // The drop can reach the panel just after the mouse comes up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.hasDropped else { return }
                self.dismiss()
            }
        }
    }

    // MARK: Clicking

    /// The pointer over a clicked wheel: the same hover as a drag, but moving
    /// off it only clears the hover; a click elsewhere puts it away.
    func pointerMoved(to offset: CGPoint) {
        guard model.job == nil, !isClosing else { return }
        let hit = model.geometry.hit(offset)
        guard hit != model.hovered else { return }
        withAnimation(WheelMotion.hover) { model.hovered = hit }
        if hit != nil && hit != .hub { tick() }
    }

    func clicked(at offset: CGPoint) {
        guard model.job == nil, !isClosing else { return }
        _ = drop(at: offset)
    }

    private func watchClicksElsewhere() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }) { clickMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window !== self.panel { self.dismiss() }
            }
            return event
        }) { clickMonitors.append(local) }
    }

    private func stopWatchingClicks() {
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors.removeAll()
    }

    // MARK: The pill

    private func shrinkToPill() {
        guard !isClosing else { return }
        let size = WheelView.pillSize
        let margin = WheelGeometry.shadowReach
        panel.setFrame(CGRect(x: center.x - size.width / 2 - margin, y: center.y - size.height / 2 - margin,
                              width: size.width + margin * 2, height: size.height + margin * 2), display: true)
        (panel.contentView as? WheelDropView)?.unregisterDraggedTypes()
    }

    func jobFinished() {
        guard let job = model.job else { return }
        scheduleAutoClose(after: job.phase == .done ? 2.8 : job.phase == .cancelled ? 0.6 : 6)
    }

    func setPillHovered(_ hovered: Bool) {
        guard model.job != nil, model.isPillHovered != hovered else { return }
        withAnimation(WheelMotion.hover) { model.isPillHovered = hovered }
        if hovered {
            autoClose?.cancel()
        } else if model.job?.isFinished == true {
            scheduleAutoClose(after: 1.6)
        }
    }

    private func scheduleAutoClose(after delay: TimeInterval) {
        autoClose?.cancel()
        guard !model.isPillHovered else { return }
        let item = DispatchWorkItem { [weak self] in self?.close() }
        autoClose = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// A click on the pill: cancel while it runs, show the result after.
    func pillClicked() {
        guard let job = model.job else { return }
        if !job.isFinished {
            job.cancel()
        } else {
            if !job.outputs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(job.outputs) }
            close()
        }
    }

    /// Closes the pill at once, for the extension switching off.
    func tearDown() {
        stopWatchingClicks()
        model.job?.cancel()
        dismissal?.cancel()
        autoClose?.cancel()
        panel.orderOut(nil)
    }
}

/// Takes the drops, hit-tests them against the wheel, and follows the
/// pointer over the pill.
final class WheelDropView: NSView {
    weak var controller: WheelController?
    /// A clicked wheel follows the pointer itself; a dragged one hears of it through the drag.
    private let followsPointer: Bool

    override var isFlipped: Bool { true }

    init(frame: NSRect, followsPointer: Bool) {
        self.followsPointer = followsPointer
        super.init(frame: frame)
        if !followsPointer { registerForDraggedTypes([.fileURL]) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        let size = WheelView.pillSize
        let pill = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        addTrackingArea(NSTrackingArea(rect: pill, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
        if followsPointer {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseMoved(with event: NSEvent) {
        let offset = self.offset(event.locationInWindow)
        MainActor.assumeIsolated { controller?.pointerMoved(to: offset) }
    }

    /// Clicks reach here only where SwiftUI doesn't take them: on the wheel, not the pill.
    override func mouseDown(with event: NSEvent) {
        guard followsPointer else { return super.mouseDown(with: event) }
        let offset = self.offset(event.locationInWindow)
        MainActor.assumeIsolated { controller?.clicked(at: offset) }
    }

    override func mouseEntered(with event: NSEvent) {
        MainActor.assumeIsolated { controller?.setPillHovered(true) }
    }

    override func mouseExited(with event: NSEvent) {
        MainActor.assumeIsolated { controller?.setPillHovered(false) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        MainActor.assumeIsolated { controller?.dragExited() }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let offset = self.offset(sender)
        return MainActor.assumeIsolated { controller?.drop(at: offset) ?? false }
    }

    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
        let offset = self.offset(sender)
        return MainActor.assumeIsolated { controller?.dragMoved(to: offset) ?? [] }
    }

    private func offset(_ sender: NSDraggingInfo) -> CGPoint {
        offset(sender.draggingLocation)
    }

    private func offset(_ windowPoint: CGPoint) -> CGPoint {
        let point = convert(windowPoint, from: nil)
        return CGPoint(x: point.x - bounds.midX, y: point.y - bounds.midY)
    }
}

/// Takes the first click, so the pill reacts though XNotch isn't active, and
/// leaves drops, and clicks on the wheel itself, to `WheelDropView`.
final class WheelHostingView<Content: View>: NSHostingView<Content> {
    /// True while there's a wheel rather than a pill.
    var passesClicks: () -> Bool = { false }

    required init(rootView: Content) {
        super.init(rootView: rootView)
        unregisterDraggedTypes()
    }

    @MainActor required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        passesClicks() ? nil : super.hitTest(point)
    }
}
