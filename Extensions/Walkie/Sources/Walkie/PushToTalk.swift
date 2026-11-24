import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The keys you hold to talk live: a key with ⌘, ⌥ or ⌃, or a function key alone.
struct TalkShortcut: Codable, Hashable {
    var keyCode: UInt32
    /// `NSEvent.ModifierFlags` raw value, limited to ⌘⌥⌃⇧.
    var modifiers: UInt

    static let standard = TalkShortcut(keyCode: UInt32(kVK_Space), modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue)

    private static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20
    ]

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers).intersection([.command, .option, .control, .shift]) }

    init(keyCode: UInt32, modifiers: UInt) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// From a key press, if holding it can't get in the way of typing.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.intersection([.command, .option, .control]).isEmpty || Self.functionKeys.contains(Int(event.keyCode)) else {
            return nil
        }
        keyCode = UInt32(event.keyCode)
        modifiers = flags.rawValue
    }

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    /// "⌃⌥Space", in the order macOS menus use.
    var display: String {
        let order: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return order.filter { flags.contains($0.0) }.map(\.1).joined() + Self.keyName(keyCode)
    }

    private static let named: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13",
        kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20"
    ]

    /// The key's character on the current keyboard layout.
    private static func keyName(_ keyCode: UInt32) -> String {
        if let name = named[Int(keyCode)] { return name }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}

/// A system-wide key you hold: Carbon's hot keys report the press and the
/// release, need no permission, and keep the keys from the frontmost app.
@MainActor
final class PushToTalkKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let onPress: () -> Void
    private let onRelease: () -> Void
    private var held = false
    private static let signature = OSType(0x584E_574B) // "XNWK"
    private static weak var current: PushToTalkKey?

    init(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.onPress = onPress
        self.onRelease = onRelease
    }

    /// Registers the keys, replacing any before; nil turns it off. False
    /// when another app already holds them.
    @discardableResult
    func register(_ shortcut: TalkShortcut?) -> Bool {
        unregister()
        guard let shortcut else { return true }
        installHandler()
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        guard RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0,
                                  &reference) == noErr else {
            reference = nil
            return false
        }
        Self.current = self
        return true
    }

    func unregister() {
        if held { released() }
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    private func pressed() {
        // Key repeat sends the press again while held.
        guard !held else { return }
        held = true
        onPress()
    }

    private func released() {
        guard held else { return }
        held = false
        onRelease()
    }

    private func installHandler() {
        guard handler == nil else { return }
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == PushToTalkKey.signature else { return OSStatus(eventNotHandledErr) }
            let down = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if down { PushToTalkKey.current?.pressed() } else { PushToTalkKey.current?.released() }
                }
            }
            return noErr
        }, specs.count, &specs, nil, &handler)
    }
}

/// Click, then press the keys. Escape cancels; Delete turns live talk's keys off.
struct TalkShortcutRecorder: View {
    @Binding var shortcut: TalkShortcut?
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                isRecording ? stop() : start()
            } label: {
                Text(isRecording ? "Press keys…" : (shortcut?.display ?? "Record Keys"))
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .foregroundStyle(isRecording ? Color.accentColor : .primary)
                    .frame(minWidth: 96)
            }
            .help(isRecording ? "Press a key with ⌘, ⌥ or ⌃, or a function key. Escape cancels." : "Click to choose the keys")
            if shortcut != nil, !isRecording {
                Button {
                    shortcut = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("No keys")
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let plain = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
            switch Int(event.keyCode) {
            case kVK_Escape:
                stop()
            case kVK_Delete where plain, kVK_ForwardDelete where plain:
                shortcut = nil
                stop()
            default:
                guard let recorded = TalkShortcut(event: event) else {
                    NSSound.beep()
                    return nil
                }
                shortcut = recorded
                stop()
            }
            return nil
        }
    }

    private func stop() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
