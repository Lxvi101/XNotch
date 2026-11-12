import AppKit
import AVFoundation
import SwiftUI
@testable import Walkie
import XNotchKit

// A scripted tour of Walkie's real views, captured frame by frame to an MP4.
// Nothing here talks to a server or the Keychain: the store is seeded through
// its DEBUG demo hooks.

let arguments = CommandLine.arguments.dropFirst()
let menuBarTour = arguments.contains("--menubar")
let output = URL(fileURLWithPath: arguments.first { !$0.hasPrefix("--") } ?? "walkie-demo.mp4")
let sceneSize = CGSize(width: 760, height: 520)
let fps = 30.0

// MARK: People

func box(_ seed: String) -> String {
    let hex = Array("0123456789abcdef")
    var value = seed.unicodeScalars.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1.value)) &* 1099511628211 }
    return String((0..<64).map { _ in
        value = value &* 6364136223846793005 &+ 1442695040888963407
        return hex[Int(value >> 60)]
    })
}

func person(_ name: String, _ seed: String) -> Contact {
    let keys = WalkieCrypto.PublicKeys(kem: Data(), mldsa: Data(), ed: Data())
    return Contact(box: box(seed), server: "https://drop.example.com", postToken: Data(count: 32), name: name, avatar: nil,
                   keys: keys, verified: true, accepted: true, knowsUs: true,
                   addedAt: Date(), lastActivity: Date())
}

let mira = person("Mira Lindqvist", "mira-2")
let jonas = person("Jonas Weber", "jonas-1")
let aiko = person("Aiko Tanaka", "aiko-1")
let sam = person("Sam Okafor", "sam-3")

/// Speech-like loudness: syllables riding on word envelopes, with pauses.
func speechLevel(_ t: Double) -> Float {
    let word = 0.5 + 0.5 * sin(t * 5.3) * sin(t * 1.7 + 0.4)
    let syllable = abs(sin(t * 23.0 + sin(t * 3.1) * 2))
    let pause = (sin(t * 1.25) > -0.55) ? 1.0 : 0.05
    let jitter = Double.random(in: 0.85...1.1)
    return Float(max(0.02, min(1, (0.15 + 0.85 * word * syllable) * pause * jitter)))
}

func levelsArray(_ seconds: Double) -> [UInt8] {
    (0..<Int(seconds * 24)).map { UInt8(speechLevel(Double($0) / 24) * 255) }
}

// MARK: Scene

@MainActor
final class Stage: ObservableObject {
    @Published var open: CGFloat = 0
    @Published var cursor = CGPoint(x: 600, y: 420)
    @Published var cursorDown = false
    @Published var cursorVisible = true
    @Published var caption = ""
}

/// The black shell of the open notch: concave shoulders at the top, round below.
struct NotchShell: Shape {
    var topCorner: CGFloat = 14
    var bottomCorner: CGFloat = 30

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(bottomCorner, rect.height / 2)
        path.move(to: CGPoint(x: rect.minX - topCorner, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + topCorner), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.maxY), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - r), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + topCorner))
        path.addQuadCurve(to: CGPoint(x: rect.maxX + topCorner, y: rect.minY), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

struct SceneView: View {
    @ObservedObject var stage: Stage
    @ObservedObject var store: WalkieStore
    @ObservedObject var ui: WalkieUI
    let pointer: NotchPointer

    private let notch = CGSize(width: 186, height: 32)

    var body: some View {
        let open = stage.open
        let pageWidth = NotchPageContext.contentWidth + 28
        let pageHeight = notch.height + ui.contentHeight + 14
        let width = notch.width + (pageWidth - notch.width) * open
        let height = notch.height + (pageHeight - notch.height) * open

        ZStack(alignment: .top) {
            wallpaper
            // Menu bar
            HStack {
                Text("Finder").fontWeight(.bold)
                Text("File"); Text("Edit"); Text("View"); Text("Go")
                Spacer()
                Image(systemName: "wifi"); Image(systemName: "battery.75percent")
                Text("Thu 18:03")
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 16)
            .frame(height: notch.height)
            .background(.black.opacity(0.28))

            ZStack(alignment: .top) {
                NotchShell(topCorner: 10 + 6 * open, bottomCorner: 12 + 22 * open)
                    .fill(.black)
                    .shadow(color: .black.opacity(0.55 * open), radius: 24, y: 10)
                    .frame(width: width, height: height)
                WalkiePage(store: store, ui: ui, isActive: true, openSettings: {}, tick: {})
                    .frame(width: NotchPageContext.contentWidth, height: ui.contentHeight)
                    .padding(.top, notch.height + 4)
                    .opacity(Double(max(0, open - 0.35) / 0.65))
                    .blur(radius: (1 - open) * 8)
                    .scaleEffect(0.92 + 0.08 * open, anchor: .top)
                    .frame(width: width, height: height, alignment: .top)
                    .clipped()
            }
            .frame(maxWidth: .infinity)

            if !stage.caption.isEmpty {
                Text(stage.caption)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(.black.opacity(0.45)))
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 26)
                    .id(stage.caption)
                    .transition(.opacity.combined(with: .offset(y: 8)))
            }

            if stage.cursorVisible {
                Image(nsImage: NSCursor.arrow.image)
                    .scaleEffect(stage.cursorDown ? 0.86 : 1, anchor: .topLeading)
                    .position(x: stage.cursor.x + 8, y: stage.cursor.y + 11)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: sceneSize.width, height: sceneSize.height)
        .coordinateSpace(name: KitSpace.canvas)
        .environmentObject(pointer)
        .environment(\.colorScheme, .dark)
    }

    /// Drawn once: blurs are the costliest thing to re-render every frame.
    @MainActor static let wallpaperImage: NSImage? = {
        let renderer = ImageRenderer(content: SceneView.wallpaperContent.frame(width: sceneSize.width, height: sceneSize.height))
        renderer.scale = 2
        return renderer.nsImage
    }()

    private var wallpaper: some View {
        Group {
            if let image = Self.wallpaperImage { Image(nsImage: image).resizable() } else { Self.wallpaperContent }
        }
    }

    static var wallpaperContent: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.10, green: 0.12, blue: 0.22), Color(red: 0.20, green: 0.10, blue: 0.24)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color(red: 1, green: 0.45, blue: 0.3).opacity(0.35)).frame(width: 420).blur(radius: 90)
                .offset(x: -220, y: 170)
            Circle().fill(Color(red: 0.3, green: 0.55, blue: 1).opacity(0.35)).frame(width: 380).blur(radius: 90)
                .offset(x: 260, y: -40)
        }
    }
}

// MARK: Recording

@MainActor
final class Recorder {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let size: CGSize
    private var start: CFTimeInterval?

    init(url: URL, size: CGSize) throws {
        try? FileManager.default.removeItem(at: url)
        self.size = size
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height)
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
    }

    var ticks = 0, notReady = 0, renderTime = 0.0

    func capture(_ view: NSView) {
        ticks += 1
        if !input.isReadyForMoreMediaData { notReady += 1 }
        let began = CACurrentMediaTime()
        defer { renderTime += CACurrentMediaTime() - began }
        let now = CACurrentMediaTime()
        if start == nil { start = now }
        guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool, let layer = view.layer else { return }
        // This server's display sleeps, so AppKit skips drawing the occluded window; draw now.
        view.window?.displayIfNeeded()
        view.layoutSubtreeIfNeeded()
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        // Straight into the video frame: flip to AppKit's origin and draw the layer tree at 2x.
        if let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
                                   bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            let scale = size.width / view.bounds.width
            // The hosting view's layer is flipped; draw it top-down into the frame.
            if layer.isGeometryFlipped {
                context.translateBy(x: 0, y: size.height)
                context.scaleBy(x: scale, y: -scale)
            } else {
                context.scaleBy(x: scale, y: scale)
            }
            layer.render(in: context)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let time = CMTime(seconds: now - start!, preferredTimescale: 600)
        adaptor.append(buffer, withPresentationTime: time)
    }

    func finish() async {
        input.markAsFinished()
        await writer.finishWriting()
    }
}

// MARK: Script

@MainActor
final class Director {
    let stage = Stage()
    let pointer = NotchPointer()
    let store: WalkieStore
    let ui = WalkieUI()
    var host: NSView!
    var recorder: Recorder!
    private var clock: Timer?
    private var t0 = CACurrentMediaTime()
    private var cursorFrom = CGPoint.zero
    private var cursorTo = CGPoint.zero
    private var cursorStart: CFTimeInterval = 0
    private var cursorDuration: Double = 1
    var tickHook: ((Double) -> Void)?

    init() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("walkie-demo-\(UUID().uuidString)")
        store = try WalkieStore.demo(directory: dir)
        store.demoSet(contacts: [mira, jonas, aiko, sam])
        store.demoSet(online: [mira.box, aiko.box])
        seedChat()
    }

    private func seedChat() {
        let now = Date()
        var items: [ChatItem] = [
            ChatItem(id: "a1", fromMe: false, at: now.addingTimeInterval(-3600 * 3), kind: .text, text: "Landed! Coffee tomorrow?"),
            ChatItem(id: "a2", fromMe: true, at: now.addingTimeInterval(-3600 * 3 + 40), kind: .voice,
                     text: "Yes! The usual place, around nine.", duration: 3.4, levels: levelsArray(3.4), audio: "x",
                     delivery: .sent)
        ]
        if let image = Self.moodboard(), let dir = Optional(store.mediaURL("aiko/m1")) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("moodboard.png")
            try? image.write(to: url)
            items.insert(ChatItem(id: "a0", fromMe: false, at: now.addingTimeInterval(-3600 * 4), kind: .files,
                                  files: [.init(name: "moodboard.png", size: image.count, path: "aiko/m1/moodboard.png")]),
                         at: 0)
        }
        store.demoSet(chat: items, for: aiko.box)
        store.demoSet(chat: [], for: mira.box)
    }

    /// An abstract gradient picture for the files bubble.
    static func moodboard() -> Data? {
        let renderer = ImageRenderer(content:
            ZStack {
                LinearGradient(colors: [.orange, .pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(.yellow.opacity(0.7)).frame(width: 140).blur(radius: 30).offset(x: -90, y: 40)
                Circle().fill(.cyan.opacity(0.6)).frame(width: 160).blur(radius: 40).offset(x: 110, y: -50)
            }.frame(width: 480, height: 300))
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // Positions in scene coordinates.
    func facePoint(_ index: Int) -> CGPoint {
        let count = store.contacts.count + 1
        let spacing: CGFloat = 42 + 14
        let mid = sceneSize.width / 2
        let x = mid + (CGFloat(index) - CGFloat(count - 1) / 2) * spacing
        return CGPoint(x: x, y: 32 + 4 + 26)
    }

    func move(to point: CGPoint, over seconds: Double) {
        cursorFrom = stage.cursor
        cursorTo = point
        cursorStart = CACurrentMediaTime()
        cursorDuration = seconds
    }

    func start() {
        t0 = CACurrentMediaTime()
        clock = Timer.scheduledTimer(withTimeInterval: 1 / fps, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(clock!, forMode: .common)
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let p = min(1, (now - cursorStart) / max(0.01, cursorDuration))
        let e = p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2
        stage.cursor = CGPoint(x: cursorFrom.x + (cursorTo.x - cursorFrom.x) * e, y: cursorFrom.y + (cursorTo.y - cursorFrom.y) * e)
        pointer.update(stage.open > 0.5 ? stage.cursor : nil)
        tickHook?(now - t0)
        recorder.capture(host)
    }

    func at(_ seconds: Double, _ action: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated(action) }
    }

    func say(_ text: String) {
        withAnimation(.easeOut(duration: 0.35)) { stage.caption = text }
    }

    // MARK: The tour

    func run(done: @escaping @MainActor () -> Void) {
        start()
        let words = "Hey Mira, are we still on for the review at three? I'll bring the new mockups.".split(separator: " ")
        let incomingWords = "Can you look over the deck before lunch? Slide seven needs your numbers."

        // 1. The notch opens on Walkie.
        at(0.6) { self.move(to: CGPoint(x: 380, y: 22), over: 1.0) }
        at(1.4) {
            self.say("Your people live in the notch")
            withAnimation(.spring(response: 0.55, dampingFraction: 0.78)) { self.stage.open = 1 }
        }
        // 2. Hover the faces; they spread out.
        at(2.6) { self.move(to: self.facePoint(0), over: 0.8) }
        at(3.6) { self.move(to: self.facePoint(2), over: 0.7) }
        at(4.4) { self.move(to: self.facePoint(0), over: 0.6) }

        // 3. Hold Mira and talk.
        at(5.3) {
            self.say("Hold a face and talk")
            withAnimation(KitMotion.press) { self.stage.cursorDown = true }
        }
        at(5.55) {
            self.ui.beginRecording(mira.box)
            self.store.recorder.demoBegin()
            let started = CACurrentMediaTime()
            self.tickHook = { _ in
                let elapsed = CACurrentMediaTime() - started
                let spoken = min(words.count, Int(elapsed * 2.9))
                self.store.recorder.demoFeed(level: speechLevel(elapsed), elapsed: elapsed,
                                             transcript: words.prefix(spoken).joined(separator: " "))
            }
        }
        at(7.0) { self.say("It's written down as you speak") }
        // A drag away arms cancel; coming back disarms it.
        at(9.2) {
            self.move(to: CGPoint(x: self.facePoint(0).x + 30, y: 175), over: 0.5)
        }
        at(9.5) { withAnimation(KitMotion.content) { self.ui.cancelArmed = true }; self.say("Drag away to cancel") }
        at(10.5) { self.move(to: self.facePoint(0), over: 0.45) }
        at(10.8) { withAnimation(KitMotion.content) { self.ui.cancelArmed = false } }
        // Let go: it's sent.
        at(11.8) {
            self.say("Let go, and it's on their Mac")
            self.tickHook = nil
            self.store.recorder.demoEnd()
            withAnimation(KitMotion.press) { self.stage.cursorDown = false }
            let note = ChatItem(id: "m1", fromMe: true, at: Date(), kind: .voice,
                                text: words.joined(separator: " "), duration: 6.2, levels: levelsArray(6.2), audio: "x",
                                delivery: .sent)
            self.store.demoAppend(note, to: mira.box)
            self.ui.endRecording(sentTo: mira.box)
        }

        // 4. Aiko is talking to you.
        at(13.8) {
            self.move(to: CGPoint(x: 560, y: 300), over: 0.9)
            self.say("Ripples: Aiko is talking to you")
            withAnimation(.easeOut(duration: 0.3)) { self.store.demoSet(talking: [aiko.box]) }
        }
        at(16.6) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                self.store.demoSet(talking: [])
                self.store.demoSet(unread: [aiko.box: 1])
            }
            let incoming = ChatItem(id: "a4", fromMe: false, at: Date(), kind: .voice, text: incomingWords,
                                    duration: 4.8, levels: levelsArray(4.8), audio: "x", heard: false)
            self.store.demoAppend(incoming, to: aiko.box)
            self.say("Their note arrives, and plays")
        }
        // It plays: the ring fills around her face.
        at(17.0) {
            let started = CACurrentMediaTime()
            self.tickHook = { _ in
                let progress = (CACurrentMediaTime() - started) / 4.8
                self.store.player.demoPlay(progress < 1 ? "a4" : nil, progress: min(1, progress))
                if progress >= 1 {
                    self.tickHook = nil
                    self.store.demoUpdate("a4", in: aiko.box) { $0.heard = true }
                }
            }
        }

        // She also hands over a to-do.
        at(18.2) {
            let todo = ChatItem(id: "a3", fromMe: false, at: Date(), kind: .todo, text: "Book the big room for Friday",
                                remindAt: Calendar.current.date(bySettingHour: 9, minute: 0, second: 0,
                                                                of: Date().addingTimeInterval(86_400)),
                                done: false)
            self.store.demoAppend(todo, to: aiko.box)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) { self.store.demoSet(unread: [aiko.box: 2]) }
        }

        // 5. Click Aiko: the conversation.
        at(18.4) { self.move(to: self.facePoint(2), over: 0.8) }
        at(19.3) { withAnimation(KitMotion.press) { self.stage.cursorDown = true } }
        at(19.45) {
            withAnimation(KitMotion.press) { self.stage.cursorDown = false }
            self.store.markRead(aiko.box)
            self.store.demoSet(unread: [:])
            self.ui.toggleChat(aiko.box)
            self.say("Click a face for the conversation")
        }
        at(21.9) { self.say("Hand over to-dos, tick them off") }
        at(22.6) { self.move(to: CGPoint(x: 218, y: 228), over: 0.8) }
        at(23.7) { withAnimation(KitMotion.press) { self.stage.cursorDown = true } }
        at(23.85) {
            withAnimation(KitMotion.press) { self.stage.cursorDown = false }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.6)) {
                self.store.demoUpdate("a3", in: aiko.box) { $0.done = true }
            }
        }
        // Back to the faces.
        at(25.6) {
            self.say("Sealed with post-quantum encryption")
            self.ui.show(.hint)
            self.move(to: CGPoint(x: 520, y: 260), over: 1.0)
        }
        at(28.0) {
            self.say("")
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { self.stage.open = 0 }
        }
        at(29.4) { done() }
    }
}

// MARK: Main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

MainActor.assumeIsolated {
    do {
        let director = try Director()
        let host: NSView
        var menuBar: MenuBarDirector?
        if menuBarTour {
            let tour = MenuBarDirector(store: director.store)
            let scene = MenuBarSceneHost(tour: tour)
            host = NSHostingView(rootView: scene)
            menuBar = tour
        } else {
            host = NSHostingView(rootView: SceneView(stage: director.stage, store: director.store, ui: director.ui,
                                                     pointer: director.pointer))
        }
        host.frame = NSRect(origin: .zero, size: sceneSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        window.orderFrontRegardless()
        let scale: CGFloat = 1.5
        let pixels = CGSize(width: sceneSize.width * scale, height: sceneSize.height * scale)
        print("recording \(Int(pixels.width))×\(Int(pixels.height)) at \(scale)x to \(output.path)")
        let recorder = try Recorder(url: output, size: pixels)
        let finish: @MainActor () -> Void = {
            Task { @MainActor in
                await recorder.finish()
                print("done ticks \(recorder.ticks) avg capture ms \(Int(recorder.renderTime / Double(max(1, recorder.ticks)) * 1000))")
                exit(0)
            }
        }
        if let menuBar {
            menuBar.host = host
            menuBar.recorder = recorder
            menuBar.run(done: finish)
        } else {
            director.host = host
            director.recorder = recorder
            director.run(done: finish)
        }
    } catch {
        print("failed: \(error)")
        exit(1)
    }
}
app.run()

/// Re-reads the tour's panel placement, which moves between faces.
struct MenuBarSceneHost: View {
    @ObservedObject var tour: MenuBarDirector

    var body: some View {
        MenuBarScene(stage: tour.stage, cursor: tour.cursor, store: tour.store, model: tour.model, ui: tour.ui,
                     composer: tour.composer, actions: tour.actions, stripOrigin: tour.stripOrigin,
                     panelOrigin: tour.panelOrigin, geometry: tour.geometry)
            .coordinateSpace(name: KitSpace.canvas)
            .environmentObject(tour.pointer)
    }
}
