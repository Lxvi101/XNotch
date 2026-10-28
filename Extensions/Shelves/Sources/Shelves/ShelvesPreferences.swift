import AppKit
import SwiftUI

enum ShakeSensitivity: String, CaseIterable, Identifiable {
    case normal, high, highest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: "Default"
        case .high: "High"
        case .highest: "Highest"
        }
    }

    var tuning: ShakeRecognizer.Tuning {
        switch self {
        case .normal: ShakeRecognizer.Tuning(minimumStroke: 36, reversals: 3, window: 0.8)
        case .high: ShakeRecognizer.Tuning(minimumStroke: 26, reversals: 3, window: 0.9)
        case .highest: ShakeRecognizer.Tuning(minimumStroke: 18, reversals: 2, window: 0.9)
        }
    }
}

enum TriggerModifier: String, CaseIterable, Identifiable {
    case shift, control, option, command

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shift: "⇧ Shift"
        case .control: "⌃ Control"
        case .option: "⌥ Option"
        case .command: "⌘ Command"
        }
    }

    var flags: NSEvent.ModifierFlags {
        switch self {
        case .shift: .shift
        case .control: .control
        case .option: .option
        case .command: .command
        }
    }
}

enum DoubleClickAction: String, CaseIterable, Identifiable {
    case open, reveal, quickLook

    var id: String { rawValue }

    var title: String {
        switch self {
        case .open: "Open"
        case .reveal: "Reveal in Finder"
        case .quickLook: "Quick Look"
        }
    }
}

enum DragOutBehavior: String, CaseIterable, Identifiable {
    case whenMoved, always, never

    var id: String { rawValue }

    var title: String {
        switch self {
        case .whenMoved: "Only when items are moved"
        case .always: "Always"
        case .never: "Never"
        }
    }
}

struct IgnoredApp: Codable, Hashable, Identifiable {
    var bundleID: String
    var name: String
    var path: String

    var id: String { bundleID }
}

struct WatchedFolder: Codable, Hashable, Identifiable {
    var id = UUID()
    var path: String
    var isEnabled = true

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

/// Everything in the Shelves settings pane, kept in the extension's defaults suite.
@MainActor
final class ShelvesPreferences: ObservableObject {
    private let defaults: UserDefaults

    @Published var shakeEnabled: Bool { didSet { defaults.set(shakeEnabled, forKey: "shakeEnabled") } }
    @Published var sensitivity: ShakeSensitivity { didSet { defaults.set(sensitivity.rawValue, forKey: "sensitivity") } }
    @Published var modifierEnabled: Bool { didSet { defaults.set(modifierEnabled, forKey: "modifierEnabled") } }
    @Published var modifier: TriggerModifier { didSet { defaults.set(modifier.rawValue, forKey: "modifier") } }
    @Published var ignoredApps: [IgnoredApp] { didSet { store(ignoredApps, "ignoredApps") } }
    @Published var doubleClick: DoubleClickAction { didSet { defaults.set(doubleClick.rawValue, forKey: "doubleClick") } }
    @Published var dragOut: DragOutBehavior { didSet { defaults.set(dragOut.rawValue, forKey: "dragOut") } }
    @Published var onAllSpaces: Bool { didSet { defaults.set(onAllSpaces, forKey: "onAllSpaces") } }
    @Published var instantActionsEnabled: Bool { didSet { defaults.set(instantActionsEnabled, forKey: "instantActionsEnabled") } }
    /// Every action, in the order the shelf shows them.
    @Published var actionOrder: [InstantAction] { didSet { store(actionOrder, "actionOrder") } }
    @Published var disabledActions: Set<InstantAction> { didSet { store(disabledActions, "disabledActions") } }
    @Published var closeAfterAction: Bool { didSet { defaults.set(closeAfterAction, forKey: "closeAfterAction") } }
    @Published var watchedFolders: [WatchedFolder] { didSet { store(watchedFolders, "watchedFolders") } }
    /// Dropped links become the files their rules find, not link files.
    @Published var linksToFiles: Bool { didSet { defaults.set(linksToFiles, forKey: "linksToFiles") } }
    /// Every link rule, the first that covers a link wins.
    @Published var linkRules: [LinkRule] { didSet { store(linkRules, "linkRules") } }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        shakeEnabled = defaults.object(forKey: "shakeEnabled") as? Bool ?? true
        sensitivity = defaults.string(forKey: "sensitivity").flatMap(ShakeSensitivity.init) ?? .normal
        modifierEnabled = defaults.bool(forKey: "modifierEnabled")
        modifier = defaults.string(forKey: "modifier").flatMap(TriggerModifier.init) ?? .shift
        ignoredApps = Self.load("ignoredApps", from: defaults) ?? []
        doubleClick = defaults.string(forKey: "doubleClick").flatMap(DoubleClickAction.init) ?? .open
        dragOut = defaults.string(forKey: "dragOut").flatMap(DragOutBehavior.init) ?? .whenMoved
        onAllSpaces = defaults.object(forKey: "onAllSpaces") as? Bool ?? true
        instantActionsEnabled = defaults.object(forKey: "instantActionsEnabled") as? Bool ?? true
        let saved: [InstantAction] = Self.load("actionOrder", from: defaults) ?? []
        // Actions added in later versions go to the end.
        actionOrder = saved + InstantAction.allCases.filter { !saved.contains($0) }
        disabledActions = Self.load("disabledActions", from: defaults) ?? InstantAction.disabledByDefault
        closeAfterAction = defaults.object(forKey: "closeAfterAction") as? Bool ?? true
        watchedFolders = Self.load("watchedFolders", from: defaults) ?? []
        linksToFiles = defaults.object(forKey: "linksToFiles") as? Bool ?? true
        let savedRules: [LinkRule] = Self.load("linkRules", from: defaults) ?? []
        // Rules added in later versions go to the end.
        linkRules = savedRules + LinkRule.builtIn.filter { rule in !savedRules.contains { $0.id == rule.id } }
    }

    /// The rules a drop uses: none while links stay links.
    var activeLinkRules: [LinkRule] {
        linksToFiles ? linkRules.filter(\.isEnabled) : []
    }

    /// The actions a shelf offers, in order.
    var instantActions: [InstantAction] {
        guard instantActionsEnabled else { return [] }
        return actionOrder.filter { !disabledActions.contains($0) && $0.isAvailable }
    }

    func isIgnored(_ bundleID: String) -> Bool {
        ignoredApps.contains { $0.bundleID == bundleID }
    }

    func ignore(appsAt urls: [URL]) {
        let known = Set(ignoredApps.map(\.bundleID))
        let added = urls.compactMap { url -> IgnoredApp? in
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !known.contains(id) else { return nil }
            let name = FileManager.default.displayName(atPath: url.path)
            return IgnoredApp(bundleID: id, name: (name as NSString).deletingPathExtension, path: url.path)
        }
        guard !added.isEmpty else { return }
        ignoredApps = (ignoredApps + added).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func setAction(_ action: InstantAction, enabled: Bool) {
        if enabled { disabledActions.remove(action) } else { disabledActions.insert(action) }
    }

    /// Adds rules from a file. A rule that's here already, by its id, is
    /// replaced where it is. Returns how many there were.
    @discardableResult
    func importLinkRules(from data: Data) throws -> Int {
        let imported = try LinkRule.rules(from: data)
        var rules = linkRules
        for rule in imported {
            if let index = rules.firstIndex(where: { $0.id == rule.id }) { rules[index] = rule } else { rules.append(rule) }
        }
        linkRules = rules
        return imported.count
    }

    func watch(_ urls: [URL]) {
        let known = Set(watchedFolders.map(\.path))
        let added = urls.map(\.standardizedFileURL.path).filter { !known.contains($0) }
        watchedFolders += added.map { WatchedFolder(path: $0) }
    }

    private func store<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ key: String, from defaults: UserDefaults) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
