import AppKit
import Combine
import XNotchKit
import SwiftUI

enum NotchSurface {
    case closed, dropZone, open
}

/// The shell's transient deformation, apart from the model so that tracking
/// the pointer only re-renders the silhouette, not every page inside it.
@MainActor
final class NotchDeformationState: ObservableObject {
    /// Pointer-driven: proximity pull, hover, lean toward the pointer.
    @Published var attraction = NotchDeformation()
    /// Event-driven: press squash and drop impact.
    @Published var impact = NotchDeformation()
}

/// Owns every visual state change of the shell. Transitions only change state
/// and then call `render`, which derives geometry and every reveal value in one
/// `withAnimation`, so they all ride the same spring and stay in lockstep when
/// interrupted.
@MainActor
final class NotchViewModel: ObservableObject {
    @Published private(set) var surface: NotchSurface = .closed
    @Published private(set) var page: OpenPage = .shelf
    @Published private(set) var geometry: NotchShellGeometry
    let deformation = NotchDeformationState()

    @Published private(set) var dropReveal: CGFloat = 0
    @Published private(set) var openReveal: CGFloat = 0
    @Published private(set) var shelfReveal: CGFloat = 0
    @Published private(set) var mediaOpenReveal: CGFloat = 0
    @Published private(set) var trayWingsReveal: CGFloat = 0
    @Published private(set) var headphonesReveal: CGFloat = 0
    @Published private(set) var alertReveal: CGFloat = 0
    /// The extension alert in the wings, or the one waiting for the notch to close.
    @Published private(set) var alert: ExtensionAlert?
    @Published private(set) var mediaWingsReveal: CGFloat = 0
    /// 0 = shared media elements sit in the wings, 1 = in the open layout.
    @Published private(set) var mediaPlacement: CGFloat = 0
    @Published private(set) var mediaHover: CGFloat = 0
    /// Destination pills: `pillsReveal` drops them out from under the closed
    /// notch, `pillsTravel` carries them up into the open header's switcher.
    @Published private(set) var pillsReveal: CGFloat = 0
    @Published private(set) var pillsTravel: CGFloat = 0
    @Published private(set) var highlightedPill: OpenPage?
    /// Reveal progress per extension page, keyed by `OpenPage.id`.
    @Published private(set) var extensionReveal: [String: CGFloat] = [:]
    @Published private(set) var eyesReveal: CGFloat = 0
    /// The onboarding draws its own notch over this one and owns the pointer.
    @Published private(set) var isPresentingOnboarding = false

    @Published private(set) var hoveredDropTarget: DropTarget?
    @Published private(set) var notchSize: CGSize

    let shelf = ShelfStore()
    let media = NowPlayingService()
    let extensions = ExtensionManager()
    let preferences = Preferences.shared
    let eyes = NotchEyes()
    let headphones = HeadphonesMonitor()
    /// Tile frames in canvas coordinates, reported by the shelf layout.
    var tileFrames: [UUID: CGRect] = [:]
    /// Asks the controller to re-read the pointer after AppKit swallowed events (drag sessions).
    var onPointerSyncNeeded: (() -> Void)?
    var onOpenSettings: ((SettingsPane?) -> Void)?

    private(set) var isPointerInside = false
    private var isPressed = false
    private var isDraggingOut = false
    private var showsTrayWings = false
    private var showsHeadphones = false
    private var showsAlert = false
    /// Who wants the eyes up: the onboarding, a permission guide.
    private var eyesReasons: Set<EyesReason> = []
    /// Media wings stay up while playing and for a moment after pausing.
    private(set) var mediaActive = false
    private var pendingWingsToast = false
    private var pillsWanted = false
    private var collapseWork: DispatchWorkItem?
    private var trayWingsWork: DispatchWorkItem?
    private var headphonesWork: DispatchWorkItem?
    private var alertWork: DispatchWorkItem?
    private var mediaIdleWork: DispatchWorkItem?
    private var mediaGoneWork: DispatchWorkItem?
    private var pillsWork: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []

    private let mediaIdleDelay: TimeInterval = 6

    init(notchSize: CGSize) {
        self.notchSize = notchSize
        geometry = NotchMetrics.closed(notchSize)
        media.$track
            .sink { [weak self] track in self?.mediaChanged(track) }
            .store(in: &cancellables)

        extensions.driver = self
        extensions.$pagesRevision
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.extensionPagesChanged() }
            .store(in: &cancellables)
        preferences.$showsMediaInNotch
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.mediaPreferenceChanged() }
            .store(in: &cancellables)
        headphones.onConnect = { [weak self] _ in self?.showHeadphonesToast() }
        preferences.$showsHeadphonesInNotch
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.headphonesPreferenceChanged() }
            .store(in: &cancellables)
        preferences.$pillsIconOnly
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                self?.previewPills()
            }
            .store(in: &cancellables)
    }

    private var servicesStarted = false

    /// Media, the shelf and extensions all read files, some in protected
    /// folders. On first run they wait until the onboarding has asked for
    /// Full Disk Access, so macOS doesn't ask folder by folder first.
    func startServices() {
        guard !servicesStarted else { return }
        servicesStarted = true
        media.start()
        shelf.load()
        extensions.loadAll()
        extensionPagesChanged()
        if preferences.showsHeadphonesInNotch { headphones.start() }
    }

    func setPresentingOnboarding(_ presenting: Bool) {
        guard presenting != isPresentingOnboarding else { return }
        if presenting { close() }
        isPresentingOnboarding = presenting
        onPointerSyncNeeded?()
    }

    var pillsIconOnly: Bool { preferences.pillsIconOnly }

    var hasMedia: Bool { media.track != nil && preferences.showsMediaInNotch }
    private var showsMediaActivity: Bool { mediaActive && preferences.showsMediaInNotch }

    var showsEyes: Bool { !eyesReasons.isEmpty }

    var restingGeometry: NotchShellGeometry {
        if showsEyes { return NotchMetrics.eyes(notchSize) }
        if showsHeadphones { return NotchMetrics.headphonesWings(notchSize) }
        if showsAlert { return NotchMetrics.alertWings(notchSize) }
        if showsTrayWings { return NotchMetrics.wings(notchSize) }
        if showsMediaActivity { return NotchMetrics.mediaWings(notchSize) }
        return NotchMetrics.closed(notchSize)
    }

    var targetGeometry: NotchShellGeometry {
        switch surface {
        case .closed: return restingGeometry
        case .dropZone: return NotchMetrics.dropZone
        case .open:
            if page == .media { return NotchMetrics.media(notchSize) }
            if let ext = extensionPages.first(where: { $0.page == page }) {
                return NotchMetrics.extensionPage(contentHeight: ext.descriptor.contentHeight, notch: notchSize)
            }
            return NotchMetrics.shelf
        }
    }

    /// Whether a click lands on the closed media wings' play/pause glyph.
    var showsMediaWings: Bool {
        surface == .closed && !showsEyes && !showsHeadphones && !showsAlert && !showsTrayWings && showsMediaActivity
    }

    /// Re-read when an extension reports its pages changed, not per render.
    private(set) var extensionPages: [ExtensionPage] = []

    private static func pages(of extensions: ExtensionManager) -> [ExtensionPage] {
        extensions.pageProviders.flatMap { id, provider in
            provider.pages.map { descriptor in
                ExtensionPage(page: .extensionPage(id, descriptor.id), extensionID: id,
                              descriptor: descriptor, provider: provider)
            }
        }
    }

    var destinationInfos: [PageInfo] {
        var infos: [PageInfo] = []
        if hasMedia { infos.append(PageInfo(page: .media, title: "Music", symbol: "music.note", badge: 0)) }
        infos.append(PageInfo(page: .shelf, title: "Shelf", symbol: "tray.full.fill", badge: shelf.items.count))
        infos += extensionPages.map {
            PageInfo(page: $0.page, title: $0.descriptor.title, symbol: $0.descriptor.symbol, badge: $0.descriptor.badge ?? 0)
        }
        return infos
    }

    var destinations: [OpenPage] { destinationInfos.map(\.page) }
    var defaultDestination: OpenPage { hasMedia ? .media : .shelf }
    /// What a click on the notch body opens: the showing alert's page, or the default.
    var bodyDestination: OpenPage {
        if showsAlert, let page = alert?.page, destinations.contains(page) { return page }
        return defaultDestination
    }
    /// The pills (or their pending appearance) extend the hover region.
    var pillsActive: Bool { surface == .closed && (pillsWanted || pillsReveal > 0) }

    private static let pillsSpring = Animation.spring(response: 0.38, dampingFraction: 0.78)

    func updateNotchSize(_ size: CGSize) {
        notchSize = size
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { render(nil) }
    }

    private func render(_ animation: Animation?) {
        let placement: CGFloat = surface == .open ? 1 : 0
        if mediaOpenReveal == 0, mediaWingsReveal == 0, mediaPlacement != placement {
            // Invisible elements jump instead of travelling across the shell.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { mediaPlacement = placement }
        }
        withAnimation(animation) {
            geometry = targetGeometry
            dropReveal = surface == .dropZone ? 1 : 0
            openReveal = surface == .open ? 1 : 0
            shelfReveal = surface == .open && page == .shelf ? 1 : 0
            mediaOpenReveal = surface == .open && page == .media ? 1 : 0
            extensionReveal = Dictionary(uniqueKeysWithValues: extensionPages.map {
                ($0.page.id, surface == .open && page == $0.page ? CGFloat(1) : 0)
            })
            headphonesReveal = surface == .closed && showsHeadphones && !showsEyes ? 1 : 0
            alertReveal = surface == .closed && showsAlert && !showsHeadphones && !showsEyes ? 1 : 0
            trayWingsReveal = surface == .closed && showsTrayWings && !showsAlert && !showsHeadphones && !showsEyes ? 1 : 0
            eyesReveal = surface == .closed && showsEyes ? 1 : 0
            mediaWingsReveal = showsMediaWings ? 1 : 0
            // Elements on their way out fade where they are.
            if mediaOpenReveal > 0 || mediaWingsReveal > 0 { mediaPlacement = placement }
            mediaHover = showsMediaWings && isPointerInside ? 1 : 0
            pillsReveal = surface == .closed && pillsWanted ? 1 : 0
            pillsTravel = surface == .open ? 1 : 0
        }
    }

    // MARK: Pointer

    /// `pull` is 0...1 proximity, `lean` is -1...1 horizontal pointer side.
    func updatePointer(pull: CGFloat, inside: Bool, lean: CGFloat, isFileDrag: Bool) {
        guard surface == .closed, !Motion.reduceMotion || inside else { return }
        let hover: CGFloat = inside ? 1 : 0
        let target: NotchDeformation
        if isFileDrag {
            target = NotchDeformation(width: 44 * pull, height: 16 * pull,
                                      offsetX: 10 * lean * pull, shadow: 0.7 * pull)
        } else {
            target = NotchDeformation(width: 10 * pull + 14 * hover, height: 2 * pull + 2.5 * hover,
                                      offsetX: 4 * lean * pull, shadow: 0.25 * pull + 0.75 * hover)
        }
        guard !target.isClose(to: deformation.attraction) else { return }
        withAnimation(Motion.track) { deformation.attraction = target }
    }

    func pointerEntered() {
        guard !isPointerInside else { return }
        isPointerInside = true
        cancelCollapse()
        updateMediaHover()
        schedulePills()
    }

    func pointerExited() {
        guard isPointerInside else { return }
        isPointerInside = false
        shelf.hoveredID = nil
        if isPressed {
            isPressed = false
            withAnimation(Motion.press) { deformation.impact = .zero }
        }
        updateMediaHover()
        hidePills()
        if surface == .open && !isDraggingOut { scheduleCollapse() }
    }

    // MARK: Pills

    /// A short dwell keeps the pills from flashing when the pointer only
    /// passes over the notch on its way to the menu bar.
    private func schedulePills() {
        guard surface == .closed, !pillsWanted, preferences.showsDestinationPills else { return }
        pillsWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, isPointerInside, surface == .closed else { return }
            pillsWanted = true
            withAnimation(Self.pillsSpring) { self.pillsReveal = 1 }
            onPointerSyncNeeded?()
        }
        pillsWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    /// Shows the pills for a moment without a hover, so a style change in
    /// Settings can be seen where it applies.
    func previewPills() {
        guard surface == .closed, preferences.showsDestinationPills else { return }
        pillsWork?.cancel()
        pillsWanted = true
        withAnimation(Self.pillsSpring) { pillsReveal = 1 }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !isPointerInside else { return }
            hidePills()
        }
        pillsWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: work)
    }

    private func hidePills() {
        pillsWork?.cancel()
        pillsWork = nil
        guard pillsWanted else { return }
        pillsWanted = false
        highlightedPill = nil
        withAnimation(Motion.close) { pillsReveal = 0 }
    }

    /// `pill` is the pill under the pointer; on the notch body the default
    /// destination lights up, over the play/pause glyph nothing does.
    func updatePillHighlight(pill: OpenPage?, onBody: Bool, onMediaGlyph: Bool) {
        var target: OpenPage?
        if pillsWanted {
            if let pill {
                target = pill
            } else if onBody && !onMediaGlyph {
                target = bodyDestination
            }
        }
        guard target != highlightedPill else { return }
        highlightedPill = target
        if target != nil && pill != nil { Haptics.tap() }
    }

    private func updateMediaHover() {
        let target: CGFloat = showsMediaWings && isPointerInside ? 1 : 0
        guard target != mediaHover else { return }
        withAnimation(Motion.content) { mediaHover = target }
    }

    /// `point` is in canvas coordinates (top-left origin), nil when outside.
    func updateShelfHover(at point: CGPoint?) {
        var hovered: UUID?
        if surface == .open, page == .shelf, !isDraggingOut, let point {
            hovered = tileFrames.first { $0.value.contains(point) }?.key
        }
        if shelf.hoveredID != hovered { shelf.hoveredID = hovered }
        // Extension pages and shelf accessories hover through the published pointer.
        let publishes = surface == .open && !isDraggingOut && (page == .shelf || extensionPages.contains { $0.page == page })
        extensions.pointer.update(publishes ? point : nil)
    }

    /// Pressing a pill leaves the shell alone; pressing the notch squashes it.
    func pressBegan(onPill: Bool) {
        guard surface == .closed, isPointerInside else { return }
        isPressed = true
        guard !onPill else { return }
        withAnimation(Motion.press) { deformation.impact = NotchDeformation(width: 6, height: -2.5) }
    }

    /// `onMediaGlyph`: the release landed on the closed media wings' play/pause
    /// glyph. `pill`: it landed on a destination pill.
    func pressEnded(onMediaGlyph: Bool, pill: OpenPage?) {
        guard isPressed else { return }
        isPressed = false
        if isPointerInside && pill == nil && onMediaGlyph && showsMediaWings {
            withAnimation(Motion.press) { deformation.impact = .zero }
            media.togglePlayPause()
        } else if isPointerInside {
            open(page: pill ?? bodyDestination)
        } else {
            withAnimation(Motion.press) { deformation.impact = .zero }
        }
    }

    // MARK: Open / close

    var isOpen: Bool { surface == .open }

    func open(page target: OpenPage) {
        guard destinations.contains(target) else { return }
        cancelCollapse()
        guard surface != .open else { return selectPage(target) }
        cancelTrayWingsTimer()
        cancelHeadphonesTimer()
        cancelAlertTimer()
        surface = .open
        page = target
        showsTrayWings = false
        showsHeadphones = false
        headphones.dismiss()
        if showsAlert {
            showsAlert = false
            alert = nil
        }
        pillsWanted = false
        pillsWork?.cancel()
        highlightedPill = nil
        withAnimation(Motion.open) {
            deformation.attraction = NotchDeformation(shadow: 1)
            deformation.impact = .zero
        }
        render(Motion.open)
    }

    func selectPage(_ target: OpenPage) {
        guard surface == .open, target != page, destinations.contains(target) else { return }
        page = target
        shelf.hoveredID = nil
        render(Motion.open)
    }

    func close() {
        cancelCollapse()
        guard surface != .closed else { return }
        hoveredDropTarget = nil
        surface = .closed
        withAnimation(Motion.close) {
            deformation.attraction = .zero
            deformation.impact = .zero
        }
        render(Motion.close)
        shelf.selection.removeAll()
        if pendingWingsToast {
            pendingWingsToast = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.showTrayWingsToast() }
        }
        if alert != nil, !showsAlert {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.presentAlert() }
        }
    }

    func setDraggingOut(_ dragging: Bool) {
        isDraggingOut = dragging
        if dragging {
            cancelCollapse()
            shelf.hoveredID = nil
        } else {
            onPointerSyncNeeded?()
            if !isPointerInside && surface == .open { scheduleCollapse() }
        }
    }

    func openSettings() {
        close()
        onOpenSettings?(nil)
    }

    func openMediaApp() {
        guard let bundleID = media.track?.bundleIdentifier, !bundleID.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Media

    private func mediaChanged(_ track: NowPlayingTrack?) {
        guard let track else {
            // The adapter can briefly report an empty session between updates.
            guard mediaGoneWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                mediaGoneWork = nil
                guard media.track == nil else { return }
                mediaIdleWork?.cancel()
                mediaIdleWork = nil
                setMediaActive(false)
                if surface == .open && page == .media {
                    page = .shelf
                    render(Motion.open)
                }
            }
            mediaGoneWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
            return
        }
        mediaGoneWork?.cancel()
        mediaGoneWork = nil
        if track.isPlaying {
            mediaIdleWork?.cancel()
            mediaIdleWork = nil
            setMediaActive(true)
        } else if mediaActive && mediaIdleWork == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                mediaIdleWork = nil
                if media.track?.isPlaying != true { setMediaActive(false) }
            }
            mediaIdleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + mediaIdleDelay, execute: work)
        }
    }

    private func mediaPreferenceChanged() {
        if surface == .open && page == .media && !hasMedia { page = .shelf }
        render(surface == .closed ? Motion.close : Motion.open)
    }

    // MARK: Extensions

    private func extensionPagesChanged() {
        objectWillChange.send()
        extensionPages = Self.pages(of: extensions)
        if !destinations.contains(page) {
            page = .shelf
        }
        render(surface == .open ? Motion.open : nil)
    }

    private func setMediaActive(_ active: Bool) {
        guard active != mediaActive else { return }
        mediaActive = active
        if surface == .closed { render(active ? Motion.open : Motion.close) }
    }

    // MARK: Eyes

    enum EyesReason {
        case onboarding, permissionGuide
    }

    func setEyesVisible(_ visible: Bool, for reason: EyesReason) {
        let wasShowing = showsEyes
        if visible {
            eyesReasons.insert(reason)
        } else {
            eyesReasons.remove(reason)
        }
        guard showsEyes != wasShowing else { return }
        if showsEyes {
            eyes.pointer = NSEvent.mouseLocation
            eyes.expression = .asleep
        }
        if surface == .closed { render(showsEyes ? Motion.open : Motion.close) }
        onPointerSyncNeeded?()
    }

    /// The eyes follow a permission guide across the screen while it's up.
    func watchPermissionGuide(_ frame: NSRect?) {
        if let frame {
            eyes.focus = CGPoint(x: frame.midX, y: frame.maxY - 40)
            if !isPresentingOnboarding && !eyesReasons.contains(.permissionGuide) {
                setEyesVisible(true, for: .permissionGuide)
                eyes.expression = .attentive
            }
        } else {
            eyes.focus = nil
        }
    }

    func permissionGuideFinished(granted: Bool) {
        guard !isPresentingOnboarding else { return }
        eyes.flash(granted ? .happy : .sleepy, for: 1.4)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard PermissionCenter.shared.activeRequest == nil else { return }
            self?.setEyesVisible(false, for: .permissionGuide)
        }
    }

    // MARK: Keyboard

    /// Returns whether the key was consumed.
    func handleKey(_ event: NSEvent) -> Bool {
        guard surface == .open else { return false }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "," {
            openSettings()
            return true
        }
        if event.keyCode == 53 { // Escape
            if page == .shelf && !shelf.selection.isEmpty {
                withAnimation(Motion.content) { shelf.selection.removeAll() }
            } else {
                close()
            }
            return true
        }
        if let ext = extensionPages.first(where: { $0.page == page }) {
            guard let handler = ext.provider as? NotchKeyHandling else { return false }
            let key = NotchKeyPress(characters: event.charactersIgnoringModifiers ?? "", keyCode: event.keyCode,
                                    modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask))
            return handler.handleKey(key, on: ext.descriptor.id)
        }
        guard page == .shelf else { return false }
        let selected = shelf.items.filter { shelf.selection.contains($0.id) }
        switch event.keyCode {
        case 51, 117: // Delete, Forward Delete
            guard !selected.isEmpty else { return false }
            withAnimation(Motion.content) { shelf.remove(shelf.selection) }
            return true
        case 49: // Space
            guard !selected.isEmpty else { return false }
            ShelfActions.quickLook(selected)
            return true
        default:
            break
        }
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return false }
        switch event.charactersIgnoringModifiers {
        case "a":
            withAnimation(Motion.content) { shelf.selection = Set(shelf.items.map(\.id)) }
            return true
        case "c":
            guard !selected.isEmpty else { return false }
            ShelfActions.copy(selected)
            return true
        default:
            return false
        }
    }

    // MARK: File drag

    func fileDragBegan() {
        hideTrayWings()
        hideHeadphones()
        hideAlert()
    }

    func enterDropZone() {
        guard surface == .closed else { return }
        cancelTrayWingsTimer()
        surface = .dropZone
        showsTrayWings = false
        withAnimation(Motion.open) {
            deformation.attraction = NotchDeformation(shadow: 1)
            deformation.impact = .zero
        }
        render(Motion.open)
        Haptics.tap()
    }

    func exitDropZone() {
        guard surface == .dropZone else { return }
        hoveredDropTarget = nil
        surface = .closed
        withAnimation(Motion.close) { deformation.attraction = .zero }
        render(Motion.close)
    }

    func setHoveredDropTarget(_ target: DropTarget?) {
        guard surface == .dropZone, target != hoveredDropTarget else { return }
        hoveredDropTarget = target
        if target != nil { Haptics.tap() }
    }

    func fileDragEnded() {
        // A successful drop has already moved on to the shelf.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.exitDropZone()
        }
    }

    func performDrop(_ urls: [URL], on target: DropTarget) {
        hoveredDropTarget = nil
        switch target {
        case .shelf:
            receive(urls)
            land()
            surface = .open
            page = .shelf
            render(Motion.open)
            if !isPointerInside { scheduleCollapse() }
        case .airDrop:
            ShelfActions.airDrop(urls)
            exitDropZone()
        }
    }

    /// Files resolved after the drop (file promises) land on the shelf as they arrive.
    func receive(_ urls: [URL]) {
        let added = withAnimation(Motion.content) { shelf.add(urls) }
        if !added.isEmpty { pendingWingsToast = true }
    }

    /// Squash on arrival, then a rebound that carries the energy away.
    private func land() {
        Haptics.tap()
        guard !Motion.reduceMotion else { return }
        withAnimation(Motion.impact) { deformation.impact = NotchDeformation(width: 14, height: -10) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { [weak self] in
            withAnimation(Motion.rebound) { self?.deformation.impact = .zero }
        }
    }

    // MARK: Tray wings

    private func showTrayWingsToast() {
        guard surface == .closed, !shelf.items.isEmpty else { return }
        showsTrayWings = true
        render(Motion.open)
        scheduleTrayWingsHide()
    }

    private func scheduleTrayWingsHide() {
        cancelTrayWingsTimer()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if isPointerInside {
                scheduleTrayWingsHide()
            } else {
                hideTrayWings()
            }
        }
        trayWingsWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchMetrics.wingsToastDuration, execute: work)
    }

    func hideTrayWings() {
        cancelTrayWingsTimer()
        guard showsTrayWings else { return }
        showsTrayWings = false
        render(Motion.close)
    }

    private func cancelTrayWingsTimer() {
        trayWingsWork?.cancel()
        trayWingsWork = nil
    }

    // MARK: Headphones

    /// Headphones or a speaker connected: their wings show for a moment, longer while hovered.
    private func showHeadphonesToast() {
        guard surface == .closed, !isPresentingOnboarding else {
            headphones.dismiss()
            return
        }
        let wasShowing = showsHeadphones
        showsHeadphones = true
        if !wasShowing {
            render(Motion.open)
            Haptics.tap()
        }
        scheduleHeadphonesHide()
        onPointerSyncNeeded?()
    }

    private func scheduleHeadphonesHide() {
        cancelHeadphonesTimer()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if isPointerInside {
                scheduleHeadphonesHide()
            } else {
                hideHeadphones()
            }
        }
        headphonesWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchMetrics.headphonesToastDuration, execute: work)
    }

    func hideHeadphones() {
        cancelHeadphonesTimer()
        guard showsHeadphones else { return }
        showsHeadphones = false
        render(Motion.close)
        onPointerSyncNeeded?()
        // Keep the device on screen while the wings fold away.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !showsHeadphones else { return }
            headphones.dismiss()
        }
    }

    private func cancelHeadphonesTimer() {
        headphonesWork?.cancel()
        headphonesWork = nil
    }

    private func headphonesPreferenceChanged() {
        if preferences.showsHeadphonesInNotch {
            if servicesStarted { headphones.start() }
        } else {
            hideHeadphones()
            headphones.stop()
        }
    }

    // MARK: Extension alerts

    /// Shown now when the notch is closed and idle, otherwise once it closes.
    private func presentAlert() {
        guard alert != nil, surface == .closed, !isPresentingOnboarding else { return }
        let wasShowing = showsAlert
        showsAlert = true
        if !wasShowing {
            render(Motion.open)
            Haptics.tap()
        }
        scheduleAlertHide()
        onPointerSyncNeeded?()
    }

    private func scheduleAlertHide() {
        cancelAlertTimer()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if isPointerInside {
                scheduleAlertHide()
            } else {
                hideAlert()
            }
        }
        alertWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchMetrics.alertDuration, execute: work)
    }

    func hideAlert() {
        cancelAlertTimer()
        guard showsAlert else { return }
        showsAlert = false
        render(Motion.close)
        onPointerSyncNeeded?()
        // Keep the alert on screen while the wings fold away.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !showsAlert else { return }
            alert = nil
        }
    }

    private func cancelAlertTimer() {
        alertWork?.cancel()
        alertWork = nil
    }

    // MARK: Collapse

    private func scheduleCollapse() {
        cancelCollapse()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !isPointerInside, !isDraggingOut else { return }
            close()
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchMetrics.autoCollapseDelay, execute: work)
    }

    private func cancelCollapse() {
        collapseWork?.cancel()
        collapseWork = nil
    }
}

extension NotchViewModel: ExtensionNotchDriver {
    var shelfFiles: [URL] { shelf.items.map(\.url) }

    func openSettings(extension id: ExtensionID) {
        close()
        onOpenSettings?(.extensionPane(id))
    }

    func showAlert(_ alert: NotchAlert, from id: ExtensionID) {
        guard servicesStarted else { return }
        self.alert = ExtensionAlert(alert: alert, extensionID: id)
        presentAlert()
    }

    /// Files an extension brought, say from an iPhone, arrive like a drop.
    func addToShelf(_ urls: [URL]) {
        guard servicesStarted else { return }
        receive(urls)
        guard !isPresentingOnboarding else { return }
        land()
        open(page: .shelf)
        if !isPointerInside { scheduleCollapse() }
    }
}

enum Haptics {
    @MainActor static func tap() {
        guard Preferences.shared.hapticsEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}
