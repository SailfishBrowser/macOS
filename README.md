# Sailfish for macOS

Sailfish is a calm, fast, open-source browser for the Mac, built on Chromium. Your tabs live in a sidebar, your
work in spaces, and the web stays out of your way. Website: [sail.fish](https://sail.fish).

## Features

- A sidebar of pinned and today tabs, folders and tab groups, organized into spaces with their own colors
- A command bar for search, tabs and commands
- Little Sailfish, a small window for links opened from other apps, and Peek for links from pinned sites
- Split view, Reader view, find in page, downloads, archived tabs and history
- uBlock Origin built in, and Chrome extensions from the Chrome Web Store
- Import from Arc, Chrome, Edge, Dia and Safari, read on your Mac with nothing uploaded
- Automatic updates through Sparkle

## Requirements

- A Mac with Apple silicon
- macOS 15 Sequoia or later

## Download

Get the latest release from [sail.fish](https://sail.fish) or
[Releases](https://github.com/SailfishBrowser/macOS/releases/latest).

## Building

You need Xcode 26.5 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
cd macOS
sh scripts/fetch-engine.sh   # the prebuilt EngineCore.framework, checked against engine/ENGINE_SHA256
sh scripts/fetch-ublock.sh   # uBlock Origin, checked against its release digest
xcodegen generate
open Sailfish.xcodeproj
```

Run the `Sailfish` scheme. To run the tests from the command line:

```sh
xcodebuild -project Sailfish.xcodeproj -scheme Sailfish -destination platform=macOS \
  -skipMacroValidation -skipPackagePluginValidation test
```

## Layout

- `macOS/`: the app, in Swift with [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture), and its tests and scripts.
- `engine/`: EngineCore, the Chromium build the app embeds: patches to Chromium (`engine/patches`), an
  Objective-C bridge (`engine/src`) and build scripts. See [engine/README.md](engine/README.md).
- `brand/`: the app icon artwork.

## The engine

`fetch-engine.sh` downloads `EngineCore-<version>-arm64.zip` from the `engine-<version>` release of this
repository, where `<version>` is the Chromium version in `engine/CHROMIUM_VERSION`. Building the engine yourself
takes a Mac with about 150 GB free, Chromium's toolchain and several hours; `engine/scripts` syncs, patches and
builds it on such a Mac. With `ENGINE_HOST=user@host` set, `fetch-engine.sh` copies the framework built there
instead. A new engine is published with `engine/scripts/package-engine.sh`, which zips the framework and prints the
checksum for `engine/ENGINE_SHA256`.

## Releases

Releases are built by the [Release workflow](.github/workflows/release.yml), started by hand with a version (or by
pushing a `v<version>` tag). It tests the app, signs it with a Developer ID, notarizes it, and publishes release
`v<version>` with the DMG, Sparkle deltas from the previous release and `appcast.xml`, the update feed that
`sail.fish/appcast.xml` redirects to. The build number is one more than the last release's. A run marked
prerelease publishes a prerelease, which neither the download link nor the update feed picks up.

`macOS/scripts/release.sh` does the same on a Mac with the signing identity, notarization credentials and Sparkle
key.

## License

Sailfish is licensed under the [Apache License 2.0](LICENSE). It includes third-party software under its own
licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
