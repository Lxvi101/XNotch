import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XNotchKit

// MARK: State

/// What the menu bar faces are doing. The status item feeds it pointer and
/// drag state; the views draw from it.
@MainActor
final class MenuBarModel: ObservableObject {
    /// The pointer is over the strip: the stacked faces fan out.
    @Published var hovering = false
    /// The face under the pointer: it gets the name pill.
    @Published var hovered: String?
    /// The face a file is being dragged onto.
    @Published var dropTarget: String?
    /// The pointer during a file drag, in the drop view's coordinates.
    @Published var dropPoint: CGPoint?
    /// Files just went to this face.
    @Published var dropped: String?
    /// The drag left: the drop panel is playing its way out.
    @Published var dropLeaving = false
    /// Incoming messages already shown; newer ones arrive blurred and tinted, then come into focus.
    @Published var revealed: Set<String> = []
}

/// Where things sit across the panel window, from the controller.
@MainActor
final class PanelGeometry: ObservableObject {
    /// The open or hovered face, across the panel (0…1).
    @Published var anchorX: CGFloat = 0.5
    /// Every face's centre, in panel points: the drop panel glides between them.
    @Published var faceX: [String: CGFloat] = [:]
}

/// The composer of the open conversation: what you're writing, the files
/// waiting to go, and a voice note being recorded or reviewed.
@MainActor
final class ComposerState: ObservableObject {
    enum Phase: Equatable { case idle, recording, review }

    @Published var text = ""
    @Published var files: [URL] = []
    @Published var phase: Phase = .idle
    @Published var take: VoiceRecorder.Take?
    /// Started by holding a face: letting go sends it straight away.
    var holdToTalk = false
    private(set) var box: String?

    var canSend: Bool {
        phase == .review || !files.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A different face: start fresh.
    func prepare(for box: String) {
        guard self.box != box else { return }
        self.box = box
        text = ""
        files = []
        phase = .idle
        take = nil
    }
}

/// The composer's buttons, carried out by the menu bar controller.
struct ComposerActions {
    var send: () -> Void
    var record: () -> Void
    var stop: () -> Void
    var discard: () -> Void
    var attach: () -> Void
    var screenshot: () -> Void
    var removeFile: (URL) -> Void
    var playTake: () -> Void
}

// MARK: Layout

/// Where the faces sit in the strip; the AppKit hit testing uses the same numbers.
/// The faces overlap in a row of fixed width. The face in focus gets room on
/// both sides and the others close up to pay for it, so focus travels along
/// the row without the row ever changing width.
enum MenuBarLayout {
    static func faceSize(barHeight: CGFloat) -> CGFloat { min(26, max(18, barHeight - 5)) }

    /// From one face's centre to the next beside the focused face: no overlap, a hair of air.
    private static func clearPitch(_ face: CGFloat) -> CGFloat { face + 3 }

    /// The row's span, first centre to last: room for one face in focus mid-row.
    static func span(count: Int, barHeight: CGFloat) -> CGFloat {
        let face = faceSize(barHeight: barHeight)
        guard count > 1 else { return 0 }
        let links = CGFloat(count - 1)
        let clear = min(2, links)
        return clear * clearPitch(face) + (links - clear) * face * 0.5
    }

    static func width(count: Int, barHeight: CGFloat) -> CGFloat {
        span(count: count, barHeight: barHeight) + faceSize(barHeight: barHeight) + 10
    }

    static func centers(count: Int, barHeight: CGFloat, focus: Int?) -> [CGFloat] {
        guard count > 0 else { return [] }
        let face = faceSize(barHeight: barHeight)
        let span = span(count: count, barHeight: barHeight)
        let links = count - 1
        var pitches = Array(repeating: links > 0 ? span / CGFloat(links) : 0, count: max(0, links))
        if let focus, links > 0 {
            // The links touching the focused face open up; the rest share what's left.
            let open = Set([focus - 1, focus].filter { (0..<links).contains($0) })
            let rest = links - open.count
            let tight = rest > 0 ? (span - CGFloat(open.count) * clearPitch(face)) / CGFloat(rest) : 0
            for index in 0..<links { pitches[index] = open.contains(index) ? clearPitch(face) : max(face * 0.3, tight) }
        }
        var x = (width(count: count, barHeight: barHeight) - pitches.reduce(0, +)) / 2
        var centers: [CGFloat] = []
        for index in 0..<count {
            centers.append(x)
            if index < pitches.count { x += pitches[index] }
        }
        return centers
    }

    /// The face nearest `x`, as the row is laid out with `focus` in focus.
    static func face(at x: CGFloat, count: Int, barHeight: CGFloat, focus: Int?) -> Int? {
        let centers = centers(count: count, barHeight: barHeight, focus: focus)
        guard let nearest = centers.enumerated().min(by: { abs($0.element - x) < abs($1.element - x) }) else { return nil }
        return abs(nearest.element - x) <= faceSize(barHeight: barHeight) * 0.75 ? nearest.offset : nil
    }
}

/// Timings measured frame by frame from the reference.
/// Every curve is a critically damped or lightly bouncy spring (or a long ease-out),
/// so motion starts quickly, settles softly and picks up from wherever it is when
/// something interrupts it.
enum MenuBarMotion {
    /// The panel settling in under the menu bar.
    static let panelIn = Animation.smooth(duration: 0.42, extraBounce: 0.04)
    /// The panel going: quicker than it came, no bounce.
    static let panelOut = Animation.smooth(duration: 0.26)
    /// A sent bubble popping into place, and the composer making room.
    static let pop = Animation.smooth(duration: 0.46, extraBounce: 0.12)
    /// The conversation making room and gliding up to a new message. No bounce:
    /// a scroll that overshoots its end reads as a jolt.
    static let follow = Animation.smooth(duration: 0.42)
    /// The composer changing between writing, recording and reviewing.
    static let morph = Animation.smooth(duration: 0.44, extraBounce: 0.06)
    static let crossfade = Animation.easeInOut(duration: 0.22)
    /// A new message coming into focus: an ease-out-quint, long and gentle at the end.
    static let reveal = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.8)
    /// The drop panel gliding to the next face.
    static let glide = Animation.smooth(duration: 0.48, extraBounce: 0.08)
    /// The drop panel growing out of a blob under the face.
    static let grow = Animation.smooth(duration: 0.5, extraBounce: 0.14)
    /// Focus moving along the faces, and the rings that follow it.
    static let focus = Animation.smooth(duration: 0.42, extraBounce: 0.1)
    /// Hover and small state changes: buttons, labels, rings.
    static let hover = Animation.smooth(duration: 0.28)
}

// MARK: Strip

/// The faces in the menu bar: evenly spaced, the open one ringed.
struct MenuBarFaces: View {
    @ObservedObject var store: WalkieStore
    @ObservedObject var model: MenuBarModel
    @ObservedObject var ui: WalkieUI
    @ObservedObject var player: VoicePlayer
    let barHeight: CGFloat

    private var people: [Contact] { store.stripPeople }

    private var open: String? {
        if let target = model.dropTarget { return target }
        if case .chat(let box) = ui.panel { return box }
        return nil
    }

    var body: some View {
        let people = people
        let focused = model.dropTarget ?? model.hovered ?? open
        let focus = focused.flatMap { box in people.firstIndex { $0.box == box } }
        let centers = MenuBarLayout.centers(count: people.count, barHeight: barHeight, focus: focus)
        let face = MenuBarLayout.faceSize(barHeight: barHeight)
        ZStack(alignment: .topLeading) {
            ForEach(Array(people.enumerated()), id: \.element.box) { index, contact in
                MenuBarFace(contact: contact, size: face, isOpen: open == contact.box && focused == contact.box,
                            isTarget: focused == contact.box && open != contact.box, store: store, ui: ui,
                            player: player, dropped: model.dropped == contact.box)
                    .scaleEffect(focused == contact.box ? 1.1 : 1)
                    .position(x: centers[index], y: barHeight / 2)
                    // Later faces sit on earlier ones; the focused face on top of all.
                    .zIndex(focused == contact.box ? 100 : Double(index))
            }
        }
        .frame(width: MenuBarLayout.width(count: people.count, barHeight: barHeight), height: barHeight)
        // Focus sliding along the row: a soft spring with a little give.
        .animation(MenuBarMotion.focus, value: focused)
    }
}

private struct MenuBarFace: View {
    let contact: Contact
    let size: CGFloat
    let isOpen: Bool
    /// A file hovers this face: a white ring.
    let isTarget: Bool
    @ObservedObject var store: WalkieStore
    @ObservedObject var ui: WalkieUI
    @ObservedObject var player: VoicePlayer
    let dropped: Bool

    private var playing: Double? {
        guard let id = player.playing, store.chats[contact.box]?.contains(where: { $0.id == id }) == true else { return nil }
        return player.progress
    }

    var body: some View {
        ZStack {
            if store.talking.contains(contact.box) {
                TalkingRipples(color: .white)
            }
            FaceImage(name: contact.name, seed: contact.box, avatar: contact.avatar)
            // The rings stay in the tree and fade and tighten in, rather than snapping on.
            ZStack {
                // A dark ring with a fine light edge, as the open face wears.
                Circle().strokeBorder(.black.opacity(0.85), lineWidth: 2.2)
                Circle().strokeBorder(.white.opacity(0.55), lineWidth: 0.8).padding(-1)
            }
            .opacity(isOpen ? 1 : 0)
            .scaleEffect(isOpen ? 1 : 1.18)
            Circle().strokeBorder(.white, lineWidth: 2).padding(-2.5)
                .opacity(isTarget ? 1 : 0)
                .scaleEffect(isTarget ? 1 : 1.22)
            if let playing {
                PlaybackRing(progress: playing).padding(-2)
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .topTrailing) {
            if dropped || ui.sendBadges[contact.box] != nil {
                SendBadge(failed: ui.sendBadges[contact.box] == true).scaleEffect(0.6).offset(x: 6, y: -6)
            } else if (store.unread[contact.box] ?? 0) > 0 {
                // Unread: the red dot macOS uses for notifications, with a thin dark
                // ring so it stays apart from the face on any menu bar.
                Circle().fill(Color(nsColor: .systemRed)).frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(.black.opacity(0.55), lineWidth: 1))
                    .offset(x: 2, y: -2)
                    .transition(.scale(scale: 0.2).combined(with: .opacity))
            }
        }
        .animation(MenuBarMotion.focus, value: isOpen)
        .animation(MenuBarMotion.focus, value: isTarget)
        .animation(MenuBarMotion.pop, value: store.unread[contact.box] ?? 0)
    }
}

/// "Mira · 1d ago", or "Mira" and a green dot while they're online.
struct NamePill: View {
    let contact: Contact
    @ObservedObject var store: WalkieStore

    var body: some View {
        HStack(spacing: 5) {
            Text(contact.box == WalkieStore.selfBox ? "You" : contact.firstName).fontWeight(.semibold)
            if store.online.contains(contact.box) {
                Circle().fill(KitStyle.green).frame(width: 6, height: 6)
            } else if let seen = store.lastSeen[contact.box] {
                Text("· \(Self.ago(seen))").foregroundStyle(.white.opacity(0.6))
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background { PanelGlass(shape: Capsule(), tone: .dark) }
        .fixedSize()
    }

    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m ago"
        case ..<86_400: return "\(Int(seconds / 3600))h ago"
        default: return "\(Int(seconds / 86_400))d ago"
        }
    }
}

// MARK: Glass

private struct GlassFallbackKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Draws glass as a flat tint, for renderers that can't see behind the window.
    var walkieGlassFallback: Bool {
        get { self[GlassFallbackKey.self] }
        set { self[GlassFallbackKey.self] = newValue }
    }
}

/// XNotch's glass in three depths: the composer, your bubbles (dark) and
/// theirs (lighter, the desktop showing more).
struct PanelGlass<S: InsettableShape>: View {
    enum Tone { case composer, dark, light }

    let shape: S
    var tone: Tone = .composer
    var tint: Color?
    @Environment(\.walkieGlassFallback) private var fallback

    var body: some View {
        if fallback {
            ZStack {
                shape.fill(flat)
                if let tint { shape.fill(tint.opacity(0.25)) }
                shape.strokeBorder(.white.opacity(0.14), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
        } else {
            KitGlass(shape: shape, tint: tint, shade: shade)
                .shadow(color: .black.opacity(0.22), radius: 10, y: 5)
        }
    }

    private var shade: Double {
        switch tone {
        case .composer: 0.45
        case .dark: 0.6
        case .light: 0.18
        }
    }

    private var flat: Color {
        switch tone {
        case .composer: Color(red: 0.13, green: 0.12, blue: 0.13).opacity(0.94)
        case .dark: Color(white: 0.06).opacity(0.92)
        case .light: Color(white: 0.42).opacity(0.9)
        }
    }
}

// MARK: Panel

/// Everything under the menu bar: the name pill on hover, the floating
/// conversation once a face is open, the drop field while a file hovers a face.
struct MenuBarPanelView: View {
    @ObservedObject var store: WalkieStore
    @ObservedObject var model: MenuBarModel
    @ObservedObject var ui: WalkieUI
    @ObservedObject var composer: ComposerState
    let actions: ComposerActions
    @ObservedObject var geometry: PanelGeometry

    var body: some View {
        GeometryReader { proxy in
            let faceX = proxy.size.width * geometry.anchorX
            ZStack(alignment: .top) {
                if let box = model.dropTarget, let contact = store.stripContact(box) {
                    // One panel for the whole drag: it glides under each face it targets.
                    let size = DropPanel.size
                    let x = min(max(geometry.faceX[box] ?? faceX, size.width / 2 + 8), proxy.size.width - size.width / 2 - 8)
                    let origin = CGPoint(x: x - size.width / 2, y: 0)
                    DropPanel(contact: contact, point: model.dropPoint.map { CGPoint(x: $0.x - origin.x, y: $0.y) },
                              leaving: model.dropLeaving)
                        .position(x: x, y: size.height / 2)
                        .animation(MenuBarMotion.glide, value: box)
                        .id("drop")
                } else if case .chat(let box) = ui.panel, let contact = store.contact(box) {
                    FloatingConversation(store: store, model: model, composer: composer, contact: contact, actions: actions)
                        .modifier(FadeIn())
                        .transition(.settle)
                        .id("chat-\(box)")
                } else if let box = model.hovered, let contact = store.stripContact(box) {
                    // Hangs under its face, wherever the panel sits.
                    NamePill(contact: contact, store: store)
                        .position(x: faceX, y: 14)
                        .transition(.settle)
                        .id("pill-\(box)")
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .padding(.top, 6)
        .animation(MenuBarMotion.panelOut, value: ui.panel)
        .animation(MenuBarMotion.panelOut, value: model.dropTarget == nil)
        .animation(MenuBarMotion.hover, value: model.hovered)
        .overlay(alignment: .bottom) {
            if let notice = ui.notice {
                Text(notice)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background { PanelGlass(shape: Capsule(), tone: .dark) }
                    .padding(.bottom, 8)
                    .transition(.settle)
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

/// The last few messages as glass bubbles over the desktop, and the composer.
struct FloatingConversation: View {
    @ObservedObject var store: WalkieStore
    @ObservedObject var model: MenuBarModel
    @ObservedObject var composer: ComposerState
    let contact: Contact
    let actions: ComposerActions

    static let width: CGFloat = 372
    /// How far the blurred desktop reaches beyond the bubbles before it has faded out.
    static let backdropReach: CGFloat = 64
    /// The newest few fill the view when it opens; older ones are a scroll up.
    private static let shown = 4
    /// How far back you can scroll.
    private static let kept = 200
    /// Room inside the scroll view for the bubbles' shadows, which it would clip.
    private static let shadowRoom: CGFloat = 16
    private static let spacing: CGFloat = 8
    /// What was there when the conversation opened: only messages after it pop in.
    @State private var openedWith: Set<String>?
    @State private var rowHeights: [String: CGFloat] = [:]
    /// A message just arrived: glide to it once its height is known.
    @State private var followLatest = false
    private static let end = "end"

    private var items: [ChatItem] { Array((store.chats[contact.box] ?? []).suffix(Self.kept)) }

    /// Tall enough for the newest `shown` messages, so it opens looking the same as before.
    private func viewport(for items: [ChatItem]) -> CGFloat {
        let recent = items.suffix(Self.shown)
        let rows = recent.reduce(0) { $0 + (rowHeights[$1.id] ?? 0) }
        return rows + CGFloat(max(0, recent.count - 1)) * Self.spacing + 2 * Self.shadowRoom
    }

    var body: some View {
        let items = items
        let scrolls = items.count > Self.shown
        VStack(spacing: Self.spacing) {
            if !items.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                        VStack(spacing: Self.spacing) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                let age = items.count - 1 - index
                                FloatingBubble(item: item, store: store, contact: contact,
                                               fresh: !item.fromMe && !model.revealed.contains(item.id))
                                    .modifier(PopIn(pops: openedWith.map { !$0.contains(item.id) } ?? false, fromTrailing: item.fromMe))
                                    .opacity(age >= 3 ? 0.7 : age == 2 ? 0.88 : 1)
                                    .frame(maxWidth: .infinity, alignment: item.fromMe ? .trailing : .leading)
                                    .background(GeometryReader { row in
                                        Color.clear.preference(key: RowHeightsKey.self, value: [item.id: row.size.height])
                                    })
                                    .id(item.id)
                                    .transition(.opacity)
                            }
                        }
                        .padding(Self.shadowRoom)
                        // Below the shadow room: scrolling here puts the newest bubble
                        // right above the composer, not half under it.
                        Color.clear.frame(height: 0).id(Self.end)
                        }
                    }
                    .defaultScrollAnchor(.bottom)
                    .frame(height: viewport(for: items))
                    // Older messages dissolve at the top instead of being cut off.
                    .mask {
                        VStack(spacing: 0) {
                            LinearGradient(colors: [.black.opacity(scrolls ? 0 : 1), .black], startPoint: .top, endPoint: .bottom)
                                .frame(height: Self.shadowRoom + 10)
                            Color.black
                        }
                    }
                    .padding(-Self.shadowRoom)
                    .onPreferenceChange(RowHeightsKey.self) { heights in
                        MainActor.assumeIsolated { measured(heights, proxy: proxy) }
                    }
                    .onChange(of: items.last?.id) { _, last in
                        guard last != nil else { return }
                        followLatest = true
                        // Normally the new row's height arrives first and the glide
                        // starts there; this catches a row whose height didn't change.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            guard followLatest else { return }
                            followLatest = false
                            withAnimation(MenuBarMotion.follow) { proxy.scrollTo(Self.end, anchor: .bottom) }
                        }
                    }
                }
            }
            Composer(store: store, composer: composer, recorder: store.recorder, player: store.player,
                     contact: contact, actions: actions)
        }
        .frame(width: Self.width)
        .background { ProgressiveBackdrop().padding(-Self.backdropReach) }
        .animation(MenuBarMotion.pop, value: items.map(\.id))
        .onAppear {
            openedWith = Set(items.map(\.id))
            reveal()
        }
        .onChange(of: items.map(\.id)) { _, _ in
            reveal()
            // Read as it arrives: no dot for a conversation you're looking at.
            store.markRead(contact.box)
        }
    }

    /// Row heights from the latest layout. The view grows to fit the newest
    /// messages and glides to the bottom in one animation, so the list makes
    /// room and slides up as one body while the new bubble pops in.
    private func measured(_ heights: [String: CGFloat], proxy: ScrollViewProxy) {
        let first = rowHeights.isEmpty
        let follow = followLatest && items.last.map { heights[$0.id] != nil } == true
        guard heights.contains(where: { rowHeights[$0.key] != $0.value }) || follow else { return }
        if first {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { rowHeights.merge(heights) { $1 } }
            return
        }
        if follow { followLatest = false }
        withAnimation(MenuBarMotion.follow) {
            rowHeights.merge(heights) { $1 }
            if follow { proxy.scrollTo(Self.end, anchor: .bottom) }
        }
    }

    /// New messages arrive out of focus and tinted, then settle in.
    private func reveal() {
        let fresh = items.filter { !$0.fromMe && !model.revealed.contains($0.id) }.map(\.id)
        guard !fresh.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            withAnimation(MenuBarMotion.reveal) { model.revealed.formUnion(fresh) }
        }
    }
}

private struct RowHeightsKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct FloatingBubble: View {
    let item: ChatItem
    @ObservedObject var store: WalkieStore
    let contact: Contact
    /// Not yet seen: blurred and tinted.
    let fresh: Bool

    var body: some View {
        content
            .foregroundStyle(fresh ? Color(red: 0.35, green: 0.62, blue: 1) : .white)
            .blur(radius: fresh ? 2.6 : 0)
            .copyMenu(item)
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .text:
            Text(item.text ?? "")
                .font(.system(size: 13.5))
                .lineLimit(4)
                .textSelection(.enabled)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background { PanelGlass(shape: Capsule(), tone: item.fromMe ? .dark : .light) }
                .frame(maxWidth: 300, alignment: item.fromMe ? .trailing : .leading)
        case .voice:
            VoiceBubble(item: item, store: store, player: store.player)
        case .files:
            HStack(spacing: 6) {
                ForEach((item.files ?? []).prefix(4)) { file in
                    Thumbnail(url: store.mediaURL(file.path), size: 64)
                }
            }
            .padding(6)
            .background { PanelGlass(shape: RoundedRectangle(cornerRadius: 20, style: .continuous), tone: item.fromMe ? .dark : .light) }
        case .todo:
            HStack(spacing: 8) {
                Image(systemName: item.done == true ? "checkmark.circle.fill" : "circle.dotted")
                    .font(.system(size: 14, weight: .medium))
                Text(item.text ?? "")
                    .font(.system(size: 13.5))
                    .strikethrough(item.done == true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background { PanelGlass(shape: Capsule(), tone: item.fromMe ? .dark : .light) }
        }
    }
}

private struct VoiceBubble: View {
    let item: ChatItem
    @ObservedObject var store: WalkieStore
    @ObservedObject var player: VoicePlayer

    var body: some View {
        let playing = player.playing == item.id
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    if let audio = item.audio { player.toggle(item.id, url: store.mediaURL(audio)) }
                } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                Text(Durations.clock(playing ? (item.duration ?? 0) * player.progress : item.duration ?? 0))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                NoteWaveform(levels: item.levels ?? [], progress: playing ? player.progress : 0, bars: 26, tint: .white)
                    .frame(width: 96, height: 14)
            }
            if let text = item.text, !text.isEmpty {
                Text(text)
                    .font(.system(size: 11))
                    .opacity(0.6)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(maxWidth: 300, alignment: .leading)
        .background { PanelGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous), tone: item.fromMe ? .dark : .light) }
    }
}

/// A file as a small rounded picture, or its icon.
struct Thumbnail: View {
    let url: URL
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit().padding(size * 0.12)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .task(id: url) {
            guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true else { return }
            image = await Task.detached(priority: .utility) { () -> NSImage? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                          kCGImageSourceCreateThumbnailFromImageAlways: true,
                          kCGImageSourceThumbnailMaxPixelSize: 240,
                          kCGImageSourceCreateThumbnailWithTransform: true
                      ] as CFDictionary) else { return nil }
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }.value
        }
    }
}

// MARK: Composer

/// The glass pill under the bubbles. It writes, records and reviews, and
/// morphs between them in place.
struct Composer: View {
    @ObservedObject var store: WalkieStore
    @ObservedObject var composer: ComposerState
    @ObservedObject var recorder: VoiceRecorder
    @ObservedObject var player: VoicePlayer
    let contact: Contact
    let actions: ComposerActions
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !composer.files.isEmpty {
                HStack(spacing: 8) {
                    ForEach(composer.files, id: \.self) { url in
                        Thumbnail(url: url, size: 52)
                            .overlay(alignment: .topTrailing) {
                                Button { actions.removeFile(url) } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 7, weight: .heavy))
                                        .foregroundStyle(.black)
                                        .frame(width: 16, height: 16)
                                        .background(Circle().fill(.white))
                                }
                                .buttonStyle(.plain)
                                .offset(x: 5, y: -5)
                            }
                            .transition(.scale(scale: 0.4).combined(with: .opacity).combined(with: .blur(6)))
                    }
                }
                .padding(.top, 2)
            }
            switch composer.phase {
            case .idle: writing.transition(.morph)
            case .recording: recording.transition(.morph)
            case .review: review.transition(.morph)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(width: FloatingConversation.width)
        .background { PanelGlass(shape: RoundedRectangle(cornerRadius: 26, style: .continuous), tone: .composer) }
        .animation(MenuBarMotion.morph, value: composer.phase)
        .animation(MenuBarMotion.pop, value: composer.files)
        .onAppear { if composer.phase == .idle { focused = true } }
    }

    // Writing

    private var writing: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Note to \(contact.firstName)…", text: $composer.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundStyle(.white)
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit(actions.send)
            HStack(spacing: 20) {
                ComposerGlyph(symbol: "waveform", help: "Record a voice note", action: actions.record)
                ComposerGlyph(symbol: "paperclip", help: "Add files", action: actions.attach)
                ComposerGlyph(symbol: "camera.viewfinder", help: "Add a screenshot", action: actions.screenshot)
                Spacer()
                SendButton(title: "Send", active: composer.canSend, action: actions.send)
            }
        }
    }

    // Recording

    private var language: String {
        (Locale.current.language.languageCode?.identifier ?? "en").prefix(2).capitalized
    }

    private var recording: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 3) {
                    Image(systemName: "text.bubble").font(.system(size: 10, weight: .semibold))
                    Text(language).font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.8))
                .help("Written down on this Mac as you speak")
                LiveWaveform(levels: recorder.levels).frame(height: 22)
            }
            Text(recorder.transcript.isEmpty ? " " : recorder.transcript)
                .font(.system(size: 13.5))
                .foregroundStyle(.white)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.interpolate)
                .animation(MenuBarMotion.crossfade, value: recorder.transcript)
            HStack(spacing: 6) {
                Circle().fill(Color(red: 1, green: 0.62, blue: 0.2)).frame(width: 7, height: 7)
                    .opacity(Int(recorder.elapsed * 2).isMultiple(of: 2) ? 1 : 0.4)
                Text("Recording").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                Text(Durations.clock(recorder.elapsed))
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
                    .contentTransition(.numericText())
                Spacer()
                SendButton(title: "Stop", active: false, action: actions.stop)
            }
        }
    }

    // Reviewing

    private var review: some View {
        let playing = player.playing == "composer-take"
        let take = composer.take
        return VStack(alignment: .leading, spacing: 8) {
            NoteWaveform(levels: take?.levels ?? [], progress: playing ? player.progress : 0, bars: 54, tint: .white)
                .frame(height: 20)
            if let text = take?.transcript, !text.isEmpty {
                Text(text)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.white)
                    .lineLimit(3)
            }
            HStack(spacing: 14) {
                Button(action: actions.discard) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash").font(.system(size: 11, weight: .semibold))
                        Text("Esc").font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.55))
                }
                .buttonStyle(.plain)
                Spacer()
                Button(action: actions.playTake) {
                    HStack(spacing: 5) {
                        Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 9, weight: .bold))
                            .contentTransition(.symbolEffect(.replace))
                        Text(Durations.clock(playing ? (take?.duration ?? 0) * player.progress : take?.duration ?? 0))
                            .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                    }
                    .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                SendButton(title: "Send", active: true, action: actions.send)
            }
        }
    }
}

private struct ComposerGlyph: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        NotchHoverReader { hovering in
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.6))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(PressScaleStyle(scale: 0.85))
            .help(help)
        }
    }
}

/// Grey and quiet until there's something to send, then blue.
private struct SendButton: View {
    let title: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Image(systemName: "return").font(.system(size: 10, weight: .bold)).opacity(0.65)
            }
            .foregroundStyle(.white.opacity(active ? 1 : 0.4))
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .background(Capsule().fill(active ? Color(red: 0.0, green: 0.48, blue: 1) : Color.white.opacity(0.08)))
        }
        .buttonStyle(PressScaleStyle(scale: 0.93))
        .animation(MenuBarMotion.hover, value: active)
    }
}

// MARK: Drop field

/// "Drop to Mira": one glass panel for the whole drag. It grows out of a
/// blob under the face, glides from face to face as the pointer moves, and
/// on the way out lets its dots go first, then itself.
struct DropPanel: View {
    let contact: Contact
    /// The pointer, in the panel's own coordinates.
    let point: CGPoint?
    let leaving: Bool

    static let size = CGSize(width: 400, height: 160)
    @State private var grown = false
    /// The label waits for the panel to finish growing.
    @State private var labelShown = false
    @State private var dots = true
    @State private var gone = false

    var body: some View {
        let width = grown ? Self.size.width : 30
        let height = grown ? Self.size.height : 30
        let shape = RoundedRectangle(cornerRadius: grown ? 36 : 15, style: .continuous)
        ZStack {
            TimelineView(.animation) { timeline in
                DotField(point: point, time: timeline.date.timeIntervalSinceReferenceDate)
            }
            .opacity(dots && grown ? 1 : 0)
            Text(contact.box == WalkieStore.selfBox ? "Drop to Me" : "Drop to \(contact.firstName)")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
                .contentTransition(.opacity)
                .animation(MenuBarMotion.crossfade, value: contact.box)
                .opacity(labelShown ? 1 : 0)
                .blur(radius: labelShown ? 0 : 4)
                .scaleEffect(labelShown ? 1 : 0.94)
        }
        .frame(width: width, height: height)
        .clipShape(shape)
        .background { PanelGlass(shape: shape, tone: .light) }
        .scaleEffect(gone ? 0.96 : 1, anchor: .top)
        .offset(y: gone ? -6 : 0)
        .opacity(gone ? 0 : 1)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
        .onAppear {
            withAnimation(MenuBarMotion.grow) { grown = true }
            withAnimation(.smooth(duration: 0.32).delay(0.18)) { labelShown = true }
        }
        .onChange(of: leaving) { _, leaving in
            guard leaving else { return }
            withAnimation(.smooth(duration: 0.3)) { dots = false }
            withAnimation(.smooth(duration: 0.32).delay(0.22)) { gone = true }
        }
    }
}

private struct DotField: View {
    let point: CGPoint?
    let time: TimeInterval

    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 14
            let columns = Int(size.width / spacing)
            let rows = Int(size.height / spacing)
            let originX = (size.width - CGFloat(columns - 1) * spacing) / 2
            let originY = (size.height - CGFloat(rows - 1) * spacing) / 2
            for row in 0..<rows {
                for column in 0..<columns {
                    let x = originX + CGFloat(column) * spacing
                    let y = originY + CGFloat(row) * spacing
                    let wave = 0.5 + 0.5 * sin(time * 1.6 - Double(x + y) * 0.018)
                    var glow = 0.0
                    if let point {
                        let distance = hypot(Double(x - point.x), Double(y - point.y))
                        glow = exp(-(distance * distance) / (2 * 55 * 55))
                    }
                    let radius = 0.9 + 0.35 * wave + 2.2 * glow
                    let opacity = 0.16 + 0.1 * wave + 0.7 * glow
                    context.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                                 with: .color(.white.opacity(opacity)))
                }
            }
        }
    }
}

// MARK: Backdrop

/// The desktop behind the conversation, blurred most behind the bubbles and
/// fading to nothing toward the edges, so they read on any wallpaper and no
/// edge shows where the effect stops. It frosts light in Light Mode and dims
/// dark in Dark Mode: a dark cloud over the white windows of Light Mode reads
/// as a grey smudge, and a light one over dark windows as milky haze.
private struct ProgressiveBackdrop: View {
    @Environment(\.walkieGlassFallback) private var fallback
    @StateObject private var system = SystemAppearance()

    var body: some View {
        let light = !system.isDark
        ZStack {
            if !fallback {
                BackdropBlur(dark: !light)
                if !light {
                    // A second pass on a tighter falloff, so the blur deepens toward the middle.
                    BackdropBlur(dark: true).mask { falloff(solid: 0.25) }
                }
            }
            if !light || fallback {
                LinearGradient(colors: [.black.opacity(0.36), .black.opacity(0.24)], startPoint: .top, endPoint: .bottom)
            }
        }
        .mask { falloff(solid: 0.5) }
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.3), value: light)
    }

    /// Opaque over the inner `solid` part, then easing to clear at the edges,
    /// drawn as gradients so every renderer shows the same soft falloff.
    private func falloff(solid: CGFloat) -> some View {
        EllipticalGradient(stops: [.init(color: .white, location: 0),
                                   .init(color: .white, location: solid),
                                   .init(color: .white.opacity(0.55), location: solid + (1 - solid) * 0.45),
                                   .init(color: .white.opacity(0.15), location: solid + (1 - solid) * 0.78),
                                   .init(color: .clear, location: 1)],
                           center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5)
    }
}

/// Light or Dark Mode, live. The panel itself is always dark, so SwiftUI's
/// colour scheme can't tell.
@MainActor
private final class SystemAppearance: ObservableObject {
    @Published private(set) var isDark = SystemAppearance.current
    private var observation: NSKeyValueObservation?

    init() {
        observation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isDark != Self.current else { return }
                    self.isDark = Self.current
                }
            }
        }
    }

    private static var current: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

private struct BackdropBlur: NSViewRepresentable {
    let dark: Bool

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .fullScreenUI
        view.blendingMode = .behindWindow
        view.state = .active
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        let name: NSAppearance.Name = dark ? .darkAqua : .aqua
        if view.appearance?.name != name { view.appearance = NSAppearance(named: name) }
    }
}

// MARK: Transitions

/// The panel's entrance: it fades in, drops the last few points into place and sharpens.
/// Run from `onAppear`, so it plays however the view was inserted.
private struct FadeIn: ViewModifier {
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown ? 1 : 0.965, anchor: .top)
            .offset(y: shown ? 0 : -8)
            .blur(radius: shown ? 0 : 6)
            .onAppear { withAnimation(MenuBarMotion.panelIn) { shown = true } }
    }
}

private struct PopModifier: ViewModifier {
    let progress: CGFloat
    let anchor: UnitPoint

    func body(content: Content) -> some View {
        content
            .scaleEffect(0.6 + 0.4 * progress, anchor: anchor)
            .offset(y: (1 - progress) * 10)
            .blur(radius: (1 - progress) * 8)
            .opacity(Double(progress))
    }
}

/// A sent or arriving bubble: small, soft and faint at its edge, then full
/// size and sharp, with a little give at the end. Started from `onAppear`, so it plays
/// however SwiftUI inserted the row.
private struct PopIn: ViewModifier {
    let pops: Bool
    let fromTrailing: Bool
    @State private var progress: CGFloat?

    func body(content: Content) -> some View {
        content
            .modifier(PopModifier(progress: progress ?? (pops ? 0 : 1), anchor: fromTrailing ? .bottomTrailing : .bottomLeading))
            .onAppear {
                guard pops, progress == nil else { return }
                progress = 0
                withAnimation(MenuBarMotion.pop) { progress = 1 }
            }
    }
}

// MARK: Shared transitions

private struct BlurEffect: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View { content.blur(radius: radius) }
}

extension AnyTransition {
    static func blur(_ radius: CGFloat) -> AnyTransition {
        .modifier(active: BlurEffect(radius: radius), identity: BlurEffect(radius: 0))
    }

    /// Panels leaving: fade, sink a few points toward the menu bar and soften.
    static var settle: AnyTransition {
        .asymmetric(insertion: .opacity,
                    removal: .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
                        .combined(with: .offset(y: -6)).combined(with: .blur(4)))
    }

    /// One composer state melting into the next.
    static var morph: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.96)).combined(with: .blur(6))
    }
}
