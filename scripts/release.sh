#!/bin/bash
# Prepare local artifacts only. GitHub writes belong exclusively to the draft workflow.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"
[[ "$(uname -s)" == Darwin ]] || { echo "Release packaging requires macOS." >&2; exit 1; }
[[ $# -le 1 ]] || { echo "Usage: scripts/release.sh [existing-version-tag]" >&2; exit 1; }
VERSION="$(tr -d '\r\n' < VERSION)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "VERSION must contain a release version such as 0.1.0." >&2; exit 1; }
COMMIT="$(git rev-parse --verify HEAD)"
if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
    echo "Release artifacts require a clean committed checkout so source and binary match." >&2
    exit 1
fi
if [[ $# -eq 1 ]]; then
    [[ "$1" == "v$VERSION" ]] || { echo "The tag must match VERSION." >&2; exit 1; }
    TAG_COMMIT="$(git rev-parse --verify "refs/tags/$1^{commit}")"
    [[ "$TAG_COMMIT" == "$COMMIT" ]] || { echo "The tag must point to this checkout." >&2; exit 1; }
fi
ARCH="${HUSHBAR_ARCH:-$(uname -m)}"
case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported release architecture: $ARCH" >&2; exit 1 ;; esac
export HUSHBAR_ARCH="$ARCH"
scripts/check.sh
scripts/test.sh
scripts/build-app.sh
ACTUAL_ARCH="$(lipo -archs dist/Hushbar.app/Contents/MacOS/Hushbar)"
[[ "$ACTUAL_ARCH" == "$ARCH" ]] || { echo "App architecture does not match the artifact name." >&2; exit 1; }
# Refuse symlinked output directories rather than writing outside generated dist.
[[ ! -L dist && ! -L dist/release ]] || { echo "Refusing a symlinked artifact directory." >&2; exit 1; }
mkdir -p dist/release
PREFIX="Hushbar-$VERSION"
ZIP="$PREFIX-macos-$ARCH.zip"
SOURCE="$PREFIX-source.tar.gz"
RECIPE="$PREFIX-$ARCH-SOURCE.md"
SUMS="$PREFIX-$ARCH-SHA256SUMS.txt"
ditto -c -k --sequesterRsrc --keepParent dist/Hushbar.app "dist/release/$ZIP"
# gzip -n omits timestamps and filenames from the compressor header.
# git archive includes all committed source, licence, notices, artwork and privacy manifest.
git archive --format=tar --prefix="$PREFIX/" "$COMMIT" | gzip -n > "dist/release/$SOURCE"
SWIFT_VERSION="$(swift --version)"
SDK_VERSION="$(xcrun --show-sdk-version)"
OS_VERSION="$(sw_vers -productVersion)"
SIGNING=ad-hoc
if [[ "${CODESIGN_IDENTITY:--}" != - ]]; then SIGNING=user-supplied; fi
cat > "dist/release/$RECIPE" <<EOF
# Corresponding source for Hushbar $VERSION, $ARCH

The app archive is $ZIP. Its corresponding source is $SOURCE at commit $COMMIT.
SHA-256 hashes are in $SUMS. The source includes LICENSE, README.md with upstream
notices, all local packages, build scripts, original icon source, and
Support/PrivacyInfo.xcprivacy.

Built on macOS $OS_VERSION with SDK $SDK_VERSION. Signing mode: $SIGNING.
This recipe does not claim notarization or bit-for-bit reproducibility of signatures.

Compiler output:

~~~text
$SWIFT_VERSION
~~~

Extract the source archive, enter $PREFIX, install Bun for repository checks,
and run these commands on macOS 14 or later with Swift 6 or later:

~~~sh
scripts/check.sh
scripts/test.sh
HUSHBAR_ARCH=$ARCH scripts/build-app.sh
~~~

The result is dist/Hushbar.app. The default signature is ad-hoc.
For Developer ID signing, set CODESIGN_IDENTITY to your own installed identity.
Notarization is a separate maintainer step requiring your own Apple credentials.
EOF
(cd dist/release && shasum -a 256 "$ZIP" "$SOURCE" "$RECIPE" > "$SUMS")
echo "Prepared $ZIP, $SOURCE, $RECIPE, and $SUMS in dist/release. Nothing uploaded."
