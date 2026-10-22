import AppKit

public enum XNotchKit {
    /// Raised on any binary-incompatible change. XNotch refuses an extension
    /// built against a different ABI instead of crashing inside it.
    public static let abi = 3
    /// Semantic version of the API. An extension's manifest names the lowest
    /// version it needs in `kit.minAPI`.
    public static let apiVersion = "1.9.0"
}

public typealias ExtensionID = String

/// The class named in the bundle's `NSPrincipalClass`. XNotch instantiates it
/// before the host is ready, so keep `init` empty and do the work in
/// `XNotchExtension.activate(host:)`.
@objc public protocol XNotchExtensionPrincipal: NSObjectProtocol {
    init()
    @MainActor func makeExtension() -> AnyObject
}

/// The extension itself. Conform to surface protocols (`NotchPageProviding`,
/// `NotchKeyHandling`, `SettingsPaneProviding`, `ShelfAccessoryProviding`) to appear in XNotch.
@MainActor
public protocol XNotchExtension: AnyObject {
    /// Must equal `XNotchExtensionID` in Info.plist and `id` in extension.json.
    static var id: ExtensionID { get }

    /// Called when the extension is switched on, at launch or from Settings.
    func activate(host: ExtensionHost) throws

    /// Called when the extension is switched off. Stop timers and observers;
    /// the bundle stays loaded and may be activated again.
    func deactivate()
}

/// extension.json, in the bundle's Resources.
public struct ExtensionManifest: Codable, Hashable, Sendable {
    public struct Kit: Codable, Hashable, Sendable {
        public var abi: Int
        public var minAPI: String
    }

    public struct Creator: Codable, Hashable, Sendable {
        public var name: String
        public var url: String?
    }

    public var id: ExtensionID
    public var name: String
    public var version: String
    public var summary: String
    /// SF Symbol shown in Settings and wherever XNotch lists the extension.
    public var symbol: String
    /// Hex colour of the symbol's tile, e.g. "#3A82F7".
    public var tint: String?
    /// Longer text for the extension's page in the store. Falls back to `summary`.
    public var description: String?
    /// Image files in the bundle's Resources, shown as previews in the store,
    /// e.g. `["Previews/1.png"]`. 16:10 looks best.
    public var previews: [String]?
    public var kit: Kit
    public var creator: Creator?
    /// The `@objc` name of the `XNotchExtensionPrincipal` class; the packaging
    /// script writes it into Info.plist as `NSPrincipalClass`.
    public var principalClass: String
}
