# Build and test

Pastemin has one codebase, one sandboxed app, and one bundle identifier: `tools.min.pastemin`. Public source builds start the same 30-day trial locally after its disclosure; Mac App Store production builds use Apple's signed original acquisition date. Both use the same five-item post-trial limit and StoreKit verification. Automatic paste is available only in local builds.

## Requirements

Building requires an Apple-silicon Mac running macOS 14 or later, Python 3, and Apple Command Line Tools or Xcode with the macOS SDK.

## Build

```sh
python3 scripts/build.py
```

The command creates an ad-hoc-signed app at `build/Pastemin.app`. It does not install or launch the app. A source build does not grant Pro access by itself.

Automatic paste remains disabled by default in local builds. When enabled, Pastemin asks macOS for event-posting permission the first time you select an item. If permission is unavailable or declined, Pastemin still restores the item to the clipboard and returns focus to the previous app.

The Mac App Store build (`--app-store`) omits the automatic-paste setup page, settings control, and event-posting code. Selecting an item copies it and returns focus for manual pasting with ⌘V. Store builds neither read nor change a local build's saved automatic-paste preference.

## Test

```sh
python3 scripts/test_all.py
```

The suite builds both sandboxed editions and checks storage, search, pagination, localization, setup, privacy boundaries, StoreKit entitlement decisions, signing metadata, panel presentation, and the post-trial access limit. It also verifies that the Store executable contains no event-posting permission or synthetic-paste calls.

Run the offline release audit after changing identity, entitlements, privacy metadata, StoreKit logic, icons, or public URLs:

```sh
python3 scripts/check_app_store.py
```

## Images

```sh
python3 scripts/render_hero.py --no-app-store
```

Renders the README images in `docs/images` from the real panel view with a fictional history, drawn as the glass panel over a wallpaper. The renderer compiles the app sources and never launches the app or reads your clipboard. Without `--no-app-store` it also writes the Mac App Store screenshot set to `private/app-store/screenshots`, and `--profile <directory>` adds 900-pixel copies for the GitHub organization profile.

## Source layout

| Path | Contents |
| --- | --- |
| `Sources/PasteminApp` | AppKit and SwiftUI interface, clipboard storage, setup, and StoreKit logic |
| `Resources/*.lproj` | Matching interface translations for 31 languages |
| `Configuration` | Sandbox entitlements |
| `scripts` | Builder, validation, and regression suites |
| `docs` | Public build and privacy documentation |

Keep generated builds, packages, archives, signing files, credentials, and maintainer release data out of Git.
