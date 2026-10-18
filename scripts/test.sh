#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"
PORTABLE=false
if [[ "${1:-}" == --portable ]]; then PORTABLE=true; shift; fi
command -v swift >/dev/null || { echo "Swift 6 or later is required." >&2; exit 1; }
swift --version
SWIFT_TEST=(swift test -j "${SWIFT_JOBS:-2}")
# Work around discovery only for the affected macOS 27 / Swift 6.4 CLT.
# Resolve the plugin from the selected compiler; never use a machine-specific path.
if [[ "$(uname -s)" == Darwin ]]; then
    COMPILER="$(xcrun --find swiftc)"
    if [[ "$COMPILER" == /Library/Developer/CommandLineTools/* ]] && \
       [[ "$(sw_vers -productVersion)" == 27.* ]] && \
       "$COMPILER" --version | head -1 | grep -Eq 'Swift version 6\.4([. ]|$)'; then
        PLUGIN="$(dirname "$(dirname "$COMPILER")")/lib/swift/host/plugins/testing/libTestingMacros.dylib"
        if [[ -f "$PLUGIN" ]]; then
            SWIFT_TEST+=(-Xswiftc -load-plugin-library -Xswiftc "$PLUGIN")
            echo "Using the selected CLT's TestingMacros discovery workaround."
        fi
    fi
fi
# Each dependency has its own test invocation. Root swift test does not run them.
PACKAGES=(Packages/DeviceProtocol Packages/SupportDiagnostics)
if [[ "$(uname -s)" == Darwin && "$PORTABLE" == false ]]; then
    PACKAGES+=(Packages/DeviceRuntime .)
elif [[ "$PORTABLE" == false ]]; then
    echo "Skipping DeviceRuntime and HushbarApp tests: AppKit and IOBluetooth require macOS."
fi
for package in "${PACKAGES[@]}"; do
    [[ -f "$package/Package.swift" ]] || { echo "Missing package manifest: $package/Package.swift" >&2; exit 1; }
    echo "Testing $package"
    "${SWIFT_TEST[@]}" --package-path "$package" "$@"
done
