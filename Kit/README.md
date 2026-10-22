# XNotchKit

Build extensions for XNotch: pages in the notch, keyboard shortcuts, and a pane in Settings. The Folders extension (`Extensions/Folders`) is a complete, small example built only against this kit.

## How an extension is put together

An extension is a SwiftPM package with:

- a **dynamic library** product that depends on `XNotchKit`. It must be dynamic: the app already carries XNotchKit, and a second static copy would give every kit type two identities, so casts between them fail.
- an **`extension.json`** manifest at the package root.
- optionally a **`Resources/`** folder, copied into the bundle.

`scripts/build_extension.sh` turns that into a `.xnext` bundle: it builds the library, writes the Info.plist (`NSPrincipalClass`, `XNotchExtensionID`), points the library at the app's XNotchKit, and signs it.

```sh
scripts/build_extension.sh path/to/MyExtension --install
```

`--install` copies the bundle to `~/Library/Application Support/XNotch/Extensions`. Restart XNotch to load it. Extensions inside the app's `Contents/PlugIns` are listed as built in. Every extension starts switched off, built-in or not: users add it in the welcome tour or under Settings → Extensions.

## Package.swift

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Weather",
    platforms: [.macOS(.v14)],
    products: [.library(name: "Weather", type: .dynamic, targets: ["Weather"])],
    dependencies: [.package(path: "../XNotch/Kit")],
    targets: [.target(name: "Weather", dependencies: [.product(name: "XNotchKit", package: "Kit")])]
)
```

## extension.json

```json
{
  "id": "weather",
  "name": "Weather",
  "version": "1.0.0",
  "summary": "The forecast, under the notch.",
  "symbol": "cloud.sun.fill",
  "tint": "#2F9BFF",
  "principalClass": "WeatherPrincipal",
  "kit": { "abi": 3, "minAPI": "1.1.0" },
  "creator": { "name": "You", "url": "https://example.com" }
}
```

`id` must match your extension's `static let id`; XNotch refuses the bundle otherwise. `symbol` and `tint` draw its icon in Settings. For the extension store you can add a longer `"description"` and `"previews"`, a list of images in `Resources/` (e.g. `["Previews/1.png", "Previews/2.png"]`, 16:10 looks best); without previews the store draws a card from `symbol` and `tint`. XNotch reads the manifest without running your code, so a disabled extension is never loaded.

## The code

```swift
import XNotchKit
import SwiftUI

// Named in Info.plist. XNotch creates it before anything is ready: keep init empty.
@objc(WeatherPrincipal)
public final class WeatherPrincipal: NSObject, XNotchExtensionPrincipal {
    public override init() { super.init() }
    @MainActor public func makeExtension() -> AnyObject { WeatherExtension() }
}

@MainActor
final class WeatherExtension: XNotchExtension, NotchPageProviding {
    static let id: ExtensionID = "weather"
    let model = WeatherModel()
    private var host: ExtensionHost?

    func activate(host: ExtensionHost) throws {
        self.host = host
        model.start()
    }

    func deactivate() {
        model.stop()
        host = nil
    }

    var pages: [NotchPageDescriptor] {
        [NotchPageDescriptor(id: "forecast", title: "Weather", symbol: "cloud.sun.fill")]
    }

    func makePageView(for page: NotchPageDescriptor, context: NotchPageContext) -> AnyView {
        AnyView(ForecastView(model: model, size: context.size))
    }
}
```

## Surfaces

| Protocol | What it adds |
|---|---|
| `NotchPageProviding` | One or more pages in the open notch. Each gets a destination pill under the closed notch and a segment in the header switcher. |
| `NotchKeyHandling` | Key presses while your page is open and the notch has keyboard focus (after a click into it). Return `true` to consume. Escape and ⌘, are XNotch's. |
| `SettingsPaneProviding` | A page under Extensions in Settings. Return a `Form { … }.formStyle(.grouped)` to match. A Form ignores `.onMove`; for rows the user reorders, put `ReorderableRows(items, onMove:) { row }` alone in a `Section` (API 1.9.0). |
| `PermissionRequesting` | Permissions XNotch asks for in its welcome tour, right after its own (API 1.2.0). List what's missing without prompting; show macOS's prompt only in `requestPermission(_:)`. |
| `ShelfAccessoryProviding` | A button in the tray header and entries in a tray file's right-click menu (API 1.3.0). `ShelfContext.targets` is the selection, or every file when nothing is selected; read it when the button is used. Draw the button with `ShelfHeaderButton` so it matches the header and shrinks with it. |
| `ShelfFileActing` | Menu entries for shelf files that make new files, which land back on the shelf they came from: call `ShelfFileRequest.deliver(_:)` with them (API 1.6.0). They show in the tray and on floating shelves. The Converter's "Convert 12 Images…" is one. |

A page's content area is `NotchPageContext.contentWidth` (400 pt) wide and `NotchPageDescriptor.contentHeight` tall (98 pt by default, the tray's height). XNotch draws the notch row above it and reveals your view with the same blur-to-focus spring as its own pages.

`makePageView` runs on every render of the notch, so keep state in your own `ObservableObject`s and observe them from the view. Don't create models inside the returned view.

While your page is fully hidden XNotch removes its view, so `@State` inside it resets each time the page opens. Keep anything that should survive in your model. Also:

- Don't touch the file system, Launch Services (`NSWorkspace.icon(forFile:)`, `FileManager.displayName(atPath:)`) or the network from `body`, which runs on animation frames. Cache those in your model, and refresh them in `onAppear` or when `NotchPageContext.isActive` turns true.
- `@Environment(\.isNotchSurfaceVisible)` is false whenever the surface holding a view is hidden but still mounted, or the notch is off screen (a fullscreen space, the Lock Screen, displays asleep). Pause `TimelineView`s and timers on it.

## The host

`activate(host:)` hands you an `ExtensionHost`:

- `storage.defaults`: a UserDefaults suite of your own. `storage.directory` is a private folder under Application Support.
- `notch`: `open(page:)`, `close()`, `isOpen`, `pagesDidChange()` when a page's title or badge changes, and `openSettings()` to show your pane in Settings (API 1.3.0).
- `notch.showAlert(_:)` (API 1.4.0): a few seconds in the closed notch's wings, as when headphones connect. A symbol and a word on the left, a short value and an optional ring on the right; `page` is what a click opens. Vitals uses it when the disk fills up or memory runs short. Alert only on a change the user would want to know about, not on every reading.
- `(notch as? NotchEyesAlerting)?.showAlert(_:eyes:)` (API 1.5.0): the same alert with a warning sign and its title on the left, and the notch's eyes on the right showing how serious it is (`.caution` or `.critical`) in place of the value. Vitals offers it as an alert style.
- `(notch as? NotchEyesWatching)?.watch(_:mood:)` (API 1.7.0): opens the notch's eyes under the closed notch, as in the welcome tour, and points them at a spot on screen (AppKit screen coordinates; nil follows the pointer). Call it again as the spot moves. `stopWatching(farewell:)` closes them, after a moment of `.happy` or another mood if you pass one. Computer Use keeps them on the agent's cursor while an agent drives the Mac.
- `(host as? PermissionGuiding)?.guide(_:for:isGranted:)` (API 1.8.0): XNotch's permission guide for another app, such as a helper your extension installs. It opens Accessibility or Screen Recording in System Settings and docks its card there with that app's icon to drag in. `isGranted` must ask the app itself, since XNotch can't see another app's grants. Computer Use uses it for Wink.
- `shelf` (API 1.3.0): `files` in the tray, and `add(_:)` to put files there and open the notch on them, as a drop does. The iPhone & iPad extension uses it for files that arrive from a phone.
- `(shelf as? ShelfActionSharing)?.sharedShelfActions(for:)` (API 1.6.0): other extensions' `ShelfFileActing` entries, for an extension with shelves of its own. Floating shelves add them to their menu, delivering the new files to themselves.
- `DragModifierClaims` (API 1.6.0): if a gesture made while dragging files belongs to you when a key is held, `set` the key, and `claimed(excluding:)` before answering a drag yourself, so two extensions never answer the same drag. The Converter claims its wheel key; Shelves leaves shakes made with it held alone.
- `workspace`: open and reveal files, and `chooseFolders()` for a picker in front of everything.
- `feedback.tick()`: the trackpad tick, which respects the user's haptics setting.
- `log`: an `os.Logger` under `dev.levi.XNotch.extension`.

## Looking like XNotch

- `KitStyle` has the notch's text colours, fills and green.
- `KitMotion` has its content and press springs, and `shell` (API 1.4.0), the spring the notch reshapes with. When a change resizes your page (you call `pagesDidChange()` with a new `contentHeight`), animate it with `KitMotion.shell` and lay the new content out at its final size: the notch grows on the same spring, so the two move as one.
- `PressScaleStyle` is its button press.
- **Hover:** the notch panel never becomes key while you hover, so AppKit tracking areas (and `onHover`) are unreliable inside it. Wrap hoverable views in `NotchHoverReader { isHovered in … }`, which follows the pointer XNotch publishes and only rebuilds its content when the hover changes.
- **Right-click menus:** SwiftUI's `contextMenu` doesn't open in the notch for the same reason. Use `notchContextMenu`, which takes right-clicks and control-clicks and lets ordinary clicks through:

```swift
FolderTile(folder)
    .notchContextMenu {
        [.action("Show in Finder", symbol: "folder") { reveal(folder) },
         .separator,
         .action("Remove", symbol: "minus.circle", isDestructive: true) { remove(folder) }]
    }
```

Right-clicking anywhere else in the notch shows XNotch's own menu (Settings, Quit).

- **Pop-up menus:** `notchMenu` opens the same kind of menu on any click, under the view, like a pop-up button (API 1.3.0). Cloud Links uses it for the link's lifetime.

## Versioning

- `XNotchKit.abi` changes on any binary-incompatible change. An extension built for another ABI is listed in Settings with the reason and isn't loaded.
- `XNotchKit.apiVersion` is semantic. `kit.minAPI` names the lowest version your extension needs.
