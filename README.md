<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="brand/sailfish-logo-outline.svg">
    <source media="(prefers-color-scheme: light)" srcset="brand/sailfish-logo.svg">
    <img src="brand/sailfish-logo.svg" alt="Sailfish" width="140">
  </picture>
</p>

<h1 align="center">Sailfish</h1>

<p align="center"><b>The Open-Source Alternative to Arc.</b></p>

<p align="center">
  Sailfish is a calm, fast browser, designed to give you the same feel as if you were using Arc. Your tabs live in a
  sidebar, your work in spaces, and the web stays out of your way.
</p>

<p align="center">
  <a href="https://github.com/SailfishBrowser/macOS/actions/workflows/test.yml"><img src="https://img.shields.io/github/actions/workflow/status/SailfishBrowser/macOS/test.yml?branch=main&label=tests&style=flat" alt="Tests"></a>
  <a href="https://github.com/SailfishBrowser/macOS/releases/latest"><img src="https://img.shields.io/github/v/release/SailfishBrowser/macOS?label=release&style=flat" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/SailfishBrowser/macOS?style=flat" alt="License"></a>
  <a href="#requirements"><img src="https://img.shields.io/badge/macOS-15%2B%20%C2%B7%20Apple%20silicon-blue?style=flat" alt="macOS 15+ on Apple silicon"></a>
</p>

<p align="center">
  <a href="https://github.com/SailfishBrowser/macOS/releases/latest/download/Sailfish.dmg">Download</a> ·
  <a href="https://sail.fish">Website</a> ·
  <a href="https://sail.fish/guide">Guide</a> ·
  <a href="https://sail.fish/compare">Compare</a> ·
  <a href="https://github.com/SailfishBrowser/macOS/releases">Changelog</a> ·
  <a href="#contributing">Contributing</a>
</p>

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

[Sailfish.dmg](https://github.com/SailfishBrowser/macOS/releases/latest/download/Sailfish.dmg) is always the latest
release, and Sailfish keeps itself up to date from there. Every release and its notes are on
[Releases](https://github.com/SailfishBrowser/macOS/releases).

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
- `brand/`: the app icon and logo artwork.

## The engine

`fetch-engine.sh` downloads `EngineCore-<version>-arm64.zip` from the `engine-<version>` release of this
repository, where `<version>` is the Chromium version in `engine/CHROMIUM_VERSION`. Building the engine yourself
takes a Mac with about 150 GB free, Chromium's toolchain and several hours; `engine/scripts` syncs, patches and
builds it on such a Mac. With `ENGINE_HOST=user@host` set, `fetch-engine.sh` copies the framework built there
instead. A new engine is published with `engine/scripts/package-engine.sh`, which zips the framework and prints the
checksum for `engine/ENGINE_SHA256`.

## Releases

Releases are built by the [Release workflow](.github/workflows/release.yml), started by hand with a version (or by
pushing a `v<version>` tag). It builds the app, signs it with a Developer ID, notarizes it, and publishes release
`v<version>` with the DMG, Sparkle deltas from the previous release and `appcast.xml`, the update feed that
`sail.fish/appcast.xml` redirects to. The build number is one more than the last release's. A run marked
prerelease publishes a prerelease, which neither the download link nor the update feed picks up.

`macOS/scripts/release.sh` does the same on a Mac with the signing identity, notarization credentials and Sparkle
key.

## Contributing

Issues and pull requests are welcome. Build the app as in [Building](#building) and run the tests before you open a
pull request; the [Test workflow](.github/workflows/test.yml) runs them on every pull request too.

## License

Sailfish is licensed under the [Apache License 2.0](LICENSE). It includes third-party software under its own
licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

<p align="center">Created by <a href="https://harunkhan.org">Harun</a> and <a href="https://tso.dev">Joseph</a></p>
