#!/bin/bash
# Build a standalone app without modifying an installed copy.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
if [[ "$(uname -s)" != Darwin ]]; then
    echo "App packaging requires macOS 14 or later and Swift 6 or later." >&2
    exit 1
fi
cd "$ROOT"
export MACOSX_DEPLOYMENT_TARGET=14.0
DIST="$ROOT/dist"
[[ ! -L "$DIST" ]] || { echo "Refusing a symlinked dist directory." >&2; exit 1; }
for file in Support/Info.plist Support/PrivacyInfo.xcprivacy LICENSE README.md VERSION; do
    [[ -f "$file" ]] || { echo "Missing required packaging input: $file" >&2; exit 1; }
done
if [[ ! -f Support/AppIcon.png ]]; then
    [[ -f scripts/render-icon.swift ]] || { echo "Missing Support/AppIcon.png and its renderer." >&2; exit 1; }
    xcrun swift scripts/render-icon.swift Support/AppIcon.png
fi
BUILD_ARGS=(-c release --product Hushbar -j "${SWIFT_JOBS:-2}")
BIN_ARGS=(-c release --show-bin-path)
if [[ -n "${HUSHBAR_ARCH:-}" ]]; then
    case "$HUSHBAR_ARCH" in arm64|x86_64) ;; *) echo "HUSHBAR_ARCH must be arm64 or x86_64." >&2; exit 1 ;; esac
    BUILD_ARGS+=(--arch "$HUSHBAR_ARCH")
    BIN_ARGS+=(--arch "$HUSHBAR_ARCH")
fi
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BIN_ARGS[@]}")"
mkdir -p "$DIST"
STAGING="$(mktemp -d "$DIST/.Hushbar.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/Hushbar.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Hushbar" "$APP/Contents/MacOS/Hushbar"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp LICENSE Support/PrivacyInfo.xcprivacy "$APP/Contents/Resources/"
# Keep attribution in the README and include it separately in the built app.
awk '/^## Credits and licence$/ { found = 1 } found { print } END { if (!found) exit 1 }' \
    README.md > "$APP/Contents/Resources/NOTICE.md"
# SwiftPM emits resource bundles for local dependencies beside the executable.
# Copy every bundle, not just the app target's resources.
for bundle in "$BIN_DIR"/*.bundle; do
    [[ -d "$bundle" ]] || continue
    cp -R "$bundle" "$APP/Contents/Resources/"
done
[[ -d "$APP/Contents/Resources/DeviceProtocol_DeviceProtocol.bundle" ]] || {
    echo "The DeviceProtocol resource bundle is missing." >&2; exit 1;
}
ICONSET="$STAGING/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Support/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" Support/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
plutil -lint "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
VERSION="$(tr -d '\r\n' < VERSION)"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$APP_VERSION" == "$VERSION" ]] || { echo "VERSION and Info.plist disagree." >&2; exit 1; }
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")"
[[ "$BUNDLE_ID" == io.github.aaditagrawal.hushbar ]] || { echo "Unexpected bundle identifier." >&2; exit 1; }
IDENTITY="${CODESIGN_IDENTITY:--}"
if [[ "$IDENTITY" == - ]]; then
    # Keep local rebuilds recognizable to privacy permissions. This requirement
    # identifies the bundle only and does not authenticate a publisher.
    codesign --force --sign - --identifier "$BUNDLE_ID" \
        -r='designated => identifier "io.github.aaditagrawal.hushbar"' "$APP"
else
    # Let Developer ID signing retain its certificate-bound default requirement.
    codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" --timestamp --options runtime "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"
codesign --display --requirements - "$APP"
# Replace only this generated app, after a successful build and signature check.
rm -rf "$DIST/Hushbar.app"
mv "$APP" "$DIST/Hushbar.app"
echo "Built and verified: dist/Hushbar.app"
echo "Not notarized by this script."
