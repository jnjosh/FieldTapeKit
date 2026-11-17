# Getting Started

Add FieldTapeKit to an app, find an OP-1, and copy its tapes off and back on.

## Overview

FieldTapeKit is a Swift package with one library, `FieldTapeKit`. It needs iOS, iPadOS or macOS 27, and Xcode 27.2 or later. It has no dependencies.

Everything goes through ``FieldDevice``, one connected OP-1. You get one from ``FieldDevice/connections`` when a person plugs in an OP-1 Field and puts it in MTP mode.

### Add the package

In Xcode, choose **File ▸ Add Package Dependencies**, add FieldTapeKit by its repository URL or as a local package, and add the `FieldTapeKit` library to your app's target. In a `Package.swift`, add it to `dependencies` and name the product in your target:

```swift
.target(name: "MyApp", dependencies: [
    .product(name: "FieldTapeKit", package: "FieldTapeKit"),
])
```

The package also has `FieldCheckKit` and `FieldTapeConformance`. They're for FieldCheck, the app that checks FieldTapeKit against a real OP-1, and an app doesn't need them.

### Find an OP-1

``FieldDevice/connections`` is an asynchronous sequence of connection events. Iterating it starts watching for an OP-1, and cancelling the task stops it. It starts with a ``FieldDevice/ConnectionEvent/connected(_:)`` event for every OP-1 already plugged in.

```swift
import FieldTapeKit

func watch() async {
    do {
        for try await event in FieldDevice.connections {
            switch event {
            case .connected(let device):
                print("Connected: firmware \(device.info.firmware)")
            case .disconnected(let id):
                print("Disconnected: \(id)")
            case .couldNotOpen(let error):
                print("Found an OP-1 but couldn't open it: \(error.localizedDescription)")
            }
        }
    } catch {
        print(error.localizedDescription)   // The person didn't allow access to connected devices.
    }
}
```

On iOS and iPadOS, the first iteration asks the person to allow access to connected devices. If they don't, the sequence throws ``FieldError`` with ``FieldError/Code/notAuthorized``.

The person puts the OP-1 in MTP mode on the OP-1 itself. FieldTapeKit can't do that for them. Unplugging the OP-1 takes it out of MTP mode, and a reconnect gives a new ``FieldDevice``.

### List the tapes

``FieldDevice/tapes()`` reads every tape fresh. Each ``Tape`` is a snapshot: list again to see a change.

```swift
let tapes = try await device.tapes()
for tape in tapes {
    print(tape.name, tape.type?.description ?? "unknown type", tape.duration, tape.recordedTracks)
}
let slots = try await device.tapeSlots()
print("\(slots.used) of \(slots.limit) tape slots used")
```

A tape that isn't sound, with `tape.json` missing or tracks that don't match it, is listed too, with ``Tape/problems`` saying why. It can't be copied.

### Copy a tape off

``FieldDevice/copyTape(_:to:compression:progress:)`` writes one `.reelarchive` file into a folder, reads it back, and checks it against what came off the OP-1 by SHA-256. The tape stays on the OP-1.

```swift
let folder = URL.documentsDirectory.appending(path: "Tapes")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

let archive = try await device.copyTape(tape, to: folder)
print("Saved \(archive.url.lastPathComponent)")
```

It never overwrites a file: if `2026-220#01.reelarchive` is taken, the archive is named `2026-220#01 2.reelarchive`. To free the tape's slot as well, use ``FieldDevice/moveTape(_:to:progress:)``, which deletes the tape only once the archive checks out.

### Put it back

Open the archive with ``ReelArchive/init(contentsOf:)``, which checks every file in it, then restore it:

```swift
let archive = try ReelArchive(contentsOf: url)
let restored = try await device.restoreTape(from: archive)
```

That restores it under its archived name, as a new tape. If a tape with that name is on the OP-1, it's refused with ``FieldError/Code/alreadyExists`` and nothing changes, unless you say what to do with the tape that's there:

```swift
// Archive the tape that's there first, to exactly this URL, then replace it.
let backup = folder.appending(path: "\(archive.name) before restore.reelarchive")
let replaced = try await device.restoreTape(from: archive, conflict: .replace(archivingExistingTo: backup))

// Or restore it under another name, as a new tape.
let copy = try await device.restoreTape(from: archive, as: TapeName("2026-220#05"))
```

### Try it without an OP-1

``FieldDevice/simulated(_:)`` makes an OP-1 in memory, which works the same way:

```swift
let device = FieldDevice.simulated {
    SimulatedTape("2026-220#01", type: .vintage, seconds: [12, 0, 4.5])
}
let tapes = try await device.tapes()
```

## See Also

- <doc:IntegratingWithYourApp>
- <doc:TheOP1>
- <doc:KeepingMusicSafe>
- <doc:TestingWithTheSimulatedOP1>
