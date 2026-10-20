import AppKit

/// Modifier keys extensions have taken for gestures made while dragging
/// files, so two extensions never answer the same drag (API 1.6.0). The
/// Converter claims the key that opens its wheel; Shelves leaves shakes made
/// with that key held alone.
@MainActor
public enum DragModifierClaims {
    private static var claims: [ExtensionID: NSEvent.ModifierFlags] = [:]

    /// Takes keys for an extension, replacing what it had; nil gives them back.
    public static func set(_ flags: NSEvent.ModifierFlags?, for id: ExtensionID) {
        claims[id] = flags
    }

    /// The keys every other extension has taken.
    public static func claimed(excluding id: ExtensionID) -> NSEvent.ModifierFlags {
        claims.filter { $0.key != id }.values.reduce(into: NSEvent.ModifierFlags()) { $0.formUnion($1) }
    }
}
