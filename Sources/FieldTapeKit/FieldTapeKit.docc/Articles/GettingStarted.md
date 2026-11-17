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

@Snippet(path: "WatchingForAnOP1", slice: "watch")

On iOS and iPadOS, the first iteration asks the person to allow access to connected devices. If they don't, the sequence throws ``FieldError`` with ``FieldError/Code/notAuthorized``.

The person puts the OP-1 in MTP mode on the OP-1 itself. FieldTapeKit can't do that for them. Unplugging the OP-1 takes it out of MTP mode, and a reconnect gives a new ``FieldDevice``.

### List the tapes

``FieldDevice/tapes()`` reads every tape fresh. Each ``Tape`` is a snapshot: list again to see a change.

@Snippet(path: "CopyingTapes", slice: "list")

A tape that isn't sound, with `tape.json` missing or tracks that don't match it, is listed too, with ``Tape/problems`` saying why. It can't be copied.

### Copy a tape off

``FieldDevice/copyTape(_:to:compression:progress:)`` writes one `.reelarchive` file into a folder, reads it back, and checks it against what came off the OP-1 by SHA-256. The tape stays on the OP-1.

@Snippet(path: "CopyingTapes", slice: "copy")

It never overwrites a file: if `2026-220#01.reelarchive` is taken, the archive is named `2026-220#01 2.reelarchive`. To free the tape's slot as well, use ``FieldDevice/moveTape(_:to:progress:)``, which deletes the tape only once the archive checks out.

### Put it back

Open the archive with ``ReelArchive/init(contentsOf:)``, which checks every file in it, then restore it with ``FieldDevice/restoreTape(from:as:conflict:progress:)``. By default it's restored under its archived name, as a new tape. If a tape with that name is on the OP-1, that's refused with ``FieldError/Code/alreadyExists`` and nothing changes, unless you say what to do with the tape that's there:

@Snippet(path: "CopyingTapes", slice: "restore")

### Try it without an OP-1

``FieldDevice/simulated(_:)`` makes an OP-1 in memory, which works the same way:

@Snippet(path: "SimulatedOP1", slice: "build")

## See Also

- <doc:IntegratingWithYourApp>
- <doc:TheOP1>
- <doc:KeepingMusicSafe>
- <doc:TestingWithTheSimulatedOP1>
