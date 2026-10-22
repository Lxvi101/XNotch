import AppKit
import SwiftUI

let noteAccent = Color(nsColor: MarkdownTheme.accent)
private let noteShape = RoundedRectangle(cornerRadius: NoteGeometry.cornerRadius, style: .continuous)
private let noteSpace = "note"

/// The note in its window. Every piece reads only the state it draws, so a
/// hover redraws the chrome and a keystroke redraws the title and count.
struct NoteRootView: View {
    let controller: NoteController
    let state: NoteWindowState

    var body: some View {
        ZStack(alignment: .topLeading) {
            NoteSurface(state: state)
            EditorLayer(controller: controller, state: state)
            NoteHeader(controller: controller, state: state)
            CharacterCount(controller: controller, state: state)
            ResizeGrip(controller: controller)
            BucketLayer(controller: controller, state: state)
            SwitcherLayer(controller: controller, state: state)
            LandingLayer(state: state)
            MentionPopover(state: state, controller: controller)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .coordinateSpace(name: noteSpace)
        .clipShape(noteShape)
        .background { NoteShadow() }
        .padding(NoteGeometry.margin)
    }
}

// MARK: Surface

/// Mote's glass: near-black at the top, thinning to frosted grey below.
private struct NoteSurface: View {
    let state: NoteWindowState

    var body: some View {
        let target = state.isDragTarget
        ZStack {
            VisualEffect()
            LinearGradient(stops: [.init(color: .black.opacity(0.94), location: 0),
                                   .init(color: .black.opacity(0.78), location: 0.32),
                                   .init(color: .black.opacity(0.42), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            noteShape.strokeBorder(target ? noteAccent.opacity(0.9) : .white.opacity(0.11), lineWidth: target ? 1.6 : 1)
        }
        .animation(NoteMotion.hover, value: target)
    }
}

/// The shadow, only outside the note so it never shows through the glass.
private struct NoteShadow: View {
    var body: some View {
        noteShape
            .fill(.black.opacity(0.42))
            .blur(radius: 14)
            .offset(y: 8)
            .mask {
                ZStack {
                    Rectangle().padding(-NoteGeometry.margin)
                    noteShape.blendMode(.destinationOut)
                }
                .compositingGroup()
            }
            .allowsHitTesting(false)
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// MARK: Editor

/// The text, receding behind the bucket and the switcher as they open.
private struct EditorLayer: View {
    let controller: NoteController
    let state: NoteWindowState

    var body: some View {
        // Dimmed and blurred behind the bucket by the editor itself (see
        // MarkdownEditor.setFocus): SwiftUI effects here would re-host the
        // text view and lose its scroll position.
        EditorHost(editor: controller.editor)
            // Text scrolling up fades out under the header, as in Mote, instead of being cut.
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 12)
                    Color.black
                }
            }
            .padding(.top, NoteGeometry.header - 6)
    }
}

private struct EditorHost: NSViewRepresentable {
    let editor: MarkdownEditor

    func makeNSView(context: Context) -> NSScrollView { editor.scrollView }
    func updateNSView(_ view: NSScrollView, context: Context) {}
}

// MARK: Header

private struct NoteHeader: View {
    let controller: NoteController
    let state: NoteWindowState

    var body: some View {
        let chrome = state.isHovered || state.receded
        ZStack {
            MoveArea(controller: controller)
            NoteTitle(controller: controller)
                .padding(.horizontal, 96)
                .allowsHitTesting(false)
            HStack(spacing: 0) {
                CloseButton { controller.close() }
                    .opacity(chrome ? 1 : 0)
                    .scaleEffect(chrome ? 1 : 0.8)
                Spacer(minLength: 0)
                Toolbar(controller: controller, state: state, isVisible: chrome)
            }
            .padding(.horizontal, 9)
        }
        .frame(height: NoteGeometry.header)
        .animation(NoteMotion.hover, value: chrome)
    }
}

private struct NoteTitle: View {
    let controller: NoteController

    var body: some View {
        let position = controller.state.positionLabel
        let space = controller.spaceName
        (Text(position ?? controller.note.displayTitle)
            .foregroundStyle(position == nil ? .white.opacity(0.42) : noteAccent.opacity(0.9))
         + Text(position == nil && space != nil ? "  ·  \(space!)" : "")
            .foregroundStyle(.white.opacity(0.24)))
            .font(.system(size: 12.5, weight: .medium).monospacedDigit())
            .lineLimit(1)
            .truncationMode(.tail)
            .contentTransition(.opacity)
            .animation(NoteMotion.content, value: controller.note.id)
    }
}

private struct CloseButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(hovered ? 0.92 : 0.6))
                .frame(width: 24, height: 24)
                .background(Circle().fill(.white.opacity(hovered ? 0.16 : 0.09)))
                .overlay(Circle().strokeBorder(.white.opacity(0.07)))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovered = $0 }
        .animation(NoteMotion.hover, value: hovered)
        .help("Close note (⌘W)")
    }
}

/// Mote's capsule of buttons: the bucket, the switcher and a new note. The
/// bucket stays when the rest fade, while it holds files.
private struct Toolbar: View {
    let controller: NoteController
    let state: NoteWindowState
    let isVisible: Bool

    var body: some View {
        let note = controller.note
        let count = note.attachments.count
        let bucketShown = isVisible || count > 0 || state.isDragTarget
        HStack(spacing: 0) {
            BucketButton(state: state, count: count) { controller.toggleBucket() }
                .opacity(bucketShown ? 1 : 0)
            ToolbarButton(symbol: "doc.text.magnifyingglass", isOn: state.showsSwitcher, help: "Find a note (⌘K)") {
                controller.toggleSwitcher()
            }
            .opacity(isVisible ? 1 : 0)
            ToolbarButton(symbol: "plus", isOn: false, help: "New note (⌘N)") { controller.newNote() }
                .background {
                    GeometryReader { proxy in
                        Color.clear.onAppear {
                            let frame = proxy.frame(in: .named(noteSpace))
                            state.plusCenter = CGPoint(x: frame.midX, y: frame.midY)
                        }
                        .onChange(of: proxy.frame(in: .named(noteSpace))) { _, frame in
                            state.plusCenter = CGPoint(x: frame.midX, y: frame.midY)
                        }
                    }
                }
                .opacity(isVisible ? 1 : 0)
        }
        .padding(.horizontal, 3)
        .frame(height: 26)
        .background {
            Capsule().fill(.white.opacity(0.08))
                .overlay(Capsule().strokeBorder(.white.opacity(0.07)))
                .opacity(isVisible ? 1 : 0)
        }
    }
}

private struct ToolbarButton: View {
    let symbol: String
    let isOn: Bool
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(isOn ? 0.95 : (hovered ? 0.9 : 0.6)))
                .frame(width: 26, height: 22)
                .background(Capsule().fill(.white.opacity(isOn ? 0.14 : (hovered ? 0.08 : 0))))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovered = $0 }
        .animation(NoteMotion.hover, value: hovered)
        .animation(NoteMotion.hover, value: isOn)
        .help(help)
    }
}

/// The bucket: swells and warms while files hover over the note, and
/// flinches as each one lands, its handle swinging.
private struct BucketButton: View {
    let state: NoteWindowState
    let count: Int
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        let target = state.isDragTarget
        let open = state.showsBucket
        Button(action: action) {
            HStack(spacing: 3) {
                BucketIcon(hits: state.bucketHits)
                    .foregroundStyle(target || open ? noteAccent : .white.opacity(hovered ? 0.9 : 0.62))
                    .frame(width: 15, height: 15)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(target || open ? noteAccent : .white.opacity(0.62))
                        .contentTransition(.numericText(value: Double(count)))
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .padding(.horizontal, count > 0 ? 7 : 5.5)
            .frame(height: 22)
            .background(Capsule().fill(noteAccent.opacity(target ? 0.22 : 0)).blur(radius: target ? 0 : 4))
            .background(Capsule().fill(.white.opacity(open ? 0.14 : (hovered ? 0.08 : 0))))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .scaleEffect(target ? 1.18 : 1)
        .onHover { hovered = $0 }
        .animation(NoteMotion.hover, value: hovered)
        .animation(NoteMotion.bloom, value: target)
        .animation(NoteMotion.content, value: count)
        .background {
            GeometryReader { proxy in
                // The pail's middle, not the button's: the count sits beside it.
                Color.clear.onAppear {
                    let frame = proxy.frame(in: .named(noteSpace))
                    state.bucketCenter = CGPoint(x: frame.minX + 13, y: frame.midY)
                }
                .onChange(of: proxy.frame(in: .named(noteSpace))) { _, frame in
                    state.bucketCenter = CGPoint(x: frame.minX + 13, y: frame.midY)
                }
            }
        }
        .help("Bucket: files kept with this note (⇧⌘B)")
    }
}

/// A pail with a handle, drawn: SF Symbols has no bucket.
struct BucketIcon: View {
    let hits: Int

    var body: some View {
        ZStack {
            BucketHandle()
                .stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                .keyframeAnimator(initialValue: 0.0, trigger: hits) { content, angle in
                    content.rotationEffect(.degrees(angle), anchor: UnitPoint(x: 0.5, y: 0.36))
                } keyframes: { _ in
                    KeyframeTrack {
                        SpringKeyframe(NoteMotion.reduced ? 0 : 26, duration: 0.09)
                        SpringKeyframe(0, duration: 0.7, spring: .init(response: 0.42, dampingRatio: 0.38))
                    }
                }
            BucketBody()
                .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        // The hit squashes it a little along its height, and it springs back.
        .keyframeAnimator(initialValue: CGFloat(1), trigger: hits) { content, squash in
            content.scaleEffect(x: 1 + (1 - squash) * 0.6, y: squash, anchor: .bottom)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(NoteMotion.reduced ? 1 : 0.8, duration: 0.07)
                SpringKeyframe(1, duration: 0.5, spring: .init(response: 0.3, dampingRatio: 0.5))
            }
        }
    }
}

private struct BucketBody: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()
        let top = rect.minY + h * 0.36
        let bottom = rect.minY + h * 0.95
        path.move(to: CGPoint(x: rect.minX + w * 0.08, y: top))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.2, y: bottom - h * 0.06))
        path.addQuadCurve(to: CGPoint(x: rect.minX + w * 0.3, y: bottom), control: CGPoint(x: rect.minX + w * 0.215, y: bottom))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.7, y: bottom))
        path.addQuadCurve(to: CGPoint(x: rect.minX + w * 0.8, y: bottom - h * 0.06), control: CGPoint(x: rect.minX + w * 0.785, y: bottom))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.92, y: top))
        path.closeSubpath()
        return path
    }
}

private struct BucketHandle: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + w * 0.12, y: rect.minY + h * 0.36))
        path.addCurve(to: CGPoint(x: rect.minX + w * 0.88, y: rect.minY + h * 0.36),
                      control1: CGPoint(x: rect.minX + w * 0.14, y: rect.minY - h * 0.08),
                      control2: CGPoint(x: rect.minX + w * 0.86, y: rect.minY - h * 0.08))
        return path
    }
}

// MARK: Count and grip

private struct CharacterCount: View {
    let controller: NoteController
    let state: NoteWindowState

    var body: some View {
        Text(controller.note.characterCount.formatted())
            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.24))
            .contentTransition(.numericText())
            .padding(.trailing, 16)
            .padding(.bottom, 11)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .opacity(state.receded ? 0 : 1)
            .allowsHitTesting(false)
    }
}

private struct ResizeGrip: View {
    let controller: NoteController

    var body: some View {
        ResizeArea(controller: controller)
            .frame(width: 18, height: 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }
}

// MARK: Landings

/// Files flying from where they were dropped into the bucket, in an arc,
/// shrinking as they go in.
private struct LandingLayer: View {
    let state: NoteWindowState

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(state.landings) { landing in
                LandingView(landing: landing, end: state.bucketCenter)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

private struct LandingView: View {
    let landing: NoteWindowState.Landing
    let end: CGPoint
    @State private var progress: CGFloat = 0

    var body: some View {
        Image(nsImage: landing.image)
            .resizable()
            .interpolation(.high)
            .frame(width: 44, height: 44)
            .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
            .modifier(Flight(start: landing.start, end: end, progress: progress))
            .onAppear {
                withAnimation(NoteMotion.reduced ? .easeOut(duration: 0.05)
                              : .spring(response: 0.42, dampingFraction: 0.9).delay(landing.delay)) { progress = 1 }
            }
    }
}

private struct Flight: ViewModifier, Animatable {
    let start: CGPoint
    let end: CGPoint
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = min(max(progress, 0), 1.05)
        let x = start.x + (end.x - start.x) * p
        // Lifted on the way, as if tossed, more for a longer throw.
        let lift = sin(min(p, 1) * .pi) * min(60, abs(end.x - start.x) * 0.25 + 20)
        let y = start.y + (end.y - start.y) * p - lift
        content
            .scaleEffect(1 - 0.72 * min(p, 1))
            .blur(radius: p > 0.85 ? (p - 0.85) * 12 : 0)
            .opacity(p > 0.8 ? Double(max(0, 1 - (p - 0.8) / 0.2)) : 1)
            .position(x: x, y: y)
    }
}

// MARK: Bucket

private struct BucketLayer: View {
    let controller: NoteController
    let state: NoteWindowState

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if state.showsBucket {
                    // A click beside the drawer folds it away.
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { controller.toggleBucket() }
                    let width = proxy.size.width - 20
                    BucketDrawer(controller: controller, state: state)
                        .frame(width: width)
                        .frame(maxHeight: proxy.size.height - NoteGeometry.header - 12, alignment: .top)
                        .fixedSize(horizontal: false, vertical: true)
                        .offset(x: 10, y: NoteGeometry.header)
                        .transition(.bloom(from: UnitPoint(x: (state.bucketCenter.x - 10) / max(width, 1), y: -0.04)))
                }
            }
        }
    }
}

/// The bucket opened: every file kept with the note.
private struct BucketDrawer: View {
    let controller: NoteController
    let state: NoteWindowState
    @State private var revealed = false

    var body: some View {
        let note = controller.note
        let files = note.attachments
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Bucket")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                if !files.isEmpty {
                    Text("\(files.count) · \(Attachments.formatted(note.attachmentsSize))")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.4))
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 0)
                ToolbarButton(symbol: "plus", isOn: false, help: "Add files…") { controller.addFilesWithPanel() }
                ToolbarButton(symbol: "folder", isOn: false, help: "Show in Finder") { controller.revealBucket() }
            }
            if files.isEmpty {
                VStack(spacing: 8) {
                    BucketIcon(hits: state.bucketHits)
                        .foregroundStyle(.white.opacity(0.3))
                        .frame(width: 30, height: 30)
                    Text("Drop files on the note to keep them here.")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 70, maximum: 90), spacing: 4)], spacing: 4) {
                        ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                            AttachmentTile(controller: controller, state: state, attachment: file)
                                .scaleEffect(revealed ? 1 : 0.6)
                                .blur(radius: revealed ? 0 : 4)
                                .opacity(revealed ? 1 : 0)
                                .animation(NoteMotion.bloom.delay(NoteMotion.reduced ? 0 : Double(min(index, 12)) * 0.018),
                                           value: revealed)
                                .transition(.scale(scale: 0.5).combined(with: .opacity))
                        }
                    }
                    .padding(.bottom, 2)
                }
                .frame(maxHeight: 280)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(white: 0.13).opacity(0.92))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.1)))
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        }
        .onAppear { revealed = true }
    }
}

private struct AttachmentTile: View {
    let controller: NoteController
    let state: NoteWindowState
    let attachment: Attachment
    @State private var hovered = false
    @State private var image: NSImage?

    var body: some View {
        let selected = state.selectedAttachment == attachment.id
        VStack(spacing: 4) {
            Image(nsImage: image ?? Thumbnails.image(for: attachment.path))
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 42, height: 42)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1.5)
            Text(attachment.name)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(selected ? 1 : 0.78))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .frame(height: 28, alignment: .top)
        }
        .padding(.top, 7)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(selected ? noteAccent.opacity(0.24) : .white.opacity(hovered ? 0.07 : 0))
        }
        .overlay(AttachmentItemArea(controller: controller, attachment: attachment))
        .onHover { hovered = $0 }
        .animation(NoteMotion.hover, value: hovered)
        .animation(NoteMotion.hover, value: selected)
        .task(id: attachment.path) {
            guard image == nil else { return }
            if let thumbnail = await Thumbnails.thumbnail(for: attachment.path) {
                withAnimation(NoteMotion.hover) { image = thumbnail }
            }
        }
    }
}

// MARK: Transitions

/// Opens out of a point, coming into focus; folds back into it.
private struct Bloom: ViewModifier {
    let amount: CGFloat
    let anchor: UnitPoint

    func body(content: Content) -> some View {
        content
            .scaleEffect(1 - 0.85 * amount, anchor: anchor)
            .blur(radius: 8 * amount)
            .opacity(1 - Double(amount))
    }
}

extension AnyTransition {
    static func bloom(from anchor: UnitPoint) -> AnyTransition {
        NoteMotion.reduced ? .opacity
            : .modifier(active: Bloom(amount: 1, anchor: anchor), identity: Bloom(amount: 0, anchor: anchor))
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.9), value: configuration.isPressed)
    }
}

// MARK: AppKit areas

/// The header's empty space moves the note; a right-click opens its menu.
private struct MoveArea: NSViewRepresentable {
    let controller: NoteController

    func makeNSView(context: Context) -> MoveAreaView {
        let view = MoveAreaView()
        view.controller = controller
        return view
    }

    func updateNSView(_ view: MoveAreaView, context: Context) { view.controller = controller }
}

final class MoveAreaView: NSView {
    weak var controller: NoteController?
    private var start: (mouse: CGPoint, origin: CGPoint)?
    private var moved = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        start = (NSEvent.mouseLocation, window.frame.origin)
        moved = false
        MainActor.assumeIsolated { controller?.beginMove() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let mouse = NSEvent.mouseLocation
        let delta = CGPoint(x: mouse.x - start.mouse.x, y: mouse.y - start.mouse.y)
        if !moved, hypot(delta.x, delta.y) < 2 { return }
        moved = true
        MainActor.assumeIsolated { controller?.move(to: CGPoint(x: start.origin.x + delta.x, y: start.origin.y + delta.y)) }
    }

    override func mouseUp(with event: NSEvent) {
        defer { start = nil }
        MainActor.assumeIsolated {
            if moved {
                controller?.endMove()
            } else {
                controller?.editor.focus(atEnd: false)
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            guard let controller else { return }
            NSMenu.popUpContextMenu(controller.noteMenu(), with: event, for: self)
        }
    }
}

/// The bottom-right corner resizes the note.
private struct ResizeArea: NSViewRepresentable {
    let controller: NoteController

    func makeNSView(context: Context) -> ResizeAreaView {
        let view = ResizeAreaView()
        view.controller = controller
        return view
    }

    func updateNSView(_ view: ResizeAreaView, context: Context) { view.controller = controller }
}

final class ResizeAreaView: NSView {
    weak var controller: NoteController?
    private var start: (mouse: CGPoint, frame: CGRect)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: Self.cursor)
    }

    private static let cursor: NSCursor = {
        if #available(macOS 15, *) {
            return NSCursor.frameResize(position: .bottomRight, directions: .all)
        }
        return NSCursor.crosshair
    }()

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        start = (NSEvent.mouseLocation, NoteGeometry.noteFrame(inWindow: window.frame))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let mouse = NSEvent.mouseLocation
        MainActor.assumeIsolated {
            controller?.resize(from: start.frame, by: CGSize(width: mouse.x - start.mouse.x, height: mouse.y - start.mouse.y))
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard start != nil else { return }
        start = nil
        MainActor.assumeIsolated { controller?.endMove() }
    }
}

/// A file in the bucket: click to select (space for Quick Look),
/// double-click to open, drag out for a copy, right-click for its menu.
private struct AttachmentItemArea: NSViewRepresentable {
    let controller: NoteController
    let attachment: Attachment

    func makeNSView(context: Context) -> AttachmentItemView {
        let view = AttachmentItemView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: AttachmentItemView, context: Context) {
        view.controller = controller
        view.attachment = attachment
    }
}

final class AttachmentItemView: NSView {
    weak var controller: NoteController?
    var attachment: Attachment?
    private var down: NSEvent?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        down = event
        guard let attachment else { return }
        if event.clickCount == 2 {
            down = nil
            NSWorkspace.shared.open(attachment.url)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { down = nil }
        guard down?.clickCount == 1, let attachment else { return }
        MainActor.assumeIsolated {
            guard let state = controller?.state else { return }
            state.selectedAttachment = state.selectedAttachment == attachment.id ? nil : attachment.id
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = down, let attachment else { return }
        guard hypot(event.locationInWindow.x - start.locationInWindow.x,
                    event.locationInWindow.y - start.locationInWindow.y) > 3 else { return }
        down = nil
        MainActor.assumeIsolated { controller?.beginDrag(attachment, event: event, from: self) }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let attachment else { return }
        MainActor.assumeIsolated {
            guard let controller else { return }
            controller.state.selectedAttachment = attachment.id
            NSMenu.popUpContextMenu(controller.menu(for: attachment), with: event, for: self)
        }
    }
}
