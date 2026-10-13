#!/bin/zsh
# Prepare a signed release; --publish also pushes a tag and publishes on GitHub.
set -euo pipefail
ROOT=${0:A:h:h}
cd "$ROOT"
[[ $# == 0 || ( $# == 1 && $1 == --publish ) ]] || { echo 'usage: scripts/release.sh [--publish]' >&2; exit 2; }
VERSION=$(plutil -extract version raw -o - release.json)
REPOSITORY=$(plutil -extract repository raw -o - release.json)
ACCOUNT=$(plutil -extract sparkleKeyAccount raw -o - release.json)
PUBLIC_KEY=$(plutil -extract sparklePublicKey raw -o - release.json)
NOTES="$ROOT/releases/$VERSION.md"
[[ -f "$NOTES" ]] || { echo "Missing $NOTES" >&2; exit 1; }
if [[ "${1:-}" == --publish ]]; then
    [[ -z $(git status --porcelain) ]] || { echo 'Commit all changes before publishing.' >&2; exit 1; }
    [[ $(gh repo view --json nameWithOwner --jq .nameWithOwner) == "$REPOSITORY" ]] || { echo 'Wrong origin repository.' >&2; exit 1; }
    [[ $(git rev-parse HEAD) == $(git ls-remote origin refs/heads/main | cut -f1) ]] || { echo 'Push main before publishing.' >&2; exit 1; }
    if gh release view "v$VERSION" --repo "$REPOSITORY" >/dev/null 2>&1; then
        echo "v$VERSION already exists; increment version and build in release.json." >&2
        exit 1
    fi
fi
scripts/build_app.sh
TOOLS="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
[[ $("$TOOLS/generate_keys" --account "$ACCOUNT" -p) == "$PUBLIC_KEY" ]] || { echo 'Keychain public key differs from release.json.' >&2; exit 1; }
OUT="$ROOT/build/releases/$VERSION"
mkdir -p "$OUT"
ARCHIVE="$OUT/XNotch-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$ROOT/build/XNotch.app" "$ARCHIVE"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$ARCHIVE" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$ROOT/build/XNotch.app"
    ditto -c -k --sequesterRsrc --keepParent "$ROOT/build/XNotch.app" "$ARCHIVE"
fi
# The DMG is the first download; Sparkle keeps updating from the ZIP.
DMG="$OUT/XNotch-$VERSION.dmg"
STAGING="$OUT/dmg"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
ditto "$ROOT/build/XNotch.app" "$STAGING/XNotch.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname XNotch -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGING"
if [[ "${CODE_SIGN_IDENTITY:--}" != "-" ]]; then codesign --sign "$CODE_SIGN_IDENTITY" --timestamp "$DMG"; fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi
SIGNATURE=$("$TOOLS/sign_update" --account "$ACCOUNT" -p "$ARCHIVE")
python3 scripts/make_appcast.py "$ARCHIVE" "$SIGNATURE" "$OUT/appcast.xml"
"$TOOLS/sign_update" --account "$ACCOUNT" "$OUT/appcast.xml"
python3 scripts/verify_release.py "$OUT"
(cd "$OUT" && shasum -a 256 "XNotch-$VERSION.dmg" "XNotch-$VERSION.zip" appcast.xml > SHA256SUMS)
echo "Prepared $OUT"
if [[ "${1:-}" == --publish ]]; then
    COMMIT=$(git rev-parse HEAD)
    git tag -a "v$VERSION" -m "XNotch $VERSION" "$COMMIT"
    git push origin "v$VERSION"
    gh release create "v$VERSION" "$DMG" "$ARCHIVE" "$OUT/appcast.xml" "$OUT/SHA256SUMS" \
        --repo "$REPOSITORY" --verify-tag --latest --title "XNotch $VERSION" --notes-file "$NOTES"
fi
