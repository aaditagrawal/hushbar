#!/bin/bash
# Render actual SwiftUI/AppKit views with deterministic demo data, no Bluetooth.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"
[[ "$(uname -s)" == Darwin ]] || { echo "Screenshot rendering requires a macOS GUI session." >&2; exit 1; }
[[ $# -le 1 ]] || { echo "Usage: scripts/screenshots.sh [output-directory]" >&2; exit 1; }
OUTPUT="${1:-$ROOT/docs/screenshots}"
scripts/build-app.sh
"$ROOT/dist/Hushbar.app/Contents/MacOS/Hushbar" --render-snapshots "$OUTPUT"
echo "Review the PNGs before including them in documentation. Demo values are not hardware evidence."
