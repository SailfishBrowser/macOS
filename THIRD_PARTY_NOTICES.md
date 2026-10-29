# Third-party notices

Sailfish is licensed under the Apache License 2.0 ([LICENSE](LICENSE)). It includes or downloads the software
below, each under its own license.

## Chromium

The engine (`engine/`, and the `EngineCore.framework` the app embeds) is built from Chromium,
https://www.chromium.org. Copyright The Chromium Authors. BSD 3-Clause License:
https://chromium.googlesource.com/chromium/src/+/main/LICENSE. Chromium includes third-party components under
their own licenses, listed at chrome://credits in a running build. The patches in `engine/patches` modify Chromium
and are under its license.

## uBlock Origin

The app bundles uBlock Origin 1.75.0, downloaded by `macOS/scripts/fetch-ublock.sh` from its official release.
Copyright Raymond Hill and contributors. GNU General Public License v3.0. It is a separate program, distributed
unchanged except for an added manifest `key`; its license is `LICENSE.txt` in
`Sailfish.app/Contents/Resources/uBlock0.chromium`. Source: https://github.com/gorhill/uBlock/tree/1.75.0

## Readability

`macOS/Sailfish/Resources/Reader` contains Readability 0.6.0 by Mozilla, https://github.com/mozilla/readability.
Copyright (c) 2010 Arc90 Inc. Apache License 2.0 (`Readability-0.6.0-LICENSE.md` beside it). The test fixtures
in `macOS/SailfishTests/Fixtures/Reader` include a page from its test suite.

## Ardia

Four files in `macOS/Sailfish/Engine` are adapted from Ardia's own source files at commit a01a909,
https://github.com/mantrakp04/ardia. Ardia, Copyright 2026 Mantra Patel. Apache License 2.0, the license of
Sailfish ([LICENSE](LICENSE)). Sailfish changed each of them, and each keeps Ardia's copyright line at its top.
Ardia's engine patches and its bundled uBlock Origin are GPL-3.0, and Sailfish uses neither.

- `WebKitPageScript.swift`, from `packages/ardiacore/ios/WebKitPageScript.swift`
- `WebKitDownloads.swift`, from `packages/ardiacore/ios/WebKitDownloads.swift`
- `WebKitStoreRemovals.swift`, from `packages/ardiacore/ios/WebKitStoreRemovals.swift`
- `ProtectedMedia.swift`, from the protected-media detector in `packages/ardiacore/ios/page_script.js`, lines 763
  to 833

## Sparkle

Sparkle 2.10.1, https://sparkle-project.org. Copyright (c) 2006-2013 Andy Matuschak, (c) 2009-2013 Elgato
Systems GmbH, (c) 2011-2014 Kornel Lesiński, (c) 2015-2017 Mayur Pawashe, (c) 2014 C.W. Betts, (c) 2014 Petroules
Corporation, (c) 2014 Big Nerd Ranch, and others. MIT License. Sparkle includes components under their own
licenses: https://github.com/sparkle-project/Sparkle/blob/2.10.1/LICENSE

## Swift packages

MIT License, Copyright (c) Point-Free, Inc.:

- swift-composable-architecture, https://github.com/pointfreeco/swift-composable-architecture
- swift-sharing, https://github.com/pointfreeco/swift-sharing
- swift-dependencies, https://github.com/pointfreeco/swift-dependencies
- swift-navigation, https://github.com/pointfreeco/swift-navigation
- swift-perception, https://github.com/pointfreeco/swift-perception
- swift-case-paths, https://github.com/pointfreeco/swift-case-paths
- swift-clocks, https://github.com/pointfreeco/swift-clocks
- swift-concurrency-extras, https://github.com/pointfreeco/swift-concurrency-extras
- swift-custom-dump, https://github.com/pointfreeco/swift-custom-dump
- swift-identified-collections, https://github.com/pointfreeco/swift-identified-collections
- combine-schedulers, https://github.com/pointfreeco/combine-schedulers
- xctest-dynamic-overlay, https://github.com/pointfreeco/xctest-dynamic-overlay

Apache License 2.0 with Runtime Library Exception, Copyright Apple Inc. and the Swift project authors:

- swift-collections, https://github.com/apple/swift-collections
- swift-syntax, https://github.com/swiftlang/swift-syntax
