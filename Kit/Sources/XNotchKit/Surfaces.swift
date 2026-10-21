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

// MARK: Shelf

/// What a shelf control acts on.
@MainActor
public struct ShelfContext {
    private let resolveTargets: @MainActor () -> [URL]

    public init(targets: @escaping @MainActor () -> [URL]) {
        resolveTargets = targets
    }

    /// The selected files, or every file on the shelf when none is selected.
    /// Read it when the control is used, not when it's built.
    public var targets: [URL] { resolveTargets() }
}

/// Controls on the shelf (API 1.3.0).
@MainActor
public protocol ShelfAccessoryProviding {
    /// Shown in the shelf header, before AirDrop, while the shelf has files.
    /// Use `ShelfHeaderButton` to match the header's own buttons.
    func makeShelfAccessory(context: ShelfContext) -> AnyView?

    /// Added to a shelf file's right-click menu, for these files.
    func shelfMenuItems(for files: [URL]) -> [NotchMenuItem]
}

/// Files on a shelf, for an action that can make new ones (API 1.6.0).
@MainActor
public struct ShelfFileRequest {
    /// The files the action is for: the selection, or the whole shelf.
    public let files: [URL]
    private let deliverFiles: @MainActor ([URL]) -> Void

    public init(files: [URL], deliver: @escaping @MainActor ([URL]) -> Void) {
        self.files = files
        deliverFiles = deliver
    }

    /// Puts files the action made on the shelf the request came from.
    public func deliver(_ urls: [URL]) { deliverFiles(urls) }
}

/// Menu entries for shelf files that can hand new files back to the shelf
/// they came from (API 1.6.0). XNotch shows them on the notch shelf; an
/// extension with shelves of its own shows them through `ShelfActionSharing`.
@MainActor
public protocol ShelfFileActing {
    /// Entries for these files; none when nothing applies.
    func shelfActions(for request: ShelfFileRequest) -> [NotchMenuItem]
}

/// Other extensions' `ShelfFileActing` entries, for an extension that keeps
/// shelves of its own, like Shelves (API 1.6.0). XNotch's `ShelfAccess`
/// adopts it: `host.shelf as? ShelfActionSharing`.
@MainActor
public protocol ShelfActionSharing: AnyObject {
    /// Every other active extension's entries for the request's files.
    func sharedShelfActions(for request: ShelfFileRequest) -> [NotchMenuItem]
}

/// The shelf header's round button. `label` is drawn at 10.5 pt in the
/// header's colours; pass a symbol name for the common case.
public struct ShelfHeaderButton<Label: View>: View {
    private let action: @MainActor () -> Void
    private let label: Label
    @Environment(\.shelfHeaderButtonSize) private var size

    public init(action: @escaping @MainActor () -> Void, @ViewBuilder label: () -> Label) {
        self.action = action
        self.label = label()
    }

    public var body: some View {
        NotchHoverReader { hovering in
            Button { action() } label: {
                label
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.6))
                    .frame(width: size, height: size)
                    .background(Circle().fill(.white.opacity(hovering ? 0.16 : 0.08)))
                    .scaleEffect(hovering ? 1.06 : 1)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .animation(KitMotion.content, value: hovering)
        }
    }
}

private struct ShelfHeaderButtonSizeKey: EnvironmentKey {
    static let defaultValue: CGFloat = 24
}

extension EnvironmentValues {
    /// The shelf header's button diameter: smaller when extensions add
    /// buttons, so they all stay clear of the camera housing.
    public var shelfHeaderButtonSize: CGFloat {
        get { self[ShelfHeaderButtonSizeKey.self] }
        set { self[ShelfHeaderButtonSizeKey.self] = newValue }
    }
}

extension ShelfHeaderButton where Label == Image {
    public init(symbol: String, action: @escaping @MainActor () -> Void) {
        self.init(action: action) { Image(systemName: symbol) }
    }
}

// MARK: Permissions

/// Something an extension can't do until the user allows it, like reading
/// another app's login from the Keychain. XNotch offers it in the welcome tour.
public struct ExtensionPermission: Identifiable, Hashable, Sendable {
    /// Unique within the extension.
    public var id: String
    /// What it unlocks, in a few words: "Claude Code limits".
    public var title: String
    /// Where macOS will ask, in a word or two: "Keychain".
    public var detail: String
    /// A sentence or two for the tour: why, and what macOS will show.
    public var reason: String
    public var symbol: String
    /// Hex colour of the symbol's tile, e.g. "#D97757".
    public var tint: String?

    public init(id: String, title: String, detail: String, reason: String, symbol: String, tint: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.reason = reason
        self.symbol = symbol
        self.tint = tint
    }
}

/// Permissions XNotch asks for on the extension's behalf in its welcome tour,
/// right after its own.
@MainActor
public protocol PermissionRequesting {
    /// Permissions still missing. Must not show any prompt to find out.
    var pendingPermissions: [ExtensionPermission] { get }

    /// Called when the user clicks Allow. Show macOS's prompt now and return
    /// whether the permission is granted for good, not just this once.
    func requestPermission(_ id: String) async -> Bool
}

/// A privacy permission another app needs, asked for with XNotch's guide (API 1.8.0).
public enum GuidedPermission: String, Sendable, Hashable, CaseIterable {
    case accessibility
    case screenRecording
}

/// XNotch's permission guide for an app other than XNotch: it opens the
/// permission's list in System Settings and docks a card under it with the
/// app's icon to drag in, then watches for the grant (API 1.8.0). The host
/// adopts it: `host as? PermissionGuiding`.
@MainActor
public protocol PermissionGuiding: AnyObject {
    /// `app` is the bundle to drag into the list. `isGranted` is asked about
    /// twice a second while the guide is up; the app's own process has to
    /// answer it, since XNotch can't see another app's grants. Returns whether
    /// the permission ended up granted.
    func guide(_ permission: GuidedPermission, for app: URL,
               isGranted: @escaping @Sendable () async -> Bool) async -> Bool
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
