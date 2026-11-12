import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XNotchKit

struct ConversationView: View {
    @ObservedObject var store: WalkieStore
    @ObservedObject var player: VoicePlayer
    @ObservedObject var ui: WalkieUI
    let contact: Contact
    let isActive: Bool
    let onHoldBegan: () -> Void
    let onHoldEnded: (Bool) -> Void
    /// Their face beside the name, where the faces aren't already on screen above.
    var showsFace = false

    @State private var draft = ""
    @State private var todoMode = false
    @State private var remind: Reminder = .none
    @FocusState private var focused: Bool

    private var items: [ChatItem] { store.chats[contact.box] ?? [] }
    private var accent: Color { Color(hex: FacePalette.tintHex(for: contact.box)) ?? .orange }

    var body: some View {
        VStack(spacing: 6) {
            header
            if !contact.accepted { requestBanner }
            messages
            composer
        }
        .padding(.bottom, 2)
        .onAppear { store.markRead(contact.box) }
        .onChange(of: items.count) { _, _ in if isActive { store.markRead(contact.box) } }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            if showsFace {
                FaceImage(name: contact.name, seed: contact.box, avatar: contact.avatar)
                    .frame(width: 34, height: 34)
                    .overlay(alignment: .bottomTrailing) {
                        if store.talking.contains(contact.box) {
                            TalkingRipples(color: .white).frame(width: 34, height: 34)
                        }
                    }
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(showsFace ? contact.firstName : contact.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Image(systemName: contact.verified ? "checkmark.shield.fill" : "shield")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(contact.verified ? KitStyle.green : .white.opacity(0.35))
                        .help(contact.verified
                              ? "Keys checked: post-quantum end-to-end encrypted."
                              : "Encrypted, keys not yet checked. Compare safety numbers in Settings → Walkie.")
                }
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                    Text(statusText)
                        .contentTransition(.interpolate)
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .animation(KitMotion.content, value: statusText)
            }
            Spacer()
            Image(systemName: "lock.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.28))
                .help("X-Wing (ML-KEM-768 + X25519), signed with ML-DSA-65 and Ed25519")
        }
        .padding(.horizontal, 6)
    }

    private var statusText: String {
        if store.talking.contains(contact.box) { return "Talking to you…" }
        if store.online.contains(contact.box) { return "Active now" }
        return "Gets it when they're back"
    }

    private var statusColor: Color {
        if store.talking.contains(contact.box) { return accent }
        return store.online.contains(contact.box) ? KitStyle.green : .white.opacity(0.25)
    }

    private var requestBanner: some View {
        HStack(spacing: 8) {
            Text("\(contact.firstName) added you. Talk back?")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
            Spacer()
            Button("Accept") { store.accept(contact) }
                .buttonStyle(PillButtonStyle(fill: KitStyle.green, text: .black))
            Button("Remove") {
                ui.show(.hint)
                store.remove(contact)
            }
            .buttonStyle(PillButtonStyle(fill: .white.opacity(0.12), text: .white))
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.06)))
    }

    // MARK: Messages

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                // Not lazy: at most 400 rows, and real heights make the bottom anchor exact.
                VStack(spacing: 6) {
                    if items.isEmpty {
                        Text("Say hi. Hold \(contact.firstName)'s face to talk.")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.35))
                            .padding(.top, 34)
                    }
                    ForEach(items) { item in
                        MessageRow(item: item, store: store, player: player, contact: contact, accent: accent)
                            .id(item.id)
                            .transition(.asymmetric(
                                insertion: .offset(y: 14).combined(with: .opacity).combined(with: .scale(scale: 0.92, anchor: item.fromMe ? .bottomTrailing : .bottomLeading)),
                                removal: .opacity))
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .animation(.smooth(duration: 0.48, extraBounce: 0.06), value: items.map(\.id))
            }
            .defaultScrollAnchor(.bottom)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                                         .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom))
            .onAppear {
                // Open on the newest message, after the first layout pass.
                for delay in [0.0, 0.08] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        if let last = items.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
            .onChange(of: items.last?.id) { _, last in
                guard let last else { return }
                // After the new row's first layout, or it scrolls to where the row isn't yet.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(.smooth(duration: 0.46)) { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                if todoMode {
                    Image(systemName: "circle.dotted")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .transition(.scale.combined(with: .opacity))
                }
                TextField(todoMode ? "A to-do for \(contact.firstName)…" : "Message \(contact.firstName)…", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white)
                    .focused($focused)
                    .onSubmit(send)
                Button(action: send) {
                    HStack(spacing: 4) {
                        Text(todoMode ? "Hand over" : "Send")
                        Image(systemName: "return")
                            .font(.system(size: 9, weight: .bold))
                            .opacity(0.7)
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(draft.isEmpty ? Color.white.opacity(0.1) : accent))
                }
                .buttonStyle(PressScaleStyle(scale: 0.92))
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                .animation(KitMotion.content, value: draft.isEmpty)
            }
            HStack(spacing: 14) {
                HoldToTalkButton(onBegan: onHoldBegan, onEnded: onHoldEnded, ui: ui)
                ComposerIcon(symbol: "camera.viewfinder", help: "Send a screenshot", action: screenshot)
                ComposerIcon(symbol: "plus", help: "Send files", action: pickFiles)
                ComposerIcon(symbol: todoMode ? "checklist.checked" : "checklist", help: "Hand over a to-do",
                             isOn: todoMode) {
                    withAnimation(.smooth(duration: 0.37, extraBounce: 0.12)) { todoMode.toggle() }
                    focused = true
                }
                if todoMode {
                    Menu {
                        ForEach(Reminder.allCases, id: \.self) { choice in
                            Button(choice.title) { remind = choice }
                        }
                    } label: {
                        Label(remind == .none ? "Remind" : remind.title, systemImage: "bell")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .foregroundStyle(.white.opacity(0.7))
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
                Spacer()
            }
            .padding(.leading, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(focused ? 0.1 : 0.07))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(focused ? 0.14 : 0.07)))
        }
        .animation(KitMotion.content, value: focused)
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

private struct MessageRow: View {
    let item: ChatItem
    @ObservedObject var store: WalkieStore
    @ObservedObject var player: VoicePlayer
    let contact: Contact
    let accent: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if item.fromMe { Spacer(minLength: 54) }
            VStack(alignment: item.fromMe ? .trailing : .leading, spacing: 2) {
                content
                footer
            }
            if !item.fromMe { Spacer(minLength: 54) }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .voice: VoiceBubble(item: item, store: store, player: player, accent: accent)
        case .files: FilesBubble(item: item, store: store)
        case .text:
            Text(item.text ?? "")
                .font(.system(size: 12.5))
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(bubble)
        case .todo: TodoCard(item: item, store: store, contact: contact)
        }
    }

    private var bubble: some View {
        RoundedRectangle(cornerRadius: 15, style: .continuous)
            .fill(item.fromMe ? accent.opacity(0.85) : Color.white.opacity(0.1))
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 4) {
            Text(item.at, format: .dateTime.hour().minute())
            if item.fromMe {
                switch item.delivery {
                case .sending: ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 10, height: 10)
                case .failed:
                    Button {
                        store.retry(item, to: contact)
                    } label: {
                        Label("Not sent · Retry", systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                default: Image(systemName: "checkmark").font(.system(size: 7, weight: .bold))
                }
            }
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(.white.opacity(0.3))
        .padding(.horizontal, 4)
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
                             bars: 30, tint: .white)
                    .frame(width: 128, height: 22)
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
        .frame(maxWidth: 280, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(item.fromMe ? accent.opacity(0.85) : Color.white.opacity(0.1))
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

/// The mic in the composer works like a face: hold to talk.
private struct HoldToTalkButton: View {
    let onBegan: () -> Void
    let onEnded: (Bool) -> Void
    @ObservedObject var ui: WalkieUI
    @State private var holding = false
    @State private var down = false

    var body: some View {
        Image(systemName: "waveform")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(holding ? 1 : 0.6))
            .frame(width: 24, height: 22)
            .background(Circle().fill(holding ? Color.red.opacity(0.7) : .clear).frame(width: 28, height: 28))
            .scaleEffect(holding ? 1.15 : 1)
            .animation(.smooth(duration: 0.3, extraBounce: 0.12), value: holding)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !down {
                            down = true
                            holding = true
                            onBegan()
                        }
                        let armed = hypot(value.translation.width, value.translation.height) > 70
                        if armed != ui.cancelArmed { ui.cancelArmed = armed }
                    }
                    .onEnded { _ in
                        down = false
                        holding = false
                        onEnded(false)
                    }
            )
            .help("Hold to talk")
    }
}

private struct ComposerIcon: View {
    let symbol: String
    let help: String
    var isOn = false
    let action: () -> Void

    var body: some View {
        NotchHoverReader { hovering in
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(isOn || hovering ? 0.95 : 0.6))
                    .frame(width: 24, height: 22)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PressScaleStyle(scale: 0.85))
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
