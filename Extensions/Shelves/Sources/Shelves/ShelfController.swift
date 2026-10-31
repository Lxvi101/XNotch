import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import XNotchKit

/// One shelf on screen: its panel, the label above it, drops onto it, drags
/// out of it and its menu.
@MainActor
final class ShelfController: NSObject {
    let shelf: Shelf
    let panel: ShelfPanel
    /// Set when the shelf shows new files from a watched folder.
    var watchedFolderID: UUID?
    private let labelPanel = ActionLabelPanel()
    /// Files on their way in from other apps, for the tray and the expanded header.
    let delivery = Delivery()
    /// Made the first time a drop takes long enough to need it.
    private var trayPanel: ReceivingTrayPanel?
    private var shipments: [Shipment] = []
    private var pendingTrayHide: DispatchWorkItem?
    private unowned let library: ShelfLibrary
    private let preferences: ShelvesPreferences
    private let frameSpring = FrameSpring()
    private var observers: Set<AnyCancellable> = []
    private var draggedFiles: [ShelfFile] = []
    /// Where the drag was last seen, in shelf coordinates.
    private var dragPoint: CGPoint?
    private var hasReceivedDrop = false
    private(set) var isClosing = false

    init(shelf: Shelf, library: ShelfLibrary, preferences: ShelvesPreferences) {
        self.shelf = shelf
        self.library = library
        self.preferences = preferences
        panel = ShelfPanel(shelfSize: ShelfGeometry.compact)
        super.init()
        let dropView = ShelfDropView(frame: CGRect(origin: .zero, size: panel.frame.size))
        dropView.controller = self
        let hosting = ShelfHostingView(rootView: ShelfView(shelf: shelf, library: library, controller: self))
        hosting.frame = dropView.bounds
        hosting.autoresizingMask = [.width, .height]
        dropView.addSubview(hosting)
        panel.contentView = dropView
        panel.onKeyDown = { [weak self] event in self?.handleKey(event) ?? false }
        frameSpring.onFrame = { [weak self] frame in
            self?.panel.setFrame(frame, display: true)
            self?.layoutTray()
        }
        applySpaces()
        shelf.actions = preferences.instantActions
        // Settings change rarely; the shelf keeps its own copy of what they mean.
        preferences.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.applySpaces()
                    let actions = self.preferences.instantActions
                    if self.shelf.actions != actions { self.shelf.actions = actions }
                }
            }
        }.store(in: &observers)
    }

    private func applySpaces() {
        let behavior: NSWindow.CollectionBehavior = preferences.onAllSpaces
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.moveToActiveSpace, .fullScreenAuxiliary]
        if panel.collectionBehavior != behavior { panel.collectionBehavior = behavior }
    }

    private var shelfFrame: CGRect { ShelfGeometry.shelfFrame(inWindow: panel.frame) }

    // MARK: Showing

    /// Shows the shelf centred on a point, in screen coordinates, growing out of it.
    func show(centeredAt point: CGPoint) {
        let size = ShelfGeometry.compact
        show(shelfAt: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2), growingFrom: point)
    }

    /// Shows the shelf with its bottom-left corner at a point, kept on screen.
    func show(at origin: CGPoint) {
        let size = ShelfGeometry.compact
        show(shelfAt: origin, growingFrom: CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2))
    }

    private func show(shelfAt origin: CGPoint, growingFrom point: CGPoint) {
        let frame = clamped(CGRect(origin: origin, size: ShelfGeometry.compact))
        // The shelf grows out of the pointer, even when the screen edge pushed it aside.
        shelf.presenceAnchor = UnitPoint(x: min(max((point.x - frame.minX) / frame.width, 0), 1),
                                         y: min(max((frame.maxY - point.y) / frame.height, 0), 1))
        panel.setFrame(ShelfGeometry.windowFrame(forShelf: frame), display: true)
        panel.orderFrontRegardless()
        // One frame at rest first, so the spring has a starting point to leave from.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                withAnimation(ShelfMotion.appear) { self.shelf.isPresented = true }
            }
        }
    }

    func bringToFront() {
        panel.orderFrontRegardless()
    }

    func setExpanded(_ expanded: Bool) {
        guard shelf.isExpanded != expanded, !isClosing else { return }
        let size = expanded ? ShelfGeometry.expanded : ShelfGeometry.compact
        // Where the frame is heading, not where it is, so a quick reversal
        // keeps the shelf's top-left corner still.
        let current = shelfFrame
        let target = clamped(CGRect(x: current.minX, y: current.maxY - size.height, width: size.width, height: size.height))
        withAnimation(ShelfMotion.content) {
            shelf.isExpanded = expanded
            if !expanded { shelf.selection.removeAll() }
        }
        frameSpring.response = 0.42
        frameSpring.damping = 0.86
        frameSpring.animate(from: panel.frame, to: ShelfGeometry.windowFrame(forShelf: target), in: panel.contentView!)
    }

    /// Closes the shelf; it stays in Recent Shelves unless it's empty.
    func close(clearing: Bool = false) {
        guard !isClosing else { return }
        if clearing { shelf.remove(Set(shelf.files.map(\.id))) }
        leave()
    }

    /// Fades the shelf away, then hands it back to the library. `before` runs
    /// once it's off screen, so its files can go without being seen to.
    private func leave(before: @escaping @MainActor () -> Void = {}) {
        isClosing = true
        hideLabel()
        cancelIncoming()
        withAnimation(ShelfMotion.disappear) { shelf.isPresented = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + (ShelfMotion.reduced ? 0.16 : 0.24)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.frameSpring.stop()
                self.panel.orderOut(nil)
                self.labelPanel.orderOut(nil)
                self.trayPanel?.orderOut(nil)
                before()
                self.library.didClose(self)
            }
        }
    }

    // MARK: Moving and merging

    /// The shelf this one will merge into if let go now.
    private weak var mergeTarget: ShelfController?

    /// The pointer's last position and speed while moving, for the merge to carry on from.
    private var lastMove: (origin: CGPoint, time: CFTimeInterval)?
    private var moveVelocity = CGVector.zero

    func beginMove() {
        frameSpring.stop()
        lastMove = nil
        moveVelocity = .zero
        // Above any shelf it's carried over.
        panel.orderFrontRegardless()
    }

    /// Follows the pointer, keeping the shelf's top under the menu bar as a
    /// system window move would, and looks for a shelf to merge into.
    func move(to origin: CGPoint) {
        var origin = origin
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            origin.y = min(origin.y, screen.visibleFrame.maxY - panel.frame.height + ShelfGeometry.margin)
        }
        panel.setFrameOrigin(origin)
        trackVelocity(origin)
        // Files still on their way couldn't follow it into another shelf.
        let target = shelf.files.isEmpty || !shelf.incoming.isEmpty ? nil : library.shelf(at: mouse, excluding: self)
        guard target !== mergeTarget else { return }
        mergeTarget?.setMergeTarget(false)
        mergeTarget = target
        target?.setMergeTarget(true)
        withAnimation(ShelfMotion.hover) { shelf.isOverShelf = target != nil }
        if target != nil { library.tick() }
    }

    /// Smoothed, so one uneven event doesn't throw the shelf.
    private func trackVelocity(_ origin: CGPoint) {
        let now = CACurrentMediaTime()
        if let last = lastMove, now - last.time > 0.001 {
            let dt = now - last.time
            let instant = CGVector(dx: (origin.x - last.origin.x) / dt, dy: (origin.y - last.origin.y) / dt)
            let weight = min(dt / 0.05, 1)
            moveVelocity = CGVector(dx: moveVelocity.dx + (instant.dx - moveVelocity.dx) * weight,
                                    dy: moveVelocity.dy + (instant.dy - moveVelocity.dy) * weight)
        }
        lastMove = (origin, now)
    }

    func endMove() {
        guard let target = mergeTarget else { return }
        mergeTarget = nil
        target.setMergeTarget(false)
        guard !target.isClosing else {
            withAnimation(ShelfMotion.hover) { shelf.isOverShelf = false }
            return
        }
        merge(into: target)
    }

    /// Lights up under a shelf that's carried over it, with the label saying what letting go will do.
    private func setMergeTarget(_ on: Bool) {
        withAnimation(ShelfMotion.hover) { shelf.isDropTarget = on }
        if on { showLabel("Merge Shelves") } else { hideLabel() }
    }

    /// Pours this shelf's files into `target` and sinks into it.
    private func merge(into target: ShelfController) {
        let frame = shelfFrame
        target.receive(shelf.files, from: CGPoint(x: frame.midX, y: frame.midY))
        if shelf.isPinned { target.shelf.isPinned = true }
        if target.watchedFolderID == nil { target.watchedFolderID = watchedFolderID }
        let destination = target.shelfFrame
        shelf.presenceAnchor = .center
        frameSpring.response = 0.3
        frameSpring.damping = 1
        // A pointer that stopped a while before letting go has no speed left to carry.
        let held = lastMove.map { CACurrentMediaTime() - $0.time > 0.08 } ?? true
        frameSpring.animate(from: panel.frame,
                            to: ShelfGeometry.windowFrame(forShelf: CGRect(x: destination.midX - frame.width / 2,
                                                                          y: destination.midY - frame.height / 2,
                                                                          width: frame.width, height: frame.height)),
                            initialVelocity: held ? .zero : moveVelocity,
                            in: panel.contentView!)
        // Its files live on in the target, so it leaves nothing in Recent Shelves.
        leave { [weak self] in self?.shelf.files.removeAll() }
    }

    /// Takes another shelf's files, flying in from `point` on screen.
    private func receive(_ files: [ShelfFile], from point: CGPoint) {
        let frame = shelfFrame
        shelf.lastDrop = CGPoint(x: point.x - frame.minX, y: frame.maxY - point.y)
        let count = withAnimation(ShelfMotion.appear) { shelf.merge(files) }
        if count > 0 { shelf.landings += 1 }
        shelf.lastDrop = nil
        // Saved now, not after the usual pause: the merged shelf's own files
        // must be on record before the library sweeps the closed one's away.
        library.saveNow(shelf)
        library.tick()
    }

    /// Hides the panel at once, for the extension switching off.
    func dismiss() {
        frameSpring.stop()
        panel.orderOut(nil)
        labelPanel.orderOut(nil)
        trayPanel?.orderOut(nil)
    }

    /// Keeps a shelf frame on the screen it's mostly on.
    private func clamped(_ frame: CGRect) -> CGRect {
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return frame }
        var frame = frame
        frame.origin.x = min(max(frame.minX, visible.minX + 6), visible.maxX - frame.width - 6)
        frame.origin.y = min(max(frame.minY, visible.minY + 6), visible.maxY - frame.height - 6)
        return frame
    }

    func setHovered(_ hovered: Bool) {
        guard shelf.isHovered != hovered else { return }
        withAnimation(ShelfMotion.hover) { shelf.isHovered = hovered }
    }

    // MARK: The action label

    private func showLabel(_ title: String) {
        labelPanel.model.title = title
        if !labelPanel.isVisible || !labelPanel.model.isVisible {
            let frame = shelfFrame
            let size = ActionLabelPanel.size
            labelPanel.setFrame(CGRect(x: frame.midX - size.width / 2, y: frame.maxY + 2, width: size.width, height: size.height),
                                display: false)
            labelPanel.orderFrontRegardless()
        }
        labelPanel.model.isVisible = true
    }

    private func hideLabel() {
        labelPanel.model.isVisible = false
    }

    // MARK: Drops

    private var actions: [InstantAction] { shelf.actions }

    /// Called on every drag update, so it changes state only when something changed.
    func dragMoved(to point: CGPoint, in size: CGSize, isOwn: Bool) -> NSDragOperation {
        dragPoint = point
        if !shelf.isDragInside {
            withAnimation(ShelfMotion.hover) {
                shelf.isDragInside = true
                shelf.isDropTarget = !isOwn
            }
        }
        if shelf.showsActions {
            let index = ShelfGeometry.actionFrames(count: actions.count, in: size).firstIndex { $0.contains(point) }
            let action = index.map { actions[$0] }
            if shelf.hoveredAction != action {
                withAnimation(ShelfMotion.hover) { shelf.hoveredAction = action }
                if let action {
                    showLabel(action.title)
                    library.tick()
                } else {
                    hideLabel()
                }
            }
            return action == nil ? [] : .copy
        }
        if !actions.isEmpty, ShelfGeometry.boltFrame(in: size).insetBy(dx: -6, dy: -6).contains(point) {
            withAnimation(ShelfMotion.bloom) { shelf.showsActions = true }
            library.tick()
            return []
        }
        return isOwn ? [] : .copy
    }

    func dragLeft() {
        guard shelf.isDragInside || shelf.showsActions else { return }
        hideLabel()
        withAnimation(ShelfMotion.bloom) {
            shelf.isDragInside = false
            shelf.isDropTarget = false
            shelf.showsActions = false
            shelf.hoveredAction = nil
        }
    }

    func drop(_ info: NSDraggingInfo, at point: CGPoint, isOwn: Bool) -> Bool {
        let pasteboard = info.draggingPasteboard
        hasReceivedDrop = true
        if shelf.showsActions {
            guard let action = shelf.hoveredAction else { return false }
            let wasEmpty = shelf.files.isEmpty
            PasteboardReader.read(pasteboard, into: library.filesDirectory, links: preferences.activeLinkRules) { [weak self] urls, _ in
                guard let self else { return }
                let done = action.perform(with: urls, sendToNotchShelf: self.library.sendToNotchShelf)
                if done && wasEmpty && self.preferences.closeAfterAction && !self.shelf.isPinned && self.shelf.files.isEmpty {
                    self.close()
                }
            }
            return true
        }
        guard !isOwn else { return false }
        let promises = PasteboardReader.promises(in: info)
        let files = promises.isEmpty ? PasteboardReader.files(in: info) : []
        if !promises.isEmpty {
            receive(promises, from: pasteboard, droppedAt: point)
        } else if !files.isEmpty {
            receive(files, droppedAt: point)
        } else if pasteboard.availableType(from: [.png, .tiff]) == nil, let link = PasteboardReader.webLink(on: pasteboard),
                  let rule = LinkResolver.rule(for: link.url, in: preferences.activeLinkRules) {
            receive(link, rule: rule, preview: PasteboardReader.preview(in: info), droppedAt: point)
        } else {
            shelf.lastDrop = point
            add(from: pasteboard)
        }
        return true
    }

    /// The drag that shook this shelf out let go. Dropped anywhere but here,
    /// the shelf was a mistake, so it goes away again.
    func triggeringDragEnded() {
        // The drop can reach the shelf just after the mouse comes up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.hasReceivedDrop, !self.shelf.isPinned, self.shelf.files.isEmpty else { return }
                self.close()
            }
        }
    }

    func add(from pasteboard: NSPasteboard) {
        PasteboardReader.read(pasteboard, into: library.filesDirectory, links: preferences.activeLinkRules) { [weak self] urls, owned in
            self?.add(urls, owned: owned)
        }
    }

    /// Waits for the files' thumbnails, so they land as themselves rather than
    /// as icons that change a moment later. The files are read off the main
    /// thread: on a network volume each one is a round trip.
    func add(_ urls: [URL], owned: Set<URL> = [], then done: @escaping @MainActor () -> Void = {}) {
        Task {
            let files = await ShelfFile.load(urls, owned: owned)
            await Thumbnails.prepare(files.map(\.path))
            insert(files, tried: urls.count)
            done()
        }
    }

    private func insert(_ files: [ShelfFile], tried: Int) {
        let count = withAnimation(ShelfMotion.appear) {
            shelf.merge(files)
        }
        if count > 0 {
            shelf.landings += 1
            library.tick()
        } else if tried > 0 {
            NSSound.beep()
        }
        shelf.lastDrop = nil
    }

    // MARK: Files on their way

    /// How long dropped files can take and still land as themselves. Slower
    /// ones (promised files still being written, files on a network volume)
    /// are stood in for by what was dragged.
    private static let landingGrace: TimeInterval = 0.12
    /// The tray only comes out for promised files still on their way after this.
    private static let trayDelay: TimeInterval = 0.45
    /// How long a stand-in waits for its file's thumbnail before landing as the icon.
    private static let thumbnailLimit: TimeInterval = 3

    /// One drop's files, from the drop until the last one lands, fails or is
    /// let go.
    private final class Shipment {
        let point: CGPoint
        /// Promised files are written into the shelf's storage, so they're its
        /// own and show in the tray; dropped files from Finder are neither.
        let isPromised: Bool
        var incoming: [IncomingFile] = []
        var folders: [String] = []
        /// Ready within the grace, before there was a stand-in to land on.
        var early: [(id: UUID, file: ShelfFile)] = []
        var failedEarly: Set<UUID> = []
        /// The files have been put on the shelf, as themselves or as stand-ins.
        var isPlaced = false
        var isCancelled = false
        var settled = 0

        init(point: CGPoint, isPromised: Bool) {
            self.point = point
            self.isPromised = isPromised
        }

        var isFinished: Bool { settled >= incoming.count }
    }

    private func receive(_ promises: [(receiver: NSFilePromiseReceiver, preview: NSImage?)],
                         from pasteboard: NSPasteboard, droppedAt point: CGPoint) {
        let sender = NSWorkspace.shared.frontmostApplication
        beginDelivery(from: sender == .current ? nil : sender?.localizedName)
        let shipment = Shipment(point: point, isPromised: true)
        shipments.append(shipment)
        // Browsers cancel promises they can't keep, but carry the image itself
        // too. With one item dragged, that image is the promised file's. It's
        // read now: once the drag is over, the browser no longer serves it.
        let ownImage = promises.count == 1 && pasteboard.pasteboardItems?.count == 1
            ? PasteboardReader.imageData(on: pasteboard) : nil
        for (receiver, preview) in promises {
            let types = receiver.fileTypes.map { UTType($0) }
            let standIns = (types.isEmpty ? [nil] : types).map { type in
                IncomingFile(kind: FileKind(type: type),
                             preview: preview ?? NSWorkspace.shared.icon(for: type ?? .data))
            }
            shipment.incoming += standIns
            // A promise's files come back in the order they were promised.
            var slots = standIns.map(\.id)
            let ownImage = standIns.count == 1 ? ownImage : nil
            let directory = library.filesDirectory
            let folder = PasteboardReader.receive(receiver, into: directory) { [weak self] url in
                let id = slots.isEmpty ? nil : slots.removeFirst()
                guard url == nil, let ownImage else {
                    self?.prepare(url, as: id, in: shipment)
                    return
                }
                Task.detached(priority: .userInitiated) {
                    let url = PasteboardReader.imageFile(from: ownImage, into: directory)
                    await self?.prepare(url, as: id, in: shipment)
                }
            }
            shipment.folders.append(folder.lastPathComponent)
        }
        library.receivingFolders.formUnion(shipment.folders)
        delivery.total += shipment.incoming.count
        start(shipment)
        showTrayIfSlow(shipment)
    }

    /// A link a rule turns into a file. What was dragged stands in while the
    /// file downloads; the link itself lands when there's no file to be had.
    private func receive(_ link: (url: URL, title: String?), rule: LinkRule, preview: NSImage?, droppedAt point: CGPoint) {
        let host = link.url.host()
        beginDelivery(from: host?.hasPrefix("www.") == true ? String(host!.dropFirst(4)) : host)
        let shipment = Shipment(point: point, isPromised: true)
        shipments.append(shipment)
        let type = rule.source == .previewImage ? UTType.image : UTType(filenameExtension: link.url.pathExtension) ?? .data
        let standIn = IncomingFile(kind: FileKind(type: type), preview: preview ?? NSWorkspace.shared.icon(for: type))
        shipment.incoming.append(standIn)
        let folder = PasteboardReader.freshFolder(in: library.filesDirectory)
        shipment.folders.append(folder.lastPathComponent)
        library.receivingFolders.formUnion(shipment.folders)
        delivery.total += 1
        start(shipment)
        showTrayIfSlow(shipment)
        Task { [weak self] in
            let file = try? await LinkResolver.download(link.url, with: rule, into: folder)
            self?.prepare(file ?? PasteboardReader.linkFile(for: link.url, title: link.title, in: folder), as: standIn.id, in: shipment)
        }
    }

    /// A new shipment is on its way from `source`: the tray counts it with
    /// those still coming, or starts over.
    private func beginDelivery(from source: String?) {
        if shipments.isEmpty && !isTrayShown || delivery.phase != .receiving {
            delivery.reset()
        }
        pendingTrayHide?.cancel()
        delivery.source = source
    }

    private func showTrayIfSlow(_ shipment: Shipment) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.trayDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.shipments.contains(where: { $0 === shipment }) else { return }
                self.showTray()
            }
        }
    }

    /// Files dropped from Finder and the like. They're here already, but on a
    /// network volume reading them and making their thumbnails takes a while,
    /// so they get stand-ins just like promised files.
    private func receive(_ dropped: [(url: URL, preview: NSImage?)], droppedAt point: CGPoint) {
        let shipment = Shipment(point: point, isPromised: false)
        shipments.append(shipment)
        for (url, preview) in dropped {
            let type = UTType(filenameExtension: url.pathExtension)
            let standIn = IncomingFile(kind: FileKind(type: type),
                                       preview: preview ?? NSWorkspace.shared.icon(for: type ?? .data))
            shipment.incoming.append(standIn)
            prepare(url, as: standIn.id, in: shipment)
        }
        start(shipment)
    }

    private func start(_ shipment: Shipment) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.landingGrace) { [weak self] in
            MainActor.assumeIsolated { self?.placeStandIns(for: shipment) }
        }
    }

    /// Reads a file that's here and makes its thumbnail, so it lands as
    /// itself; nil when the sender couldn't make it.
    private func prepare(_ url: URL?, as id: UUID?, in shipment: Shipment) {
        Task {
            guard let url else { return settle(nil, as: id, in: shipment) }
            let file = await ShelfFile.load(url, isOwned: shipment.isPromised)
            if let file {
                await Thumbnails.prepare([file.path], limit: Self.thumbnailLimit)
            } else if shipment.isPromised {
                try? FileManager.default.removeItem(at: url)
            }
            settle(file, as: id, in: shipment)
        }
    }

    /// A file is ready to land, or nil when it never came or is gone.
    /// `id` is its stand-in's; nil for a file beyond what was promised.
    private func settle(_ file: ShelfFile?, as id: UUID?, in shipment: Shipment) {
        if id != nil { shipment.settled += 1 }
        if shipment.isCancelled || isClosing {
            if let file, shipment.isPromised { try? FileManager.default.removeItem(at: file.url) }
            return
        }
        guard let id else {
            if let file { insert([file], tried: 1) }
            return
        }
        guard shipment.isPlaced else {
            if let file { shipment.early.append((id, file)) } else { shipment.failedEarly.insert(id) }
            // All ready within the grace: they land as themselves.
            if shipment.isFinished { landTogether(shipment) }
            return
        }
        if let file { land(file, as: id, in: shipment) } else { fail(id, in: shipment) }
        finish(shipment)
    }

    private func landTogether(_ shipment: Shipment) {
        shipment.isPlaced = true
        let files = shipment.early.map(\.file)
        if shipment.isPromised {
            delivery.received += files.count
            delivery.failed += shipment.failedEarly.count
        }
        shelf.lastDrop = shipment.point
        insert(files, tried: shipment.incoming.count)
        finish(shipment)
    }

    /// The drop is taking a while: what was dragged lands now, soft and
    /// breathing, and turns into each file as it's ready.
    private func placeStandIns(for shipment: Shipment) {
        guard !shipment.isPlaced, !shipment.isCancelled, !isClosing else { return }
        shipment.isPlaced = true
        if shipment.isPromised { delivery.failed += shipment.failedEarly.count }
        let standIns = shipment.incoming.filter { !shipment.failedEarly.contains($0.id) }
        shelf.lastDrop = shipment.point
        withAnimation(ShelfMotion.appear) { shelf.incoming += standIns }
        shelf.landings += 1
        library.tick()
        // Kept until the stand-ins have been drawn, so they fly in from the drop.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.shelf.lastDrop = nil }
        }
        let early = shipment.early
        shipment.early = []
        for (id, file) in early { land(file, as: id, in: shipment) }
        finish(shipment)
    }

    /// Turns a stand-in into its file, whose thumbnail is ready, so it comes
    /// into focus as itself.
    private func land(_ file: ShelfFile, as id: UUID, in shipment: Shipment) {
        var file = file
        file.id = id
        let landed = withAnimation(ShelfMotion.arrive) { shelf.land(file) }
        if landed && shipment.isPromised { delivery.received += 1 }
    }

    /// A stand-in whose file never came shakes, then goes.
    private func fail(_ id: UUID, in shipment: Shipment) {
        if shipment.isPromised { delivery.failed += 1 }
        guard let index = shelf.incoming.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(ShelfMotion.hover) { shelf.incoming[index].failed = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                withAnimation(ShelfMotion.content) { self.shelf.incoming.removeAll { $0.id == id } }
            }
        }
    }

    private func finish(_ shipment: Shipment) {
        guard shipment.isPlaced, shipment.isFinished, let index = shipments.firstIndex(where: { $0 === shipment }) else { return }
        shipments.remove(at: index)
        library.receivingFolders.subtract(shipment.folders)
        guard shipments.isEmpty else { return }
        if delivery.failed > 0 && delivery.received == 0 && isTrayShown { NSSound.beep() }
        withAnimation(ShelfMotion.content) { delivery.phase = delivery.failed > 0 ? .failed : .done }
        // Long enough to read how it went, then the tray tucks back under the shelf.
        hideTray(after: isTrayShown ? (delivery.failed > 0 ? 1.8 : 0.9) : 0)
    }

    /// Stops waiting for everything on its way. Files that come in later are thrown away.
    func cancelIncoming() {
        guard !shipments.isEmpty || !shelf.incoming.isEmpty else { return }
        for shipment in shipments {
            shipment.isCancelled = true
            library.receivingFolders.subtract(shipment.folders)
        }
        shipments.removeAll()
        withAnimation(ShelfMotion.content) { shelf.incoming.removeAll() }
        hideTray()
    }

    // MARK: The tray

    private var isTrayShown: Bool { trayPanel?.model.isVisible == true }

    private func showTray() {
        pendingTrayHide?.cancel()
        pendingTrayHide = nil
        guard !isClosing, panel.isVisible else { return }
        let tray = trayPanel ?? ReceivingTrayPanel(delivery: delivery) { [weak self] in self?.cancelIncoming() }
        trayPanel = tray
        if tray.parent == nil {
            tray.collectionBehavior = panel.collectionBehavior
            // Below the shelf, unless that's off the bottom of the screen.
            let visible = (panel.screen ?? NSScreen.main)?.visibleFrame
            let below = visible.map { shelfFrame.minY - ReceivingTrayPanel.size.height >= $0.minY } ?? true
            tray.model.edge = below ? .bottom : .top
            layoutTray(force: true)
            panel.addChildWindow(tray, ordered: .above)
        }
        // One frame at rest under the shelf first, for the spring to leave from.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, tray.parent != nil, self.pendingTrayHide == nil else { return }
                withAnimation(ShelfMotion.tray) { tray.model.isVisible = true }
            }
        }
    }

    private func hideTray(after delay: TimeInterval = 0) {
        pendingTrayHide?.cancel()
        guard let tray = trayPanel, tray.parent != nil else {
            pendingTrayHide = nil
            if shipments.isEmpty { delivery.reset() }
            return
        }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                withAnimation(ShelfMotion.disappear) { tray.model.isVisible = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, !tray.model.isVisible else { return }
                        self.panel.removeChildWindow(tray)
                        tray.orderOut(nil)
                        if self.shipments.isEmpty { self.delivery.reset() }
                    }
                }
            }
        }
        pendingTrayHide = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Hangs the tray from the middle of the shelf's edge, as the shelf moves or resizes.
    private func layoutTray(force: Bool = false) {
        guard let tray = trayPanel, force || tray.parent != nil else { return }
        let frame = shelfFrame
        let size = ReceivingTrayPanel.size
        let y = tray.model.edge == .bottom ? frame.minY - size.height : frame.maxY
        tray.setFrame(CGRect(x: frame.midX - size.width / 2, y: y, width: size.width, height: size.height), display: false)
    }

    // MARK: Clicks

    func doubleClick(_ files: [ShelfFile]) {
        let urls = files.map(\.url)
        switch preferences.doubleClick {
        case .open: FileActions.open(urls)
        case .reveal: FileActions.reveal(urls)
        case .quickLook: QuickLook.shared.show(urls, from: panel)
        }
    }

    func select(_ file: ShelfFile, extending: Bool) {
        withAnimation(ShelfMotion.hover) {
            if extending {
                if shelf.selection.contains(file.id) { shelf.selection.remove(file.id) } else { shelf.selection.insert(file.id) }
            } else {
                shelf.selection = shelf.selection == [file.id] ? [] : [file.id]
            }
        }
        QuickLook.shared.follow(shelf.targets.map(\.url))
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (event.keyCode, modifiers) {
        case (49, []): // space
            QuickLook.shared.toggle(shelf.targets.map(\.url), from: panel)
        case (53, []): // escape
            if shelf.isExpanded { setExpanded(false) } else { close() }
        case (51, []), (117, []): // delete
            guard !shelf.selection.isEmpty else { return false }
            remove(Set(shelf.selection))
        case (0, [.command]): // ⌘A
            withAnimation(ShelfMotion.hover) { shelf.selection = Set(shelf.files.map(\.id)) }
        case (8, [.command]): // ⌘C
            FileActions.copyToPasteboard(shelf.targets.map(\.url))
        case (9, [.command]): // ⌘V
            add(from: .general)
        case (13, [.command]): // ⌘W
            close()
        default:
            return false
        }
        return true
    }

    private func remove(_ ids: Set<UUID>) {
        withAnimation(ShelfMotion.content) { shelf.remove(ids) }
    }

    /// Catches up with files deleted or moved elsewhere, closing the shelf if that emptied it.
    func refreshFiles() {
        guard !isClosing else { return }
        let hadFiles = !shelf.files.isEmpty
        withAnimation(ShelfMotion.content) { shelf.refresh() }
        if hadFiles, shelf.isEmpty, !shelf.isPinned { close() }
    }

    // MARK: Menu

    func menu(for files: [ShelfFile]) -> NSMenu {
        let menu = NSMenu()
        let urls = files.map(\.url)
        if !files.isEmpty {
            let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            openWith.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil)
            let apps = NSMenu()
            for (index, app) in FileActions.applications(toOpen: urls).prefix(16).enumerated() {
                let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
                let item = ClosureMenuItem(index == 0 ? "\(name) (default)" : name) { FileActions.open(urls, with: app) }
                let icon = NSWorkspace.shared.icon(forFile: app.path)
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
                apps.addItem(item)
            }
            openWith.submenu = apps
            openWith.isEnabled = !apps.items.isEmpty
            menu.addItem(openWith)
            menu.addItem(ClosureMenuItem("Show in Finder", symbol: "folder") { FileActions.reveal(urls) })
            menu.addItem(ClosureMenuItem("Quick Look", symbol: "eye") { [weak self] in
                QuickLook.shared.show(urls, from: self?.panel)
            })
            menu.addItem(.separator())
            for action in [InstantAction.airDrop, .mail, .messages] where action.isAvailable {
                let item = ClosureMenuItem(action.title) { [weak self] in
                    _ = action.perform(with: urls, sendToNotchShelf: self?.library.sendToNotchShelf ?? { _ in })
                }
                let icon = action.icon.copy() as? NSImage
                icon?.size = NSSize(width: 16, height: 16)
                item.image = icon
                menu.addItem(item)
            }
            let share = NSSharingServicePicker(items: urls).standardShareMenuItem
            share.title = "More"
            menu.addItem(share)
            menu.addItem(.separator())
            // What other extensions make from the files lands back on this shelf.
            let request = ShelfFileRequest(files: urls) { [weak self] made in self?.add(made) }
            let shared = library.sharedActions(request)
            if !shared.isEmpty {
                NotchContextMenuView.menu(shared).items.forEach { item in
                    item.menu?.removeItem(item)
                    menu.addItem(item)
                }
                menu.addItem(.separator())
            }
            let copyTitle = files.count == 1 ? "Copy “\(files[0].name)”" : "Copy \(files.count) Items"
            menu.addItem(ClosureMenuItem(copyTitle, symbol: "doc.on.doc") { FileActions.copyToPasteboard(urls) })
            menu.addItem(ClosureMenuItem(files.count == 1 ? "Copy Path" : "Copy Paths", symbol: "link") {
                FileActions.copyPaths(urls)
            })
            menu.addItem(ClosureMenuItem("Copy to…", symbol: "plus.square.on.square") { [weak self] in
                self?.transfer(files, move: false)
            })
            menu.addItem(ClosureMenuItem("Move to…", symbol: "folder.badge.plus") { [weak self] in
                self?.transfer(files, move: true)
            })
            menu.addItem(ClosureMenuItem("Send to Tray", symbol: "rectangle.topthird.inset.filled") { [weak self] in
                self?.library.sendToNotchShelf(urls)
            })
            if files.count < shelf.files.count {
                menu.addItem(.separator())
                let title = files.count == 1 ? "Remove from Shelf" : "Remove \(files.count) Items"
                menu.addItem(ClosureMenuItem(title, symbol: "minus.circle") { [weak self] in
                    self?.remove(Set(files.map(\.id)))
                })
            }
            menu.addItem(.separator())
        }
        let clipboard = ClosureMenuItem("Add from Clipboard", symbol: "doc.on.clipboard") { [weak self] in
            self?.add(from: .general)
        }
        clipboard.isEnabled = PasteboardReader.canRead(.general)
        menu.addItem(clipboard)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Rename Shelf…", symbol: "pencil") { [weak self] in self?.rename() })
        let pin = ClosureMenuItem("Pin Shelf", symbol: "pin") { [weak self] in self?.shelf.isPinned.toggle() }
        pin.state = shelf.isPinned ? .on : .off
        menu.addItem(pin)
        if !shelf.files.isEmpty {
            menu.addItem(ClosureMenuItem(shelf.isExpanded ? "Collapse Shelf" : "Expand Shelf",
                                         symbol: shelf.isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") { [weak self] in
                guard let self else { return }
                setExpanded(!shelf.isExpanded)
            })
            menu.addItem(ClosureMenuItem("Clear Shelf", symbol: "trash") { [weak self] in
                self?.close(clearing: true)
            })
        }
        menu.addItem(ClosureMenuItem("Close Shelf", symbol: "xmark") { [weak self] in self?.close() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Shelves Settings…", symbol: "gearshape") { [weak self] in
            self?.library.openSettings()
        })
        return menu
    }

    private func transfer(_ files: [ShelfFile], move: Bool) {
        guard let folder = FileActions.chooseFolder(prompt: move ? "Move" : "Copy") else { return }
        let moved = FileActions.transfer(files.map(\.url), to: folder, move: move)
        guard move else { return }
        // The shelf follows its files to their new home.
        for (index, file) in shelf.files.enumerated() {
            if let destination = moved[file.url], var updated = ShelfFile(url: destination, isOwned: false) {
                updated.id = file.id
                shelf.files[index] = updated
            }
        }
    }

    private func rename() {
        let alert = NSAlert()
        alert.messageText = "Rename Shelf"
        alert.informativeText = "Leave it empty to name the shelf after its files."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = shelf.customName ?? ""
        field.placeholderString = ShelfSummary.name(for: shelf.files)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        shelf.customName = name.isEmpty ? nil : name
    }

    // MARK: Dragging out

    func beginDrag(_ files: [ShelfFile], event: NSEvent, from view: NSView, image: NSImage?) {
        guard !files.isEmpty else { return }
        let side: CGFloat = 56
        let origin = view.convert(event.locationInWindow, from: nil)
        let items = files.enumerated().map { index, file -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: file.url as NSURL)
            let offset = CGFloat(min(index, 4)) * 4
            item.setDraggingFrame(NSRect(x: origin.x - side / 2 + offset, y: origin.y - side / 2 - offset, width: side, height: side),
                                  contents: index == 0 ? (image ?? Thumbnails.image(for: file.path)) : Thumbnails.image(for: file.path))
            return item
        }
        draggedFiles = files
        let session = view.beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }
}

extension ShelfController: NSDraggingSource {
    /// Finder moves files when the source allows it, which is what a shelf
    /// is for; apps that only take copies still accept the drop.
    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .generic] : [.copy, .generic]
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        MainActor.assumeIsolated { dragEnded(operation: operation) }
    }

    private func dragEnded(operation: NSDragOperation) {
        let dragged = draggedFiles
        draggedFiles = []
        guard operation != [] else { return }
        let finish: @MainActor () -> Void = { [weak self] in
            guard let self, !isClosing else { return }
            let gone = Set(dragged.filter { !FileManager.default.fileExists(atPath: $0.path) }.map(\.id))
            if !gone.isEmpty { remove(gone) }
            guard !shelf.isPinned else { return }
            switch preferences.dragOut {
            case .always: close()
            case .whenMoved: if !gone.isEmpty && shelf.files.isEmpty { close() }
            case .never: break
            }
        }
        // Finder can finish a move after the session ends.
        if operation.contains(.move) || operation.contains(.delete) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { MainActor.assumeIsolated { finish() } }
        } else {
            finish()
        }
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, symbol: String? = nil, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() {
        MainActor.assumeIsolated { handler() }
    }
}
