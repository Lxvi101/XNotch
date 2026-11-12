import Foundation

/// Hold to talk, shared by the notch page and the menu bar faces: start on
/// hold, then send on release, or throw away when cancel is armed.
@MainActor
enum Talk {
    static func begin(_ contact: Contact, store: WalkieStore, ui: WalkieUI, tick: @escaping () -> Void) {
        guard store.recorder.micAuthorized else {
            Task {
                if await VoiceRecorder.requestMic() {
                    ui.flash("Microphone on. Hold the face again to talk.")
                } else {
                    ui.flash("XNotch needs the microphone: System Settings → Privacy & Security → Microphone.")
                }
            }
            return
        }
        do {
            try store.recorder.start(directory: FileManager.default.temporaryDirectory.appendingPathComponent("XNotchWalkie"),
                                     transcribe: store.transcribe) {
                end(contact, cancel: false, store: store, ui: ui, tick: tick)
            }
        } catch {
            ui.flash(error.localizedDescription)
            return
        }
        tick()
        store.player.stop()
        store.signalTalking(true, to: contact)
        ui.beginRecording(contact.box)
    }

    static func end(_ contact: Contact, cancel: Bool, store: WalkieStore, ui: WalkieUI, tick: @escaping () -> Void) {
        guard store.recorder.isRecording else { return }
        let cancelled = cancel || ui.cancelArmed
        store.signalTalking(false, to: contact)
        if cancelled {
            store.recorder.cancel()
            ui.endRecording(sentTo: nil)
            return
        }
        Task {
            let take = await store.recorder.stop()
            guard let take else {
                ui.endRecording(sentTo: nil)
                ui.flash("Hold a little longer to talk. A click opens the conversation.")
                return
            }
            tick()
            store.sendVoice(take, to: contact)
            ui.endRecording(sentTo: contact.box)
        }
    }
}
