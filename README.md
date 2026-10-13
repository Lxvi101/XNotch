# XNotch

A macOS notch companion with Now Playing, a file shelf, Lock Screen media controls, and loadable extensions. Requires macOS 14 or later; supports Apple Silicon and Intel.

## Install

Download the ZIP from [the latest release](https://github.com/Lxvi101/XNotch/releases/latest), extract it, and move XNotch.app to Applications. XNotch runs without a Dock icon. Open it again, or right-click the notch, to reach Settings.

The first launch plays a short welcome tour and asks for Full Disk Access, so the shelf and Folders can open files anywhere. XNotch opens the right pane in System Settings and docks a guide beside it; drag XNotch from the guide into the list. The tour then offers the extensions (all start off) and asks for whatever the ones you add need. Replay the tour or grant access later under **Settings → General**.

The 0.2.0 release is Developer ID signed but not notarized. macOS may require first-launch approval in System Settings → Privacy & Security.

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

## Updates

Automatic checking and downloading are enabled by default. Sparkle checks daily, verifies the signed feed and update archive before extraction, and manages installation and relaunch. Adjust these settings or check manually under **Settings → About XNotch → Updates**. An update that needs attention makes XNotch temporarily available in the Dock.

Install 0.2.0 manually if you currently have 0.1; older builds have no updater. Your existing preferences and shelf are preserved by the app's migration.

## Build

Requires Xcode 26 or later (Swift 6.2), its command line tools, and Python 3.

```sh
scripts/build_app.sh
scripts/build_app.sh --run
```

This builds a universal `build/XNotch.app`, including Sparkle and the bundled Folders and AI Usage extensions. `--run` copies it to `~/Applications` and opens it from there, because a bundle inside a protected folder such as Documents makes macOS ask for that folder. Development builds use ad hoc signing. Use `ARCHITECTURES=arm64` for a faster local build, or set `CODE_SIGN_IDENTITY` to your Developer ID certificate to sign for distribution.

See [XNotchKit](Kit/README.md) for the extension API and [Folders](Extensions/Folders) for a complete example.

## Release

See [RELEASING.md](RELEASING.md): bump `release.json`, write `releases/<version>.md`, push `main`, then run `scripts/release.sh --publish` with your Developer ID identity. Release notes also appear in Settings → What's New.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE) and [third-party notices](THIRD_PARTY_NOTICES.md).
