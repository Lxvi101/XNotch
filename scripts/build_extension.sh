#!/bin/zsh
# Package a XNotchKit extension into a .xnext bundle.
#
# The package needs a dynamic library product and an extension.json at its
# root. Anything in a Resources/ folder beside extension.json is bundled too.
#
# usage: scripts/build_extension.sh <package-dir> [--output DIR] [--install]
#   --output DIR  where to put <Name>.xnext (default: <package>/.build/xnext)
#   --install     also copy it to ~/Library/Application Support/XNotch/Extensions
set -euo pipefail

PKG=${1:?usage: build_extension.sh <package-dir> [--output DIR] [--install]}
PKG=${PKG:A}
shift
OUT="$PKG/.build/xnext"
INSTALL=0
while (( $# )); do
    case $1 in
        --output) OUT=${2:A}; shift 2 ;;
        --install) INSTALL=1; shift ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
    esac
done

MANIFEST="$PKG/extension.json"
[[ -f $MANIFEST ]] || { echo "$MANIFEST is missing" >&2; exit 1; }
field() { plutil -extract "$1" raw -o - "$MANIFEST" }
ID=$(field id)
NAME=$(field name)
VERSION=$(field version)
PRINCIPAL=$(field principalClass)
PRODUCT=$(swift package --package-path "$PKG" dump-package | plutil -extract products.0.name raw -o - -)

ARCH_FLAGS=()
for ARCH in ${(s: :)${ARCHITECTURES:-"arm64 x86_64"}}; do ARCH_FLAGS+=(--arch "$ARCH"); done
swift build -c release "${ARCH_FLAGS[@]}" --package-path "$PKG" --product "$PRODUCT" >&2
BIN=$(swift build -c release "${ARCH_FLAGS[@]}" --package-path "$PKG" --show-bin-path)

BUNDLE="$OUT/${NAME// /}.xnext"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN/lib$PRODUCT.dylib" "$BUNDLE/Contents/MacOS/$PRODUCT"
cp "$MANIFEST" "$BUNDLE/Contents/Resources/extension.json"
[[ -d "$PKG/Resources" ]] && cp -R "$PKG/Resources/" "$BUNDLE/Contents/Resources/"

# XNotchKit is already loaded by the app; point the extension at the app's copy.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$BUNDLE/Contents/MacOS/$PRODUCT" 2>/dev/null

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.levi.XNotch.extension.$ID</string>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleExecutable</key><string>$PRODUCT</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>NSPrincipalClass</key><string>$PRINCIPAL</string>
    <key>XNotchExtensionID</key><string>$ID</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$BUNDLE" >/dev/null

if (( INSTALL )); then
    DEST="$HOME/Library/Application Support/XNotch/Extensions"
    mkdir -p "$DEST"
    rm -rf "$DEST/${BUNDLE:t}"
    cp -R "$BUNDLE" "$DEST/"
    echo "installed to $DEST/${BUNDLE:t}; restart XNotch to load it" >&2
fi
echo "$BUNDLE"
