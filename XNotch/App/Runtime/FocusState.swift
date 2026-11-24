import Foundation

/// Whether a Focus such as Do Not Disturb is on. Apple's Focus status API
/// answers only apps with the Communication Notifications entitlement, so
/// this reads the record macOS keeps of active Focuses instead, which Full
/// Disk Access opens. Read when asked, never polled: nothing runs while
/// nobody needs to know.
enum FocusState {
    private static let assertions = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")

    @MainActor private static var cached: (at: Date, on: Bool)?

    /// False when the record can't be read (no Full Disk Access).
    @MainActor static var isOn: Bool {
        if let cached, Date().timeIntervalSince(cached.at) < 1 { return cached.on }
        let on = read()
        cached = (Date(), on)
        return on
    }

    /// `{"data": [{"storeAssertionRecords": [...]}]}`: a Focus is on while
    /// any record is held; turning it off moves it to the invalidations.
    private static func read() -> Bool {
        guard let data = try? Data(contentsOf: assertions),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stores = root["data"] as? [[String: Any]] else { return false }
        return stores.contains { ($0["storeAssertionRecords"] as? [Any])?.isEmpty == false }
    }
}
