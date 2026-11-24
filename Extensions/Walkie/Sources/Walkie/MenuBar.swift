import AppKit
import Combine
import SwiftUI
import XNotchKit

/// Walkie's faces in the macOS menu bar. Hovering names a face, a click opens
/// the conversation as glass bubbles over the desktop, holding a face talks,
/// and files dragged onto a face wait in its composer.
@MainActor
final class MenuBarController {
    let model = MenuBarModel()
    let ui = WalkieUI()
    let composer = ComposerState()
    /// Hover for the panel's controls, which read it the way they do in the notch.
    let pointer = NotchPointer()
    private let store: WalkieStore
    private let openSettings: () -> Void
    private let tick: () -> Void
    private let statusItem: NSStatusItem
    private let strip: FaceStripView
    private let facesHost: NSHostingView<AnyView>
    private let panel: MenuBarPanel
    private let panelHost: PanelDropView
    let geometry = PanelGeometry()
    /// Files dropped on your own face: they go to your tray.
    var onDropToSelf: (([URL]) -> Void)?
    private var cancellables: Set<AnyCancellable> = []
    private var outsideClick: Any?
    private var keys: Any?
    private var dropTracking: Timer?

    /// Wide and tall enough that the feathered backdrop fades out before the window's edge.
    static let panelSize = CGSize(width: 540, height: 640)

    private var barHeight: CGFloat { NSStatusBar.system.thickness }

    init(store: WalkieStore, openSettings: @escaping () -> Void, tick: @escaping () -> Void) {
        self.store = store
        self.openSettings = openSettings
        self.tick = tick
        statusItem = NSStatusBar.system.statusItem(withLength: 40)
        strip = FaceStripView()
        facesHost = NSHostingView(rootView: AnyView(EmptyView()))
        panel = MenuBarPanel(size: Self.panelSize)
        panelHost = PanelDropView(frame: CGRect(origin: .zero, size: Self.panelSize))

        facesHost.rootView = AnyView(MenuBarFaces(store: store, model: model, ui: ui, player: store.player, barHeight: barHeight))
        strip.addSubview(facesHost)
        strip.controller = self
        statusItem.button?.addSubview(strip)
        statusItem.button?.setAccessibilityLabel("Walkie")

        let content = NSHostingView(rootView: AnyView(EmptyView()))
        content.frame = panelHost.bounds
        content.autoresizingMask = [.width, .height]
        panelHost.addSubview(content)
        panelHost.controller = self
        panel.contentView = panelHost
        content.rootView = AnyView(PanelRoot(store: store, model: model, ui: ui, composer: composer, controller: self))

        store.$contacts.receive(on: RunLoop.main).sink { [weak self] _ in self?.layoutStrip() }.store(in: &cancellables)
        ui.$panel.receive(on: RunLoop.main).sink { [weak self] _ in self?.syncPanel() }.store(in: &cancellables)
        model.$dropTarget.receive(on: RunLoop.main).sink { [weak self] _ in self?.syncPanel() }.store(in: &cancellables)
        model.$hovered.receive(on: RunLoop.main).sink { [weak self] _ in self?.syncPanel() }.store(in: &cancellables)
        ui.$notice.receive(on: RunLoop.main).sink { [weak self] _ in self?.syncPanel() }.store(in: &cancellables)
        layoutStrip()
    }

    func remove() {
        if store.recorder.isRecording { store.recorder.cancel() }
        hidePanelNow()
        NSStatusBar.system.removeStatusItem(statusItem)
        cancellables.removeAll()
    }


    lazy var actions = ComposerActions(
        send: { [weak self] in self?.send() },
        record: { [weak self] in self?.startRecording(hold: false) },
        stop: { [weak self] in self?.stopRecording() },
        discard: { [weak self] in self?.discard() },
        attach: { [weak self] in self?.pickFiles() },
        screenshot: { [weak self] in self?.screenshot() },
        removeFile: { [weak self] url in self?.composer.files.removeAll { $0 == url } },
        playTake: { [weak self] in
            guard let self, let take = self.composer.take else { return }
            self.store.player.toggle("composer-take", url: take.url)
        }
    )

    // MARK: Strip

    private var people: [Contact] { store.stripPeople }

    private func layoutStrip() {
        // You're always there; the strip shows once there's someone to talk to.
        statusItem.isVisible = people.count > 1
        let width = MenuBarLayout.width(count: people.count, barHeight: barHeight)
        statusItem.length = width
        let frame = CGRect(x: 0, y: 0, width: width, height: barHeight)
        strip.frame = frame
        facesHost.frame = frame
    }

    /// The face in focus: a dragged file's target, the one under the pointer, or the open one.
    private var focusIndex: Int? {
        let box = model.dropTarget ?? model.hovered ?? openBox
        return box.flatMap { b in people.firstIndex { $0.box == b } }
    }

    func face(atStripX x: CGFloat) -> Contact? {
        MenuBarLayout.face(at: x, count: people.count, barHeight: barHeight, focus: focusIndex).map { people[$0] }
    }

    func pointerMoved(toStripX x: CGFloat?) {
        let inside = x != nil
        if model.hovering != inside { model.hovering = inside }
        let hovered = x.flatMap { face(atStripX: $0)?.box }
        if model.hovered != hovered { model.hovered = hovered }
    }

    private var openBox: String? {
        if case .chat(let box) = ui.panel { return box }
        return nil
    }

    private func open(_ contact: Contact) {
        guard contact.accepted else { close(); openSettings(); return }
        composer.prepare(for: contact.box)
        store.markRead(contact.box)
        ui.show(.chat(contact.box))
    }

    // MARK: Press: hold to talk, click to open

    private var holdWork: DispatchWorkItem?
    private var pressed: Contact?
    private var holding = false
    /// The held face hears you live instead of getting a voice note.
    private var holdingLive = false

    func pressBegan(atStripX x: CGFloat) {
        guard let contact = face(atStripX: x) else { return }
        pressed = contact
        model.hovered = nil
        let work = DispatchWorkItem { [weak self] in
            guard let self, let contact = self.pressed, contact.box != WalkieStore.selfBox else { return }
            self.holding = true
            // Both of you have the other here: talk live, no panel in the way.
            if contact.isLive, !self.store.isTalkingLive, self.store.beginLive(only: contact) {
                self.holdingLive = true
                self.tick()
                return
            }
            self.open(contact)
            self.startRecording(hold: true)
        }
        holdWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func pressMoved() {}

    func pressEnded() {
        holdWork?.cancel()
        defer {
            pressed = nil
            holding = false
            holdingLive = false
        }
        guard let contact = pressed else { return }
        if holdingLive {
            store.endLive()
            tick()
        } else if holding {
            stopRecording()
        } else if contact.box == WalkieStore.selfBox {
            // Your own face opens Walkie setup in Settings.
            tick()
            close()
            openSettings()
        } else {
            tick()
            if openBox == contact.box { close() } else { open(contact) }
        }
    }

    // MARK: Composer

    private var openContact: Contact? { openBox.flatMap { store.contact($0) } }

    private func startRecording(hold: Bool) {
        guard let contact = openContact, composer.phase == .idle else { return }
        guard store.recorder.micAuthorized else {
            Task {
                let granted = await VoiceRecorder.requestMic()
                ui.flash(granted ? "Microphone on. Try again to talk." : "XNotch needs the microphone: System Settings → Privacy & Security → Microphone.")
            }
            return
        }
        do {
            try store.recorder.start(directory: FileManager.default.temporaryDirectory.appendingPathComponent("XNotchWalkie"),
                                     transcribe: store.transcribe) { [weak self] in self?.stopRecording() }
        } catch {
            ui.flash(error.localizedDescription)
            return
        }
        tick()
        store.player.stop()
        store.signalTalking(true, to: contact)
        composer.holdToTalk = hold
        withAnimation(MenuBarMotion.morph) { composer.phase = .recording }
    }

    /// Stop: a held face sends at once; the composer's mic stops into review.
    private func stopRecording() {
        guard composer.phase == .recording, let contact = openContact else { return }
        store.signalTalking(false, to: contact)
        let sendNow = composer.holdToTalk
        Task {
            let take = await store.recorder.stop()
            guard let take else {
                withAnimation(MenuBarMotion.morph) { composer.phase = .idle }
                ui.flash("That was too short to send.")
                return
            }
            composer.take = take
            if sendNow {
                send()
            } else {
                withAnimation(MenuBarMotion.morph) { composer.phase = .review }
            }
        }
    }

    private func discard() {
        if composer.phase == .recording {
            store.recorder.cancel()
            if let contact = openContact { store.signalTalking(false, to: contact) }
        }
        if let take = composer.take { try? FileManager.default.removeItem(at: take.url) }
        composer.take = nil
        store.player.stop()
        withAnimation(MenuBarMotion.morph) { composer.phase = .idle }
    }

    /// Everything waiting goes, in order: files, the voice note, the text.
    private func send() {
        guard let contact = openContact, composer.canSend else { return }
        tick()
        withAnimation(MenuBarMotion.pop) {
            if !composer.files.isEmpty {
                store.sendFiles(composer.files, to: contact)
                composer.files = []
            }
            if composer.phase == .review || composer.holdToTalk, let take = composer.take {
                store.player.stop()
                store.sendVoice(take, to: contact)
                composer.take = nil
            }
            let text = composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { store.sendText(text, to: contact) }
            composer.text = ""
            composer.holdToTalk = false
            composer.phase = .idle
        }
    }

    private func pickFiles() {
        let picker = NSOpenPanel()
        picker.canChooseFiles = true
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = true
        picker.prompt = "Add"
        picker.presentAboveOverlays { [weak self] urls in
            guard let self else { return }
            if !urls.isEmpty {
                withAnimation(MenuBarMotion.pop) { self.composer.files += urls.filter { !self.composer.files.contains($0) } }
            }
            if self.panel.isVisible { self.panel.makeKey() }
        }
    }

    private func screenshot() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Screenshot \(UUID().uuidString.prefix(6)).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", url.path]
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, FileManager.default.fileExists(atPath: url.path) else { return }
                withAnimation(MenuBarMotion.pop) { self.composer.files.append(url) }
            }
        }
        try? process.run()
    }

    // MARK: Drops

    /// A file reached the strip: the drop panel opens under the face it's on.
    func dragMoved(toStripX x: CGFloat) -> Bool {
        guard !model.dropLeaving else { return false }
        if model.dropTarget == nil, let contact = face(atStripX: x) {
            tick()
            model.dropTarget = contact.box
        }
        trackDropPointer()
        return model.dropTarget != nil
    }

    /// The pointer decides, wherever it is over the strip or the panel.
    func dragLeftStrip() {}

    func dragEnteredPanel() -> Bool {
        model.dropTarget != nil && !model.dropLeaving
    }

    /// Files dropped on a face wait in its composer; on you, they go to your tray.
    func drop(_ urls: [URL]) -> Bool {
        guard let box = model.dropTarget, !urls.isEmpty else { return false }
        finishDrop()
        tick()
        withAnimation(.smooth(duration: 0.46, extraBounce: 0.12)) { model.dropped = box }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            withAnimation(KitMotion.content) { self?.model.dropped = nil }
        }
        if box == WalkieStore.selfBox {
            onDropToSelf?(urls)
            return true
        }
        guard let contact = store.contact(box) else { return false }
        open(contact)
        withAnimation(MenuBarMotion.pop) { composer.files += urls.filter { !composer.files.contains($0) } }
        panel.makeKey()
        return true
    }

    /// The drop panel goes at once: the conversation takes its place.
    private func finishDrop() {
        dropTracking?.invalidate()
        dropTracking = nil
        model.dropPoint = nil
        model.dropLeaving = false
        model.dropTarget = nil
    }

    /// The drag left or was let go elsewhere: dots fade, then the panel, then it's gone.
    func endDrop() {
        guard model.dropTarget != nil, !model.dropLeaving else { return }
        dropTracking?.invalidate()
        dropTracking = nil
        model.dropLeaving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            guard let self, self.model.dropLeaving else { return }
            self.finishDrop()
        }
    }

    /// Drag sessions swallow mouse-moved events: read the pointer on a timer.
    /// Its horizontal position picks the face; leaving the strip and the
    /// panel, or letting go, ends the drop.
    private func trackDropPointer() {
        guard dropTracking == nil else { return }
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.followDrag() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dropTracking = timer
    }

    private func followDrag() {
        guard let window = strip.window else { return }
        let mouse = NSEvent.mouseLocation
        if NSEvent.pressedMouseButtons == 0 {
            endDrop()
            return
        }
        let over = panel.frame.insetBy(dx: 0, dy: 0).contains(mouse) || window.frame.insetBy(dx: -12, dy: -6).contains(mouse)
        guard over else {
            endDrop()
            return
        }
        // The face nearest the pointer, across the fanned-out row.
        let local = strip.convert(window.convertPoint(fromScreen: mouse), from: nil).x
        let centers = MenuBarLayout.centers(count: people.count, barHeight: barHeight, focus: focusIndex)
        if let nearest = centers.enumerated().min(by: { abs($0.element - local) < abs($1.element - local) }) {
            let box = people[nearest.offset].box
            if model.dropTarget != box {
                tick()
                model.dropTarget = box
            }
        }
        let frame = panel.frame
        model.dropPoint = CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y - 6)
    }

    // MARK: Panel

    private enum Showing { case nothing, pill, interactive }

    private var showing: Showing {
        if model.dropTarget != nil || openBox != nil || ui.notice != nil { return .interactive }
        return model.hovered != nil ? .pill : .nothing
    }

    private func syncPanel() {
        switch showing {
        case .nothing: hidePanel()
        case .pill: showPanel(interactive: false)
        case .interactive: showPanel(interactive: true)
        }
    }

    private func showPanel(interactive: Bool) {
        hideWork?.cancel()
        positionPanel()
        // The name pill never catches a click meant for what's under it.
        panel.ignoresMouseEvents = !interactive
        if !panel.isVisible { panel.orderFrontRegardless() }
        if interactive {
            installMonitors()
            if openBox != nil { panel.makeKey() }
        }
    }

    private var hideWork: DispatchWorkItem?

    private func hidePanel() {
        hideWork?.cancel()
        // Let the fade play out before the window goes.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.showing == .nothing else { return }
            self.hidePanelNow()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34, execute: work)
    }

    private func hidePanelNow() {
        panel.orderOut(nil)
        removeMonitors()
    }

    /// Under the face it belongs to, kept on screen. While a file is dragged
    /// the window holds still under the strip and the drop panel glides inside it.
    private func positionPanel() {
        guard let window = strip.window, let screen = window.screen ?? NSScreen.main else { return }
        let centers = MenuBarLayout.centers(count: people.count, barHeight: barHeight, focus: focusIndex)
        func screenX(_ local: CGFloat) -> CGFloat {
            window.convertToScreen(strip.convert(CGRect(x: local, y: 0, width: 0, height: 0), to: nil)).minX
        }
        let box = model.dropTarget == nil ? (openBox ?? model.hovered) : nil
        let index = box.flatMap { b in people.firstIndex { $0.box == b } }
        let anchor = screenX(index.map { centers[$0] } ?? strip.bounds.midX)
        let size = Self.panelSize
        // During a drop the window holds still; the panel inside it moves.
        if !(model.dropTarget != nil && panel.isVisible) {
            var x = anchor - size.width / 2
            x = min(max(x, screen.visibleFrame.minX + 4), screen.visibleFrame.maxX - size.width - 4)
            panel.setFrame(CGRect(x: x, y: window.frame.minY - size.height, width: size.width, height: size.height),
                           display: false)
        }
        let origin = panel.frame.minX
        geometry.anchorX = min(1, max(0, (anchor - origin) / size.width))
        var faces: [String: CGFloat] = [:]
        for (index, person) in people.enumerated() { faces[person.box] = screenX(centers[index]) - origin }
        geometry.faceX = faces
    }

    private func installMonitors() {
        guard outsideClick == nil else { return }
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.clickedOutside() }
        }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Only Esc typed into the panel: Esc in a file picker is the picker's.
            guard event.keyCode == 53, let self, event.window === self.panel else { return event }
            MainActor.assumeIsolated { self.escape() }
            return nil
        }
    }

    private func removeMonitors() {
        if let outsideClick { NSEvent.removeMonitor(outsideClick) }
        if let keys { NSEvent.removeMonitor(keys) }
        outsideClick = nil
        keys = nil
    }

    private func clickedOutside() {
        guard composer.phase != .recording else { return }
        let mouse = NSEvent.mouseLocation
        if let window = strip.window, window.frame.contains(mouse) { return }
        close()
    }

    /// Esc steps back: a recording or a review is thrown away first, then the panel closes.
    private func escape() {
        if composer.phase != .idle { discard() } else { close() }
    }

    func close() {
        guard composer.phase != .recording else { return }
        ui.show(.hint)
        ui.notice = nil
    }
}

/// Holds the panel's SwiftUI tree and refreshes the anchor when the panel moves.
private struct PanelRoot: View {
    @ObservedObject var store: WalkieStore
    @ObservedObject var model: MenuBarModel
    @ObservedObject var ui: WalkieUI
    @ObservedObject var composer: ComposerState
    let controller: MenuBarController

    var body: some View {
        MenuBarPanelView(store: store, model: model, ui: ui, composer: composer, actions: controller.actions,
                         geometry: controller.geometry)
            .coordinateSpace(name: KitSpace.canvas)
            .environmentObject(controller.pointer)
    }
}

/// The strip in the status item: its own mouse handling (hover, hold, click)
/// and file drops, hit-tested with `MenuBarLayout`.
final class FaceStripView: NSView {
    weak var controller: MenuBarController?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { controller?.pointerMoved(toStripX: x(event)) }
    override func mouseMoved(with event: NSEvent) { controller?.pointerMoved(toStripX: x(event)) }
    override func mouseExited(with event: NSEvent) { controller?.pointerMoved(toStripX: nil) }
    override func mouseDown(with event: NSEvent) { controller?.pressBegan(atStripX: x(event)) }
    override func mouseDragged(with event: NSEvent) { controller?.pressMoved() }
    override func mouseUp(with event: NSEvent) { controller?.pressEnded() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func x(_ event: NSEvent) -> CGFloat { convert(event.locationInWindow, from: nil).x }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dragged(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dragged(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { controller?.dragLeftStrip() }

    private func dragged(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller?.dragMoved(toStripX: convert(sender.draggingLocation, from: nil).x) == true ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        controller?.drop(fileURLs(sender)) ?? false
    }
}

/// The panel's content view: it takes files once a drag moves down into it,
/// and feeds the pointer to the panel's hover effects.
final class PanelDropView: NSView {
    weak var controller: MenuBarController?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) { report(event) }
    override func mouseEntered(with event: NSEvent) { report(event) }
    override func mouseDragged(with event: NSEvent) { report(event) }
    override func mouseExited(with event: NSEvent) { controller?.pointer.update(nil) }

    /// SwiftUI's canvas space starts at the top left.
    private func report(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        controller?.pointer.update(CGPoint(x: point.x, y: bounds.height - point.y))
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller?.dragEnteredPanel() == true ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller?.dragEnteredPanel() == true ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { controller?.dragLeftStrip() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        controller?.drop(fileURLs(sender)) ?? false
    }
}

private func fileURLs(_ sender: NSDraggingInfo) -> [URL] {
    sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
}

/// Floats over everything without activating XNotch; it becomes key when you
/// click into it, so the composer takes typing.
final class MenuBarPanel: NSPanel {
    init(size: CGSize) {
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { true }
}
