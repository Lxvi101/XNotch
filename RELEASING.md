# Releasing XNotch

A release is a GitHub release with four assets: the universal app DMG for first installs, the ZIP that Sparkle updates from, a signed `appcast.xml`, and `SHA256SUMS`. Installed copies find it through the latest release's appcast and update themselves with Sparkle.

## Once per Mac

- Xcode 26 or later, Python 3, and `gh` logged in to the account that owns `Lxvi101/XNotch`.
- The Developer ID Application certificate in the login Keychain (`security find-identity -v -p codesigning`).
- The Sparkle signing key in the login Keychain under account `dev.levi.XNotch`. Only its public key is committed. Never generate a replacement: installed copies would reject every later update.
- Notarization credentials, required to publish: `xcrun notarytool store-credentials XNotch --apple-id <Apple ID> --team-id 59UPSTU6WZ`, with an app-specific password from account.apple.com. Without notarization, macOS blocks the app on first launch.

## Each release

1. **Bump the version.** In `release.json`, raise `version` (for example `0.3.0` → `0.4.0`) and increase `build` by one. Sparkle compares `build`, so it must always go up.
2. **Write the notes** in `releases/<version>.md`: one summary sentence, a `- ` bullet list of changes, then any install remarks. Keep blank lines between blocks. This file becomes the GitHub release notes, the text of the update dialog, and the entry in Settings → What's New.
3. **Commit and push `main`**, and wait for the Build workflow to pass.
4. **Dry run**, which builds, signs and verifies everything into `build/releases/<version>/` without publishing:

   ```sh
   CODE_SIGN_IDENTITY='Developer ID Application: Levi Dan Berger (59UPSTU6WZ)' scripts/release.sh
   ```

5. **Publish.** The same command with `--publish` tags `v<version>`, pushes the tag and creates the GitHub release with all four assets:

   ```sh
   NOTARY_PROFILE=XNotch CODE_SIGN_IDENTITY='Developer ID Application: Levi Dan Berger (59UPSTU6WZ)' scripts/release.sh --publish
   ```

6. **Check it.** `gh release view v<version>` should list the DMG, the ZIP, `appcast.xml` and `SHA256SUMS`. In a copy of the previous version, Settings → About XNotch → Check for Updates should offer the new one.

## Rules

- Never edit a ZIP or `appcast.xml` after it's signed. To redo a release, regenerate and upload all four assets together.
- Never reuse a version: publishing refuses an existing tag. Bump `release.json` instead.
- Publishing requires a clean working tree, with `main` pushed and matching `origin/main`.
