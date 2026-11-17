# ``FieldTapeKit``

Take tapes and album sides off a Teenage Engineering OP-1 Field over USB, and put them back, from an iOS, iPadOS or macOS app.

## Overview

FieldTapeKit reads and writes the files on an OP-1 Field in MTP mode, with no driver. It talks to the OP-1 through ImageCaptureCore's raw PTP passthrough, and gives an app three layers on one type, ``FieldDevice``:

- **Tapes:** list the OP-1's tapes, copy one off into a `.reelarchive` file, move it off to free its slot, and restore it byte for byte.
- **The album:** copy side A or B off as a WAV file, and tell whether a side was recorded over since.
- **Files:** list, read, write and delete files, shaped like `FileManager`.

People's music often lives only on the OP-1, so the API makes losing it hard to do by accident. Nothing is deleted or overwritten without a verified copy or a person's confirmation, every copy is read back and matched by SHA-256, and a failure stops at once and reports what changed. <doc:KeepingMusicSafe> has the rules.

@Snippet(path: "WatchingForAnOP1", slice: "copyEverything")

``FieldDevice/simulated(_:)`` makes an OP-1 that exists only in memory, which runs the same code, for tests and SwiftUI previews.

FieldTapeKit is tested on OP-1 firmware 1.7.3. It needs iOS, iPadOS or macOS 27, and has no dependencies.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:TheOP1>
- <doc:KeepingMusicSafe>
- ``FieldDevice``

### Connecting

- ``FieldDevice/connections``
- ``FieldDevice/ConnectionEvent``
- ``FieldDeviceInfo``
- ``FieldStorage``

### Tapes

- ``Tape``
- ``TapeName``
- ``TapeType``
- ``TapeTrack``
- ``TapeManifest``
- ``TapeSlots``
- ``TapeConflict``
- ``TapeCopy``
- ``TapeDeletion``

### Tape Archives

- ``ReelArchive``
- ``UniformTypeIdentifiers/UTType/reelArchive``

### The Album

- ``Album``
- ``AlbumSide``
- ``AlbumSideCopy``
- ``AudioFormat``
- ``SideConflict``
- ``SideReplacement``

### Files

- ``FieldItem``
- ``FieldFormat``
- ``UploadOptions``
- ``ExistingFile``
- ``FileDeletion``
- ``System/FilePath``

### Testing and Previews

- <doc:TestingWithTheSimulatedOP1>
- ``FieldDevice/simulated(_:)``
- ``SimulatedContentsBuilder``
- ``SimulatedContents``
- ``SimulatedTape``
- ``Directory``
- ``File``

### Errors

- <doc:HandlingErrors>
- ``FieldError``

### Apps and Platforms

- <doc:IntegratingWithYourApp>
- <doc:Concurrency>
- <doc:Performance>
- <doc:FirmwareAndVersions>
