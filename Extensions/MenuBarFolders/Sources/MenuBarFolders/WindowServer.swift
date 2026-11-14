import AppKit
import CoreGraphics

// Private WindowServer calls for menu bar item windows. The approach (asking
// the window server for every process's menu bar windows, reading their
// bounds even when parked off screen) follows Ice and Thaw, both GPL-3.0.
// See THIRD_PARTY_NOTICES.md.

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("CGSGetWindowCount")
private func CGSGetWindowCount(_ cid: Int32, _ target: Int32, _ count: inout Int32) -> CGError

@_silgen_name("CGSGetProcessMenuBarWindowList")
private func CGSGetProcessMenuBarWindowList(_ cid: Int32, _ target: Int32, _ capacity: Int32,
                                            _ list: UnsafeMutablePointer<CGWindowID>, _ count: inout Int32) -> CGError

@_silgen_name("CGSGetScreenRectForWindow")
private func CGSGetScreenRectForWindow(_ cid: Int32, _ wid: CGWindowID, _ rect: inout CGRect) -> CGError

@_silgen_name("CGSSetConnectionProperty")
private func CGSSetConnectionProperty(_ cid: Int32, _ target: Int32, _ key: CFString, _ value: CFTypeRef) -> CGError

enum WindowServer {
    private static let connection = CGSMainConnectionID()

    /// Every process's menu bar windows, front to back. Includes app menus.
    static func menuBarWindowIDs() -> [CGWindowID] {
        var total: Int32 = 0
        guard CGSGetWindowCount(connection, 0, &total) == .success, total > 0 else { return [] }
        var list = [CGWindowID](repeating: 0, count: Int(total))
        var count: Int32 = 0
        guard CGSGetProcessMenuBarWindowList(connection, 0, total, &list, &count) == .success else { return [] }
        return Array(list.prefix(Int(count)))
    }

    /// Bounds in global display coordinates (top-left origin), also for
    /// windows parked off screen.
    static func bounds(of window: CGWindowID) -> CGRect? {
        var rect = CGRect.zero
        return CGSGetScreenRectForWindow(connection, window, &rect) == .success ? rect : nil
    }

    /// Lets a background app hide the cursor while it posts events.
    static func allowBackgroundCursorControl() {
        _ = CGSSetConnectionProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }

    /// A CFArray of raw window numbers, the form the CGWindowList calls take.
    static func windowArray(_ ids: [CGWindowID]) -> CFArray? {
        var pointers: [UnsafeRawPointer?] = ids.compactMap { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard !pointers.isEmpty else { return nil }
        var callbacks = CFArrayCallBacks(version: 0, retain: nil, release: nil, copyDescription: nil, equal: nil)
        return CFArrayCreate(nil, &pointers, pointers.count, &callbacks)
    }

    private typealias CreateImage = @convention(c) (CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) -> Unmanaged<CGImage>?

    /// Looked up at runtime: the SDK marks it unavailable, but it still
    /// captures windows parked off screen, which ScreenCaptureKit won't.
    private static let createImage: CreateImage? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: CreateImage.self)
    }()

    /// The item's own window, transparent around the icon. Needs Screen Recording.
    static func image(of window: CGWindowID) -> CGImage? {
        createImage?(.null, .optionIncludingWindow, window, [.boundsIgnoreFraming, .bestResolution])?.takeRetainedValue()
    }
}
