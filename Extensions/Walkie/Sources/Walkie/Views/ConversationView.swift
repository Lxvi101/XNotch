import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XNotchKit

/// One conversation, filling the notch page: who, what was said, and a
/// one-line composer. Holding the mic or the face records right here; your
/// words form a bubble as you speak.
struct ConversationView: View {
    @ObservedObject var store: WalkieStore
    @ObservedObject var player: VoicePlayer
    @ObservedObject var ui: WalkieUI
    let contact: Contact
    let isActive: Bool
    let onHoldBegan: () -> Void
    let onHoldEnded: (Bool) -> Void
    let onBack: () -> Void
    /// Where the face flies in from.
    var faces: Namespace.ID?

    @State private var draft = ""
    @State private var todoMode = false
    @State private var remind: Reminder = .none
    @State private var faceHolding = false
    @FocusState private var focused: Bool

    private var items: [ChatItem] { store.chats[contact.box] ?? [] }
    private var accent: Color { Color(hex: FacePalette.tintHex(for: contact.box)) ?? .orange }
    private var isRecording: Bool { ui.recording == contact.box }

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: 40)
            if !contact.accepted { requestBanner.padding(.bottom, 4) }
            messages
                .frame(maxHeight: .infinity)
            composer
                .padding(.top, 6)
        }
        .padding(.bottom, 2)
        .onAppear { store.markRead(contact.box) }
        .onChange(of: items.count) { _, _ in if isActive { store.markRead(contact.box) } }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            BackChevron(action: onBack)
            ZStack {
                if store.talking.contains(contact.box) {
                    TalkingRipples(color: accent)
                }
                if isRecording {
                    Circle().fill((ui.cancelArmed ? Color.red : accent).opacity(0.35)).scaleEffect(1.3).blur(radius: 3)
                }
                FaceImage(name: contact.name, seed: contact.box, avatar: contact.avatar)
                    .matchedFace(contact.box, in: faces)
            }
            .frame(width: 30, height: 30)
            .overlay(alignment: .bottomTrailing) {
                if store.online.contains(contact.box) {
                    Circle()
                        .fill(KitStyle.green)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(.black, lineWidth: 2))
                        .offset(x: 2, y: 2)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .scaleEffect(faceHolding ? 1.12 : 1)
            .animation(.smooth(duration: 0.3, extraBounce: 0.15), value: faceHolding)
            .contentShape(Circle())
            .modifier(HoldToTalkGesture(ui: ui, holding: $faceHolding, onHoldBegan: onHoldBegan, onHoldEnded: onHoldEnded,
                                        onClick: onBack))
            .help("Hold to talk to \(contact.firstName)")

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(contact.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Image(systemName: contact.verified ? "checkmark.seal.fill" : "lock.fill")
                        .font(.system(size: contact.verified ? 10 : 8, weight: .semibold))
                        .foregroundStyle(contact.verified ? accent : .white.opacity(0.3))
                        .help(contact.verified
                              ? "Keys checked. End-to-end encrypted with X-Wing (ML-KEM-768 + X25519), signed with ML-DSA-65 and Ed25519."
                              : "End-to-end encrypted. Compare safety numbers in Settings → Walkie to check the keys.")
                }
                Text(statusText)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                    .contentTransition(.interpolate)
                    .animation(KitMotion.content, value: statusText)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 2)
    }

    private var statusText: String {
        if isRecording { return ui.cancelArmed ? "Let go to throw it away" : "Listening…" }
        if store.talking.contains(contact.box) { return "Talking to you…" }
        if store.online.contains(contact.box) { return "Active now" }
        return "Gets it when they're back"
    }

    private var statusColor: Color {
        if isRecording { return ui.cancelArmed ? .red.opacity(0.9) : .white.opacity(0.75) }
        if store.talking.contains(contact.box) { return accent }
        return store.online.contains(contact.box) ? KitStyle.green.opacity(0.85) : .white.opacity(0.4)
    }

    private var requestBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.badge.plus").font(.system(size: 10, weight: .semibold))
            Text("\(contact.firstName) added you. Answer in Settings → Walkie.")
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.white.opacity(0.6))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(Capsule().fill(.white.opacity(0.06)))
    }

    // MARK: Messages

    private var rows: [MessageRowModel] { MessageRowModel.rows(for: items) }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                // Not lazy: at most 400 rows, and real heights make the bottom anchor exact.
                VStack(spacing: 0) {
                    if rows.isEmpty && !isRecording {
                        emptyState
                    }
                    ForEach(rows) { row in
                        MessageRow(row: row, store: store, player: player, contact: contact, accent: accent)
                            .id(row.id)
                            .transition(.asymmetric(
                                insertion: .offset(y: 12).combined(with: .opacity)
                                    .combined(with: .scale(scale: 0.9, anchor: row.item.fromMe ? .bottomTrailing : .bottomLeading)),
                                removal: .opacity))
                    }
                    if isRecording {
                        LiveNoteBubble(recorder: store.recorder, accent: accent, cancelArmed: ui.cancelArmed)
                            .padding(.top, rows.last?.item.fromMe == true ? 3 : 8)
                            .transition(.offset(y: 12).combined(with: .opacity)
                                .combined(with: .scale(scale: 0.85, anchor: .bottomTrailing)))
                    }
                    Color.clear.frame(height: 1).id(Self.end)
                }
                .padding(.horizontal, 2)
                .padding(.top, 8)
                .animation(.smooth(duration: 0.44, extraBounce: 0.06), value: rows.map(\.id))
                .animation(.smooth(duration: 0.4, extraBounce: 0.1), value: isRecording)
            }
            .defaultScrollAnchor(.bottom)
            // Older messages dissolve under the header instead of being cut by it.
            .mask(VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 26)
                Color.black
            })
            .onAppear {
                // Open on the newest message, after the first layout pass.
                for delay in [0.0, 0.08] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { proxy.scrollTo(Self.end, anchor: .bottom) }
                }
            }
            .onChange(of: items.last?.id) { _, _ in scrollToEnd(proxy) }
            .onChange(of: isRecording) { _, _ in scrollToEnd(proxy) }
            .onChange(of: store.recorder.transcript.count / 24) { _, _ in
                if isRecording { scrollToEnd(proxy) }
            }
        }
    }

    private static let end = "end"

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        // After the new row's first layout, or it scrolls to where the row isn't yet.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.smooth(duration: 0.42)) { proxy.scrollTo(Self.end, anchor: .bottom) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "waveform")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(accent.opacity(0.9))
            Text("Hold the mic or \(contact.firstName)'s face to talk.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 22)
    }

    // MARK: Composer

    private var hasDraft: Bool { !draft.trimmingCharacters(in: .whitespaces).isEmpty }

    private var composer: some View {
        HStack(spacing: 6) {
            HoldToTalkButton(onBegan: onHoldBegan, onEnded: onHoldEnded, ui: ui, accent: accent,
                             isRecording: isRecording)
            ZStack {
                if isRecording {
                    RecordingStrip(recorder: store.recorder, firstName: contact.firstName, cancelArmed: ui.cancelArmed)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else {
                    field
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .frame(height: 32)
            .background {
                Capsule()
                    .fill(fieldFill)
                    .overlay(Capsule().strokeBorder(.white.opacity(focused && !isRecording ? 0.16 : 0.07)))
            }
            .animation(KitMotion.content, value: isRecording)
            .animation(KitMotion.content, value: ui.cancelArmed)
            .animation(KitMotion.content, value: focused)
        }
        .frame(height: 32)
    }

    private var fieldFill: Color {
        if isRecording { return ui.cancelArmed ? Color.red.opacity(0.2) : accent.opacity(0.16) }
        return .white.opacity(focused ? 0.11 : 0.08)
    }

    private var field: some View {
        HStack(spacing: 6) {
            if todoMode {
                Image(systemName: "circle.dotted")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accent)
                    .transition(.scale.combined(with: .opacity))
            }
            TextField(todoMode ? "A to-do for \(contact.firstName)…" : "Message \(contact.firstName)…", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(.white)
                .focused($focused)
                .onSubmit(send)
            if todoMode {
                Menu {
                    ForEach(Reminder.allCases, id: \.self) { choice in
                        Button(choice.title) { remind = choice }
                    }
                } label: {
                    Image(systemName: remind == .none ? "bell" : "bell.fill")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(remind == .none ? .white.opacity(0.55) : accent)
                .help(remind == .none ? "Add a reminder" : "Reminder: \(remind.title)")
                .transition(.scale.combined(with: .opacity))
            }
            ZStack(alignment: .trailing) {
                if hasDraft {
                    Button(action: send) {
                        Image(systemName: todoMode ? "checkmark" : "arrow.up")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(accent))
                    }
                    .buttonStyle(PressScaleStyle(scale: 0.86))
                    .help(todoMode ? "Hand over the to-do" : "Send")
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                } else {
                    HStack(spacing: 2) {
                        ComposerIcon(symbol: "camera.viewfinder", help: "Send a screenshot", action: screenshot)
                        ComposerIcon(symbol: "paperclip", help: "Send files", action: pickFiles)
                        ComposerIcon(symbol: "checklist", help: todoMode ? "Back to a message" : "Hand over a to-do",
                                     isOn: todoMode, tint: accent) {
                            withAnimation(.smooth(duration: 0.37, extraBounce: 0.12)) { todoMode.toggle() }
                            focused = true
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
                }
            }
            .animation(.smooth(duration: 0.3, extraBounce: 0.15), value: hasDraft)
        }
        .padding(.leading, todoMode ? 10 : 13)
        .padding(.trailing, 4)
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if todoMode {
            store.sendTodo(text, remindAt: remind.date, to: contact)
            withAnimation(.smooth(duration: 0.37, extraBounce: 0.12)) { todoMode = false }
            remind = .none
        } else {
            store.sendText(text, to: contact)
        }
        draft = ""
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Send to \(contact.firstName)"
        let store = store, contact = contact
        panel.presentAboveOverlays { urls in
            if !urls.isEmpty { store.sendFiles(urls, to: contact) }
        }
    }

    /// The system's own selection capture; Esc cancels it.
    private func screenshot() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Screenshot \(Self.stamp.string(from: Date())).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", url.path]
        process.terminationHandler = { _ in
            Task { @MainActor in
                guard FileManager.default.fileExists(atPath: url.path) else { return }
                store.sendFiles([url], to: contact)
                try? FileManager.default.removeItem(at: url)
            }
        }
        try? process.run()
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }()
}

/// "‹": back to the faces.
private struct BackChevron: View {
    let action: () -> Void

    var body: some View {
        NotchHoverReader { hovering in
            Button(action: action) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.5))
                    .frame(width: 24, height: 28)
                    .background(Circle().fill(.white.opacity(hovering ? 0.1 : 0)).frame(width: 26, height: 26))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleStyle(scale: 0.85))
            .animation(KitMotion.content, value: hovering)
            .help("Back to everyone")
        }
    }
}

/// The composer while you talk: a pulsing dot, your voice, and the clock.
private struct RecordingStrip: View {
    @ObservedObject var recorder: VoiceRecorder
    let firstName: String
    let cancelArmed: Bool

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(cancelArmed ? Color.white.opacity(0.6) : Color(red: 1, green: 0.3, blue: 0.25))
                .frame(width: 7, height: 7)
                .opacity(Int(recorder.elapsed * 2).isMultiple(of: 2) ? 1 : 0.35)
                .animation(.easeInOut(duration: 0.4), value: Int(recorder.elapsed * 2))
            Text(Durations.clock(recorder.elapsed))
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
                .contentTransition(.numericText())
                .animation(.snappy, value: Int(recorder.elapsed))
            LiveWaveform(levels: recorder.levels, color: cancelArmed ? .red : .white.opacity(0.85))
                .frame(height: 18)
            Text(cancelArmed ? "Let go to cancel" : "Let go to send")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(cancelArmed ? Color.red.opacity(0.95) : .white.opacity(0.5))
                .contentTransition(.interpolate)
                .fixedSize()
        }
        .padding(.horizontal, 13)
    }
}

/// Your voice note forming in the conversation, words and all, before you let go.
private struct LiveNoteBubble: View {
    @ObservedObject var recorder: VoiceRecorder
    let accent: Color
    let cancelArmed: Bool

    var body: some View {
        HStack {
            Spacer(minLength: 54)
            Text(recorder.transcript.isEmpty ? "…" : recorder.transcript)
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(recorder.transcript.isEmpty ? 0.5 : 0.92))
                .lineLimit(4)
                .truncationMode(.head)
                .contentTransition(.interpolate)
                .animation(.easeInOut(duration: 0.2), value: recorder.transcript)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill((cancelArmed ? Color.red : accent).opacity(0.28))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .foregroundStyle((cancelArmed ? Color.red : accent).opacity(0.8)))
                }
                .opacity(cancelArmed ? 0.55 : 1)
                .animation(KitMotion.content, value: cancelArmed)
        }
    }
}

enum Reminder: CaseIterable, Hashable {
    case none, inAnHour, thisEvening, tomorrowMorning

    var title: String {
        switch self {
        case .none: "No reminder"
        case .inAnHour: "In an hour"
        case .thisEvening: "This evening, 18:00"
        case .tomorrowMorning: "Tomorrow, 9:00"
        }
    }

    /// "today, 18:00", "tomorrow, 9:00", "Fri, 9:00" or "14 Nov, 9:00", in
    /// the same language as the rest of Walkie; the time follows the Mac's clock style.
    static func describe(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "today, \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow, \(time)"
        }
        let english = DateFormatter()
        english.locale = Locale(identifier: "en_GB")
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        english.dateFormat = (0..<7).contains(days) ? "EEE" : "d MMM"
        return "\(english.string(from: date)), \(time)"
    }

    var date: Date? {
        let calendar = Calendar.current
        let now = Date()
        switch self {
        case .none: return nil
        case .inAnHour: return now.addingTimeInterval(3600)
        case .thisEvening:
            let evening = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now) ?? now
            return evening > now ? evening : calendar.date(byAdding: .day, value: 1, to: evening)
        case .tomorrowMorning:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
        }
    }
}

// MARK: Rows

/// A message with what's drawn around it: a time above when a while has
/// passed, tight spacing within a run from one person, and the delivery
/// status under your latest message only.
struct MessageRowModel: Identifiable, Equatable {
    let item: ChatItem
    let stamp: Date?
    let tight: Bool
    let showsStatus: Bool
    var id: String { item.id }

    static func rows(for items: [ChatItem]) -> [MessageRowModel] {
        let visible = items.filter(\.hasContent)
        let lastMine = visible.last(where: \.fromMe)?.id
        var rows: [MessageRowModel] = []
        var previous: ChatItem?
        for item in visible {
            let gap = previous.map { item.at.timeIntervalSince($0.at) } ?? .infinity
            let stamp = gap > 15 * 60 ? item.at : nil
            let tight = stamp == nil && previous?.fromMe == item.fromMe && gap < 120
            rows.append(MessageRowModel(item: item, stamp: stamp, tight: tight,
                                        showsStatus: item.id == lastMine || item.delivery == .failed))
            previous = item
        }
        return rows
    }

    /// "12:37" today, "Yesterday 12:37", "Mon 12:37" this week, "14 Nov 12:37" before.
    static func describe(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if calendar.isDateInYesterday(date) { return "Yesterday \(time)" }
        let english = DateFormatter()
        english.locale = Locale(identifier: "en_GB")
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        english.dateFormat = days < 7 ? "EEE" : "d MMM"
        return "\(english.string(from: date)) \(time)"
    }
}

extension ChatItem {
    /// What Copy puts on the clipboard: the message, a voice note's words, a to-do.
    var copyableText: String? {
        guard kind != .files, let text, !text.isEmpty else { return nil }
        return text
    }

    /// Something to draw: an empty text or file list would leave a bare bubble.
    var hasContent: Bool {
        switch kind {
        case .text: !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .files: !(files ?? []).isEmpty
        case .voice: audio != nil
        case .todo: true
        }
    }
}

extension View {
    /// Right-click a message to copy it. The notch panel isn't key while you
    /// point at it, so the menu has to be XNotch's own, not SwiftUI's.
    @ViewBuilder
    func copyMenu(_ item: ChatItem) -> some View {
        if let text = item.copyableText {
            notchContextMenu {
                [.action(item.kind == .voice ? "Copy Words" : "Copy", symbol: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }]
            }
        } else {
            self
        }
    }
}

private struct MessageRow: View {
    let row: MessageRowModel
    @ObservedObject var store: WalkieStore
    @ObservedObject var player: VoicePlayer
    let contact: Contact
    let accent: Color

    private var item: ChatItem { row.item }

    var body: some View {
        VStack(spacing: 0) {
            if let stamp = row.stamp {
                Text(MessageRowModel.describe(stamp))
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.3))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)
                    .padding(.bottom, 6)
            }
            HStack(alignment: .bottom, spacing: 0) {
                if item.fromMe { Spacer(minLength: 54) }
                VStack(alignment: item.fromMe ? .trailing : .leading, spacing: 3) {
                    content
                        .copyMenu(item)
                    if row.showsStatus, item.fromMe { status }
                }
                if !item.fromMe { Spacer(minLength: 54) }
            }
        }
        .padding(.top, row.stamp != nil ? 0 : row.tight ? 3 : 8)
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .voice: VoiceBubble(item: item, store: store, player: player, accent: accent)
        case .files: FilesBubble(item: item, store: store)
        case .text:
            Text(Self.linked(item.text ?? ""))
                .font(.system(size: 12.5))
                .foregroundStyle(.white)
                .tint(.white)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(item.fromMe ? accent.opacity(0.88) : Color.white.opacity(0.11))
                )
        case .todo: TodoCard(item: item, store: store, contact: contact)
        }
    }

    @ViewBuilder
    private var status: some View {
        Group {
            switch item.delivery {
            case .sending:
                Text("Sending…")
            case .failed:
                Button {
                    store.retry(item, to: contact)
                } label: {
                    Label("Not sent · Try again", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red.opacity(0.95))
                }
                .buttonStyle(.plain)
            case .heard:
                Text(item.kind == .voice ? "Heard" : "Seen")
            default:
                Text("Delivered")
            }
        }
        .font(.system(size: 9.5, weight: .semibold))
        .foregroundStyle(.white.opacity(0.32))
        .padding(.trailing, 4)
        .contentTransition(.interpolate)
        .animation(KitMotion.content, value: item.delivery)
    }

    /// Links in a message, underlined and clickable.
    static func linked(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard text.contains("."),
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return attributed }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed) else { continue }
            attributed[lower..<upper].link = url
            attributed[lower..<upper].underlineStyle = .single
        }
        return attributed
    }
}

private struct VoiceBubble: View {
    let item: ChatItem
    @ObservedObject var store: WalkieStore
    @ObservedObject var player: VoicePlayer
    let accent: Color

    private var isPlaying: Bool { player.playing == item.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 9) {
                Button {
                    guard let audio = item.audio else { return }
                    player.toggle(item.id, url: store.mediaURL(audio))
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(item.fromMe ? accent : .black)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(.white))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(PressScaleStyle(scale: 0.86))
                NoteWaveform(levels: item.levels ?? [], progress: isPlaying ? player.progress : 0,
                             bars: 26, tint: .white)
                    .frame(width: 112, height: 20)
                Text(Durations.clock(isPlaying ? (item.duration ?? 0) * player.progress : item.duration ?? 0))
                    .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
                    .contentTransition(.numericText())
                if !item.fromMe, item.heard != true {
                    Circle().fill(.white).frame(width: 6, height: 6).transition(.scale)
                }
            }
            if let text = item.text, !text.isEmpty {
                Text(text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.78))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: 270, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(item.fromMe ? accent.opacity(0.88) : Color.white.opacity(0.11))
        )
        .animation(KitMotion.content, value: isPlaying)
    }
}

private struct FilesBubble: View {
    let item: ChatItem
    @ObservedObject var store: WalkieStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(item.files ?? []) { file in
                FileChip(file: file, url: store.mediaURL(file.path), fromMe: item.fromMe)
            }
        }
    }
}

private struct FileChip: View {
    let file: ChatItem.StoredFile
    let url: URL
    let fromMe: Bool
    @State private var thumbnail: NSImage?

    var body: some View {
        NotchHoverReader { hovering in
            Group {
                if let thumbnail, isImage {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 180, height: 112)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12)))
                } else {
                    HStack(spacing: 8) {
                        Image(nsImage: thumbnail ?? NSWorkspace.shared.icon(forFile: url.path))
                            .resizable()
                            .frame(width: 26, height: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(file.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                                .font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.5))
                        }
                        .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .frame(maxWidth: 220, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.1)))
                }
            }
            .scaleEffect(hovering ? 1.03 : 1)
            .shadow(color: .black.opacity(hovering ? 0.4 : 0), radius: 8, y: 3)
            .animation(.smooth(duration: 0.34, extraBounce: 0.12), value: hovering)
            .onTapGesture { NSWorkspace.shared.open(url) }
            .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
            .notchContextMenu {
                [.action("Open", symbol: "arrow.up.forward.app") { NSWorkspace.shared.open(url) },
                 .action("Show in Finder", symbol: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }]
            }
            .help("Click to open, drag to take it anywhere")
        }
        .task(id: url) { thumbnail = await Self.thumbnail(url) }
    }

    private var isImage: Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    private static func thumbnail(_ url: URL) async -> NSImage? {
        guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true else { return nil }
        return await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 480,
                      kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) else { return nil }
            return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }.value
    }
}

private struct TodoCard: View {
    let item: ChatItem
    @ObservedObject var store: WalkieStore
    let contact: Contact

    private var done: Bool { item.done ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Button {
                    guard !item.fromMe else { return }
                    withAnimation(.smooth(duration: 0.39, extraBounce: 0.12)) { store.toggleTodo(item, of: contact) }
                } label: {
                    ZStack {
                        Circle()
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.6, dash: done ? [] : [2.2, 2.2]))
                            .foregroundStyle(.white.opacity(done ? 0 : 0.8))
                        Circle()
                            .fill(.white.opacity(0.6))
                            .scaleEffect(done ? 1 : 0.1)
                            .opacity(done ? 1 : 0)
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(.black.opacity(0.75))
                            .scaleEffect(done ? 1 : 0.2)
                            .opacity(done ? 1 : 0)
                    }
                    .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help(item.fromMe ? "\(contact.firstName) ticks this off" : "Tick it off; \(contact.firstName) sees it")
                Text(item.text ?? "")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(done ? 0.45 : 0.95))
                    .strikethrough(done, color: .white.opacity(0.6))
                    .animation(.smooth(duration: 0.3), value: done)
            }
            if let remindAt = item.remindAt {
                Label {
                    Text("Reminder \(Reminder.describe(remindAt))")
                } icon: {
                    Image(systemName: "bell.fill")
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.42))
                .padding(.leading, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 270, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.09))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.08)))
        )
    }
}

// MARK: Controls

/// The mic beside the composer works like a face: hold to talk.
private struct HoldToTalkButton: View {
    let onBegan: () -> Void
    let onEnded: (Bool) -> Void
    @ObservedObject var ui: WalkieUI
    let accent: Color
    let isRecording: Bool
    @State private var down = false

    var body: some View {
        NotchHoverReader { hovering in
            Image(systemName: "mic.fill")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white.opacity(isRecording || hovering ? 1 : 0.7))
                .frame(width: 32, height: 32)
                .background {
                    Circle().fill(isRecording ? (ui.cancelArmed ? Color.red.opacity(0.75) : accent)
                                  : .white.opacity(hovering ? 0.14 : 0.08))
                }
                .scaleEffect(isRecording ? 1.1 : 1)
                .animation(.smooth(duration: 0.3, extraBounce: 0.15), value: isRecording)
                .animation(KitMotion.content, value: ui.cancelArmed)
                .animation(KitMotion.content, value: hovering)
                .contentShape(Circle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !down {
                                down = true
                                onBegan()
                            }
                            let armed = hypot(value.translation.width, value.translation.height) > 70
                            if armed != ui.cancelArmed { withAnimation(KitMotion.content) { ui.cancelArmed = armed } }
                        }
                        .onEnded { _ in
                            down = false
                            onEnded(false)
                        }
                )
                .help("Hold to talk")
        }
    }
}

private struct ComposerIcon: View {
    let symbol: String
    let help: String
    var isOn = false
    var tint: Color = .white
    let action: () -> Void

    var body: some View {
        NotchHoverReader { hovering in
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isOn ? tint : .white.opacity(hovering ? 0.95 : 0.5))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.white.opacity(hovering ? 0.1 : 0)))
                    .contentShape(Circle())
            }
            .buttonStyle(PressScaleStyle(scale: 0.85))
            .animation(KitMotion.content, value: hovering)
            .help(help)
        }
    }
}

struct PillButtonStyle: ButtonStyle {
    let fill: Color
    let text: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(text)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(fill))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(KitMotion.press, value: configuration.isPressed)
    }
}
