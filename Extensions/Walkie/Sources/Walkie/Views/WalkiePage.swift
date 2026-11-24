import AppKit
import SwiftUI
import XNotchKit

/// What the page shows, and how tall it is for it.
@MainActor
final class WalkieUI: ObservableObject {
    enum Panel: Equatable {
        /// The faces, with a hint line under them.
        case hint
        /// One conversation filling the page; its face rides up into the header.
        case chat(String)
    }

    @Published private(set) var panel: Panel = .hint
    /// The face being held to talk to. A conversation records in place; on
    /// the faces, a card opens under them.
    @Published private(set) var recording: String?
    /// The pointer went far enough from the held face to cancel on release.
    @Published var cancelArmed = false
    /// Faces that just sent: `true` when it failed.
    @Published private(set) var sendBadges: [String: Bool] = [:]
    @Published var notice: String?

    var onHeightChange: (() -> Void)?
    private var noticeWork: DispatchWorkItem?

    static let facesHeight: CGFloat = 80
    /// The tallest a page can be and still fit the notch's canvas under a
    /// camera notch, the same limit Vitals keeps to.
    static let maxHeight: CGFloat = 208
    static let recordingCardHeight: CGFloat = 106

    var contentHeight: CGFloat {
        switch panel {
        case .chat: Self.maxHeight
        case .hint: Self.facesHeight + (recording == nil ? 20 : Self.recordingCardHeight)
        }
    }

    /// `animated: false` when the notch is opening straight onto the panel,
    /// so it grows to the panel's height on its own spring.
    func show(_ panel: Panel, animated: Bool = true) {
        guard panel != self.panel else { return }
        if animated {
            withAnimation(KitMotion.shell) { self.panel = panel }
        } else {
            self.panel = panel
        }
        onHeightChange?()
    }

    func toggleChat(_ box: String) {
        show(panel == .chat(box) ? .hint : .chat(box))
    }

    func beginRecording(_ box: String) {
        cancelArmed = false
        guard recording != box else { return }
        withAnimation(KitMotion.shell) { recording = box }
        onHeightChange?()
    }

    func endRecording(sentTo box: String?, failed: Bool = false) {
        if recording != nil {
            withAnimation(KitMotion.shell) { recording = nil }
            onHeightChange?()
        }
        guard let box else { return }
        withAnimation(.smooth(duration: 0.46, extraBounce: 0.12)) { sendBadges[box] = failed }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            withAnimation(KitMotion.content) { _ = self?.sendBadges.removeValue(forKey: box) }
        }
    }

    func flash(_ message: String) {
        noticeWork?.cancel()
        withAnimation(KitMotion.content) { notice = message }
        let work = DispatchWorkItem { [weak self] in withAnimation(KitMotion.content) { self?.notice = nil } }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }
}

struct WalkiePage: View {
    @ObservedObject var store: WalkieStore
    @ObservedObject var ui: WalkieUI
    let isActive: Bool
    let openSettings: () -> Void
    let tick: () -> Void

    /// Faces fly between the row and a conversation's header.
    @Namespace private var faces

    var body: some View {
        ZStack(alignment: .top) {
            if case .chat(let box) = ui.panel, let contact = store.contact(box) {
                ConversationView(store: store, player: store.player, ui: ui, contact: contact, isActive: isActive,
                                 onHoldBegan: { holdBegan(contact) }, onHoldEnded: { holdEnded(contact, cancel: $0) },
                                 onBack: { tick(); ui.show(.hint) }, faces: faces)
                    .id("chat-\(box)")
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)),
                                            removal: .opacity.combined(with: .offset(y: 6))))
            } else {
                VStack(spacing: 0) {
                    FacesRow(store: store, ui: ui, faces: faces, onHoldBegan: holdBegan, onHoldEnded: holdEnded,
                             onClick: click, onSettings: openSettings)
                        .frame(height: WalkieUI.facesHeight)
                    below
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .id("faces")
                .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)),
                                        removal: .opacity.combined(with: .scale(scale: 0.97, anchor: .top))))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 12)
        .overlay(alignment: .bottom) { noticeBanner }
        .onChange(of: store.lastError) { _, error in
            if let error { ui.flash(error); store.lastError = nil }
        }
    }

    /// Under the faces: the hint, or the card while you hold a face.
    @ViewBuilder
    private var below: some View {
        ZStack(alignment: .top) {
            if let box = ui.recording, let contact = store.contact(box) {
                RecordingCard(recorder: store.recorder, contact: contact, cancelArmed: ui.cancelArmed)
                    .id("recording")
                    // A short drop, not a full move: content never passes over the faces.
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -10)).combined(with: .scale(scale: 0.97, anchor: .top)),
                                            removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .top))))
            } else {
                HintLine(store: store, openSettings: openSettings)
                    .id("hint")
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var noticeBanner: some View {
        if let notice = ui.notice {
            Text(notice)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color(red: 0.25, green: 0.1, blue: 0.1)).overlay(Capsule().strokeBorder(.white.opacity(0.1))))
                // Above the composer in a conversation, so it never covers what you type.
                .padding(.bottom, ui.panel == .hint ? 4 : 46)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onTapGesture { ui.notice = nil }
        }
    }

    // MARK: Hold to talk

    private func click(_ contact: Contact) {
        tick()
        guard contact.accepted else { openSettings(); return }
        store.markRead(contact.box)
        ui.toggleChat(contact.box)
    }

    private func holdBegan(_ contact: Contact) {
        guard contact.accepted else { openSettings(); return }
        Talk.begin(contact, store: store, ui: ui, tick: tick)
    }

    private func holdEnded(_ contact: Contact, cancel: Bool) {
        Talk.end(contact, cancel: cancel, store: store, ui: ui, tick: tick)
    }
}

extension View {
    /// Lets a face fly between two places that show it, when there's a namespace.
    @ViewBuilder
    func matchedFace(_ box: String, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            matchedGeometryEffect(id: "face-\(box)", in: namespace)
        } else {
            self
        }
    }
}

/// Down starts a short timer: still down when it fires means talk; up
/// before it means a click. Dragging far from the face arms cancel.
struct HoldToTalkGesture: ViewModifier {
    @ObservedObject var ui: WalkieUI
    @Binding var holding: Bool
    let onHoldBegan: () -> Void
    let onHoldEnded: (Bool) -> Void
    let onClick: () -> Void

    @State private var pressed = false
    @State private var holdWork: DispatchWorkItem?

    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    if !pressed {
                        pressed = true
                        let work = DispatchWorkItem {
                            holding = true
                            onHoldBegan()
                        }
                        holdWork = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
                    }
                    if holding {
                        let armed = hypot(value.translation.width, value.translation.height) > 70
                        if armed != ui.cancelArmed { withAnimation(KitMotion.content) { ui.cancelArmed = armed } }
                    }
                }
                .onEnded { _ in
                    holdWork?.cancel()
                    holdWork = nil
                    pressed = false
                    if holding {
                        holding = false
                        onHoldEnded(false)
                    } else {
                        onClick()
                    }
                }
        )
    }
}

// MARK: Faces

private struct FacesRow: View {
    @ObservedObject var store: WalkieStore
    @ObservedObject var ui: WalkieUI
    let faces: Namespace.ID
    let onHoldBegan: (Contact) -> Void
    let onHoldEnded: (Contact, Bool) -> Void
    let onClick: (Contact) -> Void
    let onSettings: () -> Void

    var body: some View {
        NotchHoverReader { hovering in
            HStack(spacing: hovering || isFocused ? 14 : 6) {
                ForEach(store.contacts) { contact in
                    FaceButton(store: store, ui: ui, player: store.player, contact: contact, faces: faces,
                               onHoldBegan: { onHoldBegan(contact) },
                               onHoldEnded: { onHoldEnded(contact, $0) },
                               onClick: { onClick(contact) }, onSettings: onSettings)
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                }
                SettingsFace(emphasized: store.contacts.isEmpty, action: onSettings)
            }
            .frame(maxWidth: .infinity)
            .animation(.smooth(duration: 0.48, extraBounce: 0.12), value: hovering)
            .animation(.smooth(duration: 0.48, extraBounce: 0.12), value: store.contacts.map(\.box))
        }
    }

    private var isFocused: Bool { ui.recording != nil }
}

private struct FaceButton: View {
    @ObservedObject var store: WalkieStore
    @ObservedObject var ui: WalkieUI
    @ObservedObject var player: VoicePlayer
    let contact: Contact
    let faces: Namespace.ID
    let onHoldBegan: () -> Void
    let onHoldEnded: (Bool) -> Void
    let onClick: () -> Void
    let onSettings: () -> Void

    @State private var holding = false

    private let size: CGFloat = 42

    private var isSelected: Bool { isRecordingHere }
    private var isRecordingHere: Bool { ui.recording == contact.box }
    private var playingProgress: Double? {
        guard let id = player.playing, store.chats[contact.box]?.contains(where: { $0.id == id }) == true else { return nil }
        return player.progress
    }

    var body: some View {
        NotchHoverReader { hovering in
            VStack(spacing: 4) {
                ZStack {
                    if store.talking.contains(contact.box) {
                        TalkingRipples(color: Color(hex: FacePalette.tintHex(for: contact.box)) ?? .white)
                    }
                    if isRecordingHere {
                        RecordingHalo(recorder: store.recorder, cancel: ui.cancelArmed)
                    }
                    FaceImage(name: contact.name, seed: contact.box, avatar: contact.avatar)
                        .saturation(contact.accepted ? 1 : 0.2)
                        .matchedFace(contact.box, in: faces)
                    if let progress = playingProgress {
                        PlaybackRing(progress: progress).padding(-3)
                    }
                    Circle()
                        .strokeBorder(.white.opacity(isSelected ? 0.95 : hovering ? 0.3 : 0.1), lineWidth: isSelected ? 2.5 : 1)
                        .padding(isSelected ? -4 : 0)
                }
                .frame(width: size, height: size)
                .overlay(alignment: .bottomTrailing) { presenceDot }
                .overlay(alignment: .topTrailing) { badge }
                .scaleEffect(scale(hovering: hovering))
                .shadow(color: .black.opacity(hovering ? 0.5 : 0.25), radius: hovering ? 8 : 3, y: hovering ? 4 : 1)
                .animation(.smooth(duration: 0.34, extraBounce: 0.18), value: hovering)
                .animation(.smooth(duration: 0.3, extraBounce: 0.12), value: holding)
                .animation(.smooth(duration: 0.4, extraBounce: 0.12), value: isSelected)

                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(hovering || isSelected ? 0.9 : 0.45))
                    .lineLimit(1)
                    .frame(maxWidth: 64)
                    .contentTransition(.interpolate)
                    .animation(KitMotion.content, value: label)
            }
            .contentShape(Rectangle())
            .modifier(HoldToTalkGesture(ui: ui, holding: $holding, onHoldBegan: onHoldBegan, onHoldEnded: onHoldEnded,
                                        onClick: onClick))
            .notchContextMenu { menu }
            .help("Hold to talk to \(contact.firstName). Click to open.")
        }
    }

    private func scale(hovering: Bool) -> CGFloat {
        if holding { return 1.18 }
        if isSelected { return 1.08 }
        return hovering ? 1.12 : 1
    }

    private var label: String {
        if !contact.accepted { return "New" }
        if store.talking.contains(contact.box) { return "Talking…" }
        if isRecordingHere { return ui.cancelArmed ? "Cancel" : "Listening" }
        return contact.firstName
    }

    @ViewBuilder
    private var presenceDot: some View {
        if store.online.contains(contact.box) {
            Circle()
                .fill(KitStyle.green)
                .frame(width: 10, height: 10)
                .overlay(Circle().strokeBorder(.black, lineWidth: 2))
                .offset(x: 1, y: 1)
                .transition(.scale.combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var badge: some View {
        if let failed = ui.sendBadges[contact.box] {
            SendBadge(failed: failed).offset(x: 5, y: -5)
        } else if let count = store.unread[contact.box], count > 0 {
            Text("\(count)")
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .foregroundStyle(.black)
                .padding(.horizontal, 5)
                .frame(minWidth: 16, minHeight: 16)
                .background(Capsule().fill(KitStyle.green))
                .overlay(Capsule().strokeBorder(.black, lineWidth: 1.5))
                .offset(x: 5, y: -4)
                .transition(.scale.combined(with: .opacity))
        }
    }

    private var menu: [NotchMenuItem] {
        var items: [NotchMenuItem] = [
            .action("Open Conversation", symbol: "bubble.left.and.bubble.right") { onClick() }
        ]
        items.append(.separator)
        items.append(.action("Manage People in Settings…", symbol: "gearshape") { onSettings() })
        return items
    }
}

/// The halo around the held face, breathing with your voice.
private struct RecordingHalo: View {
    @ObservedObject var recorder: VoiceRecorder
    let cancel: Bool

    var body: some View {
        let level = CGFloat(recorder.levels.suffix(3).max() ?? 0)
        Circle()
            .fill((cancel ? Color.red : Color(red: 1, green: 0.42, blue: 0.24)).opacity(0.35))
            .scaleEffect(1.15 + level * 0.55)
            .blur(radius: 4)
            .animation(.smooth(duration: 0.20), value: level)
    }
}

private struct SettingsFace: View {
    let emphasized: Bool
    let action: () -> Void

    var body: some View {
        NotchHoverReader { hovering in
            Button(action: action) {
                VStack(spacing: 4) {
                    // Smaller and quieter than a face, so it never reads as another person.
                    Image(systemName: emphasized ? "person.badge.plus" : "gearshape.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(hovering ? 0.9 : emphasized ? 0.7 : 0.4))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(.white.opacity(hovering ? 0.14 : 0.06)))
                        .overlay {
                            if emphasized {
                                Circle().strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [3, 3])).foregroundStyle(.white.opacity(0.3))
                            }
                        }
                        .scaleEffect(hovering ? 1.08 : 1)
                        .frame(width: 42, height: 42)
                    Text(emphasized ? "Add people" : "Settings")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(hovering ? 0.9 : emphasized ? 0.6 : 0.3))
                }
            }
            .buttonStyle(PressScaleStyle(scale: 0.9))
            .animation(.smooth(duration: 0.34, extraBounce: 0.12), value: hovering)
        }
    }
}

// MARK: Panels

private struct HintLine: View {
    @ObservedObject var store: WalkieStore
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            switch store.status {
            case .needsServer:
                Button(action: openSettings) {
                    Label("Connect your XNotch Cloud server to start", systemImage: "server.rack")
                }
                .buttonStyle(.plain)
            case .connecting:
                ProgressView().controlSize(.mini)
                Text("Connecting…")
            case .offline(let reason):
                Image(systemName: "wifi.exclamationmark")
                Text(reason).lineLimit(1)
            case .online:
                if store.contacts.isEmpty {
                    Button("Add people in Settings", action: openSettings)
                        .buttonStyle(.plain)
                } else {
                    Image(systemName: "lock.fill").font(.system(size: 8, weight: .bold))
                    Text("Hold to talk · Click to open · Drop files on a face")
                }
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.white.opacity(0.42))
        .frame(maxWidth: .infinity)
    }
}

struct RecordingCard: View {
    @ObservedObject var recorder: VoiceRecorder
    let contact: Contact
    let cancelArmed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Circle()
                    .fill(cancelArmed ? Color.white.opacity(0.5) : Color(red: 1, green: 0.3, blue: 0.25))
                    .frame(width: 7, height: 7)
                    .opacity(Int(recorder.elapsed * 2).isMultiple(of: 2) ? 1 : 0.35)
                    .animation(.easeInOut(duration: 0.4), value: Int(recorder.elapsed * 2))
                LiveWaveform(levels: recorder.levels, color: cancelArmed ? .red : .white)
                    .frame(height: 30)
                Text(Durations.clock(recorder.elapsed))
                    .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
                    .contentTransition(.numericText())
                    .animation(.snappy, value: Int(recorder.elapsed))
            }
            Text(caption)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.white.opacity(recorder.transcript.isEmpty ? 0.38 : 0.78))
                .lineLimit(2, reservesSpace: true)
                .truncationMode(.head)
                .contentTransition(.interpolate)
                .animation(.easeInOut(duration: 0.22), value: recorder.transcript)
            HStack {
                Text(cancelArmed ? "Release to throw it away" : "Release to send to \(contact.firstName)")
                Spacer()
                Text(cancelArmed ? "" : "Drag away to cancel")
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(cancelArmed ? Color.red.opacity(0.9) : .white.opacity(0.35))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(cancelArmed ? Color.red.opacity(0.12) : Color.white.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.08)))
        }
        .animation(KitMotion.content, value: cancelArmed)
    }

    private var caption: String {
        recorder.transcript.isEmpty ? "Talk to \(contact.firstName)…" : recorder.transcript
    }
}
