import AppKit
import OSLog
import XNotchKit

/// Owns the menu bar side: one divider, one status item per folder.
///
/// Left to right: `[filed items][divider][everything else][folders][system]`.
/// The divider is 10,000 pt long, so macOS can't fit it and parks it off the
/// bar together with everything to its left.
///
/// The bar's order is a list. A Command-drag inserts an item beside the one it
/// is dropped on, and a status item's saved "preferred position" (distance
/// from the right edge of the screen) only decides where it is inserted when
/// it is created. So every move here drops beside something on screen, and
/// the divider is put in place by creating it with a position that falls
/// inside the leftmost icon that should stay visible: it lands just left of
/// that icon. That works however crowded the bar is, notch included, where
/// the divider itself never fits on screen.
@MainActor
final class BarController: NSObject {
    let store: FolderStore
    let feedback: ExtensionFeedback
    var openSettings: () -> Void = {}

    let mover = ItemMover()
    private let log = Logger(subsystem: "dev.levi.XNotch.extension", category: "menubarfolders")
    private var divider: NSStatusItem?
    private var dividerGeneration = 0
    private var folderItems: [UUID: NSStatusItem] = [:]
    private var dragWatcher: DragIntoFolderWatcher?
    private(set) lazy var drawer: DrawerController = {
        let drawer = DrawerController(store: store)
        drawer.onOpen = { [weak self] item, folder in self?.open(item, from: folder) }
        drawer.onAdd = { [weak self] folder, anchor in self?.showAddMenu(for: folder, at: anchor) }
        drawer.onReorder = { [weak self] folder, from, to in
            self?.store.moveItem(in: folder, from: IndexSet(integer: from), to: to)
            self?.refreshIcon(for: folder)
        }
        drawer.onDragOut = { [weak self] item, point in self?.takeOut(item, droppedAt: point) }
        return drawer
    }()

    /// The item out of its folder right now, waiting for its menu to close.
    private var revealed: (item: BarItem, folder: UUID)?
    private var restashTask: Task<Void, Never>?

    /// Everything that moves icons runs one after another: the mover drives
    /// a single pointer, and two jobs at once would undo each other.
    private var lastJob: Task<Void, Never>?
    private var stopped = false

    /// Watching the bar for icons that turn up on the wrong side of the divider.
    private var barPoll: DispatchSourceTimer?
    private var barWindows: Set<CGWindowID> = []
    private var pendingCheck: DispatchWorkItem?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    /// Tries to put each icon in place, per window, so one that won't move
    /// isn't dragged forever.
    private var attempts: [String: (window: CGWindowID, count: Int)] = [:]

    private static let collapsedLength: CGFloat = 10_000
    private static let layoutVersion = 2

    init(store: FolderStore, feedback: ExtensionFeedback) {
        self.store = store
        self.feedback = feedback
    }

    // MARK: Lifecycle

    func start(defaults: UserDefaults) {
        if defaults.integer(forKey: "layoutVersion") < Self.layoutVersion {
            // Folders used to sit at the left end, where the notch hides them.
            for folder in store.folders {
                UserDefaults.standard.removeObject(forKey: Self.positionKey(autosaveName(for: folder)))
            }
            defaults.set(Self.layoutVersion, forKey: "layoutVersion")
        }
        for name in ["MenuBarFolders.Divider", "MenuBarFolders.Divider.0", "MenuBarFolders.Divider.1"] {
            UserDefaults.standard.removeObject(forKey: Self.positionKey(name))
        }
        seedFolderPositions()
        for folder in store.folders { makeStatusItem(for: folder) }
        dragWatcher = DragIntoFolderWatcher(controller: self)

        Task {
            // Let the folders land before measuring the bar.
            try? await Task.sleep(for: .milliseconds(300))
            await waitForAccessibility()
            guard !stopped else { return }
            // Filed icons are all in view at launch, with no divider yet; the
            // first check puts one in and hides them. At login most apps start
            // after XNotch and add their icons over the next minute, each
            // wherever it likes, which the watch catches.
            watchBar()
            scheduleCheck(after: 0)
        }
    }

    /// Runs `job` once every job before it has finished.
    private func enqueue(_ job: @escaping @MainActor () async -> Void) {
        let previous = lastJob
        lastJob = Task { [weak self] in
            await previous?.value
            guard let self, !self.stopped else { return }
            await job()
        }
    }

    // MARK: Permission

    /// Without Accessibility, macOS silently drops every event the mover
    /// posts: nothing moves and nothing is clicked. Nothing touches the bar
    /// until it's granted.
    var canMoveItems: Bool { AXIsProcessTrusted() }
    /// Asks for Accessibility with XNotch's guide. Set by the extension.
    var requestAccessibility: (() -> Void)?

    /// Whether moving works; when it doesn't, a click on a folder asks for it.
    @discardableResult
    func ensureAccessibility() -> Bool {
        if canMoveItems { return true }
        DebugLog.write("blocked: Accessibility not granted")
        requestAccessibility?()
        return false
    }

    /// At launch nothing is asked: XNotch's permission checkup does that.
    private func waitForAccessibility() async {
        guard !canMoveItems else { return }
        DebugLog.write("waiting for Accessibility")
        while !canMoveItems {
            try? await Task.sleep(for: .seconds(2))
        }
        DebugLog.write("Accessibility granted")
    }

    func stop() {
        stopped = true
        barPoll?.cancel()
        barPoll = nil
        pendingCheck?.cancel()
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
        restashTask?.cancel()
        dragWatcher?.stop()
        dragWatcher = nil
        drawer.close(animated: false)
        // Everything filed comes back into view when the divider goes.
        if let divider { NSStatusBar.system.removeStatusItem(divider) }
        folderItems.values.forEach(remove)
        folderItems = [:]
        divider = nil
    }

    // MARK: Placement

    private static func positionKey(_ autosaveName: String) -> String {
        "NSStatusItem Preferred Position \(autosaveName)"
    }

    private var screenWidth: CGFloat { CGDisplayBounds(CGMainDisplayID()).maxX }

    /// Small positions put the folders at the right end, beside Control
    /// Center, where a crowded bar never pushes them behind the notch. A
    /// folder the user has Command-dragged elsewhere keeps its place.
    private func seedFolderPositions() {
        let count = store.folders.count
        for (index, folder) in store.folders.enumerated() {
            let key = Self.positionKey(autosaveName(for: folder))
            if UserDefaults.standard.object(forKey: key) == nil {
                UserDefaults.standard.set(Double(count - index), forKey: key)
            }
        }
    }

    /// Removing a status item also forgets where it was. Keep the place so it
    /// comes back there next launch.
    private func remove(_ item: NSStatusItem) {
        let key = Self.positionKey(item.autosaveName)
        let saved = UserDefaults.standard.object(forKey: key)
        NSStatusBar.system.removeStatusItem(item)
        if let saved { UserDefaults.standard.set(saved, forKey: key) }
    }

    private func autosaveName(for folder: BarFolder) -> String { "MenuBarFolders.\(folder.id.uuidString)" }

    private func window(for folder: UUID) -> CGWindowID? {
        folderItems[folder]?.button?.window.map { CGWindowID($0.windowNumber) }
    }

    /// Folder icons on the bar, in global display coordinates.
    var folderFrames: [(id: UUID, frame: CGRect)] {
        folderItems.compactMap { id, item in
            guard let window = item.button?.window,
                  let bounds = WindowServer.bounds(of: CGWindowID(window.windowNumber)), bounds.minX > 0 else { return nil }
            return (id, bounds)
        }
    }

    /// The leftmost icon that should stay in view: unfiled and on the bar.
    /// The folders stand in when everything else is filed.
    private func boundary(excluding excluded: Set<String> = []) -> (window: CGWindowID, bounds: CGRect)? {
        shown(excluding: excluded).min { $0.bounds.minX < $1.bounds.minX }
    }

    /// Everything on the bar that should stay in view: loose icons and the folders.
    private func shown(excluding excluded: Set<String> = []) -> [(window: CGWindowID, bounds: CGRect)] {
        let filed = store.filedIDs.union(excluded)
        let loose = BarItem.current().filter { !filed.contains($0.id) && $0.bounds.minX > 0 && $0.bounds.width > 0 }
            .map { (window: $0.windowID, bounds: $0.bounds) }
        let folders = folderFrames.compactMap { entry in window(for: entry.id).map { (window: $0, bounds: entry.frame) } }
        return loose + folders
    }

    /// A fresh divider, 1 pt and invisible, right before the boundary icon:
    /// the line between what hides and what shows, not yet stretched.
    ///
    /// It's made where it belongs, from a saved position worked out from the
    /// icon's place, so nothing on the bar moves. Saved positions only place
    /// an item when it's made, and other apps' go stale, so where it lands is
    /// checked; a miss is Command-dragged into place, twice at most.
    private func stageDivider(excluding excluded: Set<String> = []) async -> (item: NSStatusItem, bar: BarItem)? {
        await waitForBarToSettle()
        guard var target = boundary(excluding: excluded) else { return nil }
        dividerGeneration += 1
        let name = "MenuBarFolders.Divider.\(dividerGeneration % 2)"
        // Distance from the screen's right edge to the item's right edge.
        UserDefaults.standard.set(Double(screenWidth - target.bounds.minX), forKey: Self.positionKey(name))
        // A status item made at zero length can stay without a real window.
        let fresh = NSStatusBar.system.statusItem(withLength: 1)
        fresh.autosaveName = name
        fresh.isVisible = true
        fresh.button?.image = nil
        // macOS takes a few hundred milliseconds to give a new item its place.
        // Until then its window is parked off the bar, and a drag would lift
        // it without ever dropping it in.
        _ = await waitForPlacement(of: fresh)
        guard let window = fresh.button?.window, let item = BarItem.own(CGWindowID(window.windowNumber)) else {
            NSStatusBar.system.removeStatusItem(fresh)
            return nil
        }
        // Stretched, it hides everything left of it, so it may only be
        // stretched with every icon that should show to its right. Centres
        // are compared: the 1 pt item's window is wider than the item and
        // sits a few points shy of the next icon. Filed icons may be on
        // either side; the ones in view are dropped left of it next.
        func isSeated() -> Bool {
            guard let mine = WindowServer.bounds(of: item.windowID), mine.minX > 0, Self.isOnBarRow(mine) else { return false }
            return shown(excluding: excluded).allSatisfy { $0.bounds.midX > mine.midX }
        }
        var seated = isSeated()
        DebugLog.write("divider made beside \(target.window): in place=\(seated) at \(WindowServer.bounds(of: item.windowID)?.minX ?? -1)")
        var attempt = 0
        while !seated && attempt < 2 {
            attempt += 1
            let drop = dividerDrop(before: target.window)
            let moved = await mover.move(item, to: drop.side, of: drop.window)
            await waitForBarToSettle()
            seated = isSeated()
            DebugLog.write("divider drag #\(attempt) beside \(target.window): moved=\(moved) seated=\(seated) at \(WindowServer.bounds(of: item.windowID)?.minX ?? -1) shown from \(shown(excluding: excluded).map(\.bounds.minX).min() ?? -1)")
            if !seated, let next = boundary(excluding: excluded) { target = next }
        }
        guard seated else {
            NSStatusBar.system.removeStatusItem(fresh)
            return nil
        }
        return (fresh, item)
    }

    /// Waits up to 1.5 s for `item` to rest on the bar.
    private func waitForPlacement(of item: NSStatusItem) async -> Bool {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < .milliseconds(1500) {
            try? await Task.sleep(for: .milliseconds(30))
            if let window = item.button?.window, let bounds = WindowServer.bounds(of: CGWindowID(window.windowNumber)),
               bounds.width > 0, bounds.minX > 0, Self.isOnBarRow(bounds) {
                return true
            }
        }
        DebugLog.write("divider not placed after 1.5 s: visible=\(item.isVisible)")
        return false
    }

    /// Where to drop the divider so it lands right before `target`. A drop
    /// on one of XNotch's own icons never ends: the release goes to that
    /// icon's button instead of finishing the drag, and the divider is left
    /// lifted off the bar. Before a folder it's dropped right of the other
    /// app's icon in front of it instead.
    private func dividerDrop(before target: CGWindowID) -> (window: CGWindowID, side: ItemMover.Side) {
        let own = Set(folderItems.keys.compactMap(window(for:)))
        guard own.contains(target), let bounds = WindowServer.bounds(of: target),
              let left = BarItem.current().filter({ $0.bounds.minX > 0 && $0.bounds.maxX <= bounds.minX + 1 })
                .max(by: { $0.bounds.maxX < $1.bounds.maxX }) else { return (target, .left) }
        return (left.windowID, .right)
    }

    /// Resting in the main display's menu bar, not lifted mid-drag or parked.
    private static func isOnBarRow(_ bounds: CGRect) -> Bool {
        abs(bounds.minY - CGDisplayBounds(CGMainDisplayID()).minY) < 1
    }

    /// Stretches a staged divider, which pushes everything left of it off
    /// screen, and retires the old one. The new one is in before the old one
    /// goes, so nothing filed flashes into view.
    private func commit(_ staged: (item: NSStatusItem, bar: BarItem)) {
        // Turned off while it was being placed: nothing may stay hidden.
        guard !stopped else {
            NSStatusBar.system.removeStatusItem(staged.item)
            return
        }
        staged.item.length = Self.collapsedLength
        let old = divider
        divider = staged.item
        if let old {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { NSStatusBar.system.removeStatusItem(old) }
        }
    }

    /// Icons slide into place after a move. Measure the bar only once two
    /// readings in a row agree.
    private func waitForBarToSettle() async {
        var last = BarItem.current().map(\.bounds)
        let deadline = ContinuousClock.now + .milliseconds(600)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(40))
            let now = BarItem.current().map(\.bounds)
            if now == last { return }
            last = now
        }
    }

    // MARK: Folder items

    private func makeStatusItem(for folder: BarFolder) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = autosaveName(for: folder)
        // macOS remembers an item dragged off the bar and keeps it off under
        // that name. A divider lifted by a drag that never landed counts, and
        // so would a folder: without its icon there's no way back to it.
        item.isVisible = true
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(folderClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.identifier = NSUserInterfaceItemIdentifier(folder.id.uuidString)
        button.setAccessibilityLabel(folder.name)
        folderItems[folder.id] = item
        refreshIcon(for: folder.id)
    }

    func refreshIcons() {
        for folder in store.folders { refreshIcon(for: folder.id) }
    }

    private func refreshIcon(for folderID: UUID) {
        guard let folder = store.folders.first(where: { $0.id == folderID }),
              let button = folderItems[folderID]?.button else { return }
        button.image = FolderGlyph.image(for: folder, icons: folder.items.prefix(4).map { store.image(for: $0) })
    }

    @objc private func folderClicked(_ sender: NSStatusBarButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            drawer.close(animated: true)
            showFolderMenu(for: id, from: sender)
        } else if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            toggleAlwaysHidden(from: id)
        } else if drawer.openFolder == id {
            // Hover opened it; the click keeps it. A second click puts it away.
            if drawer.isPinned { drawer.close(animated: true) } else { drawer.pin() }
        } else {
            present(id)
            drawer.pin()
        }
    }

    func hoverChanged(_ inside: Bool, folder: UUID) {
        // A clicked-open always hidden section stays when the pointer comes
        // back to the folder it hangs from.
        if drawer.openFolder == FolderStore.hiddenID, drawer.isPinned, hiddenAnchor == folder { return }
        if inside {
            // Option held: the always hidden icons instead of the folder's.
            let shown = NSEvent.modifierFlags.contains(.option) ? FolderStore.hiddenID : folder
            drawer.anchorHovered(shown) { [weak self] in self?.present(shown, under: folder) }
        } else {
            drawer.anchorUnhovered(folder)
        }
    }

    /// The folder the always hidden section last hung from.
    private var hiddenAnchor: UUID?

    /// Option-click: the always hidden section opens under the folder, held
    /// open like a clicked folder. Again puts it away.
    func toggleAlwaysHidden(from folderID: UUID) {
        if drawer.openFolder == FolderStore.hiddenID, drawer.isPinned {
            drawer.close(animated: true)
        } else {
            present(FolderStore.hiddenID, under: folderID)
            drawer.pin()
        }
    }

    /// The folder whose icon a drawer hangs from. The always hidden section
    /// has no icon and borrows one.
    private func anchorFolder(for folderID: UUID, preferring preferred: UUID? = nil) -> UUID? {
        guard folderID == FolderStore.hiddenID else { return folderID }
        let candidates = [preferred, hiddenAnchor, store.folders.first?.id].compactMap { $0 }
        return candidates.first { folderItems[$0] != nil }
    }

    func present(_ folderID: UUID, under anchorID: UUID? = nil, asDropTarget: Bool = false) {
        guard let anchorID = anchorFolder(for: folderID, preferring: anchorID),
              let button = folderItems[anchorID]?.button, let window = button.window else { return }
        if folderID == FolderStore.hiddenID { hiddenAnchor = anchorID }
        // The button is shorter than the bar; the status item's window spans
        // it, so its bottom is where the drawer hangs from.
        var anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        anchor.origin.y = window.frame.minY
        anchor.size.height = window.frame.height
        drawer.open(folderID, under: anchor, asDropTarget: asDropTarget)
        if !asDropTarget { Task { await recapture(folderID) } }
    }

    private func recapture(_ folderID: UUID) async {
        guard let folder = store.folder(folderID) else { return }
        let ids = Set(folder.items.map(\.id))
        await store.capture(BarItem.current().filter { ids.contains($0.id) })
        refreshIcon(for: folderID)
    }

    // MARK: Filing

    func file(_ item: BarItem, in folderID: UUID) {
        DebugLog.write("file \(item.id)")
        guard ensureAccessibility() else { return }
        store.file(item, in: folderID)
        feedback.tick()
        enqueue { [weak self] in
            guard let self else { return }
            await store.capture([item])
            refreshIcon(for: folderID)
            await stash([item.id])
        }
    }

    /// Takes an item out of its folder and puts it back on the bar: where it
    /// was dropped, or beside the other loose icons.
    func takeOut(_ itemID: String, droppedAt point: CGPoint? = nil) {
        guard ensureAccessibility() else { return }
        let folderID = store.folder(containing: itemID)?.id
        store.unfile(itemID)
        if let folderID { refreshIcon(for: folderID) }
        feedback.tick()
        if revealed?.item.id == itemID {
            restashTask?.cancel()
            revealed = nil
        }
        enqueue { [weak self] in
            guard let self, let item = BarItem.current().first(where: { $0.id == itemID }) else { return }
            if let point, let spot = dropSpot(at: point, excluding: item.windowID) {
                await mover.move(item, to: spot.side, of: spot.window)
            } else if let boundary = boundary(excluding: [itemID]) {
                await mover.move(item, to: .left, of: boundary.window)
            }
        }
    }

    func unfile(_ itemID: String) { takeOut(itemID) }

    /// The icon a drop at `point` (global display coordinates) lands beside.
    private func dropSpot(at point: CGPoint, excluding window: CGWindowID) -> (window: CGWindowID, side: ItemMover.Side)? {
        let onBar = BarItem.current().filter { $0.bounds.minX > 0 && $0.windowID != window && $0.isMovable }
            .map { ($0.windowID, $0.bounds) } + folderFrames.compactMap { entry in self.window(for: entry.id).map { ($0, entry.frame) } }
        guard let barBottom = onBar.map(\.1.maxY).max(), point.y <= barBottom + 8,
              let nearest = onBar.min(by: { abs($0.1.midX - point.x) < abs($1.1.midX - point.x) }) else { return nil }
        return (nearest.0, point.x < nearest.1.midX ? .left : .right)
    }

    func addFolder() {
        let folder = store.addFolder()
        seedFolderPositions()
        makeStatusItem(for: folder)
    }

    func removeFolder(_ id: UUID) {
        drawer.close(animated: false)
        let items = store.removeFolder(id)
        if let item = folderItems.removeValue(forKey: id) {
            NSStatusBar.system.removeStatusItem(item)
            UserDefaults.standard.removeObject(forKey: Self.positionKey(item.autosaveName))
        }
        enqueue { [weak self] in
            for filed in items {
                guard let self, let item = BarItem.current().first(where: { $0.id == filed.id }),
                      let boundary = boundary(excluding: [filed.id]) else { continue }
                await mover.move(item, to: .left, of: boundary.window)
            }
        }
    }

    /// Hides filed items that are on the bar. The new divider goes in first,
    /// right before the first icon that stays; the items are dropped just
    /// left of it, and it's stretched straight away, so each item is in view
    /// only for the moment it lands.
    private func stash(_ ids: Set<String>) async {
        guard canMoveItems else { return }
        let showing = { [weak self] in
            BarItem.current().filter { ids.contains($0.id) && self?.isHidden($0.bounds) == false && $0.id != self?.revealed?.item.id }
        }
        guard !showing().isEmpty, let staged = await stageDivider(excluding: ids) else { return }
        for item in showing() {
            await mover.move(item, to: .left, of: staged.bar.windowID)
        }
        commit(staged)
    }

    /// Nil when there's no divider on the bar, including one macOS dropped
    /// from it: then it hides nothing.
    private var dividerBounds: CGRect? {
        guard let bounds = divider?.button?.window.flatMap({ WindowServer.bounds(of: CGWindowID($0.windowNumber)) }),
              Self.isOnBarRow(bounds) else { return nil }
        return bounds
    }

    /// Left of the divider. Without one, off the left of the bar.
    private func isHidden(_ bounds: CGRect) -> Bool {
        guard let divider = dividerBounds else { return bounds.minX <= 0 }
        return bounds.maxX <= divider.minX + 1
    }

    // MARK: Keeping the bar in order

    /// Puts every icon back on its side of the divider: filed ones out of
    /// sight, loose ones in view. Apps add their icons wherever they like (at
    /// login, on relaunch, after an update), so a filed icon can turn up on
    /// the bar and a loose one behind the divider.
    private func reconcile() async {
        guard canMoveItems, revealed == nil else { return }
        let items = BarItem.current().filter(\.isMovable)
        let filed = store.filedIDs
        let strays = items.filter { filed.contains($0.id) && !isHidden($0.bounds) }
        let swallowed = dividerBounds == nil ? [] : items.filter { !filed.contains($0.id) && isHidden($0.bounds) }
        // Whatever is in place now has nothing left to try.
        let misplaced = Set((strays + swallowed).map(\.id))
        attempts = attempts.filter { misplaced.contains($0.key) }
        let tries = (strays + swallowed).filter(shouldTry)
        guard !tries.isEmpty else { return }
        DebugLog.write("reconcile: stash \(strays.map(\.id)) bring back \(swallowed.map(\.id))")

        for item in swallowed where tries.contains(item) {
            guard let boundary = boundary(excluding: [item.id]) else { break }
            await mover.move(item, to: .left, of: boundary.window)
        }
        let stashing = strays.filter(tries.contains)
        if !stashing.isEmpty {
            await store.capture(stashing)
            refreshIcons()
            await stash(Set(stashing.map(\.id)))
        }
    }

    /// Two tries per icon, counted again when its app makes a new window.
    private func shouldTry(_ item: BarItem) -> Bool {
        var entry = attempts[item.id] ?? (item.windowID, 0)
        if entry.window != item.windowID { entry = (item.windowID, 0) }
        guard entry.count < 2 else { return false }
        attempts[item.id] = (entry.window, entry.count + 1)
        return true
    }

    /// Checks the bar whenever its set of windows changes: an app started or
    /// quit, made or dropped an icon, or a display came or went. A list of
    /// window numbers every few seconds costs next to nothing; the bar is
    /// only measured when the list changes.
    private func watchBar() {
        barWindows = Set(WindowServer.menuBarWindowIDs())
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Set(WindowServer.menuBarWindowIDs())
                guard now != self.barWindows else { return }
                self.barWindows = now
                // Icons slide in; let them land.
                self.scheduleCheck(after: 0.6)
            }
        }
        timer.resume()
        barPoll = timer

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observe(workspace, name)
        }
        observe(.default, NSApplication.didChangeScreenParametersNotification)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // A new start for icons that wouldn't move before.
                self?.attempts = [:]
                self?.scheduleCheck(after: 1.5)
            }
        }
        observers.append((center, observer))
    }

    private func scheduleCheck(after delay: TimeInterval) {
        guard !stopped else { return }
        pendingCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.checkWhenIdle() }
        }
        pendingCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Moving icons hides and warps the pointer for a moment, so it waits
    /// until the user is between things: no button held, no drawer or
    /// revealed icon out, the pointer away from the bar, half a second idle.
    private func checkWhenIdle() {
        pendingCheck = nil
        guard !stopped else { return }
        let anyInput = CGEventType(rawValue: ~0)!
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        let busy = NSEvent.pressedMouseButtons != 0 || drawer.openFolder != nil || revealed != nil
            || mover.busy || idle < 0.5 || Self.pointerIsOnBar()
        if busy {
            scheduleCheck(after: 1)
            return
        }
        enqueue { [weak self] in await self?.reconcile() }
    }

    private static func pointerIsOnBar() -> Bool {
        guard let point = CGEvent(source: nil)?.location else { return false }
        return NSScreen.screens.contains { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            let bounds = CGDisplayBounds(id)
            return bounds.contains(point) && point.y - bounds.minY < 60
        }
    }

    // MARK: Opening an item

    func open(_ filed: FiledItem, from folderID: UUID) {
        DebugLog.write("open tapped \(filed.id)")
        guard ensureAccessibility() else { return }
        log.info("open \(filed.id, privacy: .public)")
        guard BarItem.current().contains(where: { $0.id == filed.id }),
              let anchorID = anchorFolder(for: folderID), window(for: anchorID) != nil else {
            log.error("open: item or folder window missing")
            NSSound.beep()
            return
        }
        feedback.tick()
        drawer.close(animated: true)
        restashTask?.cancel()
        enqueue { [weak self] in
            guard let self else { return }
            if let previous = revealed, previous.item.id != filed.id {
                revealed = nil
                await stash([previous.item.id])
            }
            // Measured now: the jobs before this one may have moved things.
            guard let item = BarItem.current().first(where: { $0.id == filed.id }),
                  let folderWindow = window(for: anchorID) else {
                NSSound.beep()
                return
            }
            // Out beside its folder, so its menu drops from where the drawer
            // was. An item already in view is clicked where it is.
            if !Self.isShowing(item) {
                let didMove = await mover.move(item, to: .left, of: folderWindow)
                log.info("open: moved=\(didMove)")
            }
            guard let live = BarItem.current().first(where: { $0.id == item.id }), Self.isShowing(live) else {
                log.error("open: item did not come into view")
                NSSound.beep()
                return
            }
            revealed = (live, folderID)
            // Some apps need a beat after their item lands before a click takes.
            try? await Task.sleep(for: .milliseconds(30))
            let before = Self.onScreenWindows()
            await mover.click(live)
            log.info("open: clicked at \(live.liveBounds().midX)")
            watchForMenuToClose(live, windowsBefore: Set(before.map(\.id)))
        }
    }

    private static func isShowing(_ item: BarItem) -> Bool {
        let bounds = item.liveBounds()
        return bounds.minX > 0 && NSScreen.screens.contains { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            return CGDisplayBounds(id).contains(CGPoint(x: bounds.midX, y: bounds.midY))
        }
    }

    /// Tucks the item back once whatever it opened has gone: the windows its
    /// click opened, or failing that any menu of its app under the bar.
    private func watchForMenuToClose(_ item: BarItem, windowsBefore: Set<CGWindowID>) {
        restashTask = Task { [weak self] in
            var opened: Set<CGWindowID> = []
            var sawMenu = false
            var quietPolls = 0
            let start = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                let windows = Self.onScreenWindows()
                let barBottom = item.liveBounds().maxY
                if ContinuousClock.now - start < .milliseconds(800) {
                    opened.formUnion(windows.filter { !windowsBefore.contains($0.id) && $0.layer > 0 }.map(\.id))
                }
                let open = windows.contains { window in
                    window.id != item.windowID && (opened.contains(window.id)
                        || (window.pid == item.pid && window.layer > 0 && window.bounds.minY <= barBottom + 40
                            && window.bounds.height > item.bounds.height + 4))
                }
                sawMenu = sawMenu || open
                quietPolls = open ? 0 : quietPolls + 1
                // A click that opened nothing (or opened an app) gets 3 s.
                if (sawMenu && quietPolls >= 3) || (!sawMenu && ContinuousClock.now - start > .seconds(3)) { break }
            }
            guard !Task.isCancelled, let self, self.revealed?.item.id == item.id else { return }
            self.revealed = nil
            self.enqueue { [weak self] in
                guard let self, self.revealed == nil, self.store.filedIDs.contains(item.id) else { return }
                await self.stash([item.id])
            }
        }
    }

    private struct ScreenWindow { let id: CGWindowID; let pid: pid_t; let layer: Int; let bounds: CGRect }

    private static func onScreenWindows() -> [ScreenWindow] {
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[CFString: Any]] else { return [] }
        return infos.compactMap { info in
            guard let id = info[kCGWindowNumber] as? CGWindowID, let pid = info[kCGWindowOwnerPID] as? pid_t,
                  let layer = info[kCGWindowLayer] as? Int, let dict = info[kCGWindowBounds] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict) else { return nil }
            return ScreenWindow(id: id, pid: pid, layer: layer, bounds: bounds)
        }
    }

    // MARK: Menus

    private func iconMenu(for folder: BarFolder) -> NSMenu {
        let menu = NSMenu()
        let contents = ClosureMenuItem(title: "What's Inside") { [weak self] in self?.setSymbol(nil, for: folder.id) }
        contents.state = folder.symbol == nil ? .on : .off
        menu.addItem(contents)
        menu.addItem(.separator())
        for symbol in FolderGlyph.symbols {
            let entry = ClosureMenuItem(title: symbol.title) { [weak self] in self?.setSymbol(symbol.name, for: folder.id) }
            entry.image = NSImage(systemSymbolName: symbol.name, accessibilityDescription: nil)
            entry.state = folder.symbol == symbol.name ? .on : .off
            menu.addItem(entry)
        }
        return menu
    }

    func setSymbol(_ symbol: String?, for folderID: UUID) {
        store.setSymbol(folderID, to: symbol)
        refreshIcon(for: folderID)
    }

    private func showFolderMenu(for folderID: UUID, from button: NSStatusBarButton) {
        guard let folder = store.folders.first(where: { $0.id == folderID }) else { return }
        let menu = NSMenu()
        let add = NSMenuItem(title: "Add to “\(folder.name)”", action: nil, keyEquivalent: "")
        add.submenu = addMenu(for: folderID)
        menu.addItem(add)
        if !folder.items.isEmpty {
            let remove = NSMenuItem(title: "Take Out", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for filed in folder.items {
                let entry = ClosureMenuItem(title: filed.name) { [weak self] in self?.unfile(filed.id) }
                entry.image = Self.menuImage(store.image(for: filed))
                submenu.addItem(entry)
            }
            remove.submenu = submenu
            menu.addItem(remove)
        }
        menu.addItem(.separator())
        let hiddenCount = store.hidden.items.count
        let showHidden = ClosureMenuItem(title: hiddenCount == 0 ? "Show Always Hidden" : "Show Always Hidden (\(hiddenCount))") { [weak self] in
            self?.drawer.close(animated: false)
            self?.toggleAlwaysHidden(from: folderID)
        }
        showHidden.toolTip = "Or Option-click a folder."
        menu.addItem(showHidden)
        let hide = NSMenuItem(title: "Add to Always Hidden", action: nil, keyEquivalent: "")
        hide.submenu = addMenu(for: FolderStore.hiddenID)
        menu.addItem(hide)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Rename…") { [weak self] in self?.promptRename(folderID) })
        let icon = NSMenuItem(title: "Icon", action: nil, keyEquivalent: "")
        icon.submenu = iconMenu(for: folder)
        menu.addItem(icon)
        menu.addItem(ClosureMenuItem(title: "New Folder") { [weak self] in self?.addFolder() })
        if store.folders.count > 1 {
            menu.addItem(ClosureMenuItem(title: "Remove Folder") { [weak self] in self?.removeFolder(folderID) })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Menu Bar Folders Settings…") { [weak self] in self?.openSettings() })
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 6), in: button)
    }

    private func showAddMenu(for folderID: UUID, at anchor: NSPoint) {
        addMenu(for: folderID).popUp(positioning: nil, at: anchor, in: nil)
    }

    /// Icons on the bar, then the ones in other folders (and the always
    /// hidden section), which move over without touching the bar.
    private func addMenu(for folderID: UUID) -> NSMenu {
        let menu = NSMenu()
        let filed = store.filedIDs
        let candidates = BarItem.current().filter { !filed.contains($0.id) && $0.isMovable && $0.bounds.minX > 0 }
        for item in candidates {
            let entry = ClosureMenuItem(title: item.name) { [weak self] in self?.file(item, in: folderID) }
            if let image = WindowServer.image(of: item.windowID) {
                entry.image = Self.menuImage(NSImage(cgImage: image, size: item.bounds.size))
            }
            menu.addItem(entry)
        }
        for other in store.allFolders where other.id != folderID && !other.items.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addItem(.sectionHeader(title: other.name))
            for filed in other.items {
                let entry = ClosureMenuItem(title: filed.name) { [weak self] in self?.move(filed.id, to: folderID) }
                entry.image = Self.menuImage(store.image(for: filed))
                menu.addItem(entry)
            }
        }
        if menu.items.isEmpty {
            let none = NSMenuItem(title: "No icons to add", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        return menu
    }

    /// Between folders, or into or out of the always hidden section. All of
    /// them are behind the divider, so nothing on the bar moves.
    func move(_ itemID: String, to folderID: UUID) {
        let from = store.folder(containing: itemID)?.id
        store.move(itemID, to: folderID)
        feedback.tick()
        if let from { refreshIcon(for: from) }
        refreshIcon(for: folderID)
    }

    private static func menuImage(_ image: NSImage) -> NSImage {
        let height: CGFloat = 16
        let width = min(40, image.size.height > 0 ? image.size.width * height / image.size.height : height)
        return NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
    }

    private func promptRename(_ folderID: UUID) {
        guard let folder = store.folders.first(where: { $0.id == folderID }) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Folder"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: folder.name)
        field.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            store.rename(folderID, to: field.stringValue)
            refreshIcon(for: folderID)
        }
    }
}

/// An NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
