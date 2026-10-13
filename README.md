# XNotch

A macOS notch companion with Now Playing, a file shelf, Lock Screen media controls, and loadable extensions. Requires macOS 14 or later; supports Apple Silicon and Intel.

## Install

Download the ZIP from [the latest release](https://github.com/Lxvi101/XNotch/releases/latest), extract it, and move XNotch.app to Applications. XNotch runs without a Dock icon. Open it again, or right-click the notch, to reach Settings.

The first launch plays a short welcome tour and asks for Full Disk Access, so the shelf and Folders can open files anywhere. XNotch opens the right pane in System Settings and docks a guide beside it; drag XNotch from the guide into the list. Replay the tour or grant access later under **Settings → General**.

The 0.2.0 release is Developer ID signed but not notarized. macOS may require first-launch approval in System Settings → Privacy & Security.

## Updates

Automatic checking and downloading are enabled by default. Sparkle checks daily, verifies the signed feed and update archive before extraction, and manages installation and relaunch. Adjust these settings or check manually under **Settings → About XNotch → Updates**. An update that needs attention makes XNotch temporarily available in the Dock.

Install 0.2.0 manually if you currently have 0.1; older builds have no updater. Your existing preferences and shelf are preserved by the app's migration.

## Build

Requires Xcode 26 or later (Swift 6.2), its command line tools, and Python 3.

```sh
scripts/build_app.sh
scripts/build_app.sh --run
```

This builds a universal `build/XNotch.app`, including Sparkle and the bundled Folders extension. `--run` copies it to `~/Applications` and opens it from there, because a bundle inside a protected folder such as Documents makes macOS ask for that folder. Development builds use ad hoc signing. Use `ARCHITECTURES=arm64` for a faster local build, or set `CODE_SIGN_IDENTITY` to your Developer ID certificate to sign for distribution.

See [XNotchKit](Kit/README.md) for the extension API and [Folders](Extensions/Folders) for a complete example.

## Release

See [RELEASING.md](RELEASING.md): bump `release.json`, write `releases/<version>.md`, push `main`, then run `scripts/release.sh --publish` with your Developer ID identity. Release notes also appear in Settings → What's New.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE) and [third-party notices](THIRD_PARTY_NOTICES.md).
