import AppKit
import SwiftUI
import XNotchKit

@MainActor
final class PermissionGuideState: ObservableObject {
    /// Where the card sits relative to System Settings, so it points the right way.
    enum Side {
        case below, right, left
    }

    let permission: Permission
    @Published var side: Side = .below
    @Published var arrived = false
    @Published var departing = false
    @Published var isDragging = false
    @Published var isGranted = false
    @Published var settingsFrontmost = true
    @Published var showsRelaunch = false

    init(permission: Permission) {
        self.permission = permission
    }
}

/// One permission request on screen: a card that flies out of the button
/// that asked, docks under System Settings and follows its window, then
/// flies up into the notch once the permission is granted.
@MainActor
final class PermissionGuideController {
    var onFinish: ((Bool) -> Void)?
    var onMove: ((NSRect?) -> Void)?

    private let state: PermissionGuideState
    private let panel: PermissionGuidePanel
    private let tracker = SystemSettingsTracker()
    private let source: NSRect
    private var flight: GuideFlight?
    private var hasLaunched = false
    private var isFinished = false
    private var pendingWork: [DispatchWorkItem] = []
    private var observers: [NSObjectProtocol] = []

    /// Room around the card for its shadow.
    static let margin: CGFloat = 22
    static let cardWidth: CGFloat = 440
    private static let panelSize = CGSize(width: cardWidth + 2 * margin, height: 210)

    init(permission: Permission, source: NSRect) {
        self.source = source
        state = PermissionGuideState(permission: permission)
        panel = PermissionGuidePanel(size: Self.panelSize)
        let actions = PermissionGuideView.Actions(
            close: { [weak self] in self?.dismiss() },
            reopenSettings: { NSWorkspace.shared.open(permission.settingsURL) },
            relaunch: PermissionCenter.relaunch,
            dragChanged: { [weak self] dragging in
                self?.state.isDragging = dragging
                self?.panel.ignoresMouseEvents = dragging
            }
        )
        let host = NotchHostingView(rootView: PermissionGuideView(state: state, actions: actions))
        host.frame = NSRect(origin: .zero, size: Self.panelSize)
        panel.contentView = host
    }

    func start() {
        tracker.onChange = { [weak self] frame in self?.settingsMoved(frame) }
        tracker.start()
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let frontmost = self.tracker.isFrontmost
                if self.state.settingsFrontmost != frontmost {
                    withAnimation(Motion.content) { self.state.settingsFrontmost = frontmost }
                }
            }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                               object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == SystemSettingsTracker.bundleIdentifier else { return }
            MainActor.assumeIsolated {
                guard let self, !self.state.isGranted else { return }
                self.dismiss()
            }
        })

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        NSWorkspace.shared.open(state.permission.settingsURL, configuration: configuration)

        // If the window can't be found, the guide still comes up near the bottom of the screen.
        schedule(after: 2.5) { [weak self] in
            guard let self, !hasLaunched, let screen = NSScreen.main else { return }
            let visible = screen.visibleFrame
            launch(to: NSPoint(x: visible.midX - Self.panelSize.width / 2, y: visible.minY + visible.height * 0.18))
        }
        if state.permission.appliesAfterRelaunch {
            schedule(after: 9) { [weak self] in
                guard let self, !state.isGranted else { return }
                withAnimation(Motion.open) { self.state.showsRelaunch = true }
            }
        }
    }

    func markGranted() {
        guard !state.isGranted, !isFinished else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) {
            state.isGranted = true
            state.showsRelaunch = false
        }
        Haptics.tap()
        schedule(after: 1.2) { [weak self] in self?.departIntoNotch() }
    }

    /// Closes without waiting for a grant.
    func dismiss() {
        guard !isFinished else { return }
        withAnimation(.easeIn(duration: 0.18)) { state.departing = true }
        schedule(after: 0.2) { [weak self] in self?.finish() }
    }

    // MARK: Placement

    private func settingsMoved(_ frame: NSRect?) {
        guard let frame, !state.isGranted else { return }
        let (origin, side) = dock(to: frame)
        if side != state.side {
            withAnimation(Motion.content) { state.side = side }
        }
        if !hasLaunched {
            launch(to: origin)
        } else if let flight {
            flight.retarget(origin)
        } else {
            panel.setFrameOrigin(origin)
            onMove?(panel.frame)
        }
    }

    /// Under System Settings, centred on its content column (right of the
    /// sidebar). Without room below, beside the window next to the top of the
    /// list; failing that, over the window's bottom edge.
    private func dock(to settings: NSRect) -> (NSPoint, PermissionGuideState.Side) {
        let size = Self.panelSize
        let margin = Self.margin
        let cardWidth = Self.cardWidth
        let visible = NSScreen.screens.first { $0.frame.intersects(settings) }?.visibleFrame ?? settings
        let sidebar = min(220, settings.width * 0.3)
        let contentMidX = settings.minX + sidebar + (settings.width - sidebar) / 2
        let centredX = (contentMidX - size.width / 2).clamped(visible.minX - margin + 8,
                                                              visible.maxX - size.width + margin - 8)
        let belowY = settings.minY - 8 + margin - size.height
        // The card is about 130pt tall at the top of the panel.
        if belowY + size.height - margin - 140 >= visible.minY {
            return (NSPoint(x: centredX, y: belowY), .below)
        }
        let besideY = (settings.maxY - 80 + margin - size.height)
            .clamped(visible.minY - margin + 140 - size.height + margin, visible.maxY - size.height + margin)
        if settings.maxX + 10 + cardWidth <= visible.maxX {
            return (NSPoint(x: settings.maxX + 10 - margin, y: besideY), .right)
        }
        if settings.minX - 10 - cardWidth >= visible.minX {
            return (NSPoint(x: settings.minX - 10 - cardWidth - margin, y: besideY), .left)
        }
        return (NSPoint(x: centredX, y: max(belowY, visible.minY - 40)), .below)
    }

    private func launch(to origin: NSPoint) {
        hasLaunched = true
        let size = Self.panelSize
        panel.setFrameOrigin(NSPoint(x: source.midX - size.width / 2, y: source.midY - size.height + Self.margin + 30))
        panel.orderFrontRegardless()
        withAnimation(.spring(response: 0.55, dampingFraction: 0.68)) { state.arrived = true }
        fly(to: origin, duration: 0.85, lift: 140)
    }

    private func departIntoNotch() {
        tracker.stop()
        guard let screen = panel.screen ?? NSScreen.main else { return finish() }
        let size = Self.panelSize
        let notch = NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height + Self.margin)
        withAnimation(.easeIn(duration: 0.42)) { state.departing = true }
        fly(to: notch, duration: 0.5, lift: 60) { [weak self] in self?.finish() }
    }

    private func fly(to origin: NSPoint, duration: TimeInterval, lift: CGFloat, completion: (() -> Void)? = nil) {
        flight?.cancel()
        let flight = GuideFlight(from: panel.frame.origin, to: origin, duration: duration, lift: lift) { [weak self] point in
            guard let self else { return }
            panel.setFrameOrigin(point)
            onMove?(panel.frame)
        } completion: { [weak self] in
            self?.flight = nil
            completion?()
        }
        self.flight = flight
        flight.start()
    }

    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        flight?.cancel()
        tracker.stop()
        pendingWork.forEach { $0.cancel() }
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        panel.orderOut(nil)
        onMove?(nil)
        onFinish?(state.isGranted)
    }

    private func schedule(after delay: TimeInterval, _ body: @escaping @MainActor () -> Void) {
        let work = DispatchWorkItem { MainActor.assumeIsolated(body) }
        pendingWork.append(work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

/// Moves a window origin along a lifted quadratic Bézier with a critically
/// damped progress curve, so the card arcs over and settles without a stop.
@MainActor
private final class GuideFlight {
    private let from: NSPoint
    private var to: NSPoint
    private let duration: TimeInterval
    private let lift: CGFloat
    private let step: (NSPoint) -> Void
    private let completion: () -> Void
    private var timer: Timer?
    private var startTime: CFTimeInterval = 0

    init(from: NSPoint, to: NSPoint, duration: TimeInterval, lift: CGFloat,
         step: @escaping (NSPoint) -> Void, completion: @escaping () -> Void) {
        self.from = from
        self.to = to
        self.duration = duration
        self.lift = lift
        self.step = step
        self.completion = completion
    }

    func start() {
        startTime = CACurrentMediaTime()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    func retarget(_ point: NSPoint) { to = point }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let elapsed = CACurrentMediaTime() - startTime
        guard elapsed < duration else {
            cancel()
            step(to)
            completion()
            return
        }
        let omega = 2 * Double.pi / (duration * 0.62)
        let t = CGFloat(min(1, 1 - exp(-omega * elapsed) * (1 + omega * elapsed)))
        let control = NSPoint(x: (from.x + to.x) / 2, y: max(from.y, to.y) + lift)
        let u = 1 - t
        step(NSPoint(x: u * u * from.x + 2 * u * t * control.x + t * t * to.x,
                     y: u * u * from.y + 2 * u * t * control.y + t * t * to.y))
    }
}

private final class PermissionGuidePanel: NSPanel {
    init(size: CGSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: Views

struct PermissionGuideView: View {
    struct Actions {
        let close: () -> Void
        let reopenSettings: () -> Void
        let relaunch: () -> Void
        let dragChanged: (Bool) -> Void
    }

    @ObservedObject var state: PermissionGuideState
    let actions: Actions

    private var appName: String {
        AppIcon.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if state.isGranted {
                grantedRow
                    .transition(.blurReplace)
            } else {
                AppDragTile(onDragChanged: actions.dragChanged)
                    .frame(height: 52)
                    .transition(.blurReplace)
            }
            if let advice = AppLocation.advice, !state.isGranted {
                locationRow(advice)
            }
            if state.showsRelaunch && !state.isGranted {
                relaunchRow
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(14)
        .frame(width: PermissionGuideController.cardWidth, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
        }
        .scaleEffect(state.departing ? 0.18 : (state.arrived ? 1 : 0.5), anchor: .top)
        .blur(radius: state.departing ? 6 : 0)
        .opacity(state.departing || !state.arrived ? 0 : 1)
        .padding(PermissionGuideController.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            GuideArrow(side: state.side, isDragging: state.isDragging, isGranted: state.isGranted)
            Text(title)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if !state.settingsFrontmost && !state.isGranted {
                iconButton("gearshape.fill", help: "Show System Settings", action: actions.reopenSettings)
                    .transition(.scale.combined(with: .opacity))
            }
            iconButton("xmark.circle.fill", help: "Close", action: actions.close)
        }
    }

    private var title: AttributedString {
        let permission = state.permission.title
        let markdown = state.isGranted
            ? "**\(permission)** is on. Thank you!"
            : "Drag **\(appName)** into the list \(listPlace), or switch it on, to allow **\(permission)**."
        return (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)
    }

    private var listPlace: String {
        switch state.side {
        case .below: "above"
        case .right: "on the left"
        case .left: "on the right"
        }
    }

    private var grantedRow: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppIcon.image)
                .resizable()
                .frame(width: 32, height: 32)
            Text(appName).font(.system(size: 13, weight: .semibold))
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: state.isGranted)
        }
        .padding(.horizontal, 10)
        .frame(height: 52)
        .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func locationRow(_ advice: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(advice)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if !AppLocation.isTranslocated {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
                .controlSize(.small)
            }
        }
    }

    private var relaunchRow: some View {
        HStack(spacing: 10) {
            Text("Already switched on? macOS applies it once \(appName) restarts.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Relaunch", action: actions.relaunch)
                .controlSize(.small)
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.primary, .secondary.opacity(0.3))
        }
        .buttonStyle(PressScaleStyle())
        .help(help)
    }
}

/// Points up at the list: a nervous wiggle while waiting, a slow pulse while
/// the icon is being dragged, a check once granted.
private struct GuideArrow: View {
    let side: PermissionGuideState.Side
    let isDragging: Bool
    let isGranted: Bool
    @State private var phase = false

    var body: some View {
        ZStack {
            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Image(systemName: "arrowshape.up.fill")
                    .foregroundStyle(.tint)
                    .rotationEffect(.degrees(isDragging ? 0 : (phase ? 10 : -10)))
                    .offset(y: isDragging ? (phase ? -3 : 1) : (phase ? -2 : 1))
                    .rotationEffect(.degrees(side == .below ? 0 : (side == .right ? -90 : 90)))
                    .scaleEffect(isDragging ? (phase ? 1.18 : 0.92) : 1)
                    .animation(.easeInOut(duration: isDragging ? 0.6 : 0.24).repeatForever(autoreverses: true),
                               value: phase)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .font(.system(size: 16, weight: .bold))
        .frame(width: 22, height: 22)
        .onAppear { phase = true }
        .onChange(of: isDragging) {
            phase = false
            DispatchQueue.main.async { phase = true }
        }
    }
}

/// XNotch's icon as a real file drag of the app bundle: what System Settings'
/// permission lists accept, exactly like dragging the app in from Finder.
private struct AppDragTile: NSViewRepresentable {
    let onDragChanged: (Bool) -> Void

    func makeNSView(context: Context) -> AppDragSourceView {
        let view = AppDragSourceView()
        view.onDragChanged = onDragChanged
        return view
    }

    func updateNSView(_ view: AppDragSourceView, context: Context) {
        view.onDragChanged = onDragChanged
    }
}

private final class AppDragSourceView: NSView, NSDraggingSource {
    var onDragChanged: ((Bool) -> Void)?
    private var mouseDownPoint: NSPoint?
    private let state = AppDragTileState()

    override init(frame: NSRect) {
        super.init(frame: frame)
        let host = NSHostingView(rootView: AppDragTileContent(state: state).allowsHitTesting(false))
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseEntered(with event: NSEvent) {
        withAnimation(KitMotion.content) { state.isHovered = true }
    }

    override func mouseExited(with event: NSEvent) {
        withAnimation(KitMotion.content) { state.isHovered = false }
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        withAnimation(KitMotion.press) { state.isPressed = true }
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownPoint = nil
        withAnimation(KitMotion.press) { state.isPressed = false }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 3 else { return }
        mouseDownPoint = nil

        let url = Bundle.main.bundleURL
        let item = NSDraggingItem(pasteboardWriter: AppBundlePasteboardWriter(url: url))
        item.setDraggingFrame(NSRect(x: point.x - 32, y: point.y - 32, width: 64, height: 64), contents: AppIcon.image)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        withAnimation(KitMotion.content) {
            state.isDragging = true
            state.isPressed = false
        }
        onDragChanged?(true)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        withAnimation(KitMotion.content) { state.isDragging = false }
        onDragChanged?(false)
    }
}

/// The payload Finder writes for a dragged app, which System Settings' lists
/// accept more reliably than a bare file URL.
private final class AppBundlePasteboardWriter: NSObject, NSPasteboardWriting {
    private let url: URL

    init(url: URL) {
        self.url = url
    }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [.fileURL, .URL, NSPasteboard.PasteboardType("NSFilenamesPboardType"), .string]
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case .fileURL, .URL: url.absoluteString
        case NSPasteboard.PasteboardType("NSFilenamesPboardType"): [url.path]
        case .string: url.path
        default: nil
        }
    }
}

@MainActor
private final class AppDragTileState: ObservableObject {
    @Published var isHovered = false
    @Published var isPressed = false
    @Published var isDragging = false
}

private struct AppDragTileContent: View {
    @ObservedObject var state: AppDragTileState
    @State private var nudge = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppIcon.image)
                .resizable()
                .frame(width: 34, height: 34)
                .offset(y: nudge && !state.isDragging ? -3 : 0)
                .opacity(state.isDragging ? 0.35 : 1)
            Text(AppIcon.name)
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
            VStack(spacing: 1) {
                Image(systemName: "hand.draw")
                    .font(.system(size: 14))
                Text("Drag")
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.background.opacity(state.isHovered ? 0.95 : 0.7))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.primary.opacity(state.isDragging ? 0.25 : 0.09),
                                      style: StrokeStyle(lineWidth: 1, dash: state.isDragging ? [4, 3] : []))
                }
        }
        .scaleEffect(state.isPressed ? 0.97 : 1)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true).delay(0.4)) { nudge = true }
        }
    }
}

/// Where XNotch is running from. Dragging the app into a permission list puts
/// its bundle on the pasteboard, so a bundle inside a protected folder makes
/// macOS ask for that folder first; a quarantined download runs from a
/// temporary copy that a permission wouldn't stick to.
@MainActor
enum AppLocation {
    static var isTranslocated: Bool { Bundle.main.bundlePath.contains("/AppTranslocation/") }

    /// The protected folder the bundle sits in, if any.
    static var protectedFolder: String? {
        let path = Bundle.main.bundlePath
        let home = NSHomeDirectory()
        let folders = [("Documents", "Documents"), ("Desktop", "Desktop"), ("Downloads", "Downloads"),
                       ("Library/Mobile Documents", "iCloud Drive")]
        return folders.first { path.hasPrefix("\(home)/\($0.0)/") }?.1
    }

    /// One sentence for the guide, or nil when the app is somewhere safe.
    static var advice: String? {
        if isTranslocated {
            return "Move \(AppIcon.name) to Applications and open it from there first. macOS runs downloaded apps from a temporary copy, and the permission wouldn't stick."
        }
        guard let folder = protectedFolder else { return nil }
        return "\(AppIcon.name) is running from \(folder), so macOS will ask about that folder when you drag it. Move it to Applications to skip that."
    }
}
