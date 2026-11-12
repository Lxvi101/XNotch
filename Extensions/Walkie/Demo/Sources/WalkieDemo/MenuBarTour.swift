import AppKit
import SwiftUI
@testable import Walkie
import XNotchKit

/// The menu bar tour: Walkie's real strip and panel views in a mock menu bar.
@MainActor
final class MenuBarStage: ObservableObject {
    @Published var caption = ""
}

/// The cursor on its own, so moving it redraws only the cursor.
@MainActor
final class CursorState: ObservableObject {
    @Published var cursor = CGPoint(x: 600, y: 380)
    @Published var cursorDown = false
    /// A picture being dragged from the desktop, at the cursor.
    @Published var dragging: NSImage?
}

struct CursorLayer: View {
    @ObservedObject var state: CursorState

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let image = state.dragging {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 90, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white, lineWidth: 2.5))
                    .rotationEffect(.degrees(-5))
                    .shadow(color: .black.opacity(0.4), radius: 10, y: 5)
                    .position(x: state.cursor.x + 6, y: state.cursor.y + 4)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
            Image(nsImage: NSCursor.arrow.image)
                .scaleEffect(state.cursorDown ? 0.86 : 1, anchor: .topLeading)
                .position(x: state.cursor.x + 8, y: state.cursor.y + 11)
        }
        .frame(width: sceneSize.width, height: sceneSize.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

enum MenuBarDemo {
    static let barHeight: CGFloat = 30
    static let panelSize = CGSize(width: 540, height: 520)
}

struct MenuBarScene: View {
    @ObservedObject var stage: MenuBarStage
    let cursor: CursorState
    @ObservedObject var store: WalkieStore
    @ObservedObject var model: MenuBarModel
    @ObservedObject var ui: WalkieUI
    let composer: ComposerState
    let actions: ComposerActions
    let stripOrigin: CGPoint
    let panelOrigin: CGPoint
    let geometry: PanelGeometry

    var body: some View {
        let stripWidth = MenuBarLayout.width(count: store.stripPeople.count, barHeight: MenuBarDemo.barHeight)
        ZStack(alignment: .topLeading) {
            SceneView.wallpaperImage.map { Image(nsImage: $0).resizable() }
            HStack(spacing: 0) {
                Image(systemName: "applelogo").padding(.leading, 18)
                Text("Finder").fontWeight(.bold).padding(.leading, 18)
                Text("File").padding(.leading, 16)
                Text("Edit").padding(.leading, 16)
                Spacer()
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.92))
            .frame(width: sceneSize.width, height: MenuBarDemo.barHeight)
            .background(.black.opacity(0.32))

            HStack(spacing: 18) {
                Image(systemName: "cloud.sun.fill")
                Image(systemName: "battery.100percent")
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .fixedSize()
            .position(x: stripOrigin.x - 46, y: MenuBarDemo.barHeight / 2)

            MenuBarFaces(store: store, model: model, ui: ui, player: store.player, barHeight: MenuBarDemo.barHeight)
                .offset(x: stripOrigin.x, y: 0)

            HStack(spacing: 18) {
                Image(systemName: "switch.2")
                Text("18:03").monospacedDigit()
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .fixedSize()
            .position(x: stripOrigin.x + stripWidth + 46, y: MenuBarDemo.barHeight / 2)

            MenuBarPanelView(store: store, model: model, ui: ui, composer: composer, actions: actions, geometry: geometry)
                .frame(width: MenuBarDemo.panelSize.width, height: MenuBarDemo.panelSize.height)
                .offset(x: panelOrigin.x, y: panelOrigin.y)
                .environment(\.walkieGlassFallback, true)

            if !stage.caption.isEmpty {
                Text(stage.caption)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(.black.opacity(0.45)))
                    .position(x: sceneSize.width / 2, y: sceneSize.height - 34)
                    .id(stage.caption)
                    .transition(.opacity.combined(with: .offset(y: 8)))
            }

            CursorLayer(state: cursor)
        }
        .frame(width: sceneSize.width, height: sceneSize.height, alignment: .topLeading)
        .clipped()
        .environment(\.colorScheme, .dark)
    }
}

@MainActor
final class MenuBarDirector: ObservableObject {
    let stage = MenuBarStage()
    let cursor = CursorState()
    let model = MenuBarModel()
    let ui = WalkieUI()
    let composer = ComposerState()
    let pointer = NotchPointer()
    let geometry = PanelGeometry()
    let store: WalkieStore
    var host: NSView!
    var recorder: Recorder!
    var tickHook: (() -> Void)?
    private var clock: Timer?
    private var cursorFrom = CGPoint.zero
    private var cursorTo = CGPoint.zero
    private var cursorStart: CFTimeInterval = 0
    private var cursorDuration = 1.0

    let stripOrigin: CGPoint
    @Published private(set) var panelOrigin = CGPoint.zero

    lazy var actions = ComposerActions(send: { [weak self] in self?.sendComposer() }, record: {}, stop: {}, discard: {},
                                       attach: {}, screenshot: {}, removeFile: { _ in }, playTake: {})

    init(store: WalkieStore) {
        self.store = store
        store.displayName = "You"
        let width = MenuBarLayout.width(count: store.stripPeople.count, barHeight: MenuBarDemo.barHeight)
        stripOrigin = CGPoint(x: (sceneSize.width - width) / 2 + 40, y: 0)
        store.demoSet(lastSeen: [jonas.box: Date().addingTimeInterval(-2 * 3600), sam.box: Date().addingTimeInterval(-86_400)])
        store.demoSet(online: [mira.box, aiko.box])
        // Older lines are already read; Aiko's last one is new.
        model.revealed = Set((store.chats[aiko.box] ?? []).map(\.id))
        aim(at: store.contacts[0].box)
    }

    var people: [Contact] { store.stripPeople }

    /// Where a face sits once it's in focus, which is where the pointer heads for.
    func faceX(_ box: String) -> CGFloat {
        let index = people.firstIndex { $0.box == box } ?? 0
        return stripOrigin.x + MenuBarLayout.centers(count: people.count, barHeight: MenuBarDemo.barHeight, focus: index)[index]
    }

    private var focusIndex: Int? {
        let box = model.dropTarget ?? model.hovered ?? { if case .chat(let b) = ui.panel { return b } else { return nil } }()
        return box.flatMap { b in people.firstIndex { $0.box == b } }
    }

    /// Puts the panel under a face (or, with nil, under the middle of the strip, for drops).
    func aim(at box: String?) {
        let x = box.map(faceX) ?? (stripOrigin.x + MenuBarLayout.width(count: people.count, barHeight: MenuBarDemo.barHeight) / 2)
        let origin = min(max(x - MenuBarDemo.panelSize.width / 2, 8), sceneSize.width - MenuBarDemo.panelSize.width - 8)
        panelOrigin = CGPoint(x: origin, y: MenuBarDemo.barHeight)
        geometry.anchorX = (x - origin) / MenuBarDemo.panelSize.width
        var faces: [String: CGFloat] = [:]
        for person in people { faces[person.box] = faceX(person.box) - origin }
        geometry.faceX = faces
    }

    func move(to point: CGPoint, over seconds: Double) {
        cursorFrom = cursor.cursor
        cursorTo = point
        cursorStart = CACurrentMediaTime()
        cursorDuration = seconds
    }

    func at(_ seconds: Double, _ action: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated(action) }
    }

    func say(_ text: String) {
        withAnimation(.easeOut(duration: 0.3)) { stage.caption = text }
    }

    func click(_ then: @escaping @MainActor () -> Void) {
        withAnimation(KitMotion.press) { cursor.cursorDown = true }
        at(0.12) {
            withAnimation(KitMotion.press) { self.cursor.cursorDown = false }
            then()
        }
    }

    /// Types like a person: a character at a time, a little slower on spaces.
    func type(_ text: String, from start: Double) -> Double {
        var t = start
        for index in text.indices {
            let prefix = String(text[...index])
            at(t) { self.composer.text = prefix }
            t += text[index] == " " ? 0.09 : 0.055
        }
        return t
    }

    func open(_ contact: Contact) {
        aim(at: contact.box)
        composer.prepare(for: contact.box)
        model.hovered = nil
        store.demoSet(unread: [:])
        ui.show(.chat(contact.box))
    }

    private func sendComposer() {
        guard case .chat(let box) = ui.panel else { return }
        withAnimation(MenuBarMotion.pop) {
            if !composer.files.isEmpty {
                let files = composer.files.compactMap { url -> ChatItem.StoredFile? in
                    guard let data = try? Data(contentsOf: url),
                          let path = try? store.disk.store(data, box: box, folder: UUID().uuidString, name: url.lastPathComponent)
                    else { return nil }
                    return .init(name: url.lastPathComponent, size: data.count, path: path)
                }
                store.demoAppend(ChatItem(id: UUID().uuidString, fromMe: true, at: Date(), kind: .files, files: files,
                                          delivery: .sent), to: box)
                composer.files = []
            }
            if composer.phase == .review, let take = composer.take {
                store.demoAppend(ChatItem(id: UUID().uuidString, fromMe: true, at: Date(), kind: .voice, text: take.transcript,
                                          duration: take.duration, levels: take.levels, audio: "x", delivery: .sent), to: box)
                composer.take = nil
            }
            let text = composer.text.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                store.demoAppend(ChatItem(id: UUID().uuidString, fromMe: true, at: Date(), kind: .text, text: text,
                                          delivery: .sent), to: box)
            }
            composer.text = ""
            composer.phase = .idle
        }
    }

    private func tick() {
        let p = min(1, (CACurrentMediaTime() - cursorStart) / max(0.01, cursorDuration))
        let e = p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2
        cursor.cursor = CGPoint(x: cursorFrom.x + (cursorTo.x - cursorFrom.x) * e, y: cursorFrom.y + (cursorTo.y - cursorFrom.y) * e)
        // The name pill follows the pointer along the strip while nothing is open.
        if case .hint = ui.panel, cursor.dragging == nil {
            let inStrip = cursor.cursor.y < MenuBarDemo.barHeight
            let hovered = inStrip ? MenuBarLayout.face(at: cursor.cursor.x - stripOrigin.x, count: people.count,
                                                       barHeight: MenuBarDemo.barHeight, focus: focusIndex).map { people[$0].box } : nil
            if model.hovering != inStrip { model.hovering = inStrip }
            if model.hovered != hovered {
                model.hovered = hovered
                if let hovered { aim(at: hovered) }
            }
        }
        if model.dropTarget != nil, !model.dropLeaving {
            // The pointer picks the face, as in the real strip.
            let local = cursor.cursor.x - stripOrigin.x
            let centers = MenuBarLayout.centers(count: people.count, barHeight: MenuBarDemo.barHeight, focus: focusIndex)
            if let nearest = centers.enumerated().min(by: { abs($0.element - local) < abs($1.element - local) }) {
                let box = people[nearest.offset].box
                if model.dropTarget != box { model.dropTarget = box }
            }
            model.dropPoint = CGPoint(x: cursor.cursor.x - panelOrigin.x, y: cursor.cursor.y - panelOrigin.y - 6)
        }
        pointer.update(cursor.cursor)
        tickHook?()
        recorder.capture(host)
    }

    func run(done: @escaping @MainActor () -> Void) {
        clock = Timer.scheduledTimer(withTimeInterval: 1 / fps, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(clock!, forMode: .common)
        store.demoAppend(ChatItem(id: "a5", fromMe: false, at: Date(), kind: .text,
                                  text: "can you send me the deck before lunch?"), to: aiko.box)
        store.demoSet(unread: [aiko.box: 1])

        // 1. Hover along the faces: each one names itself.
        at(0.3) { self.say("Hover: who's around") }
        at(0.4) { self.move(to: CGPoint(x: self.faceX(sam.box), y: 14), over: 0.9) }
        at(1.5) { self.move(to: CGPoint(x: self.faceX(jonas.box), y: 14), over: 0.6) }
        at(2.3) { self.move(to: CGPoint(x: self.faceX(aiko.box), y: 14), over: 0.5) }

        // 2. Click Aiko: bubbles over the desktop, her new line coming into focus.
        at(3.1) {
            self.say("Click: the conversation, right there")
            self.click { self.open(aiko) }
        }
        at(3.6) { self.move(to: CGPoint(x: self.faceX(aiko.box) + 160, y: 300), over: 0.8) }

        // 3. Type and send.
        let typed = type("sure, sending it now", from: 4.6)
        at(typed + 0.4) { self.sendComposer() }

        // 4. Record from the composer, stop into review, send.
        let words = "and quick heads up, slide seven still needs your numbers".split(separator: " ")
        let recordAt = typed + 1.4
        at(recordAt) {
            self.say("Talk: written down as you speak")
            self.store.recorder.demoBegin()
            withAnimation(MenuBarMotion.morph) { self.composer.phase = .recording }
            let started = CACurrentMediaTime()
            self.tickHook = {
                let elapsed = CACurrentMediaTime() - started
                let spoken = min(words.count, Int(elapsed * 2.8))
                self.store.recorder.demoFeed(level: speechLevel(elapsed), elapsed: elapsed,
                                             transcript: words.prefix(spoken).joined(separator: " "))
            }
        }
        at(recordAt + 4.2) {
            self.tickHook = nil
            self.store.recorder.demoEnd()
            self.composer.take = VoiceRecorder.Take(url: URL(fileURLWithPath: "/dev/null"), duration: 4.2,
                                                    levels: levelsArray(4.2), transcript: words.joined(separator: " "))
            self.say("Stop, listen back, send")
            withAnimation(MenuBarMotion.morph) { self.composer.phase = .review }
        }
        at(recordAt + 5.6) { self.sendComposer() }

        // 5. Drag a picture up to the strip: the drop panel follows the pointer from face to face.
        let dropAt = recordAt + 6.8
        let picture = Director.moodboard().flatMap(NSImage.init(data:))
        at(dropAt) {
            self.ui.show(.hint)
            self.say("Drag anything to the menu bar")
            self.move(to: CGPoint(x: 160, y: 400), over: 0.6)
        }
        at(dropAt + 0.7) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { self.cursor.dragging = picture }
            self.move(to: CGPoint(x: self.faceX(WalkieStore.selfBox), y: 18), over: 1.0)
        }
        at(dropAt + 1.75) {
            self.aim(at: nil)
            self.model.dropTarget = WalkieStore.selfBox
            self.move(to: CGPoint(x: self.faceX(WalkieStore.selfBox), y: 90), over: 0.6)
        }
        at(dropAt + 2.5) {
            self.say("Pick a face as you go")
            self.move(to: CGPoint(x: self.faceX(sam.box) + 20, y: 110), over: 2.2)
        }
        at(dropAt + 4.9) { self.move(to: CGPoint(x: self.faceX(mira.box), y: 100), over: 1.0) }
        // Out of the panel: dots fade, then the panel.
        at(dropAt + 6.1) { self.move(to: CGPoint(x: 120, y: 420), over: 0.9) }
        at(dropAt + 6.5) {
            self.model.dropLeaving = true
            self.at(0.6) {
                self.model.dropTarget = nil
                self.model.dropLeaving = false
                self.model.dropPoint = nil
            }
        }
        // Back in, onto Mira, and let go: it waits in her composer.
        at(dropAt + 7.6) { self.move(to: CGPoint(x: self.faceX(mira.box), y: 18), over: 1.0) }
        at(dropAt + 8.65) {
            self.aim(at: nil)
            self.model.dropTarget = mira.box
            self.move(to: CGPoint(x: self.faceX(mira.box) - 30, y: 95), over: 0.6)
        }
        at(dropAt + 9.5) {
            self.model.dropTarget = nil
            self.model.dropPoint = nil
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { self.cursor.dragging = nil }
            self.open(mira)
            if let data = Director.moodboard() {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("moodboard.png")
                try? data.write(to: url)
                withAnimation(MenuBarMotion.pop) { self.composer.files = [url] }
            }
            self.say("It waits in the composer, with a note")
        }
        let noted = type("the moodboard for friday", from: dropAt + 10.2)
        at(noted + 0.4) { self.sendComposer() }
        at(noted + 2.0) {
            self.say("")
            self.ui.show(.hint)
        }
        at(noted + 2.6) { done() }
    }
}
