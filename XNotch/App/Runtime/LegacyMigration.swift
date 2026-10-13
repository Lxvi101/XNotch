import Foundation

/// Carries data over from when the app was called DClone: the Application
/// Support folder (shelf, received files, extension data) and the settings.
/// Runs before anything reads either, and only while XNotch has neither.
enum LegacyMigration {
    private static let legacyName = "DClone"
    private static let legacyDomain = "dev.levi.DClone"
    private static let migratedKey = "migratedFromDClone"

    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migratedKey) else { return }
        defer { defaults.set(true, forKey: migratedKey) }

        let manager = FileManager.default
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let legacy = support.appendingPathComponent(legacyName, isDirectory: true)
        let current = support.appendingPathComponent("XNotch", isDirectory: true)
        if manager.fileExists(atPath: legacy.path), !manager.fileExists(atPath: current.path) {
            try? manager.moveItem(at: legacy, to: current)
        }

        if let old = defaults.persistentDomain(forName: legacyDomain) {
            for (key, value) in old where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
    }
}
