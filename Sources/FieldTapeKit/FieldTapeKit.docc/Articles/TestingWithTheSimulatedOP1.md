# Testing with the Simulated OP-1

Write fast, repeatable tests and SwiftUI previews of code that uses an OP-1, with no hardware.

## Overview

``FieldDevice/simulated(_:)`` makes an OP-1 that exists only in memory. It's the same ``FieldDevice`` type, backed by a simulated OP-1 at the MTP level instead of ImageCaptureCore, so every call runs the same code as on a real OP-1: the tape layer, archives, path matching, folder rules, safety checks and the MTP encoding itself.

It ships in the main module, not a test-only one, so an app's SwiftUI previews can use it too.

### Make a simulated OP-1

With no contents, it's a firmware 1.7.3 OP-1 with no tapes: every folder, the `readme.txt` files, and both album sides empty. A ``SimulatedContentsBuilder`` adds to that layout:

@Snippet(path: "SimulatedOP1", slice: "build")

- ``SimulatedTape`` is a sound tape: four tracks of silence of the lengths given, and a `tape.json` as the OP-1 writes one, with a clip on each recorded track.
- ``File`` is a file with given bytes, or a WAV of silence in the format the OP-1 uses where it's put: 32-bit in a tape, 16-bit elsewhere.
- ``Directory`` is a folder. One that's already there, such as `mixdown`, gets the contents added, and a file of the same name is replaced.

`if`, `switch` and `for` work inside the builder. Names are stored lowercase, as the OP-1 stores them.

### Test code that uses an OP-1

Pass the simulated device to the code under test, as you'd pass a real one:

```swift
import FieldTapeKit
import Testing

@Test func copyingATapeMakesAnArchive() async throws {
    let device = FieldDevice.simulated {
        SimulatedTape("2026-220#01", seconds: [3])
    }
    let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    let tape = try #require(try await device.tape(named: TapeName("2026-220#01")))
    let archive = try await device.copyTape(tape, to: folder)

    #expect(archive.name == tape.name)
    #expect(archive.tracks[0].isBlank == false)
}
```

Each simulated device is independent, so tests can run in parallel.

### Preview a view

```swift
#Preview {
    TapeList(device: .simulated {
        SimulatedTape("2026-220#01", type: .diskMini, seconds: [30, 12])
        SimulatedTape("2026-276#01", seconds: [])
    })
}
```

### What the simulated OP-1 does as a real one does

It reproduces what's been observed on firmware 1.7.3:

- Names are stored lowercase, and paths match ignoring case.
- The 8-tape limit, and the folder rules, with the same response code a real OP-1 sends for a name a folder doesn't allow.
- `tape.json` is rebuilt after a track is written, and still lists and reads at its old size within the session.
- Files written to `synth/user/` and `drum/user/` are converted to AIFC and cut to 6 and 20 seconds.
- The capacity a real OP-1 Field reports, and free space that falls as files are written.

### How it differs from a real OP-1

This is the canonical list. Symbols whose behavior depends on these link here.

- **It never appears in ``FieldDevice/connections``,** and never disconnects. A test can't simulate a person unplugging the OP-1 or leaving MTP mode through the public API.
- **It's always firmware 1.7.3,** with ``FieldDeviceInfo/isFirmwareTested`` true, and the serial number "SIMULATED".
- **It answers at once.** A real OP-1 reads at about 20 MB/s and writes at about 7 MB/s, and every partial read costs time for everything before it in the file. Code that shows progress or times out should be checked on hardware too.
- **It doesn't stall.** On a Mac and on an iPad, a real OP-1 has stopped answering in the middle of chunked reads (<doc:Performance>).
- **Album writing is off,** as on 1.7.3, so ``FieldDevice/restoreSide(_:from:conflict:progress:)`` throws ``FieldError/Code/notAllowed``.
- **No other app shares it,** as Image Capture can on a Mac.

### Faults and reconnects

FieldTapeKit's own tests also inject faults into the simulator: a request that never answers, an unplug mid-transfer, a corrupted read, a write the OP-1 refuses, and real transfer speeds. They also simulate leaving and re-entering MTP mode. Those hooks are internal, because their shape is still changing. They're how FieldTapeKit tests its safety rules, one test group per rule.

## See Also

- ``FieldDevice/simulated(_:)``
- ``SimulatedContentsBuilder``
- <doc:KeepingMusicSafe>
