import AppKit
import SwiftUI
@testable import Walkie
import XNotchKit

/// `WalkieDemo --stills <folder>`: the notch page in each state, one PNG
/// apiece, to check a layout at a glance without a server.
@MainActor
enum Stills {
    static func run(director: Director, host: NSView, folder: URL, done: @escaping @MainActor () -> Void) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        director.stage.open = 1
        director.stage.cursorVisible = false
        let store = director.store
        let ui = director.ui
        let now = Date()
        let masha = person("Masha Eremeeva", "masha-1")
        store.demoSet(contacts: [masha, mira, jonas])
        store.demoSet(online: [masha.box])
        store.demoSet(chat: [
            ChatItem(id: "s1", fromMe: false, at: now.addingTimeInterval(-86_400 - 600), kind: .text, text: "Did you see the invite?"),
            ChatItem(id: "s2", fromMe: true, at: now.addingTimeInterval(-120), kind: .text, text: "hi"),
            ChatItem(id: "s3", fromMe: true, at: now.addingTimeInterval(-100), kind: .text,
                     text: "https://agents.trendsway.app/invite/Ln3P5X0A-LECY_W0GMGKGIql", delivery: .sent),
            ChatItem(id: "s4", fromMe: false, at: now.addingTimeInterval(-30), kind: .voice, text: "Got it, joining now. Give me two minutes.",
                     duration: 4.2, levels: levelsArray(4.2), audio: "x"),
            ChatItem(id: "s5", fromMe: true, at: now.addingTimeInterval(-10), kind: .text, text: "Perfect 👍", delivery: .sent)
        ], for: masha.box)
        store.demoSet(chat: [], for: mira.box)

        var extra: NSView?
        let steps: [(String, @MainActor () -> Void)] = [
            ("1-faces", { ui.show(.hint) }),
            ("2-chat", { ui.show(.chat(masha.box)) }),
            ("3-chat-recording", {
                ui.beginRecording(masha.box)
                store.recorder.demoBegin()
                for i in 0..<60 {
                    store.recorder.demoFeed(level: speechLevel(Double(i) / 24), elapsed: Double(i) / 24,
                                            transcript: "On my way, see you in the room")
                }
            }),
            ("4-chat-cancel", { ui.cancelArmed = true }),
            ("5-empty-chat", {
                ui.cancelArmed = false
                store.recorder.demoEnd()
                ui.endRecording(sentTo: nil)
                ui.show(.chat(mira.box))
            }),
            ("7-menubar-scroll", {
                ui.endRecording(sentTo: nil)
                store.recorder.demoEnd()
                var many: [ChatItem] = []
                for i in 0..<12 {
                    many.append(ChatItem(id: "m\(i)", fromMe: i % 3 == 0, at: now.addingTimeInterval(Double(i - 12) * 60),
                                         kind: .text, text: "Message number \(i + 1)", delivery: .sent))
                }
                store.demoSet(chat: many, for: masha.box)
                let model = MenuBarModel()
                model.revealed = Set(many.map(\.id))
                let actions = ComposerActions(send: {}, record: {}, stop: {}, discard: {}, attach: {}, screenshot: {},
                                              removeFile: { _ in }, playTake: {})
                let view = FloatingConversation(store: store, model: model, composer: ComposerState(), contact: masha, actions: actions)
                    .environment(\.walkieGlassFallback, true)
                    .padding(40)
                    .frame(width: 452, height: 380, alignment: .bottom)
                    .background(Color(red: 0.25, green: 0.3, blue: 0.45))
                    .environment(\.colorScheme, .dark)
                    .environmentObject(NotchPointer())
                let hosting = NSHostingView(rootView: view)
                hosting.frame = NSRect(origin: .zero, size: CGSize(width: 452, height: 380))
                let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = hosting
                window.setFrameOrigin(NSPoint(x: 900, y: 40))
                window.level = .statusBar
                window.orderFrontRegardless()
                let top = (NSScreen.screens.first?.frame.height ?? 0) - window.frame.maxY
                print("REGION \(Int(window.frame.minX)),\(Int(top)),\(Int(window.frame.width)),\(Int(window.frame.height))")
                fflush(stdout)
                extra = hosting
                // A message sent while it's open: it should come to rest right above the composer.
                DispatchQueue.main.asyncAfter(deadline: .now() + (ProcessInfo.processInfo.environment["ONLY7"] != nil ? 2.0 : 0.4)) {
                    store.demoAppend(ChatItem(id: "new", fromMe: true, at: Date(), kind: .text, text: "some influencer",
                                              delivery: .sent), to: masha.box)
                }
            }),
            ("8-settings-no-server", {
                extra?.window?.orderOut(nil)
                store.demoSet(status: .needsServer)
                extra = settings(store)
            }),
            ("9-settings", {
                extra?.window?.orderOut(nil)
                var request = person("Sam Okafor", "sam-3")
                request.accepted = false
                var unverified = jonas
                unverified.verified = false
                store.demoSet(contacts: [masha, mira, unverified, request])
                store.demoSet(status: .online)
                extra = settings(store)
            }),
            ("6-faces-recording", {
                ui.show(.hint)
                ui.beginRecording(masha.box)
                store.recorder.demoBegin()
                store.recorder.demoFeed(level: 0.6, elapsed: 2.4, transcript: "Hey, quick question about the deck")
            })
        ]
        var index = ProcessInfo.processInfo.environment["ONLY7"] != nil ? 5 : 0
        func next() {
            guard index < steps.count else { done(); return }
            let (name, action) = steps[index]
            index += 1
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + (ProcessInfo.processInfo.environment["ONLY7"] != nil ? 3.5 : 1.2)) {
                save(extra ?? host, to: folder.appendingPathComponent("\(name).png"))
                extra?.window?.orderOut(nil)
                extra = nil
                next()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { next() }
    }

    private static func settings(_ store: WalkieStore) -> NSView {
        let hosting = NSHostingView(rootView: WalkieSettingsPane(store: store).frame(width: 560, height: 900))
        hosting.frame = NSRect(x: 0, y: 0, width: 560, height: 900)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: 60, y: 40))
        window.orderFrontRegardless()
        return hosting
    }

    private static func save(_ view: NSView, to url: URL) {
        view.window?.displayIfNeeded()
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
