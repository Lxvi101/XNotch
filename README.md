# XNotch

A macOS notch companion with Now Playing, a file shelf, Lock Screen media controls, and loadable extensions. Requires macOS 14 or later; supports Apple Silicon and Intel.

## Install

Download the DMG from [the latest release](https://github.com/Lxvi101/XNotch/releases/latest), open it, and drag XNotch to Applications. XNotch runs without a Dock icon. Open it again, or right-click the notch, to reach Settings.

The first launch plays a short welcome tour and asks for Full Disk Access, so the shelf and Folders can open files anywhere. XNotch opens the right pane in System Settings and docks a guide beside it; drag XNotch from the guide into the list. The tour then offers the extensions (all start off) and asks for whatever the ones you add need. Replay the tour or grant access later under **Settings → General**.

Releases are signed with Developer ID and notarized by Apple, so XNotch opens without a security warning.

## AI Usage

The built-in **AI Usage** extension shows your Claude Code, Cursor and Codex plan limits: a tile per provider with percent used (or remaining) and the time to each reset (hover for the local time). Click a tile for model-specific limits, credits, saved resets and extra spend. Like every extension it starts off: add it in the welcome tour, which then asks for any access it needs, or under **Settings → Extensions**. Choose which subscriptions to track, connect them and pick what's shown under **Settings → Extensions → AI Usage**. The notch only shows the numbers of connected subscriptions; all setup happens in Settings. It refreshes every 5 minutes by default, when the page opens with an old reading, and after the Mac wakes.

XNotch never signs in for you. It reads the login each app already keeps on this Mac, without modifying it, and only sends that login to the provider it came from:

- **Claude Code**: run `claude` and sign in with your Claude subscription. XNotch reads `~/.claude/.credentials.json` (or `$CLAUDE_CONFIG_DIR`). If Claude Code keeps its login in the Keychain item `Claude Code-credentials` instead, the welcome tour asks for it right after you add AI Usage: choose **Always Allow**. XNotch only ever asks after a click, never in the background. Claude Code can reset that permission when it renews its login; click **Allow Access…** in Settings to ask again.
- **Cursor**: sign in to the Cursor app. XNotch reads its session from Cursor's state database, read-only. Without the app, click **Sign In…** in Settings → AI Usage: Cursor's login opens in your own browser (password manager included), the same way the Cursor app signs in, and XNotch picks up the session when you're done. It keeps only that session, in your Keychain.
- **Codex**: run `codex login` and choose ChatGPT. XNotch reads `~/.codex/auth.json` (or `$CODEX_HOME`). An OpenAI API key has no plan limits to show.

Limitations:

- These usage endpoints are internal to each provider, not published APIs, and may change or stop working without notice.
- When Claude Code's or Codex's access token expires, XNotch waits for that app to renew it. It never renews or rewrites another app's login, so after a long break, use the app once and then refresh.
- Readings are cached without emails or credentials and are never shown for a different account than the one signed in. While offline, the last reading stays visible, marked stale, with its original time.
- Not yet supported: Claude's claude.ai cookie and `claude /usage` fallbacks, Cursor team and enterprise member budgets, importing cookies from a browser, and local token and cost history.

## iPhone & iPad

Share files from your iPhone or iPad straight onto the shelf, and send text to the Mac's clipboard. The **iPhone & iPad** extension listens on your local network; the XNotch app for iPhone and iPad (in [Companion](Companion)) sends to it:

- **Share sheet:** in any app, tap Share and pick XNotch. Photos, PDFs, downloads and files land in the Mac's Downloads folder and on the shelf. Links and plain text go to the clipboard.
- **The app:** a basket for photos and files, a text field for the clipboard, and a Paste button that sends what you copied. Files you send from the Mac (right-click a shelf file, or the phone button in the shelf header while the app is open) show under **From your Mac** and in the Files app.

To pair, add the extension under **Settings → Extensions**, open **Settings → Extensions → iPhone & iPad** and scan the code with the app, or point the Camera app at it. Received files are saved to Downloads; change that in the same pane.

The phone and the Mac use the fastest route that's up, and switch when a faster one appears:

1. **USB**: a cable. The Mac reaches the app through the same service Xcode and Finder use.
2. **Wi-Fi**: the same network, or peer-to-peer Wi-Fi (AirDrop's radio) when the devices are near each other without one.
3. **Internet**: through your XNotch Cloud server's relay, when they're apart. Add the server under **Over the Internet** in the same pane; **Use the Cloud Links Server** copies it from Cloud Links.
4. **Bluetooth**: slow, but it needs no Wi-Fi at all. macOS asks once.

Every route carries the same end-to-end encryption: the code holds a 256-bit key only the two devices know, each connection proves it on both sides and agrees fresh keys (X25519, ChaCha20-Poly1305), so neither the network nor the relay can read or alter anything. **Reset Pairing** makes a new key and unpairs every device.

## Cloud Links

Share shelf files as links that expire, from a server you run. Click the cloud in the shelf header and pick how long the link lives (1 hour to 30 days); XNotch uploads the files (folders are zipped) and copies the link. Right-click a file for a link with your default lifetime. **Settings → Extensions → Cloud Links** lists your links until they expire; delete one there to stop it working at once.

The server is in [Server](Server): one small Rust binary that stores files on disk or in any S3-compatible bucket (Backblaze B2, Cloudflare R2, AWS S3, MinIO), and deploys with Docker or [Dokploy](https://dokploy.com) on a VPS or a Raspberry Pi. Set its `PUBLIC_URL` and `API_TOKEN`, then enter the same URL and token in Settings and click **Test Connection**. Each link is a page that previews images and offers every file for download; expired links stop working immediately and their files are deleted.

## Updates

Automatic checking and downloading are enabled by default. Sparkle checks daily, verifies the signed feed and update archive before extraction, and manages installation and relaunch. Adjust these settings or check manually under **Settings → About XNotch → Updates**. An update that needs attention makes XNotch temporarily available in the Dock.

Install 0.2.0 manually if you currently have 0.1; older builds have no updater. Your existing preferences and shelf are preserved by the app's migration.

## Build

Requires Xcode 26 or later (Swift 6.2), its command line tools, and Python 3.

```sh
scripts/build_app.sh
scripts/build_app.sh --run
```

This builds a universal `build/XNotch.app`, including Sparkle and the bundled extensions (Folders, AI Usage, iPhone & iPad, Cloud Links). `--run` copies it to `~/Applications` and opens it from there, because a bundle inside a protected folder such as Documents makes macOS ask for that folder. Development builds use ad hoc signing. Use `ARCHITECTURES=arm64` for a faster local build, or set `CODE_SIGN_IDENTITY` to your Developer ID certificate to sign for distribution.

See [XNotchKit](Kit/README.md) for the extension API and [Folders](Extensions/Folders) for a complete example.

The iPhone and iPad app is an Xcode project in [Companion](Companion), and the Cloud Links server is a Cargo project in [Server](Server); each folder's README explains how to build and run it. Both phone and Mac use the link protocol in [Shared/XNotchLink](Shared/XNotchLink) (`swift test` there runs its tests).

## Release

See [RELEASING.md](RELEASING.md): bump `release.json`, write `releases/<version>.md`, push `main`, then run `scripts/release.sh --publish` with your Developer ID identity. Release notes also appear in Settings → What's New.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE) and [third-party notices](THIRD_PARTY_NOTICES.md).
