# Build and test

Pastemin has one codebase, one sandboxed app, and one bundle identifier: `tools.min.pastemin`. Public source builds start the same 30-day trial locally after its disclosure; Mac App Store production builds use Apple's signed original acquisition date. Both use the same five-item post-trial limit, StoreKit verification, setup, and optional automatic-paste behavior.

## Requirements

Building requires an Apple-silicon Mac running macOS 14 or later, Python 3, and Apple Command Line Tools or Xcode with the macOS SDK.

## Build

```sh
python3 scripts/build.py
```

The command creates an ad-hoc-signed app at `build/Pastemin.app`. It does not install or launch the app. A source build does not grant Pro access by itself.

Automatic paste remains disabled by default. When enabled, Pastemin asks macOS for event-posting permission the first time you select an item. If permission is unavailable or declined, Pastemin still restores the item to the clipboard and returns focus to the previous app.

## Test

```sh
python3 scripts/test_all.py
```

The suite builds the sandboxed app and checks storage, search, pagination, localization, setup, privacy boundaries, StoreKit entitlement decisions, signing metadata, panel presentation, and the post-trial access limit.

Run the offline release audit after changing identity, entitlements, privacy metadata, StoreKit logic, icons, or public URLs:

```sh
python3 scripts/check_app_store.py
```

## Source layout

| Path | Contents |
| --- | --- |
| `Sources/PasteminApp` | AppKit and SwiftUI interface, clipboard storage, setup, and StoreKit logic |
| `Resources/*.lproj` | Matching interface translations for 31 languages |
| `Configuration` | Sandbox entitlements |
| `scripts` | Builder, validation, and regression suites |
| `docs` | Public build and privacy documentation |

Keep generated builds, packages, archives, signing files, credentials, and maintainer release data out of Git.
