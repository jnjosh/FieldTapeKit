# ADR-0002: Public API for FieldTapeKit, the OP-1 Field framework

**Status:** Accepted
**Date:** 2026-11-08

- **Builds on:** [ADR 0001](0001-op1-field-ios-transport.md) (ImageCaptureCore and raw PTP as the transport, accepted)
- **Inputs:** the probe results in [PROBE-NOTES.md](../../research/PROBE-NOTES.md), and the research notes on Swift disk-access APIs ([swift-disk-access-guide.md](../swift-disk-access-guide.md), written in another session)

## Context

ADR 0001 showed that an iOS or iPadOS app can read, write, create and delete everything on the OP-1 Field over ImageCaptureCore. FieldTapeKit should make that feel like ordinary file access to Swift developers. It should also make the main use case a single call: taking tapes off the OP-1 and putting them back.

Who it's for, and what follows from that (decided 2026-11-08):
- **First user:** the framework is for the user's own app first, an app that makes it easy to offload tapes from the OP-1 and load them back on. Wider use can come later.
- **Platforms:** iOS, iPadOS and macOS, all at version 27 minimum. Older versions can be added if they're ever needed.
- **Safety:** "as harmless as possible." People's music lives on the OP-1, often in no other copy. The API makes losing a tape hard to do by accident (section 6).

The research notes describe how Swift file APIs are usually shaped:
- A pure path type (`FilePath`) that does no I/O, and a separate service that does the I/O.
- Async I/O, scoped handles, typed error codes, and option sets for behavior.
- Protocol-first designs with a live and a simulated implementation, so code can be tested without the real thing.
- Names that follow `FileManager`: `contentsOfDirectory(at:)`, `createDirectory(at:)`, `removeItem(at:)`, `copyItem(at:to:)`.

Some of this applies to the OP-1 directly, and some doesn't, because the OP-1 isn't a disk. The probe found these differences, and the API has to respect them:

| OP-1 behavior (from the probe) | What it means for the API |
| --- | --- |
| Every request is one PTP transaction at a time over USB. Reads run at about 20 MB/s and writes at about 7 MB/s. | Everything is async. There is no sync API, because no call is ever cheap. One actor per device serializes requests. |
| No open, close or seek. Files are read whole (GetObject) or in ranges (GetPartialObject), and written whole (SendObjectInfo then SendObject). | No file handles. Reads take an optional byte range. |
| Every read costs about what reading the file from its start to the read's end would, at about 19 MB/s, however it's split (FieldCheck `read.cost`, 2026-11-14). | Whole files are read with one GetObject. Reading one in chunks would take time that grows with the square of its size. |
| The OP-1 doesn't list MoveObject (0x1019) or CopyObject (0x101A) among its operations. Overwriting means delete, then send. | No `moveItem`. Replacing a file can't be atomic, so anything that replaces a file keeps a verified copy first. |
| Object handles change after the OP-1 leaves MTP mode, and names come back lowercased. | Paths are the public identity, and handles stay private. Paths match ignoring case. |
| A file the OP-1 rewrites mid-session (such as `tape.json`) reads back truncated to its old size. | The framework fetches fresh object info before every read. Nothing cached is trusted for size. |
| Each folder has its own rules: fixed names in `tapes/` and `mixdown/`, while `synth/user/` and `drum/user/` convert what they receive. | Writes are checked against the folder rules before sending. Conversions aren't treated as failures. |
| At most 8 tapes, and each tape at most 6 minutes, so a track is at most 127,008,044 bytes. Tape names use A–Z, 0–9, `#`, `-` and space, and are stored lowercase. | A validated `TapeName` type, and limit checks before any write. |
| A tape is four WAVs plus `tape.json`. Without `tape.json` the clip layout is lost, and the OP-1 rebuilds `tape.json` when a track changes. | Restoring a tape always writes the tracks first and `tape.json` last, as one operation. |
| One request hung for 60 seconds and never recurred. On 2026-11-16 such stalls recurred, and a read answered after 60.5 s. | A request is noted as slow after 30 s and waited for until 90 s, then the session is disconnected. There's no ping (Change Log, 2026-11-16). |
| Unplugging or leaving MTP mode removes the device. | Connection is a stream of events. Any call can fail with `disconnected`. |

## Decision

FieldTapeKit has three public layers on one device type. The file layer is shaped like `FileManager`. The tape and album layers are built only on the file layer's public API. Below both, the PTP layer stays internal.

```
Your app
  ├─ Tape layer    tapes(), copyTape(_:to:), moveTape(_:to:), restoreTape(from:), …     ← the app's main calls
  ├─ Album layer   album(), copySide(_:to:), restoreSide(_:from:), …
  ├─ File layer    contentsOfDirectory(at:), copyItem(at:to:), …                         ← FileManager-shaped
  └─ (internal)    MTP operations → transport: ImageCaptureCore | simulated
```

### 1. Finding the device

```swift
for try await event in FieldDevice.connections { // requests ImageCaptureCore authorization on first use
    switch event {
    case .connected(let device):    await show(device)
    case .disconnected(let id):     forget(id)
    case .couldNotOpen(let error):  show(error)    // such as another app holding it; watching goes on
    }
}
```

The same stream works without SwiftUI. In UIKit or AppKit, a controller keeps the task and cancels it:

```swift
final class DevicesViewController: UIViewController {
    private var watching: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        watching = Task { [weak self] in
            do {
                for try await event in FieldDevice.connections { self?.handle(event) }
            } catch {
                self?.show(error)                         // FieldError, code .notAuthorized
            }
        }
    }

    deinit { watching?.cancel() }
}
```

- **No browser type.** `FieldDevice.connections` is a static `AsyncSequence` of connect and disconnect events. Watching starts when something iterates it and stops when that task is cancelled. It throws only to end with `.notAuthorized`, when the person denies ImageCaptureCore access, so callers write `for try await`. In SwiftUI that's `.task {}`; in UIKit, AppKit, a command-line tool or a background service, it's a `Task` the caller keeps.
- **Current state first.** Each new iteration begins with a `.connected` event for every OP-1 already attached, so a listener that starts late doesn't miss one. That's what `NWPathMonitor` does with the current path.
- **Several listeners are fine.** They share one `ICDeviceBrowser` underneath, which is filtered to the OP-1 (USB vendor 0x2367, MTP product 0x0102, or the name). The browser stops when the last listener goes away.
- **Callback or Combine code** can wrap the stream in a few lines. FieldTapeKit doesn't ship those wrappers. If apps need an object to hold, a `FieldDeviceMonitor` can be added later on top of the same stream without changing it.
- `FieldDevice` exposes `info` (firmware version, whether that firmware is tested, serial number, storage) and `isConnected`. Untested firmware is described in section 11.
- **Free space** comes from GetStorageInfo (0x1005), in `info`. The OP-1 lists the operation, but whether its figure is accurate is untested. FieldCheck's `device.storage` check answers that ([ADR 0003](0003-firmware-check-tool.md)). Until a baseline confirms it:
  - No call refuses to start because of the reported free space. The 8-tape and 6-minute limits are the checks before a write.
  - If the OP-1 runs out of space mid-write, the call throws `.insufficientSpace`, with `changed` listing what was written. That code comes from PTP's Store Full response (0x200C). If the OP-1 answers with something else, the error is `.deviceRefused` with the response code, and FieldCheck records which.
  - Once a baseline shows the figure is accurate, the free-space check joins the other checks before the first change (section 6, rule 3).
- After a disconnect, every call throws `.disconnected`. A reconnect produces a **new** `FieldDevice`, because object handles don't survive.
- Entering MTP mode stays the user's job, on the OP-1. Switching it over USB MIDI is a possible later feature (`research/PROBE-NOTES.md`, "Entering MTP mode from the app").

### 2. Paths

- **Device paths** are `FilePath`, **relative to the device root**: `"tapes/2026-220#02/track_1.wav"`.
  - `FilePath` is the currency type the research recommends, and it does no I/O.
  - Use the standard library's `FilePath` (SE-0529) if the Xcode 27 toolchain has it, otherwise `System`'s. Check when the package is created.
- **Local files** are `URL`, because that is what the Files app, document pickers, `fileExporter` and `FileManager` hand an app.
- **Case:** the device matches paths **ignoring case**, because the OP-1 lowercases names. `FilePath` equality is still case-sensitive, so the framework returns the device's spelling from listings, and apps should use the paths they get back.
- **Well-known locations** are static members, so nobody types them:

```swift
extension FilePath {
    static let op1Tapes:   FilePath = "tapes"
    static let op1Mixdown: FilePath = "mixdown"
    static let op1Synth:   FilePath = "synth"
    static let op1Drum:    FilePath = "drum"
}
```

### 3. The file layer

`FieldDevice` is an `actor`. Names follow `FileManager`, and the overloads of `copyItem` read as download or upload, depending on which side is a `URL`:

```swift
public actor FieldDevice {
    // Inspecting
    func contentsOfDirectory(at path: FilePath) async throws -> [FieldItem]
    func item(at path: FilePath) async throws -> FieldItem?           // nil if missing
    func fileExists(at path: FilePath) async throws -> Bool

    // Reading into memory
    func contents(of path: FilePath, maximumSize: Int = 32 << 20) async throws -> Data
    func contents(of path: FilePath, range: Range<Int>) async throws -> Data

    // Downloading and uploading (device ↔ local file)
    @discardableResult
    func copyItem(at source: FilePath, to destination: URL,
                  progress: consuming Subprogress? = nil) async throws -> URL   // where it went
    func copyItem(at source: URL, to destination: FilePath,
                  options: UploadOptions = .init(), progress: consuming Subprogress? = nil) async throws -> FieldItem

    // Writing from memory
    func write(_ data: Data, to path: FilePath, options: UploadOptions = .init()) async throws -> FieldItem

    // Folders and deleting
    func createDirectory(at path: FilePath) async throws -> FieldItem
    @discardableResult
    func removeItem(at path: FilePath, keepingCopyAt backup: URL) async throws -> URL   // copy, verify, delete; files only
    func prepareToRemove(at path: FilePath) async throws -> FileDeletion         // for a person to confirm
    func removeItem(_ deletion: FileDeletion) async throws                       // confirmed; see section 6
}

public struct FieldItem: Sendable, Hashable, Identifiable {
    var path: FilePath            // as the device spells it
    var name: String
    var isDirectory: Bool
    var size: Int                 // fresh from the device at listing time
    var format: FieldFormat         // .wav, .aiff, .json, .text, .folder, .other(UInt16)
    var id: FilePath { path }
}

public struct FileDeletion: Sendable, Hashable, Identifiable {
    let id: UUID
    let item: FieldItem                // as read fresh by prepareToRemove
    let contents: [FieldItem]          // for a folder, everything in it at every depth
    var size: Int                      // the bytes that would be lost
    var losesNothing: Bool             // an empty folder: safe to skip the prompt
    // Internal: the device it belongs to. It works once, and only while item and contents match the OP-1 exactly.
}

public struct UploadOptions: Sendable {
    var existing: ExistingFile = .fail   // .fail, .replace(keepingCopyAt: URL) or .replace(confirmed: FileDeletion)
    var verify: Bool = true              // read back and compare; on by default
}
```

Choices, and why:

- **No file handles.** Whole reads and range reads cover what a read handle would do. Why not handles is under Alternatives Considered.
- **Whole files are read with one GetObject**, including by `copyItem(at:to:)` and `copyTape`. The OP-1 charges every read for everything before it in the file (`read.cost`), so one read is the only linear way. A 22 MB track reads in about 1.2 s, and a full 127 MB track should take about 7 s.
- **Downloads hold the file in memory,** at most one track (127 MB) at a time, as uploads do. Progress and cancellation are per file, so one read of a full track can run about 7 s before a cancel takes effect.
- **`maximumSize` on whole reads into memory**, as in NIO, because a tape track can be 127 MB. `copyItem(at:to:)` has no limit, because it writes the file to disk.
- **Range reads stay small.** `contents(of:range:)` uses GetPartialObject, and costs time up to where the range ends, so a small read near the end of a large file costs nearly a whole read. It suits headers and other reads near the start.
- **Uploads hold the file in memory.** `requestSendPTPCommand` takes the whole data phase as one `Data`, so an upload holds at most one track (127 MB) at a time. That's acceptable on current iPads, iPhones and Macs, and the framework never holds two.
- **Every write is read back by default.** That costs about 4 extra seconds on a 78 MB tape. It's on because harmless matters more than fast here.
- **Folder rules are checked before sending.** Writing `mixdown/probe.wav` fails locally with `.notAllowed` and the folder's rule, rather than with the OP-1's `0x2002` General Error. The rules come from the `readme.txt` files, encoded in the framework.
- **Preset folders convert files.** A write to `synth/user/` or `drum/user/` returns the `FieldItem` as the OP-1 stored it (AIFC, possibly shorter). A byte-for-byte read-back can't apply there, so those writes check the audio instead: its format, its length, and its samples (change log, 2026-11-14).
- **Progress uses Foundation's `ProgressManager` and `Subprogress`**, the pattern the 2026 document APIs use. They're available at the version 27 minimum. A caller that doesn't care passes nothing. Check the exact signatures when building.
- **Removing a folder deletes its contents first.** The probe only showed that order working. Whether one DeleteObject on a full folder works is untested, so the framework doesn't depend on it.

### 4. The tape layer

These are extensions on `FieldDevice`, written only against the file layer, so they can be tested on the simulator (section 8).

The names follow `FileManager`, as the file layer does: `copyTape` takes a tape off the OP-1 and leaves it there, and `moveTape` takes it off and frees its slot, as `copyItem` and `moveItem` do. `restoreTape` puts an archive back. Tapes made on the OP-1 itself are `createTape` (empty) and `duplicateTape` (from another tape).

```swift
extension FieldDevice {
    func tapes() async throws -> [Tape]
    func tape(named name: TapeName) async throws -> Tape?

    func tapeSlots() async throws -> TapeSlots       // used, available, limit (8)

    // Off the OP-1: writes <tape name>.reelarchive into a folder, and verifies it
    func copyTape(_ tape: Tape, to folder: URL, compression: ReelArchive.Compression = .none,
                  progress: consuming Subprogress? = nil) async throws -> ReelArchive

    // Off the OP-1 and free the slot: copy, verify, then delete the tape
    func moveTape(_ tape: Tape, to folder: URL,
                  progress: consuming Subprogress? = nil) async throws -> ReelArchive

    // Onto the OP-1: as a new tape, or over an existing one (copied off first)
    func restoreTape(from archive: ReelArchive, as name: TapeName? = nil,   // nil: the archived name
                     conflict: TapeConflict = .fail,
                     progress: consuming Subprogress? = nil) async throws -> Tape

    // New tapes on the OP-1; each needs a free slot
    func createTape(named name: TapeName, type: TapeType = .studio) async throws -> Tape
    func duplicateTape(_ tape: Tape, as name: TapeName,
                       progress: consuming Subprogress? = nil) async throws -> Tape

    // Delete with a verified copy, matched by SHA-256: no prompt needed
    func deleteTape(_ tape: Tape, keeping copy: TapeCopy,
                    progress: consuming Subprogress? = nil) async throws

    // Delete with no copy: describe it, a person confirms, then delete (section 6)
    func prepareToDelete(_ tape: Tape) async throws -> TapeDeletion
    func deleteTape(_ deletion: TapeDeletion) async throws
}

public struct TapeDeletion: Sendable, Identifiable {
    let id: UUID
    let tape: Tape                     // as read fresh by prepareToDelete; it needn't be sound
    let contents: [FieldItem]          // everything in its folder
    var audio: Duration                // how much audio would be lost
    var clipCount: Int
    var losesNothing: Bool             // a sound tape, every track blank and no clips: safe to skip the prompt
    // Internal: a fingerprint of the track sizes and tape.json, and the device it belongs to
}

public struct TapeSlots: Sendable {
    var used: Int                      // every folder in tapes/, sound or not
    var limit: Int                     // 8, from the firmware profile
    var available: Int { limit - used }
}

public enum TapeCopy: Sendable {
    case archive(ReelArchive)          // a .reelarchive that matches the tape
    case tape(Tape)                    // another tape on the OP-1 that matches it, such as a duplicate
}

public struct Tape: Sendable, Identifiable, Hashable {
    var name: TapeName
    var path: FilePath                 // tapes/<name>
    var type: TapeType?                // nil without a readable tape.json
    var tracks: [TapeTrack]            // four on a sound tape, blank ones included
    var manifest: TapeManifest?        // parsed tape.json; nil if it's missing or unreadable
    var problems: [String]             // why it isn't sound; empty for a sound tape
    var isSound: Bool                  // no problems
    var duration: Duration             // end of the last clip, at most 6 minutes
    var isEmpty: Bool                  // every track blank and no clips
    var recordedTracks: [Int]          // 1–4, the tracks with audio
}

public struct TapeName: Sendable, Hashable, CustomStringConvertible {
    static let maximumLength = 12      // for new names, from the firmware profile; see below
    init(_ string: String) throws      // .invalidName: lists the characters not allowed, or says it's too long
    // Stored lowercase; compares ignoring case
}

public struct TapeType: Sendable, Hashable, RawRepresentable {   // not an enum: a later firmware may add types
    static let studio   = TapeType(rawValue: 0)
    static let vintage  = TapeType(rawValue: 1)
    static let porta    = TapeType(rawValue: 2)
    static let diskMini = TapeType(rawValue: 3)
}

public struct TapeConflict: Sendable, Hashable {   // a struct, as ExistingFile is: two cases named replace
    static let fail                                    // default: .alreadyExists if the name is taken
    static func replace(archivingExistingTo: URL)      // archive the tape that's there to exactly this free URL,
                                                       // verify it, then overwrite
    static func replace(confirmed: TapeDeletion)       // overwrite with no archive, because a person confirmed losing it
}
```

**The 8-tape limit is checked in one place.** Every call that adds a tape checks `tapeSlots()` from a fresh listing of `tapes/` before it changes anything, and throws `.tapeLimitReached` if none is free. That's `createTape`, `duplicateTape`, and `restoreTape` when the name is new. Replacing an existing tape doesn't need a slot. The file layer's `createDirectory(at:)` runs the same check for a new folder in `tapes/`, so the limit can't be bypassed from below. The error's recovery suggestion says to move a tape off the OP-1 first.

**Tape names are at most 12 characters, when FieldTapeKit makes them.**
- The allowed characters are A–Z, 0–9, `#`, `-` and space, stored lowercase.
- 12 is the most the OP-1 keeps on 1.7.3. It accepts a longer name over MTP, then cuts it to 12 once it leaves MTP mode (2026-11-15), so FieldTapeKit refuses a longer name instead of making a tape that comes back under another name. The limit comes from the firmware profile, so another firmware can have its own.
- The limit applies only to names for a new tape: `createTape`, `duplicateTape`, and `restoreTape(from:as:)` when no tape has the name. A name that's already on the OP-1, or in an archive, is accepted at any length, so a tape can still be listed and copied off. Restoring one as a new tape is refused, with a reason saying to pass a shorter name with `as:` (change log, 2026-11-15).
- FieldCheck creates its scratch tape with a 12-character name, and a second tape with 13, to confirm the OP-1 keeps 12 and cuts 13 (ADR 0003, `names.maximum`).

**Filtering is left to the app.** `tapes()` returns an array, and Swift's own collection methods already do the job:

```swift
let miniDisks = try await device.tapes().filter { $0.type == .diskMini }
let byType    = Dictionary(grouping: try await device.tapes(), by: \.type)
let recorded  = try await device.tapes().filter { !$0.isEmpty }
```

A filter parameter on `tapes()` wouldn't save any work: there are at most 8 tapes, and listing them reads each small `tape.json` whatever the filter is. What the framework does owe apps is properties worth filtering on, so `Tape` has `type`, `duration`, `isEmpty` and `recordedTracks`, and `TapeType` is `Hashable` for grouping. If apps keep writing the same filter, it can become a convenience later without changing `tapes()`.

**`TapeManifest` is `tape.json` with nothing dropped.**
- It has typed properties for the fields the probe decoded: clips (`track`, `start` and `end` frames, `id`), loop, tempo in BPM, the mixer's eight numbers as stored (`mixerParameters`, probably four levels and four pans, unconfirmed), and tape type.
- It keeps the original JSON and writes back every key it doesn't understand. `padding` and unknown keys round-trip untouched, because the probe showed the OP-1 accepts copied values and their meaning is unknown.
- Editing a manifest is out of scope for now. It's read for display and written back as it was archived.

**`ReelArchive` is a `.reelarchive` file: one file per tape, named after it**, for example `2026-276#01.reelarchive`. Inside, it's an Apple Archive (`.aar` format):

```
2026-276#01.reelarchive   (Apple Archive, no compression by default)
  track_1.wav … track_4.wav     exactly as stored on the OP-1
  tape.json                     exactly as stored on the OP-1
  reel.json                     FieldTapeKit metadata: format version, tape name and type, OP-1 serial
                                and firmware, date, and the size and SHA-256 of every file
```

- **Apple Archive, with no dependency and no archive code of our own.** `import AppleArchive` is public on iOS, iPadOS and macOS, well below the version 27 minimum.
- **No compression by default.** Uncompressed PCM barely shrinks, and skipping compression keeps archiving at the speed of the USB read. An option allows Apple Archive's compressors (LZ4, LZFSE, zlib, LZMA) for an app that wants smaller files.
- **Writing entries:** FieldTapeKit reads each track with one GetObject and writes it straight into the archive, with the SHA-256 computed as it's written. Only one track is held in memory at a time, and nothing is staged in a temporary folder.
- **It's one ordinary file,** so it survives AirDrop, email, iCloud, Dropbox and USB drives unchanged.
- **Getting the WAVs out needs a tool that reads Apple Archive.** On a Mac that's Archive Utility or the `aa` command. iOS has no built-in way that we know of. FieldTapeKit itself can read them (`ReelArchive` exposes each track), so an app can offer "save the tracks".
- **For apps that share archives:** the person receiving one may not have an app that reads `.aar`. An app that offers sharing should decide how people get at the audio. It could export the WAVs alongside, or add its own dependency to export another format, such as zip. FieldTapeKit stays dependency-free and documents this.
- **The file type:** FieldTapeKit defines `UTType.reelArchive`, `com.jnjosh.fieldtapekit.reelarchive`, conforming to `public.data` and `public.archive`. Every app shares this one identifier, and declares it in its Info.plist as an imported type, because a framework can't declare it itself, so the app can open `.reelarchive` files from Files and from other apps (change log, 2026-11-15).
- **Opening one checks it:** `ReelArchive(contentsOf: URL)` reads the archive and checks every file against `reel.json`. It also runs the consistency check the probe uses: every clip names a real track, and each track is `44 + 8 × last clip end` bytes.

**`copyTape` and `moveTape`:**
1. Read `tape.json` fresh, and check it against the track sizes.
2. Read each track and `tape.json` with one GetObject, and write it into a temporary archive next to the destination.
3. Reopen the archive from disk with Apple Archive's decoder and check every SHA-256 against what came off the OP-1.
4. Move it into place. An archive is never overwritten: if the name is taken, a number is added, as Finder does.
5. `moveTape` only: check the tape on the OP-1 still matches the archive by name, sizes and `tape.json`, then delete its files and its folder.

**`createTape`** makes a complete empty tape, not just a folder:
1. Check the name is valid and not taken, ignoring case, and that a slot is free.
2. Create `tapes/<name>`, lowercase.
3. Write four blank tracks (the 44-byte header) and a blank `tape.json` with the chosen type. The template is the blank Disk Mini tape the probe read (2026-312#01).
4. Read everything back.

It writes the files because the OP-1 has only been seen with a folder that was filled before it left MTP mode. What it does with an empty tape folder is untested.

**`duplicateTape`** copies a tape on the OP-1 to a new name. The OP-1 has no CopyObject, so this reads each track through memory and writes it to the new tape, one track at a time:
1. Check the new name and that a slot is free.
2. Read the source `tape.json` fresh and check it against the track sizes.
3. Create the new tape, then write and read back each track, and `tape.json` last.

The copy keeps the source's `padding` values. Two tapes sharing them was fine in the probe, but its long-term effect is untested. The source is never written to.

**`restoreTape`** follows the order the probe proved, and stops at the first failure:
1. Open and check the archive, the name, and the 6-minute limit.
2. If the tape doesn't exist, check there's a free slot of the 8 (`.tapeLimitReached`). If it does, apply `conflict`. With `.replace(archivingExistingTo:)`, archive and verify the existing tape before changing anything. With `.replace(confirmed:)`, check the confirmation still matches the tape.
3. Create `tapes/<name>` if needed, lowercase.
4. Write each track, read it back and compare it: delete, then send. Skip a track that's blank on both sides.
5. Write `tape.json` **last**, because the OP-1 rebuilds it when a track changes, and read it back.
6. List the tape again and check every size.

If a step fails after the OP-1 has been changed, the error says which files were written, and any archive made in step 2 is left in place. Over an existing tape, the framework does **not** try an automatic rollback: a second round of writes to a device that just failed is more likely to make things worse. The app can offer to restore again from the same archive.

**A half-made new tape is removed.** If `createTape`, `duplicateTape`, or `restoreTape` under a new name fails partway, the new tape holds nothing that isn't somewhere else, and it would use up a slot. FieldTapeKit deletes what it created in that call, once. If that delete fails too, the tape is listed in the error's `changed`.

### 5. The album layer

The OP-1 Field's album is `mixdown/side_a.wav` and `mixdown/side_b.wav`. Unlike tapes, it's always exactly those two files: `mixdown/readme.txt` allows only those names, and the OP-1 replaces a side whenever the person records to it. So the album layer has no names, no slots and no creating or deleting, just two sides that change over time.

```swift
extension FieldDevice {
    func album() async throws -> Album

    // Off the OP-1: writes a WAV into a folder, and verifies it
    func copySide(_ side: Album.Side, to folder: URL,
                  progress: consuming Subprogress? = nil) async throws -> AlbumSideCopy
    func copyAlbum(to folder: URL,
                   progress: consuming Subprogress? = nil) async throws -> [AlbumSideCopy]   // the recorded sides

    // Has the person recorded over this side since it was copied?
    func side(_ side: Album.Side, matches copy: AlbumSideCopy) async throws -> Bool

    // Onto the OP-1: a WAV becomes side A or B
    func restoreSide(_ side: Album.Side, from file: URL,
                     conflict: SideConflict = .fail,
                     progress: consuming Subprogress? = nil) async throws -> AlbumSide
    func prepareToReplace(_ side: Album.Side) async throws -> SideReplacement   // for a person to confirm
}

public struct Album: Sendable, Hashable {
    enum Side: String, Sendable, Hashable, CaseIterable, Codable { case a, b }   // "Side A", "Side B"
    var a: AlbumSide
    var b: AlbumSide
    subscript(side: Side) -> AlbumSide
    var sides: [AlbumSide]             // A first
}

public struct AlbumSide: Sendable, Hashable {
    var side: Album.Side
    var path: FilePath                 // mixdown/side_a.wav or side_b.wav
    var isEmpty: Bool                  // the 44-byte header only
    var duration: Duration
    var size: Int
    var format: AudioFormat?           // sample rate, bit depth, channels, from the WAV header; nil if it can't be read
    var problems: [String]             // why it isn't sound, as Tape has
    var isSound: Bool
}

public struct AlbumSideCopy: Sendable, Hashable, Codable {   // an app can store it
    var side: Album.Side
    var url: URL
    var size: Int
    var sha256: String
    var copiedAt: Date
}

public struct SideConflict: Sendable, Hashable {   // a struct, as TapeConflict is
    static let fail                                                  // default: .alreadyExists if the side has audio
    static func replace(copyingExistingTo copy: URL) -> SideConflict // copy and verify the side first, to exactly that URL
    static func replace(confirmed: SideReplacement) -> SideConflict
}

public struct SideReplacement: Sendable, Hashable, Identifiable {
    let id: UUID
    let side: AlbumSide                // as read fresh by prepareToReplace
    var audio: Duration                // how much audio would be lost
    var losesNothing: Bool             // the side is empty: safe to skip the prompt
    // Internal: the device it belongs to. The side as listed is its fingerprint.
}
```

- **Copies are plain WAV files,** not archives. A side is one file with no metadata of its own, so a WAV is the most natural thing to hand an app or a person. Copies are named for the side and the date, such as `Side A 2026-11-08.wav`. As with archives, a copy never overwrites a local file: if the name is taken, a number is added.
- **Sides change, so copies remember what they copied.** `AlbumSideCopy` records the size and SHA-256 of what came off the OP-1. `side(_:matches:)` compares the size first, and reads the side again only when the sizes are equal. That lets an app show "recorded since your last copy" or skip a copy it already has.
- **An empty side is skipped.** `copyAlbum` copies only sides with audio. `copySide` on an empty side throws `.notFound`, because there's nothing to copy.
- **Restoring follows the same safety rules as tapes** (section 6). Writing over a side that has audio needs either a verified copy of it or a person's confirmation, through `prepareToReplace`. An empty side can be written to freely. **Album writing is off on 1.7.3** (2026-11-16, Change Log): `restoreSide` and writes to the sides refuse with `notAllowed`. A side written over MTP hung the OP-1 when it was written again after a reconnect, until it was restarted (`album.write-again`). Reading and copying the album work. Writing it again is a future improvement. Before sending, FieldTapeKit checks the file is a 44.1 kHz WAV, as the readme requires.
- **What the probe showed:** reading and writing a side back byte for byte worked on 1.7.3, within one session. A side deleted over MTP came back after a reconnect, but a side written over MTP lasts (FieldCheck levels 2 and 3, 2026-11-16, `album.write-kept`). Putting a side back right after hung once, which is being traced. Writing a side in a different format from the one the OP-1 records, and what the OP-1 does with a side written while it's playing the album, are untested. FieldCheck should cover both (ADR 0003).
- **No erasing.** Whether deleting a side file is safe, or whether the OP-1 recreates it, is untested, so there's no call for it. Restoring from a short silent WAV does the same job.

### 6. Safety rules

These hold across both layers. The tests check each one against the simulator.

1. **Nothing on the OP-1 is deleted or overwritten unless a verified copy exists, or a person confirmed losing it.** Every destructive call takes one of two forms:
   - **With a copy:** `deleteTape(_:keeping:)` needs a copy that matches the tape: an archive, or a matching tape on the OP-1 such as a duplicate. `moveTape` makes the archive first. Restore's `.replace(archivingExistingTo:)` and the file layer's `keepingCopyAt:` make and verify one before changing anything.
   - **Confirmed by a person:** `prepareToDelete(_:)` (or `prepareToRemove(at:)` in the file layer) reads the item fresh and returns a `TapeDeletion` (or `FileDeletion`) describing what would be lost. The app shows that to the person however it likes: SwiftUI's `confirmationDialog(item:)`, a UIKit alert, or a prompt in a command-line tool. If they agree, the app passes it to `deleteTape(_:)`, `removeItem(_:)`, or a `.replace(confirmed:)` option.
   - **A confirmation can't go stale or be reused.** It records a fingerprint of what it described: the track sizes and `tape.json` for a tape, the size for a file or an album side. If anything changed before it's used, the call refuses with `.changedSinceConfirmation`. It works once, and only on the `FieldDevice` that made it, so it doesn't survive a reconnect.
   - **Skipping the prompt is possible, by choice.** Nothing stops an app from calling `prepareToDelete` and deleting straight away. That's deliberate: it's visible in the code and can't happen by accident. `losesNothing` tells an app when skipping is harmless, as for a new empty tape from `createTape`.
   - Album sides follow the same two forms: `.replace(copyingExistingTo:)` or `.replace(confirmed:)` with a `SideReplacement` (section 5).
   - The only file layer write with nothing at risk is a new file at a free path, so it needs neither.
2. **A copy counts as verified only after it has been read back from where it was stored and matched by SHA-256.** Writes to the OP-1 are read back too, unless the caller opts out. Before a copy covers a delete, what it copied is read from the OP-1 a second time and matched to it, so a read that went wrong can't leave a bad copy that passes.
3. **Everything is checked before the first change:** names, folder rules, the 8-tape and 6-minute limits, archive consistency, and, once a FieldCheck baseline shows it's accurate, free space (section 1). A refusal changes nothing.
4. **FieldTapeKit never touches files it didn't name.** It deletes only the paths it was asked to and that it listed. It never writes `readme.txt` or anything outside `tapes/`, `mixdown/`, `synth/user/` and `drum/user/`.
5. **It never overwrites a local file.** Archives get a new name rather than replacing one.
6. **It stops at the first failure and reports exactly what changed.** There's no automatic retry of writes and no rollback of an existing tape, and a timeout is followed only by a read-only ping. The only cleanup is deleting a half-made new tape, which holds nothing that isn't elsewhere.
7. **It sends only the standard MTP operations it uses:**
   - Reads: GetDeviceInfo, GetStorageIDs, GetStorageInfo, GetObjectHandles, GetObjectInfo, GetObject, GetPartialObject.
   - Writes: SendObjectInfo, SendObject, DeleteObject.
   - Nothing vendor-specific, and no MIDI.

### 7. Errors

One error type with a code, NIO style:

```swift
public struct FieldError: Error, Sendable, LocalizedError {
    var code: Code
    var path: FilePath?
    var responseCode: UInt16?          // the PTP response, when the device refused
    var changed: [FilePath]            // what was already written or deleted, if anything
    var underlying: (any Error)?       // Error refines Sendable in Swift 6, so FieldError is Sendable

    public struct Code: Sendable, Hashable {
        static let disconnected, timedOut, notFound, alreadyExists,
                   notADirectory, isADirectory, ambiguousPath, notAllowed, invalidName, tooLarge,
                   tapeLimitReached, tapeTooLong, insufficientSpace,
                   invalidArchive, archiveMismatch,
                   changedSinceConfirmation, confirmationAlreadyUsed,
                   verificationFailed, localFileFailed, deviceRefused, deviceInUse, notAuthorized
    }
}
```

- **`insufficientSpace`:** the OP-1 answered a write with Store Full (0x200C), or, once free space is trusted, a check before the first change found too little (section 1).
- **`deviceInUse`:** another app holds the OP-1, so ImageCaptureCore won't open it for this one. Not thrown on 1.7.3, since ImageCaptureCore never says so (section 9, and the change log for 2026-11-17). It's kept for a platform that does.

- **Untyped `throws`, documented per method.** Swift 6 typed throws (`throws(FieldError)`) can't also throw `CancellationError`, and every long transfer here has to cancel the normal Swift way when a view disappears. So methods throw `FieldError` or `CancellationError`, and each method's doc comment lists the codes it can throw, as NIO does.
- **`LocalizedError`** gives every error a readable description and recovery suggestion, so SwiftUI's `.alert(error:)` works as is. For example, `notAllowed` explains the folder rule, and `tapeLimitReached` says to move a tape off the OP-1 first.
- **`changed`** is empty whenever the OP-1 wasn't touched, so an app can tell "nothing happened" from "half-restored" at a glance.
- **Timeouts:** a `timedOut` request is followed by a ping (GetDeviceInfo). If the device answers, the call can be retried. If not, the device is treated as disconnected.

### 8. Testing without an OP-1

The research recommends a protocol with live and simulated implementations. Here the swap goes one level lower, **inside** `FieldDevice`:

```swift
let device = FieldDevice.simulated {
    Tape("2026-220#02", type: .vintage, tracks: [.audio(seconds: 12), .blank, .blank, .blank])
    Directory("mixdown") { File("side_a.wav", seconds: 69) }
}
```

- **One concrete type.** `FieldDevice.simulated` is the same type, backed by a simulated MTP device instead of ImageCaptureCore. App code never deals with `any FieldFileSystem`, and the tape layer, archives, path matching, folder rules and PTP encoding all run for real in tests.
- **The OP-1's quirks:** the simulator reproduces what the probe found. That's lowercased names, `tape.json` rebuilt after a track write, stale sizes within a session, preset conversion, the 8-tape limit, `0x2002` for names a folder doesn't allow, and new handles after a reconnect.
- **Fault injection:** a timeout on the nth request, a disconnect mid-transfer, a corrupted read, and slow transfers at the real 20 and 7 MB/s. These test the safety rules.
- **Previews:** it ships in the main module rather than a test-only one, because SwiftUI previews in an app target need it. A preview can show a populated OP-1 with no hardware.
- **Conformance suite:** the same tests run against the simulator and against a real OP-1 from the probe app. That keeps the simulator honest, which the research calls its most important feature.

### 9. Platforms, concurrency and packaging

- **Platforms:** iOS 27, iPadOS 27 and macOS 27. The API is the same on all three. Raw PTP to the OP-1 on macOS is **not yet tested**, so the first framework milestone includes a Mac run of the conformance suite. Things to watch on the Mac:
  - **Other apps (seen 2026-11-17):**
    - **Image Capture shares the OP-1** with FieldTapeKit. Both open it at once, so another app's requests can come between ours, and FieldTapeKit can't tell.
    - **FieldKit, Teenage Engineering's Mac app, takes the OP-1 for itself** through libusb, so ImageCaptureCore never finds it. FieldTapeKit just sees no OP-1, with no error, and can't report `.deviceInUse`.
    - Apps should say to quit FieldKit when no OP-1 appears on a Mac.
  - A sandboxed Mac app may need a USB or camera entitlement for ImageCaptureCore. Find out which on the first run.
- **Concurrency:** `FieldDevice` is an `actor`, because PTP allows one transaction at a time. Every value type is `Sendable`, and nothing depends on the app's default `MainActor` isolation.
- **Cancellation** is checked between files and between tracks. A read or write already sent can't be cancelled, so it finishes first: up to about 7 s for a full track read, and about 18 s for a write. A cancelled restore deletes the partial file it was sending, reports what it had finished in `changed`, and leaves any archive in place.
- **Packaging:**
  - One Swift package, `FieldTapeKit`, with one library product, plus a test target with the conformance suite.
  - No SwiftUI or UIKit module for now: `AsyncSequence`, `Subprogress` and `LocalizedError` already work with both. An `@Observable` connection model can come later if the app needs it.
- **Foundation is required,** unlike the Foundation-free core the research suggests: ImageCaptureCore is Apple-only and works in `Data` and `URL`.
- **The PTP layer stays internal:** containers, operations and dataset parsing, carried over from the probe. Making a raw MTP escape hatch public would freeze it early.

### 10. Not in this API yet

These are possible later features, deliberately left out for now:
- Editing `tape.json` (moving clips, retitling).
- Copy and restore for presets, like the tape and album layers.
- Erasing an album side.
- Renaming a tape (probably MTP object properties, untested).
- Entering MTP mode over USB MIDI.

### 11. Versioning and firmware support

**FieldTapeKit follows [Semantic Versioning 2.0.0](https://semver.org) strictly.**
- **Pre-releases come first.** Releases start at `1.0.0-alpha.1`. They move to `1.0.0-beta.1` once the API is ready to try for real, and reach `1.0.0` at the full release. Semver sorts them in that order: `1.0.0-alpha.1` < `1.0.0-alpha.2` < `1.0.0-beta.1` < `1.0.0`.
- **Pre-releases carry no compatibility promise,** as semver allows. The release notes list every break between them. An app that depends on an alpha or beta names that pre-release in its package requirement, for example `exact: "1.0.0-alpha.1"`.
- **From 1.0.0, any of these needs a new major version:**
  - **The Swift API:** anything that breaks source compatibility. That includes removing or renaming anything public, changing a signature, and adding a case to a public enum: the connection events, `TapeConflict`, `SideConflict` and `Album.Side`. A new case breaks an app's exhaustive `switch`. New `FieldError.Code` or `TapeType` values only need a minor version, because those types are structs.
  - **The archive format:** every version reads every earlier `.reelarchive` format. Writing a format that earlier 1.x versions can't open is major. The format version in `reel.json` says which format an archive uses.
  - **Supported firmware:** adding support for a firmware is minor. Dropping one is major.
  - **Safety behavior:** loosening a rule in section 6, or a default that protects music, such as read-back, is major even when no API changes. Tightening one is minor, and the release notes say what is newly refused.
- **A minor version** adds API, firmware support, or the ability to read a new archive format. **A patch** fixes bugs without changing any of the above.
- **Checked before every release:**
  - `swift package diagnose-api-breaking-changes` against the previous release's tag. That needs the repository in git.
  - The archive fixtures still open. The tests keep one archive of every format version.
  - The safety-rule tests pass on the simulator for every supported firmware.

**Firmware support is additive.** Supporting a new firmware never drops an old one, except in a major version with an ADR of its own.
- **Telling firmwares apart:** `FieldDevice.info` has `firmware`, from GetDeviceInfo, and `isFirmwareTested`. It's `true` when this release ships a FieldCheck baseline for that exact version ([ADR 0003](0003-firmware-check-tool.md)).
- **A profile for each tested firmware,** built from its baseline, holds the behaviors that differ between firmwares, such as tape types or folder rules. Where firmwares differ, the code branches on the profile. Most code doesn't branch at all.
- **The simulator can act as any tested firmware** (`FieldDevice.simulated(firmware:)`), and the conformance suite runs against each one. That keeps an old firmware tested after the owner's OP-1 has moved on from it.
- **Untested firmware works, with a warning.** On a firmware with no baseline, such as 1.8 the day it ships, everything works using the profile of the newest tested firmware older than it, or the oldest profile if it's older than all of them. `isFirmwareTested` is `false`, so the app can warn the person.
  - The safety rules still hold. Read-back catches a write that didn't land as written, and nothing is deleted without a verified copy or a confirmation.
  - What they can't catch is a change the read-back doesn't see, such as the OP-1 treating a restored `tape.json` differently after a reconnect.
- **Archives can cross firmwares.** `ReelArchive` exposes the firmware it was made on, which is already in `reel.json`. Restoring onto a different firmware isn't refused, so an app can warn. Whether a particular firmware change makes that unsafe is one of the questions FieldCheck's draft ADR asks (ADR 0003, section 5).

**What breaks for someone who doesn't update their OP-1** after FieldTapeKit supports a newer firmware? Nothing, as long as the change can be supported on both firmwares: theirs keeps its profile and its tests. Only a change FieldTapeKit can't support on both would drop the old firmware, and that's a major version with its own ADR.

## Alternatives Considered

**Shape of the API**
- **A protocol with live and simulated implementations** (`any FieldFileSystem`), as the research recommends. Rejected: app code would carry an existential, and the tape layer, archives, folder rules and PTP encoding wouldn't run in tests. The swap happens inside `FieldDevice` instead, below the PTP encoding (section 8).
- **A browser object,** like `ICDeviceBrowser`. Rejected for a static `AsyncSequence`, which works the same in SwiftUI, UIKit, AppKit and command-line tools, and starts and stops with the task that iterates it. A `FieldDeviceMonitor` can still be added on top later (section 1).
- **File handles** (scoped `withFileHandle` closures, as the research recommends). Rejected: MTP has nothing to open, close or seek, so handles would invent state the device doesn't have.
- **A filter parameter on `tapes()`.** Rejected: with at most 8 tapes it saves no work, and Swift's collection methods already filter (section 4).
- **A public raw MTP layer.** Rejected for now: it would freeze the PTP layer before it has settled.
- **A SwiftUI or UIKit module.** Not now: `AsyncSequence`, `Subprogress` and `LocalizedError` already work with both.
- **A Foundation-free core,** as the research suggests. Rejected: ImageCaptureCore is Apple-only and works in `Data` and `URL`.
- **Tape name length: the OP-1's own limit, or no limit.** The editor's limit couldn't be read, because it doesn't scroll. No limit would let FieldTapeKit make names the OP-1's screen can't show. Rejected for FieldTapeKit's own limit of 15 (section 4).
- **Typed throws** (`throws(FieldError)`). Rejected: a method with typed throws can't also throw `CancellationError`, and every long transfer has to cancel the normal Swift way (section 7).

**What the OP-1 can't do**
- **`moveItem` and an atomic replace.** Not possible: the OP-1 doesn't list MoveObject or CopyObject. Replacing is delete, then send, guarded by a verified copy.
- **Deleting a folder with one DeleteObject.** It works on 1.7.3 (`delete.folder-with-files`, ADR 0003, 2026-11-15), but isn't relied on. Deleting the files first works on any firmware, and a failure part way says exactly which files went (change log, step 18).

**Backups**
- **Zip or tar archives.** Rejected: zip has no public API on iOS, and tar's (libarchive) is macOS-only, so either would mean owning a format or adding a dependency.
- **A folder of WAVs and `tape.json`,** with no archive. Rejected: a folder doesn't travel through AirDrop, email or cloud storage as one item, and one file of it can be lost or changed without anyone noticing.
- **Compression on by default.** Rejected: PCM barely shrinks, and compressing would slow archiving below the speed of the USB read. It stays an option.
- **Staging tracks in a temporary folder** before writing the archive. Rejected for writing each track straight into the archive, with the SHA-256 computed on the way.

**Reading**
- **Streaming large files in 1 MiB GetPartialObject chunks,** with a `bytes(of:chunkSize:)` sequence. Rejected by the owner (2026-11-13 and 14): each chunk costs time up to where it ends, so 16 MiB took 8.5 s in chunks against 0.9 s in one read, and a full 127 MB track would take about 7 minutes.
- **Larger chunks, such as 16 MiB.** Rejected by the owner: they would hold less in memory and report progress more often, but a full track would take about 35 s against about 7 s, and the gap grows with the file's size.

**Safety**
- **Read-back off by default,** for speed. Rejected: it costs about 4 seconds on a 78 MB tape, and harmless matters more than fast here.
- **Automatic rollback** of a failed restore over an existing tape. Rejected: a second round of writes to a device that just failed is more likely to make things worse. The archive taken first stays in place, and the app can restore from it again (section 4).
- **Refusing writes on the reported free space** before it's verified. Rejected for now: an inaccurate figure would refuse writes that fit, or allow ones that don't. The OP-1's own Store Full answer is the check until a baseline confirms the figure (section 1).

**Versioning and firmware**
- **0.y.z versions while the framework is built.** Rejected for `1.0.0` pre-releases, which make it plain that 1.0.0 is the goal and sort correctly before it.
- **Untested firmware read-only.** Rejected by the owner: copying tapes off would still work, but the app couldn't restore anything until a release supported the firmware. The safety rules guard writes instead.
- **Refusing untested firmware.** Rejected: people couldn't even copy their tapes off.
- **Supporting only the latest firmware.** Rejected: people who don't update their OP-1 would lose support with each release.

## Consequences

**Positive**
- Anyone who knows `FileManager` can use the file layer without reading the docs. Copying, moving, restoring, creating and duplicating a tape are each one call, and so are copying and restoring an album side.
- A tape can't be deleted or overwritten through FieldTapeKit without a verified archive of it, or a person's confirmation of exactly that tape as it was.
- Archives are single files, written with a first-party Apple framework, that the user can keep or share.
- The OP-1's quirks (lowercasing, stale sizes, rebuilt `tape.json`, folder rules, write order) are handled once, in the framework, not rediscovered by every app.
- Apps and the framework itself can be tested and previewed without an OP-1, against a simulator that the conformance suite checks against real hardware.

**Negative / risks**
- Replacing can't be atomic. The archive taken first means nothing is lost, but a failure mid-restore still leaves the tape half-written on the OP-1 until it's restored again.
- Safety costs time. Reading back every write adds about 4 seconds on a 78 MB tape, and archiving before a replace adds a full read.
- An upload holds a whole track in memory, up to 127 MB.
- An archive can't be opened on iOS without an app that reads Apple Archive. Apps that share archives have to plan for the person receiving one (section 4).
- macOS is committed to but untested.
- The simulator is only as faithful as what the probe observed. Firmware updates may change OP-1 behavior. [ADR 0003](0003-firmware-check-tool.md) proposes FieldCheck, a repeatable check against a saved baseline, for that.
- `TapeManifest` passes `padding` through without knowing what it means. If it refers to data stored elsewhere on the OP-1, restoring onto a different OP-1, or after other changes, could behave differently. Copies on the same device were fine. Deleting one of two tapes that share `padding` values is untested, and FieldCheck deliberately doesn't try it (ADR 0003).
- Untested firmware is allowed to write. The safety rules catch writes that didn't land, but not every change in how the OP-1 treats what was written.
- Once the owner's OP-1 updates, an old firmware is checked only against its baseline and the simulator, not on hardware. Whether an OP-1 can go back to an older firmware is unknown.
- Each firmware profile that differs from the others adds a code path to keep tested.

## Change Log

- **2026-11-08:** Decided by the owner:
  - **Name:** FieldTapeKit.
  - **Minimum OS:** 27 on every platform.
  - **macOS:** supported.
  - **Backup format:** `.reelarchive`, an Apple Archive with no compression by default. No zip or tar code of our own. Apps that share archives decide how people extract them.
  - **Read-back:** on by default.
- **2026-11-08:** Restructured to the ADR template: the alternatives the Decision rejected are collected under Alternatives Considered, and the later features are in section 10.
- **2026-11-08:** Free space settled. FieldCheck's `device.storage` check tests whether GetStorageInfo's figure is accurate. Until a baseline confirms it, nothing refuses a write on it, and Store Full (0x200C) is reported as `.insufficientSpace`.
- **2026-11-08:** Tape name length settled. The OP-1's name editor doesn't scroll, so its limit couldn't be read, and names past about 13 or 14 characters can't be read on the OP-1's screen. FieldTapeKit limits new names to 15 characters, by its own choice, and accepts names already on the OP-1 or in an archive at any length.
- **2026-11-08:** API gaps fixed. `FieldError.underlying` is `(any Error & Sendable)?`, so the error can be `Sendable`. The codes `insufficientSpace` and `deviceInUse` are added, and `SideReplacement` is defined, mirroring `TapeDeletion`.
- **2026-11-08:** Accepted by the owner.
- **2026-11-08:** Section 11 added, decided by the owner:
  - Strict semantic versioning, starting at `1.0.0-alpha.1`.
  - A major version protects the Swift API, the archive format, supported firmware and safety behavior.
  - Firmware support is additive, with a profile for each tested firmware.
  - Untested firmware works, with a warning.
- **2026-11-08:** Correction to the API gap fix above: `Error` already refines `Sendable` in Swift 6 (SE-0302), so `(any Error)?` was fine as written. The sketch is back to `(any Error)?`, which is the same type.
- **2026-11-09:** `FieldDevice.connections` throws, so the examples use `for try await`. Without that, `.notAuthorized` would have no way to reach the caller when the person denies access. Found while building step 3, and approved by the owner.
- **2026-11-13:** Decided by the owner while building step 6 of the plan, keeping the file layer as designed:
  - **Ambiguous paths:** a lookup uses an exact match first, then a single match ignoring case. If several items match ignoring case and none exactly, it throws the new code `ambiguousPath`, so nothing acts on an item the caller didn't mean. That can happen because the OP-1 keeps a new folder's name as typed until it leaves MTP mode.
  - **`FieldFormat`** comes from the MTP format code the OP-1 reports, not the file's name, because `drum/user/` keeps a converted file's `.wav` name. `tape.json` is reported as Text and `readme.txt` as Undefined, so those two are told apart by name.
  - **`FieldDevice.simulated()`** starts as a 1.7.3 OP-1 with no tapes, with every folder, the `readme.txt` files and both album sides empty, and the builder adds to that.
- **2026-11-14:** Decided by the owner, from FieldCheck's `read.cost` (ADR 0003): **whole files are read with one GetObject.** The OP-1 charges each GetPartialObject for everything before it in the file, at about 19 MB/s, so chunked streaming takes time that grows with the square of a file's size (PROBE-NOTES.md, 2026-11-13 and 14).
  - `bytes(of:chunkSize:)` is dropped from the API. It can come back if a firmware reads ranges cheaply.
  - `copyItem(at:to:)` and `copyTape` read each file with one GetObject. Downloads hold at most one track in memory, as uploads already did, and progress and cancellation are per file.
  - `contents(of:range:)` stays, for small reads near the start of a file.
  - A full 127 MB GetObject hasn't been tried. Level 2's long check (`tape.track-limit`) is its first test.
- **2026-11-14:** Decided by the owner while building step 7 of the plan:
  - **`copyItem(at: FilePath, to: URL)` returns the URL it wrote.** It never overwrites a local file and adds a number when the name is taken, as Finder does (`side_a 2.wav`), so the caller needs to know where the copy went.
  - **Three new codes:** `tooLarge` for a file over `maximumSize`, `isADirectory` for reading or copying a folder, and `localFileFailed` for a local file that can't be written or read back, with the system's error as `underlying`. FieldTapeKit still throws only `FieldError` and `CancellationError`.
  - **`contents(of:range:)` past the end** gives the bytes up to the end, and empty data from the end onwards, as reading a file normally does.
- **2026-11-14:** Decided by the owner while building step 8 of the plan:
  - **`removeItem(at:keepingCopyAt:)` returns the copy's URL,** as `copyItem` does, and works on files only. A folder throws `isADirectory` and needs `prepareToRemove` and a person's confirmation. Tapes get archives in the tape layer.
  - **The file layer refuses what belongs to the OP-1,** with `notAllowed`, before anything happens: the root, the folders every OP-1 has (from the firmware profile), and the files it puts in them itself, `readme.txt` and `you may create folders here`, on their own. A tape folder can still be deleted, and its `readme.txt` goes with it.
  - **`FileDeletion`** is defined, mirroring `TapeDeletion`. A confirmation from another connection is `changedSinceConfirmation`. It's used up when the first delete is sent, so a cancel before that keeps it.
  - **The simulator refuses DeleteObject on a folder with files in it** (0x2002). That isn't observed: what the OP-1 does is `delete.folder-with-files`, still unknown. FieldTapeKit always empties a folder first, so it doesn't depend on the answer.
- **2026-11-14:** Decided by the owner while building step 9a of the plan:
  - **A write that reads back wrong is deleted,** then `verificationFailed` is thrown. It's a new file FieldTapeKit just made at a free path, so nothing else is at risk, and a wrong track could confuse the OP-1's `tape.json` rebuild. If the delete fails too, `changed` lists the file. A send that fails or is cancelled partway is cleaned up the same way.
  - **Audio is checked against the firmware profile before sending:** a tape track must be PCM, 2 channels, 32 bits, 44.1 kHz, and a side the same at 16 bits, with a 44-byte header that matches the file's size. Anything else is `notAllowed`, until FieldCheck finds out what the OP-1 does with it (`album.write-other-format`). A track past 6 minutes is `tapeTooLong`, and `tape.json` must be a JSON object.
  - Also settled while building it: new names are sent lowercase. `createDirectory(at:)` makes only tape folders, with the new-tape name rules and the 8-tape check. Store Full is `insufficientSpace`.
- **2026-11-14:** Decided by the owner while building step 9b of the plan, writing to `synth/user/` and `drum/user/`:
  - **The read-back checks the samples, not only the length.** What the OP-1 stores must be audio in the same format as what was sent, not empty, no longer, and with the same samples as the start of it. That's stronger than section 5's "audio length", and the probe's two writes to `drum/user/` support it: the OP-1 kept every sample, and the only change to the audio was the 20-second cap. A mismatch is deleted and reported as `verificationFailed`, as in 9a.
  - **A preset must be 16-bit PCM, at 44.1 kHz mono or stereo, or 22,050 Hz mono,** in WAV, AIFF or AIFC (`NONE`, `twos` or `sowt`). 22,050 Hz mono is the format of the OP-1's own preset `applefly.aif`, so the OP-1's presets can be copied back. Anything else is `notAllowed` until FieldCheck finds out what the OP-1 does with it. The name must end in `.aif`, `.aiff`, `.aifc` or `.wav`.
  - **A shortened preset isn't reported.** `write` returns the item as the OP-1 stored it, and the public API doesn't change. The file that was sent is untouched, so nothing is lost.
  - **`synth/user/` follows the same rules,** with no cap assumed. Nothing has been written there yet, so level 2 checks it on hardware.
- **2026-11-15:** FieldCheck's first level 2 run (PROBE-NOTES.md) found that **`synth/user/` keeps 6 seconds**, where `drum/user/` keeps 20, and that **a converted preset keeps the format code it was sent with:** a WAV stored as AIFC is still listed as WAV. Neither changes a decision. A shortened preset was already allowed, and nothing in FieldTapeKit depends on a cap, which only the simulator models. But `FieldFormat` in a preset folder says what was sent, not what's stored, unlike the 2026-11-14 entry's reasoning for reading it from the format code. Its documentation says so now.
  - Also settled while building it: a preset WAV's chunks are walked, so WAVs from other apps with extra chunks are accepted. The read-back would catch the OP-1 handling one differently. A write that reads back wrong now says why in its error.
- **2026-11-16:** Decided by the owner: **a slow request is waited for, and there's no ping.** FieldCheck's runs found requests that stalled for about 60 s and then answered: the 16 MiB read in `read.cost` answered after 60.5 s, with the OP-1 fine (PROBE-NOTES.md). The 30 s timeout and ping couldn't tell that from a dead OP-1, since ImageCaptureCore sends one request at a time and the ping waited behind the stalled one, and the session then stayed disconnected though the OP-1 was there, until a replug. Now a request is noted as slow after 30 s, in the session's trace, and waited for until 90 s in all. If it answers, its answer is used and checked as usual. If not, the session is disconnected. An unplug is still noticed at once, from ImageCaptureCore removing the device. `MTPError.timedOut` isn't thrown any more, and `FieldError.Code.timedOut` stays. Failing the request at 30 s but keeping the session, and just raising the timeout with the ping kept, were rejected: the first fails a request that would have answered, and the second waits behind the same request anyway.
- **2026-11-16:** Decided by the owner while building step 21 of the plan, restoring album sides:
  - **Only a WAV in the OP-1's own layout and format is restored,** byte for byte: the 44-byte header, 16-bit stereo PCM at 44.1 kHz, matching its size, such as `copySide`'s copies. A WAV from another app with other chunks, or another format, is `notAllowed`. Rewriting it to the OP-1's layout was rejected for now: what's on the OP-1 would differ from the file, and `album.write-other-format` is still unknown.
  - **A side over 6 minutes is refused with `tapeTooLong`.** The OP-1's own limit for a side hasn't been observed, so this is the tape's limit, kept in the firmware profile as `maximumSideFrames`, and a new expectation, `album.side-limit`, records that it's unknown. The file layer refuses it too.
  - **A failure after the old side is deleted stops and reports,** as safety rule 6 says. Nothing more is written, so the side's file may be missing, and `changed` lists it. A half-made file from a refused send is still deleted, as for any write. Putting an empty side back automatically was rejected: it's another write after a failure, and whether the OP-1 minds a missing side is untested.
  - Also settled while building it:
    - `restoreSide` reads the file, checks it, then covers the side, and writes it with the file layer's replace, so a side gets the same checks again, delete, send, byte-for-byte read-back and `changed` as any file. Once the old side is deleted, cancelling no longer stops it.
    - An empty side, or a missing one, is written over whatever `conflict` says, and isn't copied, since nothing is lost.
    - `.replace(copyingExistingTo:)` copies to exactly that URL, which must be free, as `.replace(keepingCopyAt:)` does, and the copy is kept even if the restore fails.
    - A `SideReplacement` is refused if it's used, from another connection, for the other side (`notAllowed`), or the side as listed now differs. It's used up when the old side is deleted, so one cancelled before that still works.
    - `SideConflict` is a struct, as `TapeConflict` is.
  - **Whether a written side lasts isn't known, so step 21 waits for the OP-1.** The owner found the OP-1 can't empty a side, and that a side deleted over MTP came back after a reconnect (PROBE-NOTES.md). If the OP-1 rebuilds `mixdown/` from its own album, `restoreSide` would seem to work and change nothing. FieldCheck checks it across levels 2 and 3 (`album.write-kept`, ADR 0003), and step 21 isn't committed or tagged until that run shows whether `restoreSide` stays as it is, gets a warning, or is removed for 1.7.3. An in-session check in the conformance suite was dropped, since it can't show this.
    - **The first run answered it: a written side lasts** on 1.7.3 (PROBE-NOTES.md, 2026-11-16), so `restoreSide` stays as it is. But putting side B back in level 3 hung, so step 21 still waits until a side can be put back on the OP-1, with every MTP request traced.
  - **Album writing is off on 1.7.3, as a future improvement,** decided by the owner. A rule that a side can't grow was tried first: three hangs had each written a side longer than the one it replaced. Then level 3 put side B back at exactly the same length, and that hung too. What fits all four hangs is a side written over MTP in an earlier connection; every side write that worked went over a side recorded on the OP-1 (PROBE-NOTES.md). The owner's app needs only to read and copy the album. So `FirmwareProfile.albumWrites` is false on 1.7.3, and `restoreSide`, and the file layer's writes to `side_a.wav` and `side_b.wav`, throw `notAllowed` before anything changes. `restoreSide`'s code and tests stay, through a package-only override that FieldCheck uses to put back a side it overwrote. The growth rule's refusal is removed, and `album.side-grow` is replaced by `album.write-again`, which records the hang. Rewriting it to refuse only an MTP-written side was rejected for now: FieldTapeKit can't tell such a side apart yet.
- **2026-11-16:** Decided by the owner while building step 20 of the plan, reading and copying the album:
  - **A side's copy is named for the day it was copied,** in the device's time zone, such as `Side A 2026-11-16.wav`, and a taken name gets a number. The date the OP-1 reports for the file was rejected for now: whether its clock and MTP dates can be trusted isn't checked.
  - **A side that isn't sound is listed with its `problems`,** as a tape is: a missing file, a header that can't be read or doesn't match the file's size, or another format than 16-bit stereo PCM at 44.1 kHz. `album()` still lists both sides, and `copySide` refuses that side with `notAllowed`. So `AlbumSide.format` is optional, nil when the header can't be read.
  - **The OP-1 run is a reading conformance check:** `copyAlbum` copies every side with audio, each is matched by SHA-256 and by its header against the OP-1, `side(_:matches:)` must be true, and the copies are deleted. An empty side must be `notFound`. With both sides empty it's skipped.
  - Also settled while building it:
    - `album()` lists `mixdown/` and reads each side's 44-byte header with one GetPartialObject. A side is copied with one GetObject, so all of it is in memory, about 10 MB a minute.
    - A copy is written to a hidden temporary file, read back and matched by SHA-256, then moved into place, so nothing is left unless it succeeds.
    - `copyAlbum` checks both sides before copying anything, and if a copy fails it deletes the copies it already made.
    - `side(_:matches:)` compares with the side it names, even for a copy of the other side, and a missing side matches nothing.
    - `AudioFormat` has `isPCM`, `sampleRate`, `bitDepth` and `channels`.
- **2026-11-16:** Decided by the owner while building step 19 of the plan, restoring over an existing tape:
  - **A tape is replaced in place, file by file,** as section 4 says: for each track, the old one is deleted and the new one sent and read back, and a track blank on both sides is left as it is. Then `tape.json`, last. The folder stays, so a name longer than 12 characters, which a new tape couldn't have, survives. Deleting the tape and restoring it as new was rejected: the OP-1 would later cut a long name, and a failure part way would leave no tape at all.
  - **`.replace(archivingExistingTo:)` takes an exact file URL, which must be free,** as the file layer's `.replace(keepingCopyAt:)` does. A taken one throws `localFileFailed` before anything changes, so the app knows exactly where the old tape's archive is, and `restoreTape` still returns only the `Tape`. The archive is kept even if the restore fails.
  - **The writing check restores both ways** over an empty scratch tape: the smallest tape's archive over it, archiving it first, then that archive of the empty tape back over the audio, with a confirmation. Each result is matched to its archive by SHA-256.
  - Also settled while building it:
    - **`TapeConflict` is a struct,** with `.fail` and two static `replace` functions, as `ExistingFile` is, because Swift can't match two enum cases that share the name `replace`.
    - Before the first delete, a fresh listing checks the cover again: the tape against its confirmation, or against the archive just made by sizes and `tape.json`. Only the tape's own files, and an optional `readme.txt`, may be in its folder (`notAllowed`), and the archive being restored is read again from disk (`archiveMismatch`).
    - `.replace(archivingExistingTo:)` with no tape at the name restores a new tape and makes no archive. `.replace(confirmed:)` with no tape is `changedSinceConfirmation`, and a confirmation for another tape is `notAllowed`. A confirmation is used up at the first delete, so one cancelled before that still works.
    - Once the first file is deleted, cancelling no longer stops the restore, so a tape isn't left half-written for that. A failure lists in `changed` every file already deleted or written, and nothing is rolled back.
    - The existing tape needs to be sound to be archived. With a confirmation, any tape can be replaced.
- **2026-11-16:** Decided by the owner while building step 18 of the plan, deleting and moving tapes:
  - **A tape is deleted file by file, then its folder,** not with one DeleteObject on the folder, though that works on 1.7.3 (`delete.folder-with-files`). It works on any firmware, and if a delete fails part way, `changed` lists exactly the files already deleted. It's the same order as `removeItem(_:)` and the half-made-tape cleanup, and costs six requests instead of one.
  - **`deleteTape(_:keeping:)` matches every track by SHA-256** before it deletes anything: each is read from the OP-1, one at a time, and matched to the archive's record, or to the other tape's track, read the same way. Recording over a track on the OP-1 can leave every size and `tape.json` as they were, and an archive may be days old, so sizes alone could delete audio the copy doesn't hold. A full tape takes about 25 s to check, twice that with a tape as the copy, so it takes a `progress`.
  - **The writing checks gain two,** run on a duplicate of the smallest tape with audio: moving it off, matched by SHA-256 to the source, and deleting it keeping the source as its copy. The scratch tape is now deleted with `prepareToDelete` and `deleteTape(_:)`, so the confirmed path runs on the OP-1 every time.
  - Also settled while building it:
    - `moveTape` checks the tape against the archive it just made by sizes and `tape.json`, as section 4 says, since the copy read every byte a moment before. If the tape changed, or a delete fails, or the task is cancelled after the copy, the archive is kept in the folder.
    - `deleteTape(_:keeping:)` needs a sound tape. With an archive, the archive is opened from disk again after the tracks are matched, and refused with `archiveMismatch` if it no longer holds what it held when it was opened. A tape can't be its own copy (`notAllowed`).
    - Just before deleting, the tape is listed one last time, and only the files it lists, at the sizes it lists, and an optional `readme.txt` are deleted.
    - `prepareToDelete` works on a tape that isn't sound, so a broken tape can still be deleted. `TapeDeletion` keeps everything in the folder, and `losesNothing` is only ever true for a sound tape.
- **2026-11-15:** Decided by the owner while building step 17 of the plan, restoring a tape under a new name:
  - **An archived name longer than this firmware keeps is refused** when it would make a new tape, with `invalidName` and a reason saying to restore it under another name. The OP-1 would cut it to 12 once it left MTP mode, and the tape would come back under another name, perhaps one already taken. Names already on the OP-1 or in an archive are still accepted at any length for listing and copying off.
  - **It's checked on the OP-1 by a third writing check:** the smallest tape with audio is copied into an archive in a temporary folder, restored as `tapes/conformance`, matched to the archive file by file by SHA-256, and deleted with the archive.
  - Also settled while building it:
    - `restoreTape` shares `createTape`'s path: check, make the folder, write the tracks and then `tape.json`, list the tape again, and remove a half-made tape file by file.
    - Each track is read whole from the archive and checked against its SHA-256 just before it's written, so an archive changed on disk since it was opened is `archiveMismatch`, and only one track is in memory.
    - Every track is checked against the 6-minute limit before anything changes. On 1.7.3 an archive that opens can't fail this, since its `tape.json` would already be refused, but a firmware with a shorter limit could.
    - All four tracks are written, blank ones too, since a new tape has nothing to skip. Skipping a track that's blank on both sides is for step 19's replace.
    - `TapeConflict` has only `.fail` until step 19 adds the two kinds of replace, before 1.0.
- **2026-11-15:** Decided by the owner while building step 16 of the plan, creating and duplicating tapes:
  - **A half-made tape is removed file by file, then its folder,** as the probe proved on 2026-11-08, not with one DeleteObject on the folder. It works whether or not a firmware deletes a folder's contents (`delete.folder-with-files`), and a failure part way leaves the tape listed in `changed`. Whether `deleteTape` does the same is still step 18's choice.
  - **`duplicateTape` refuses a source that changes while it's copied,** as `copyTape` does: the source is read fresh at the start and listed again after its tracks are copied, before `tape.json` is written. If anything changed, it's `verificationFailed`, and the half-made copy is removed.
  - **They're checked on the OP-1 by the conformance suite's writing checks,** which FieldCheck runs only after the person confirms. Each makes the scratch tape `tapes/conformance` in a free slot, checks it and deletes it, so one slot is enough and nothing is left. The name is never level 2's, so a level 3 waiting on the OP-1 isn't touched.
  - Also settled while building it:
    - Both write the tracks first and `tape.json` last, as a restore does, then read the tape again and check it holds what was written. The OP-1 doesn't make a `tape.json` when tracks are written to a folder without one (2026-11-08), so the last write can't collide with a rebuild.
    - `createTape` writes the blank Disk Mini `tape.json` with only `tape_type` changed.
    - The name, a taken name and a free slot are checked from a fresh listing before anything is read or written, and checked again by `createDirectory(at:)`.
    - `duplicateTape`'s progress counts bytes, completed as each file is written and read back.
- **2026-11-15:** Decided by the owner while building step 15 of the plan, copying tapes off:
  - **`copyTape` copies the tape as it is when the copy starts,** read fresh, even if that differs from the `Tape` it was given, and the archive returned describes what it copied. A copy changes nothing, so an older listing isn't a reason to refuse. If a file or `tape.json` changes while it's being copied, it's refused (`verificationFailed`), and nothing is left in the folder. `moveTape`, which deletes, checks against the archive in step 18.
  - **Memory is measured on the OP-1:** the conformance suite copies the largest tape off, and FieldCheck logs its memory after each check.
  - Also settled while building it:
    - `copyTape` takes `compression:`, none by default, as section 4 offers.
    - It writes a hidden temporary archive in the destination folder, so the final move is on one volume and never replaces a file. A taken name gets a number, as Finder does.
    - A tape that isn't sound is refused with `notAllowed`, giving its problems.
    - Progress counts bytes, completed as each file is in the archive.
    - `notAllowed` now reads "FieldTapeKit won't do that with …", and `verificationFailed` with a reason "… couldn't be verified: …", so both fit copying as well as writing.
- **2026-11-15:** Decided by the owner while building step 14 of the plan, reel archives:
  - **`reel.json` keeps the OP-1's serial number,** as this ADR says, though archives are made to be shared. It's the only thing in an archive that identifies anyone.
  - **A track comes out of an archive as a file:** `extractTrack(_:to:)` streams it into a WAV in a folder, `<tape name> track_<n>.wav`, never overwriting, checking its SHA-256 on the way. Nothing large is held in memory, and a track that no longer matches isn't kept.
  - **Writing and reading came in one step,** since each tests the other.
  - Also settled while building it:
    - `reel.json` is `format`, `tape` (name and type), `device` (model, serial number, firmware), `created`, and `files`, each with its name, size and SHA-256. It's written last, once every file's hash is known.
    - Opening refuses an archive with anything but the four tracks, `tape.json` and `reel.json`, one whose `reel.json` is missing, unreadable or a newer format, or one whose `tape.json` doesn't match its tracks (`invalidArchive`), and one whose files don't match `reel.json` (`archiveMismatch`). Both codes are new.
    - `ReelArchive.Compression` is `none`, the default, or `lz4`, `lzfse`, `zlib` or `lzma`. An uncompressed archive is a plain Apple Archive, and both kinds are read the same way.
    - The writer is internal for now: step 15's `copyTape` is how apps make archives. It refuses a file that's already there, and deletes what it wrote if it's abandoned.
    - **`UTType.reelArchive` is `com.jnjosh.fieldtapekit.reelarchive`, one identifier for every app,** decided by the owner. File types are registered per device by extension, so two apps giving `.reelarchive` different identifiers would conflict wherever both are installed, even if they never share files. The type belongs to FieldTapeKit, so it's `UTType(importedAs:)`, and every app declares it under `UTImportedTypeDeclarations`, as its documentation shows. Rejected: letting each app choose its own identifier, which would also need its own extension to avoid the conflict, for files that are the same inside. The identifier and extension never change once archives are shared.
    - The tests keep `Tests/FieldTapeKitTests/Fixtures/format-1.reelarchive`, which every later version must open. It's written only when asked, and never replaced.
    - The Mac's `aa extract` takes an archive apart, compressed or not.
- **2026-11-15:** Decided by the owner while building step 13 of the plan, reading tapes:
  - **Every folder in `tapes/` is listed as a `Tape`,** sound or not, so every used slot shows. A tape with `tape.json` missing or unreadable, a track missing, an unexpected file, or tracks that don't match its clips says why in `problems`. `manifest` and `type` are optional for a tape without a readable `tape.json`. Copying a tape with problems is refused in step 15, but an app can still show it and move it.
  - **`TapeManifest.mixerParameters` is the eight numbers as stored,** since what they mean is only a guess.
  - Also settled while building it:
    - `TapeManifest` keeps `tape.json` as read in `data`, and its typed properties are clips (`track` 1 to 4, from `ch`), loop, tempo in BPM (`tempobpmdecimal` ÷ 10), `mixerParameters` and type. It refuses a file without those keys, saying which.
    - `tapes()` lists each folder and reads its `tape.json`, but not the tracks' WAV headers: the sizes against the clips are the check. It's sorted by name.
    - The simulator builder is `SimulatedTape(…)`, not `Tape(…)`, which is the type a listed tape has.
    - `TapeName`'s rule is shared with `createDirectory(at:)`, so the two can't drift.
- **2026-11-15:** **New tape names are limited to 12 characters, not 15,** decided by the owner. FieldCheck's first level 3 run found the OP-1 had cut its 15-character scratch tape, `fieldcheck #1-2`, to `fieldcheck #` once it left MTP mode (PROBE-NOTES.md). The OP-1 took the full name over MTP and listed it whole within the session, so nothing showed the cut until the reconnect. A name of 13 or more would make a tape that comes back under another name, which could also collide with a tape already there. The limit moves into the firmware profile as `maximumTapeNameLength`. Names already on the OP-1 or in an archive are still accepted at any length. The 2026-11-08 entry below gave the earlier reasoning.
- **2026-11-14:** Decided by the owner while building step 10 of the plan, replacing files:
  - **`.replace(keepingCopyAt:)` needs a free URL.** A taken one throws `localFileFailed` before anything changes, so the copy is always exactly where the caller said, and `write` still returns only the `FieldItem`. Unlike `removeItem(at:keepingCopyAt:)`, it never adds a number.
  - **A replace with nothing at the path** writes the file as new. `.replace(keepingCopyAt:)` makes no copy. `.replace(confirmed:)` throws `changedSinceConfirmation`, because what the person confirmed is gone.
  - **A replacement that reads back wrong is deleted,** as a new write is in 9a. The path is left empty, `changed` lists it, and the copy or the confirmation covers the old file.
  - Also settled while building it:
    - Everything is checked before the old file is deleted: the folder rules and formats, then the copy and its verification, or the confirmation.
    - A confirmation must be for the same path, ignoring case, or it's `notAllowed`. It's used up when the delete is sent, as in `removeItem(_:)`. A folder at the path is `isADirectory`.
    - Once the old file is deleted, cancelling no longer stops the write, so the path isn't left empty just because a task was cancelled. Any failure after the delete lists the path in `changed`.
    - `ExistingFile` is a struct with `.fail` and two static `replace` functions, not an enum. Swift can't match two enum cases that share the name `replace` in a pattern. Callers write the same code as with an enum, but can't switch on it.
- **2026-11-16:** Decided by the owner while building step 23 of the plan, the safety-rule suite: **a copy that covers a delete is matched to a second read from the OP-1** (safety rule 2). The suite's corrupted-read fault found that `moveTape`, `.replace(archivingExistingTo:)`, `removeItem(at:keepingCopyAt:)`, `.replace(keepingCopyAt:)` and so `SideConflict.replace(copyingExistingTo:)` read each file once and checked the copy against that read. A read that came back the right length with a wrong byte made a bad copy that passed, and the original was deleted. `deleteTape(_:keeping:)` already read the tape again.
  - **`moveTape` now deletes through `deleteTape(_:keeping:)`,** keeping the new archive, so every track is read again and matched by SHA-256. A restore over an archived tape matches its tracks again before the first delete, and the file layer reads a file again before deleting it. `tape.json` was already read twice.
  - **The cost is one more read** at about 20 MB/s: about 6 s for a full track, and 25 s for a full tape. Moves and replaces are rare, and a delete can't be undone.
  - **If the reads disagree, nothing is deleted and the copy is kept,** since which read went wrong isn't known. It's `verificationFailed`.
  - This tightens a rule, so it would be a minor version after 1.0.0. USB's packet CRC already catches errors on the wire, so only a fault in the OP-1 or ImageCaptureCore could cause it, and a fault that repeats on every read still can't be caught.
  - **The simulator's fault injection is complete:** a corrupted read, an unplug during a request (a SendObject leaves half its data, since what a real OP-1 keeps isn't known), and transfers at 20 MB/s reading and 7 MB/s writing. A transport that reports the device gone now leaves the session disconnected, as a timeout does.
- **2026-11-17:** step 24a, decided by the owner. macOS is a nice-to-have, so step 24 is split in two.
  - **`FieldDevice.ConnectionEvent` gains `.couldNotOpen(FieldError)`,** for an OP-1 that ImageCaptureCore found but couldn't open a session with, or whose device info couldn't be read. Until now that error was only logged, so an app saw nothing, as on a Mac where Image Capture already holds the OP-1. Watching goes on, unlike `.notAuthorized`, which ends the stream, so one OP-1 that can't be opened doesn't stop others from connecting.
  - **Its code is `.deviceRefused` for now,** with ImageCaptureCore's error as `underlying`. Step 24b maps a device held by another app to `.deviceInUse`, once the first Mac run shows how ImageCaptureCore reports it.
  - Adding a case breaks an exhaustive `switch` over the events. That's allowed before 1.0.0, and the release notes say so.
  - **FieldCheck on the Mac isn't sandboxed for now.** Which entitlement a sandboxed Mac app needs for ImageCaptureCore (section 9) stays open.
- **2026-11-17:** step 24b, decided by the owner: **`deviceInUse` is dropped from step 24, and documented.** On the Mac, neither app that could hold the OP-1 makes ImageCaptureCore report anything:
  - **Image Capture shares it.** FieldCheck connected while Image Capture had the OP-1 selected.
  - **FieldKit hides it.** It holds the OP-1 in MTP mode as its exclusive USB owner, and ImageCaptureCore doesn't list it.

  So there's no error to map:
  - **The code `deviceInUse` stays,** since codes are extensible, but it isn't thrown on 1.7.3.
  - **`couldNotOpen` stays** for a session that fails to open.
  - **Rejected:** detecting FieldKit with macOS-only IOKit code, by finding an OP-1 in MTP mode with another exclusive owner. It relies on `UsbExclusiveOwner`, which isn't documented, for a platform that's a nice-to-have.
  - **Two known limits on the Mac go in the beta's release notes:**
    - Quit FieldKit, or the OP-1 won't appear.
    - Another app, such as Image Capture, can talk to the OP-1 while FieldTapeKit does.
