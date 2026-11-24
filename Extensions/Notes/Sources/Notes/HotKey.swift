import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// A key and its modifiers, as the user pressed them.
struct KeyShortcut: Codable, Hashable {
    var keyCode: UInt32
    /// `NSEvent.ModifierFlags` raw value, limited to ⌘⌥⌃⇧.
    var modifiers: UInt
    /// The modifiers among `modifiers` that must be pressed on the right side
    /// of the keyboard, like right ⌘ + period. Nil or empty: either side.
    var rightModifiers: UInt?

    static let toggleDefault = KeyShortcut(keyCode: UInt32(kVK_ANSI_N), modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue)

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers).intersection([.command, .option, .control, .shift]) }

    var rightFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: rightModifiers ?? 0).intersection(flags) }

    /// Needs one side of the keyboard, which Carbon's hot keys can't tell apart.
    var isSideSpecific: Bool { !rightFlags.isEmpty }

    /// From a key press, if it makes a usable global shortcut: at least one
    /// of ⌘⌥⌃, so plain typing never fires it. A modifier held on the right
    /// side is recorded as right-only, so right ⌘ + period leaves ⌘ + period
    /// on the left free for other apps.
    init?(event: NSEvent) {
        self.init(keyCode: UInt32(event.keyCode), rawFlags: UInt(event.modifierFlags.rawValue))
    }

    /// From the raw flags of an `NSEvent` or `CGEvent`, which share a layout.
    init?(keyCode: UInt32, rawFlags: UInt) {
        let flags = NSEvent.ModifierFlags(rawValue: rawFlags).intersection([.command, .option, .control, .shift])
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        self.keyCode = keyCode
        modifiers = flags.rawValue
        let right = Self.rightSide(rawFlags).intersection(flags)
        rightModifiers = right.isEmpty ? nil : right.rawValue
    }

    init(keyCode: UInt32, modifiers: UInt, rightModifiers: UInt? = nil) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.rightModifiers = rightModifiers
    }

    /// Whether a key press with these raw flags is this shortcut. The right-only
    /// modifiers must be down on the right; the others may be on either side.
    func matches(keyCode: UInt32, rawFlags: UInt) -> Bool {
        guard keyCode == self.keyCode else { return false }
        let pressed = NSEvent.ModifierFlags(rawValue: rawFlags).intersection([.command, .option, .control, .shift])
        return pressed == flags && Self.rightSide(rawFlags).isSuperset(of: rightFlags)
    }

    /// The device-dependent bits macOS keeps in the low byte of the flags
    /// (`NX_DEVICER*KEYMASK` in IOKit's IOLLEvent.h).
    private static let rightBits: [(bit: UInt, flag: NSEvent.ModifierFlags)] = [
        (0x10, .command), (0x40, .option), (0x2000, .control), (0x04, .shift)
    ]

    private static func rightSide(_ rawFlags: UInt) -> NSEvent.ModifierFlags {
        rightBits.reduce(into: []) { result, entry in
            if rawFlags & entry.bit != 0 { result.insert(entry.flag) }
        }
    }

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    /// "⌃⌥N", in the order macOS menus use; "Right ⌘ ." when a side matters.
    var display: String {
        let order: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        let held = order.filter { flags.contains($0.0) }
        guard isSideSpecific else { return held.map(\.1).joined() + Self.keyName(keyCode) }
        let parts = held.map { rightFlags.contains($0.0) ? "Right \($0.1)" : $0.1 }
        return (parts + [Self.keyName(keyCode)]).joined(separator: " ")
    }

    private static let named: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"
    ]

    /// The key's character on the current keyboard layout, so a German
    /// keyboard shows "Z" where an American one shows "Y".
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

/// Why a shortcut isn't listening.
enum HotKeyProblem: Equatable {
    /// Another app holds the same keys.
    case taken
    /// Right-side shortcuts read every key press, which needs Accessibility.
    case needsAccessibility
}

/// A system-wide shortcut. Most use Carbon's hot keys, which need no
/// Accessibility permission, and the key press never reaches the frontmost
/// app. A right-side shortcut can't: Carbon sees ⌘ and not which ⌘, so it
/// would swallow left ⌘ + period too. Those use an event tap that takes only
/// the right-side press and lets every other key through.
@MainActor
final class GlobalHotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private let id: UInt32
    private var sideTap: SideKeyTap?
    /// Retries a right-side shortcut once Accessibility is granted.
    private var permissionTimer: Timer?

    /// Called when a right-side shortcut starts listening after waiting for
    /// Accessibility.
    var onRecovered: (() -> Void)?

    init(action: @escaping () -> Void) {
        self.action = action
        id = Self.nextID
        Self.nextID += 1
    }

    /// Registers the shortcut, replacing any before it; nil unregisters.
    /// Returns why it isn't listening, or nil when it is.
    @discardableResult
    func register(_ shortcut: KeyShortcut?) -> HotKeyProblem? {
        unregister()
        guard let shortcut else { return nil }
        if shortcut.isSideSpecific { return registerSideSpecific(shortcut) }
        installHandler()
        let hotKeyID = EventHotKeyID(signature: OSType(0x584E_4E54), id: id) // "XNNT"
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &reference)
        guard status == noErr else {
            reference = nil
            return .taken
        }
        Self.actions[id] = action
        return nil
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        Self.actions[id] = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        sideTap?.stop()
        sideTap = nil
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    private func registerSideSpecific(_ shortcut: KeyShortcut) -> HotKeyProblem? {
        if AXIsProcessTrusted(), let tap = SideKeyTap(shortcut: shortcut, action: action) {
            sideTap = tap
            return nil
        }
        // Checked every two seconds only while waiting; AXIsProcessTrusted is a cheap call.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted(), let tap = SideKeyTap(shortcut: shortcut, action: self.action) else { return }
                self.permissionTimer?.invalidate()
                self.permissionTimer = nil
                self.sideTap = tap
                self.onRecovered?()
            }
        }
        return .needsAccessibility
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, hotKeyID.signature == OSType(0x584E_4E54) else { return OSStatus(eventNotHandledErr) }
            let id = hotKeyID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { GlobalHotKey.actions[id]?() }
            }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}

/// Watches key presses for one right-side shortcut and keeps it from the
/// frontmost app; every other key passes straight through. Runs on the main
/// run loop, and does no more per key than compare a few integers.
@MainActor
private final class SideKeyTap {
    private let shortcut: KeyShortcut
    private let action: () -> Void
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// The key whose press was taken, so its release is taken too.
    private var heldKeyCode: UInt32?

    init?(shortcut: KeyShortcut, action: @escaping () -> Void) {
        self.shortcut = shortcut
        self.action = action
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<SideKeyTap>.fromOpaque(info).takeUnretainedValue()
            let keep = MainActor.assumeIsolated { owner.handle(type, event) }
            return keep ? Unmanaged.passUnretained(event) : nil
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return nil }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
    }

    /// False takes the event away from every app.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        case .keyDown:
            let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
            guard shortcut.matches(keyCode: keyCode, rawFlags: UInt(event.flags.rawValue)) else { return true }
            heldKeyCode = keyCode
            // Holding the keys repeats the press; toggle once.
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                DispatchQueue.main.async { [action] in action() }
            }
            return false
        case .keyUp:
            let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
            guard keyCode == heldKeyCode else { return true }
            heldKeyCode = nil
            return false
        default:
            return true
        }
    }
}
