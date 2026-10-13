import AppKit
import SwiftUI

// MARK: Notch pages

/// A page of the open notch. It gets a destination pill under the closed
/// notch and a segment in the open header's switcher.
public struct NotchPageDescriptor: Hashable, Sendable {
    /// Unique within the extension.
    public var id: String
    public var title: String
    public var symbol: String
    /// Height of the content area under the notch row, matching the shelf by
    /// default. The width is fixed at `NotchPageContext.contentWidth`.
    public var contentHeight: CGFloat
    /// A count shown on the pill and the switcher segment; nil or 0 hides it.
    public var badge: Int?

    public init(id: String, title: String, symbol: String, contentHeight: CGFloat = 98, badge: Int? = nil) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.contentHeight = contentHeight
        self.badge = badge
    }
}

public struct NotchPageContext {
    public static let contentWidth: CGFloat = 400

    public let size: CGSize
    public let isActive: Bool

    public init(size: CGSize, isActive: Bool) {
        self.size = size
        self.isActive = isActive
    }
}

@MainActor
public protocol NotchPageProviding: XNotchExtension {
    var pages: [NotchPageDescriptor] { get }

    /// Called on every render of the notch. Keep state in your own objects,
    /// not in the returned view, and observe them from it.
    func makePageView(for page: NotchPageDescriptor, context: NotchPageContext) -> AnyView
}

/// Key presses while one of the extension's pages is open and the notch has
/// keyboard focus (after a click into it).
@MainActor
public protocol NotchKeyHandling {
    /// Return true when the key was consumed.
    func handleKey(_ key: NotchKeyPress, on page: String) -> Bool
}

public struct NotchKeyPress: Sendable {
    public let characters: String
    public let keyCode: UInt16
    public let modifiers: NSEvent.ModifierFlags

    public init(characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.characters = characters
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

// MARK: Settings

/// A page in XNotch's Settings window, listed under Extensions.
@MainActor
public protocol SettingsPaneProviding {
    /// Typically a `Form { … }.formStyle(.grouped)`, to match the rest of Settings.
    func makeSettingsPane() -> AnyView
}

// MARK: Pointer

/// The pointer, published by XNotch in `KitSpace.canvas` coordinates while it
/// is over the notch. The notch panel never becomes key on hover, so AppKit
/// tracking areas (and with them `onHover`) are unreliable inside it; use
/// `NotchHoverReader` instead.
@MainActor
public final class NotchPointer: ObservableObject {
    @Published public private(set) var location: CGPoint?

    public init() {}

    public func update(_ location: CGPoint?) {
        guard location != self.location else { return }
        self.location = location
    }
}

public enum KitSpace {
    /// The notch canvas' coordinate space name.
    public static let canvas = "notch.canvas"
}

/// Hands its content whether the pointer is over it. The content is only
/// rebuilt when that changes, not on every pointer move or animation frame.
public struct NotchHoverReader<Content: View>: View {
    @State private var hovered = false
    private let content: (Bool) -> Content

    public init(@ViewBuilder content: @escaping (Bool) -> Content) {
        self.content = content
    }

    public var body: some View {
        content(hovered)
            .background(HoverProbe(hovered: $hovered))
    }
}

private struct HoverProbe: View {
    @EnvironmentObject private var pointer: NotchPointer
    @Binding var hovered: Bool

    var body: some View {
        GeometryReader { proxy in
            let inside = pointer.location.map { proxy.frame(in: .named(KitSpace.canvas)).contains($0) } ?? false
            Color.clear
                .onAppear { if hovered != inside { hovered = inside } }
                .onChange(of: inside) { _, new in hovered = new }
        }
    }
}

// MARK: Visibility

private struct NotchSurfaceVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False while the surface holding this view is fully hidden (a page
    /// that isn't open, a card that's dismissed). Pause timelines and other
    /// continuous work on it: hidden pages stay in the view tree.
    public var isNotchSurfaceVisible: Bool {
        get { self[NotchSurfaceVisibleKey.self] }
        set { self[NotchSurfaceVisibleKey.self] = newValue }
    }
}
