# Working on Hushbar

Read the package boundaries and checks below before changing package ownership. [README.md](README.md) covers usage, compatibility, reporting and attribution. [Protocol notes](docs/PROTOCOL.md) record wire evidence.

- Keep `DeviceProtocol` and `SupportDiagnostics` independent of AppKit, SwiftUI and Bluetooth. Bluetooth lifecycle belongs in `DeviceRuntime`; AppKit and SwiftUI presentation belongs in `HushbarApp`.
- Build the `Hushbar` product. Its executable module is `HushbarApp`.
- Run dependency package tests explicitly, followed by root app tests, using the commands below.
- Preserve native controls, status-item `NSPopover` anchoring and zero-height sizing checks when editing UI.
- Preserve B170 name identification, advisory unsupported exclusion reads, alternate ringing routes, connection generation checks and confirmation rollback unless a change includes evidence and regression coverage.
- Treat catalogue entries as unverified compatibility data. Only Headphone (1), firmware 1.0.1.81, has been hardware-checked. EQ writes and ringing are unverified.
- Keep support exports and public documentation free of personal device names, network addresses, absolute home paths and raw local logs.
- Preserve upstream licensing and provenance. App branding is Hushbar; Nothing and CMF product names remain device names.
- Use Bun for JavaScript and uv for Python tooling.

## Package boundaries

| Module | Owns |
| --- | --- |
| `DeviceProtocol` | Catalogue resources, framing, parsing, capabilities, EQ profiles, pure edit plans and demo fixtures. Foundation only; independent of runtime and diagnostics. |
| `SupportDiagnostics` | Typed metadata, bounded capture, privacy filtering and deterministic export. Independent of protocol, runtime and UI. |
| `DeviceRuntime` | Main-actor device discovery, RFCOMM, connection generations, routing, reads, confirmed edits, reconnects and ringing cleanup. Depends on both portable packages. |
| `HushbarApp` | AppKit lifecycle, status item, native popover, SwiftUI panels, Settings, report presentation and snapshots. Consumes runtime and shared values. |

Keep codecs and capability rules together. Keep transport callbacks and connection identity inside the session. Edits own optimistic changes, packets and confirmation reads; rollback restores only edited fields. Missing device values remain explicitly unavailable. Route negotiation uses read-only queries and preserves explicit command selectors.

The protocol package processes its own resources. Packaged lookup checks `Contents/Resources/DeviceProtocol_DeviceProtocol.bundle`, then falls back to `Bundle.module` for SwiftPM. App packaging must copy that bundle intact. The app's bundle identifier is `io.github.aaditagrawal.hushbar`.

## Build and test

App/runtime checks require macOS 14 or later and Swift 6 or later. DeviceProtocol and SupportDiagnostics can be tested on Linux with Swift 6. Run suites separately in this order, then build the product:

```sh
swift test --package-path Packages/DeviceProtocol
swift test --package-path Packages/SupportDiagnostics
swift test --package-path Packages/DeviceRuntime
swift test
swift build --product Hushbar
```

`scripts/test.sh` runs these suites, and `--portable` runs only the two portable packages. Toolchain-specific macro-loading workarounds belong in tooling, never hardcoded paths or unsafe flags in manifests. Run `scripts/check.sh` for catalogue, documentation and shell checks.

After changing catalogue resources, run `bun scripts/export-catalog.js --write` to refresh the README's device table, then run repository checks.

## Native UI

Use system typography, native controls, both appearances, Reduce Motion, keyboard access and VoiceOver labels. Keep the popover 336 points wide with 16-point insets, a 540-point scroll viewport cap and a 500-point main-page height budget. Preserve zero-height hosting-controller checks and reanchoring after page resizing.

Keep device controls inside the popover, with a back button on secondary pages. Open EQ editors even when a device setting is pending. Preserve received EQ band counts and tuning metadata; send slider changes on release through confirmation and rollback. Unknown or pending state can disable dependent controls, while Find Stop remains available. Keep restart confirmation alerts.

Snapshots must render actual views with deterministic fixtures, no Bluetooth discovery and no saved preferences. Check the live popover anchor, Settings, keyboard navigation and both appearances in a logged-in macOS session. Demo sessions, snapshots and unit tests do not prove hardware interoperability.
