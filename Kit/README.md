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

`--install` copies the bundle to `~/Library/Application Support/XNotch/Extensions`. Restart XNotch to load it. Extensions inside the app's `Contents/PlugIns` are listed as built in.

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
  "kit": { "abi": 2, "minAPI": "1.1.0" },
  "creator": { "name": "You", "url": "https://example.com" }
}
```

`id` must match your extension's `static let id`; XNotch refuses the bundle otherwise. `symbol` and `tint` draw its icon in Settings. XNotch reads the manifest without running your code, so a disabled extension is never loaded.

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
| `SettingsPaneProviding` | A page under Extensions in Settings. Return a `Form { … }.formStyle(.grouped)` to match. |

A page's content area is `NotchPageContext.contentWidth` (400 pt) wide and `NotchPageDescriptor.contentHeight` tall (98 pt by default, the shelf's height). XNotch draws the notch row above it and reveals your view with the same blur-to-focus spring as its own pages.

`makePageView` runs on every render of the notch, so keep state in your own `ObservableObject`s and observe them from the view. Don't create models inside the returned view.

While your page is fully hidden XNotch removes its view, so `@State` inside it resets each time the page opens. Keep anything that should survive in your model. Also:

- Don't touch the file system, Launch Services (`NSWorkspace.icon(forFile:)`, `FileManager.displayName(atPath:)`) or the network from `body`, which runs on animation frames. Cache those in your model, and refresh them in `onAppear` or when `NotchPageContext.isActive` turns true.
- `@Environment(\.isNotchSurfaceVisible)` is false whenever the surface holding a view is hidden but still mounted. Pause `TimelineView`s and timers on it.

## The host

`activate(host:)` hands you an `ExtensionHost`:

- `storage.defaults`: a UserDefaults suite of your own. `storage.directory` is a private folder under Application Support.
- `notch`: `open(page:)`, `close()`, `isOpen`, and `pagesDidChange()` when a page's title or badge changes.
- `workspace`: open and reveal files, and `chooseFolders()` for a picker in front of everything.
- `feedback.tick()`: the trackpad tick, which respects the user's haptics setting.
- `log`: an `os.Logger` under `dev.levi.XNotch.extension`.

## Looking like XNotch

- `KitStyle` has the notch's text colours, fills and green.
- `KitMotion` has its content and press springs.
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

## Versioning

- `XNotchKit.abi` changes on any binary-incompatible change. An extension built for another ABI is listed in Settings with the reason and isn't loaded.
- `XNotchKit.apiVersion` is semantic. `kit.minAPI` names the lowest version your extension needs.
