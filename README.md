# FieldTapeKit

Take tapes and album sides off a Teenage Engineering OP-1 Field over USB, and put them back, from an iOS, iPadOS or macOS app, with no driver.

**Latest release:** `1.0.0-beta.1`, 2026-11-17. See the [CHANGELOG](CHANGELOG.md).

FieldTapeKit talks to an OP-1 Field in MTP mode through ImageCaptureCore, and gives an app three layers on one `FieldDevice`:

- **Tapes:** list them, copy one off into a `.reelarchive` file, move it off to free its slot, and restore it byte for byte.
- **The album:** copy side A or B off as a WAV file, and tell whether it was recorded over since.
- **Files:** list, read, write and delete files, shaped like `FileManager`.

People's music often lives only on the OP-1, so nothing is deleted or overwritten without a verified copy or a person's confirmation, every copy is read back and matched by SHA-256, and a failure stops at once and reports exactly what changed.

## Requirements

- iOS, iPadOS or macOS 27.
- Xcode 27.2 or later, with Swift 6.
- An OP-1 Field in MTP mode, on firmware 1.7.3, the firmware FieldTapeKit is tested on. Other firmware works, with a warning an app can show.
- No dependencies.

## A Quick Look

```swift
import FieldTapeKit

for try await event in FieldDevice.connections {
    guard case .connected(let device) = event else { continue }
    for tape in try await device.tapes() where tape.isSound && !tape.isEmpty {
        let archive = try await device.copyTape(tape, to: folder)
        print("Copied \(tape.name) to \(archive.url.lastPathComponent)")
    }
}
```

`FieldDevice.simulated { … }` makes an OP-1 in memory that runs the same code, for tests and SwiftUI previews.

## Installation

FieldTapeKit is a Swift package. It isn't published yet, so add it by its repository URL or as a local package: in Xcode, choose **File ▸ Add Package Dependencies**, or in a `Package.swift`:

```swift
.target(name: "MyApp", dependencies: [
    .product(name: "FieldTapeKit", package: "FieldTapeKit"),
])
```

Only `FieldTapeKit` is for apps. `FieldCheckKit` and `FieldTapeConformance` are for FieldCheck, the app in [`FieldCheck/`](FieldCheck) that checks FieldTapeKit against a real OP-1. Swift Package Manager is the only package manager supported.

## Documentation

The reference and articles are a DocC catalog in [`Sources/FieldTapeKit/FieldTapeKit.docc`](Sources/FieldTapeKit/FieldTapeKit.docc). In Xcode, choose **Product ▸ Build Documentation**. To build it with its code examples, and check it, run:

```bash
./scripts/build-docs.sh
```

Start with these articles:

- [Getting Started](Sources/FieldTapeKit/FieldTapeKit.docc/Articles/GettingStarted.md)
- [Integrating with Your App](Sources/FieldTapeKit/FieldTapeKit.docc/Articles/IntegratingWithYourApp.md): SwiftUI, UIKit and AppKit, progress, confirmations, and platform setup
- [Keeping Music Safe](Sources/FieldTapeKit/FieldTapeKit.docc/Articles/KeepingMusicSafe.md): the safety rules
- [Testing with the Simulated OP-1](Sources/FieldTapeKit/FieldTapeKit.docc/Articles/TestingWithTheSimulatedOP1.md)
- [Handling Errors](Sources/FieldTapeKit/FieldTapeKit.docc/Articles/HandlingErrors.md)

The code examples are in [`Snippets/`](Snippets), and every build compiles them. Those that use the simulated OP-1 run, for example `swift run CopyingTapes`.

Why FieldTapeKit is shaped as it is lives in its decision records, [`docs/adrs/`](docs/adrs), and where the work stands is in [`docs/STATUS.md`](docs/STATUS.md).

## Status

FieldTapeKit is a personal project for now, and isn't open source yet. It's in beta: pre-releases make no promise about compatibility, and each one's notes list what broke.
