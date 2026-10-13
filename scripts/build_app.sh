#!/bin/zsh
# Build XNotch and wrap it in an .app bundle (LSUIElement, no Dock icon).
# usage: scripts/build_app.sh [--run]
# ARCHITECTURES="arm64 x86_64" (default); CODE_SIGN_IDENTITY for Developer ID builds.
set -euo pipefail
ROOT=${0:A:h:h}
cd "$ROOT"
ARCHITECTURES=${ARCHITECTURES:-"arm64 x86_64"}
export ARCHITECTURES
ARCH_FLAGS=()
for ARCH in ${(s: :)ARCHITECTURES}; do ARCH_FLAGS+=(--arch "$ARCH"); done
swift build -c release "${ARCH_FLAGS[@]}"
VERSION=$(plutil -extract version raw -o - release.json)
BUILD_NUMBER=$(plutil -extract build raw -o - release.json)
REPOSITORY=$(plutil -extract repository raw -o - release.json)
PUBLIC_KEY=$(plutil -extract sparklePublicKey raw -o - release.json)
APP="$ROOT/build/XNotch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks" "$APP/Contents/PlugIns"
BIN=$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)
cp "$BIN/XNotch" "$APP/Contents/MacOS/XNotch"
cp "$BIN/libXNotchKit.dylib" "$APP/Contents/Frameworks/"
SPARKLE="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/XNotch" 2>/dev/null
cp -R ThirdParty/mediaremote-adapter/MediaRemoteAdapter.framework \
      ThirdParty/mediaremote-adapter/mediaremote-adapter.pl "$APP/Contents/Resources/"
cp Kit/README.md "$APP/Contents/Resources/XNotchKit.md"
# Release notes, shown in Settings → What's New.
mkdir -p "$APP/Contents/Resources/Releases"
cp releases/*.md "$APP/Contents/Resources/Releases/"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/Licenses"
cp ThirdParty/mediaremote-adapter/LICENSE "$APP/Contents/Resources/Licenses/mediaremote-adapter.txt"
cp ThirdParty/Sparkle/LICENSE "$APP/Contents/Resources/Licenses/Sparkle.txt"
for EXT in Extensions/*(/); do
    scripts/build_extension.sh "$EXT" --output "$APP/Contents/PlugIns" >/dev/null
done
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.levi.XNotch</string>
    <key>CFBundleName</key><string>XNotch</string>
    <key>CFBundleExecutable</key><string>XNotch</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>SUFeedURL</key><string>https://github.com/$REPOSITORY/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key><string>$PUBLIC_KEY</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUAutomaticallyUpdate</key><true/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>
    <key>SUVerifyUpdateBeforeExtraction</key><true/>
    <key>SURequireSignedFeed</key><true/>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>dev.levi.XNotch</string>
            <key>CFBundleURLSchemes</key><array><string>xnotch</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST
SIGN_FLAGS=(--force --sign "${CODE_SIGN_IDENTITY:--}")
if [[ "${CODE_SIGN_IDENTITY:--}" != "-" ]]; then SIGN_FLAGS+=(--options runtime --timestamp); fi
sign() { codesign "${SIGN_FLAGS[@]}" "$1" >/dev/null; }
# Sign from the inside out; never use --deep to sign nested code.
sign "$APP/Contents/Frameworks/libXNotchKit.dylib"
sign "$APP/Contents/Resources/MediaRemoteAdapter.framework"
for EXT in "$APP/Contents/PlugIns/"*.xnext(N); do sign "$EXT"; done
if [[ "${CODE_SIGN_IDENTITY:--}" != "-" ]]; then
    FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
    codesign "${SIGN_FLAGS[@]}" --preserve-metadata=entitlements "$FRAMEWORK/XPCServices/Downloader.xpc" >/dev/null
    sign "$FRAMEWORK/XPCServices/Installer.xpc"
    sign "$FRAMEWORK/Autoupdate"
    sign "$FRAMEWORK/Updater.app"
    sign "$APP/Contents/Frameworks/Sparkle.framework"
fi
sign "$APP"
codesign --verify --deep --strict "$APP"
echo "$APP"
if [[ "${1:-}" == "--run" ]]; then
    pkill -x XNotch 2>/dev/null || true
    while pgrep -x XNotch >/dev/null; do sleep 0.1; done
    # Run from ~/Applications: a bundle inside a protected folder such as
    # Documents makes macOS ask for that folder when the app reads its own
    # resources or is dragged into a permission list.
    RUN_APP="$HOME/Applications/XNotch.app"
    mkdir -p "$HOME/Applications"
    rm -rf "$RUN_APP"
    ditto "$APP" "$RUN_APP"
    # LaunchServices briefly rejects (-600) an app it still considers terminating.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        open "$RUN_APP" 2>/dev/null && break
        sleep 0.5
    done
fi
