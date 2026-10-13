# XNotch

A macOS notch companion with Now Playing, a file shelf, Lock Screen media controls, and loadable extensions. Requires macOS 14 or later; supports Apple Silicon and Intel.

## Install

Download the ZIP from [the latest release](https://github.com/Lxvi101/XNotch/releases/latest), extract it, and move XNotch.app to Applications. XNotch runs without a Dock icon. Open it again, or right-click the notch, to reach Settings.

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

This builds a universal `build/XNotch.app`, including Sparkle and the bundled Folders extension. Development builds use ad hoc signing. Use `ARCHITECTURES=arm64` for a faster local build, or set `CODE_SIGN_IDENTITY` to your Developer ID certificate to sign for distribution.

See [XNotchKit](Kit/README.md) for the extension API and [Folders](Extensions/Folders) for a complete example.

## Release

1. Increment both `version` and the numeric `build` in `release.json`; add `releases/<version>.md`.
2. Keep the Sparkle signing key in the login Keychain under account `dev.levi.XNotch`. Only its public key is committed. Do not generate a replacement key for an existing update channel.
3. Commit and push `main`.
4. Prepare and verify the release, or publish it directly:

```sh
CODE_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' scripts/release.sh
CODE_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' scripts/release.sh --publish
```

Set `NOTARY_PROFILE` to an existing `notarytool` Keychain profile to notarize and staple the app before signing its update archive. Without that profile the release is not notarized; state that in its release notes.

Publishing creates an annotated version tag and uploads the universal ZIP, signed `appcast.xml`, and `SHA256SUMS` to GitHub Releases. The updater uses the latest release's appcast asset as its stable HTTPS feed. Do not edit signed feeds or ZIPs after signing. Re-sign and upload all corresponding assets together if a release must be regenerated.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE) and [third-party notices](THIRD_PARTY_NOTICES.md).
