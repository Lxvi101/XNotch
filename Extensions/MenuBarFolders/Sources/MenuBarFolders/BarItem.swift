import AppKit

/// One icon in the menu bar's status area, as the window server sees it now.
struct BarItem: Identifiable, Equatable {
    /// Stable across launches: the owner's bundle ID, the window's title, and
    /// an index when one app has several items with the same title.
    let id: String
    let windowID: CGWindowID
    let pid: pid_t
    let bundleID: String?
    let title: String?
    let bounds: CGRect
    let appName: String

    var name: String {
        let app = Self.readable(appName, splitWords: false)
        guard let title, !title.isEmpty, !title.hasPrefix("Item-"), title != appName else { return app }
        let readable = Self.readable(title)
        return bundleID?.hasPrefix("com.apple.") == true ? readable : "\(app) – \(readable)"
    }

    /// "TimeMachineMenuExtra.TMMenuExtraHost" → "Time Machine", "WiFi" stays.
    private static func readable(_ raw: String, splitWords: Bool = true) -> String {
        var name = raw
        for marker in ["MenuBarExtra", "MenuExtra", "MenuAgent"] {
            if let range = name.range(of: marker), range.lowerBound > name.startIndex {
                name = String(name[..<range.lowerBound])
            }
        }
        guard splitWords else { return name }
        return name.replacingOccurrences(of: "([a-z]{2})([A-Z])", with: "$1 $2", options: .regularExpression)
    }

    /// Clock and Control Center can't be moved, so they can't go in a folder.
    var isMovable: Bool {
        guard bundleID == "com.apple.controlcenter" else { return true }
        // AudioVideoModule is the camera/mic indicator, there only while in use.
        return !["Clock", "BentoBox", "AudioVideoModule"].contains(title ?? "")
    }

    func liveBounds() -> CGRect { WindowServer.bounds(of: windowID) ?? bounds }

    /// One of this process's own status item windows, so the mover can drag it.
    static func own(_ window: CGWindowID) -> BarItem? {
        guard let bounds = WindowServer.bounds(of: window) else { return nil }
        return BarItem(id: "own|\(window)", windowID: window, pid: ProcessInfo.processInfo.processIdentifier,
                       bundleID: Bundle.main.bundleIdentifier, title: nil, bounds: bounds, appName: "XNotch")
    }

    /// Status items in the menu bar, left to right. Skips app menus and this
    /// process's own items (the folders and the divider).
    static func current() -> [BarItem] {
        let ids = WindowServer.menuBarWindowIDs()
        guard let array = WindowServer.windowArray(ids),
              let infos = CGWindowListCreateDescriptionFromArray(array) as? [[CFString: Any]] else { return [] }
        let mainMenuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))

        // Every other display's menu bar has its own copy of each item. Only
        // the main display's can be moved: it's titled, and it sits on that
        // display's row. Titles need Screen Recording; the row always works
        // unless the displays line up at the top.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let mainTop = CGDisplayBounds(CGMainDisplayID()).minY

        struct Raw { let wid: CGWindowID; let pid: pid_t; let title: String?; let bounds: CGRect }
        var raws: [Raw] = []
        for info in infos {
            guard let wid = info[kCGWindowNumber] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID] as? pid_t, pid != ownPID,
                  let layer = info[kCGWindowLayer] as? Int, layer != mainMenuLevel,
                  let boundsDict = info[kCGWindowBounds] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 0, abs(bounds.minY - mainTop) < 1 else { continue }
            raws.append(Raw(wid: wid, pid: pid, title: info[kCGWindowName] as? String, bounds: bounds))
        }
        if raws.contains(where: { $0.title?.isEmpty == false }) {
            raws.removeAll { $0.title?.isEmpty != false }
        }

        // Same app, same title: number them by window ID, which doesn't change
        // when the items move.
        var seen: [String: Int] = [:]
        var items: [BarItem] = []
        for raw in raws.sorted(by: { $0.wid < $1.wid }) {
            let app = NSRunningApplication(processIdentifier: raw.pid)
            let bundleID = app?.bundleIdentifier
            let base = "\(bundleID ?? app?.localizedName ?? "pid\(raw.pid)")|\(raw.title ?? "")"
            let index = seen[base, default: 0]
            seen[base] = index + 1
            items.append(BarItem(id: index == 0 ? base : "\(base)#\(index)", windowID: raw.wid, pid: raw.pid,
                                 bundleID: bundleID, title: raw.title, bounds: raw.bounds,
                                 appName: app?.localizedName ?? "Menu Bar Item"))
        }
        return items.sorted { $0.bounds.minX < $1.bounds.minX }
    }
}
