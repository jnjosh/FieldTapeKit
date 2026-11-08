# Implementation plan: ADR 0002, FieldTapeKit

This plan builds [ADR 0002](../adrs/0002-op1-field-public-api.md) in 24 steps. Each step is a complete addition: it builds, its tests pass, and everything it adds to the public API works as the ADR describes. It can be committed on its own and reviewed without reading ahead. FieldCheck ([ADR 0003](../adrs/0003-firmware-check-tool.md)) is woven in where it's needed. Its steps are marked **(ADR 0003)**, because the 1.7.3 baseline comes before the rest of the framework, and FieldCheck is how every later step gets checked on the OP-1.

Steps are sized to stay near the 200–300 line guideline. Two of them (2 and 14) may run larger, and each says where to split it if it does.

## How every step works

- **Tests:** each step adds tests with [Swift Testing](https://developer.apple.com/documentation/testing). They run on the Mac with `swift test`, and on the iOS simulator with `xcodebuild test`. ImageCaptureCore doesn't work on the simulator, so those tests use the simulated OP-1.
- **On the OP-1:** steps that depend on device behavior end with a run on real hardware, through FieldCheck. You run it and share the log, as with the probe. Each step says whether that run reads only, or writes to FieldCheck's scratch content. No step writes to your tapes or album, apart from an album side that's already empty.
- **Expectations:** each step lists the expectations (ADR 0003) its code relies on. A step that starts relying on a new behavior adds its expectation.
- **Docs:** each step updates STATUS.md, and PROBE-NOTES.md only if hardware showed something new.
- **Versions:** pre-release tags are suggested at steps 15, 19 and 21, and `1.0.0-beta.1` after step 24. Each tag gets release notes listing what changed, including anything that broke since the last tag (ADR 0002, section 11).

## Facts checked for this plan (2026-11-08, Xcode 27.2)

- **Swift 6.4.2.** The package uses Swift 6 language mode with complete concurrency checking.
- **`FilePath` comes from Apple's `System` module,** not the standard library: `import System`. It's available from iOS 14 and macOS 11.
- **`ProgressManager` and `Subprogress`** are in Foundation in the iOS 27.2 SDK. `Subprogress` is `~Copyable`, which matches the ADR's `consuming Subprogress?` parameters.
- **`swift package diagnose-api-breaking-changes`** is available, for the release checks.
- **Of the probe's 21 tests,** 12 test the PTP layer and move in step 1. Four test tape checks and move with the code they test: three `tapeProblems` tests in step 5 and the tape name test in step 13. Five test the probe's own test plans (`tapeWritePlan`, `wholeTapePlan`, `copySource`), which don't move, so those tests stay with the probe. ADR 0003 says all 21 move. It should say 16.

## Layout

```
Package.swift                 FieldTapeKit package: iOS and macOS 27, no dependencies
Sources/FieldTapeKit/         The framework
Sources/FieldCheckKit/        FieldCheck's checks, with package access to the PTP layer
Sources/FieldTapeConformance/ The conformance suite, run on the simulator and on hardware
Tests/FieldTapeKitTests/
Tests/FieldCheckKitTests/
FieldCheck/                   The FieldCheck app: XcodeGen spec (project.yml) and a thin SwiftUI shell
firmware/1.7.3/               Baseline and reports
```

`research/` stays untouched.

---

## Part 1: Talking to the OP-1

### 1. The package and the PTP wire format

**Adds (all internal):**
- `Package.swift`: one library product, `FieldTapeKit`, with iOS and macOS 27 as the minimum.
- The probe's wire format code, carried over: operation codes (adding GetStorageInfo, 0x1005), containers, `PTPReader`, device info, object info, the object info dataset, payload stripping, and response codes and parameters.
- A new parser for the StorageInfo dataset, including free space.

**Tests:** the probe's 12 PTP tests, ported to Swift Testing, plus StorageInfo parsing. The StorageInfo tests use bytes built to the PTP spec, because the probe never captured a real reply.

**On the OP-1:** nothing. There's no device code yet.

**Done when:** `swift test` and the iOS simulator tests pass, and nothing is public.

### 2. The MTP session and a simulated OP-1 that can be read

**Adds (all internal):**
- `MTPTransport`, a small protocol: send a command with an optional data phase, get back data and a response.
- `MTPSession`, an actor over a transport. It handles transaction IDs, and a timeout on every request followed by a ping.
- **No OpenSession.** The probe's session-not-open fallback isn't carried over, so ADR 0002's rule 7 stays as written (decided 2026-11-08). A Session Not Open response (0x2003) is reported like any other refusal, with its response code. If a firmware ever needs a session, FieldCheck's `session.implicit` check fails and says so.
- A simulated MTP device behind the same protocol. It decodes real command containers and answers with real datasets, so the PTP encoding runs in tests. In this step it serves only the read operations: GetDeviceInfo, GetStorageIDs, GetStorageInfo, GetObjectHandles, GetObjectInfo, GetObject and GetPartialObject.
- Basic fault injection: a timeout on the nth request, and no answer at all.

**Tests:** each operation against the simulator, the session fallback, and timeout, then ping, then treated as disconnected.

**On the OP-1:** nothing yet. The live transport arrives in step 3.

**If it's too big:** commit the simulated device separately, after the session.

### 3. `FieldDevice` and connections

**Adds (public: the first API an app can use):**
- `FieldDevice`, an actor, with `info` and `isConnected`. `info` holds the firmware, `isFirmwareTested`, the serial number, and storage with free space.
- `FieldDevice.connections`, the `AsyncSequence` of connect and disconnect events:
  - It starts with the devices already connected.
  - Every listener shares one `ICDeviceBrowser`, filtered to the OP-1.
  - It asks for ImageCaptureCore authorization on first use.
- The ImageCaptureCore transport, carried from the probe's exchange code.
- `FieldError`, with the codes this step can throw: `disconnected`, `timedOut`, `notAuthorized`, `deviceInUse` and `deviceRefused`. It's `LocalizedError`, and `underlying` is `Sendable`.
- A firmware profile for 1.7.3. It's the single place for what's known per firmware, and later steps add their constants to it. `isFirmwareTested` is true only for firmware that has a profile.
- `FieldDevice.simulated()`, an empty simulated OP-1 that reports 1.7.3.
- **FieldCheck, the app shell:** an XcodeGen project in `FieldCheck/` for iOS. It shows connection events and device info.

**Tests:** the connection stream on the simulator (current state first, several listeners, cancelling), the error descriptions, and `isFirmwareTested`.

**On the OP-1 (reads only):** run FieldCheck on the iPad with the OP-1 in MTP mode. It should show connect and disconnect events, the firmware, the serial number and free space.

**Relies on:** `device.identity`, `session.implicit`, `session.data-phase`, `device.storage`.

### 4. FieldCheck: expectations, reports and the first checks (ADR 0003)

**Adds:**
- The expectation list, in FieldTapeKit next to the simulator, with stable IDs and "used by" entries.
- `FieldCheckKit`: checks as plain functions returning one result each, a runner, and reports in JSON and Markdown saved in Documents.
- Level 1 checks for `device.*`, `session.*`, `layout.*` and `names.lowercase`.

**Tests:** each check against recorded device replies, and report output.

**On the OP-1 (reads only):** a level 1 run. The report should match PROBE-NOTES.md.

### 5. FieldCheck: the rest of level 1, and the 1.7.3 baseline (ADR 0003)

**Adds:**
- The remaining level 1 checks:
  - `tape.files`, `tape.wav-format`, `tape.json-keys`, `tape.json-units` and `tape.types`;
  - `album.files` and `album.wav-format`;
  - `read.partial` and `read.speed`.
- The probe's tape consistency check, carried over as an internal function. The tape layer reuses it in step 13.
- **Save as baseline.**

**Tests:** the probe's three `tapeProblems` tests, and the new checks against recorded replies.

**On the OP-1 (reads only):** a full level 1 run, saved as `firmware/1.7.3/baseline.json`. Check it against PROBE-NOTES.md before committing it.

**Done when:** the 1.7.3 baseline is committed. The rest of FieldTapeKit is built against it.

## Part 2: The file layer

### 6. Paths and listing

**Adds (public):**
- The well-known `FilePath` locations (`op1Tapes` and the others), `FieldItem` and `FieldFormat`.
- `contentsOfDirectory(at:)`, `item(at:)` and `fileExists(at:)`.
- Internal: paths resolve to private handles, matching names ignoring case. Fresh object info comes from every listing.
- **The simulator builder,** `FieldDevice.simulated { Directory … File … }`. It lowercases names, as the OP-1 does, and lays out the 1.7.3 folders by default.
- **The conformance suite** (`FieldTapeConformance`): shared async checks that take a `FieldDevice`. A Swift Testing wrapper runs them on the simulator, and FieldCheck gets a Conformance button that runs them on hardware. Only reads at this point.

**Tests:** case-insensitive lookup, listings that use the device's spelling, `notFound` and `notADirectory`, and the conformance suite on the simulator.

**On the OP-1 (reads only):** run the conformance suite from FieldCheck.

**Relies on:** `names.lowercase`, `layout.folders`.

### 7. Reading and downloading

**Adds (public):**
- `contents(of:maximumSize:)`, `contents(of:range:)` and `bytes(of:chunkSize:)`.
- `copyItem(at: FilePath, to: URL, progress:)`. It reads fresh object info first, streams with GetPartialObject, and never overwrites a local file: if the name is taken, a number is added. The copy is read back from disk and checked against its SHA-256.
- Cancellation between chunks.
- **The simulator:** stale sizes for a file rewritten within the session.

**Tests:** ranges, the size limit, chunk sizes, local name collisions, cancellation, stale sizes and read-back mismatches.

**On the OP-1 (reads only):** the conformance suite copies a tape track and an album side off. Compare them with `shasum` on the Mac copies.

**Relies on:** `read.partial`, `rebuild.stale-size`.

### 8. Deleting files safely

**Adds (public):**
- `removeItem(at:keepingCopyAt:)`: copy, verify, then delete.
- `prepareToRemove(at:)`, returning a `FileDeletion`, and `removeItem(_:)`.
- A confirmation works once, only on the device that made it, and only if the file's size hasn't changed: otherwise `changedSinceConfirmation` or `confirmationAlreadyUsed`.
- Folders are deleted contents first. `changed` is filled in when a delete fails partway.
- **The simulator:** DeleteObject.

**Tests:** every refusal path, a confirmation reused or used on another device, and folder order. Safety rules 1, 4 and 6 are tested here first.

**On the OP-1:** nothing safe to delete yet. Hardware checks this step in step 11.

**Relies on:** `delete.files-then-folder`.

### 9. Writing new files and folders

**Adds (public):**
- `write(_:to:options:)`, `copyItem(at: URL, to: FilePath, options:progress:)` and `createDirectory(at:)`.
- `UploadOptions` with `verify`, which is on by default. `existing` has only `.fail` in this step, so a write to a path that's taken throws `alreadyExists`.
- The folder rules from the 1.7.3 `readme.txt` files, checked before sending (`notAllowed`).
- Preset folders: the result is the item as the OP-1 stored it, checked by audio length rather than bytes.
- The 8-tape check, for a new folder in `tapes/`.
- Store Full (0x200C) reported as `insufficientSpace`.
- **The simulator:** SendObjectInfo and SendObject, refusal with 0x2002, preset conversion, the 8-tape limit, and `tape.json` rebuilt after a track write.

**Tests:** each folder rule, read-back mismatches, the tape limit, preset conversion, Store Full, and cancellation (the partial file is deleted).

**On the OP-1:** checked in step 11.

**Relies on:** `write.folder`, `write.exact`, `write.refused-name`, `write.preset-converted`, `rebuild.tape-json`.

### 10. Replacing files

**Adds (public):** the two `ExistingFile` replace cases: `.replace(keepingCopyAt:)` and `.replace(confirmed:)`. Each is built from steps 8 and 9: a verified copy or a confirmation first, then delete, then send.

**Tests:** a failed copy changes nothing, a stale confirmation is refused, and a failure after the delete reports `changed`.

**On the OP-1:** checked in step 11.

### 11. FieldCheck level 2 (ADR 0003)

**Adds:**
- The scratch tape `fieldcheck #1-2`, with generated tones and a generated `tape.json`.
- `drum/user/fieldcheck.wav`.
- Free-space readings before and after.
- The album checks, on an empty side only.
- The long check, off unless asked for.
- A list of what will be created and deleted, confirmed before anything starts.
- Stopping at the first unexpected result.
- Built on the public file layer, so it checks steps 8 to 10 on hardware.

**Tests:** the check logic against the simulator, including the refusal when no slot is free.

**On the OP-1 (scratch writes):** one tape slot must be free. Run level 2.

**Relies on:** `names.maximum`, `device.storage` (free space).

### 12. FieldCheck level 3 (ADR 0003)

**Adds:**
- The reconnect flow, and remembering a pending level 3 across launches.
- The `reconnect.*` checks.
- The scratch tape's deletion as the `delete.folder-with-files` check.
- Offering to clean up a scratch tape left by an interrupted run.

**On the OP-1 (scratch writes):** level 2, then leave MTP mode and reconnect.

**Done when:** the 1.7.3 baseline covers all three levels.

## Part 3: The tape layer

### 13. Reading tapes

**Adds (public):**
- `TapeName`: the allowed characters, stored lowercase and compared ignoring case. New names are limited to 15 characters, but names already on the OP-1 are accepted at any length.
- `TapeType`, `TapeTrack` and `TapeManifest`. The manifest keeps the original JSON and round-trips unknown keys and `padding`.
- `Tape`, `tapes()`, `tape(named:)` and `tapeSlots()`.
- **The simulator builder:** `Tape(…)`.

**Tests:** the probe's tape name test, `TapeName` rules, manifest round-trip byte for byte on real `tape.json` files from `probe-results/`, the consistency check, and empty and recorded tracks.

**On the OP-1 (reads only):** the conformance suite lists your tapes.

**Relies on:** `tape.files`, `tape.json-keys`, `tape.json-units`, `tape.types`.

### 14. Reel archives

**Adds (public):**
- `ReelArchive` and `UTType.reelArchive`.
- `ReelArchive(contentsOf:)`: open, check every file against `reel.json`, and run the consistency check.
- Track access for "save the tracks".
- Internal: a streaming writer that takes chunks as they arrive and computes each SHA-256 on the way.
- No compression by default, with an option for Apple Archive's compressors.
- Format version 1, with a fixture archive kept in the tests for the semver rule.

**Tests:** round-trip, a corrupted entry, a missing `reel.json`, a size mismatch, compression, and the fixture.

**On the OP-1:** nothing. This step is all local files.

**If it's too big:** commit reading archives first, then writing them.

### 15. Copying tapes off → `1.0.0-alpha.1`

**Adds (public):** `copyTape(_:to:progress:)`, following ADR 0002's five steps: check, stream into a temporary archive, reopen and verify, then move into place under a new name.

**Tests:** a tape changed mid-copy, a failed verify leaving nothing behind, name collisions, cancellation, and progress.

**On the OP-1 (reads only):** copy one of your tapes off. On the Mac, extract it with `aa`, and compare the tracks with `shasum`.

**Tag:** `1.0.0-alpha.1`. This is the first thing the owner's app needs: taking tapes off.

### 16. Creating and duplicating tapes

**Adds (public):**
- `createTape(named:type:)`, from the blank Disk Mini template.
- `duplicateTape(_:as:progress:)`, through memory one track at a time.
- Both check the name and a free slot, and remove a half-made tape once if they fail.

**Tests:** the tape limit, a name taken (ignoring case), cleanup after a failure, and cleanup that itself fails (reported in `changed`).

**On the OP-1 (scratch writes):** create and duplicate under the scratch name, which needs one free slot. Then delete it on the OP-1, or with step 18.

### 17. Restoring a tape under a new name

**Adds (public):** `restoreTape(from:as:conflict:progress:)`, with `TapeConflict.fail`. It checks everything first, writes tracks first and `tape.json` last, reads each one back, and removes a half-made tape if it fails.

**Tests:** the write order, a refusal changing nothing, cleanup, and cancellation.

**On the OP-1 (scratch writes):** restore an archive of the scratch tape under the scratch name.

**Relies on:** `rebuild.tape-json`, `reconnect.kept`.

### 18. Deleting and moving tapes

**Adds (public):**
- `TapeCopy`, `deleteTape(_:keeping:)`, `prepareToDelete(_:)` returning `TapeDeletion`, and `deleteTape(_:)`.
- `moveTape(_:to:progress:)`.

**Tests:** a copy that doesn't match is refused, a stale or reused confirmation is refused, `losesNothing`, and move refusing to delete when the tape changed after archiving.

**On the OP-1 (scratch writes):** move the scratch tape off, then delete what's left.

### 19. Restoring over an existing tape → `1.0.0-alpha.2`

**Adds (public):** `TapeConflict.replace(archivingExistingTo:)` and `.replace(confirmed:)`. The existing tape is archived and verified, or its confirmation checked, before anything changes. There's no rollback, and `changed` is reported.

**Tests:** a failure at each point, with the archive left in place.

**On the OP-1 (scratch writes):** restore over the scratch tape.

**Tag:** `1.0.0-alpha.2`. Tapes go off and back on.

## Part 4: The album layer

### 20. Reading and copying the album

**Adds (public):**
- `Album`, `AlbumSide` and `AudioFormat`, parsed from the WAV header.
- `album()`, `copySide(_:to:progress:)` and `copyAlbum(to:progress:)`.
- `AlbumSideCopy`, which is `Codable`, and `side(_:matches:)`.

**Tests:** empty sides skipped, `notFound` for an empty side, name collisions, and matching by size first, then SHA-256.

**On the OP-1 (reads only):** copy the album off.

**Relies on:** `album.files`, `album.wav-format`.

### 21. Restoring album sides → `1.0.0-alpha.3`

**Adds (public):** `restoreSide(_:from:conflict:progress:)`, `SideConflict`, `prepareToReplace(_:)` and `SideReplacement`, plus the 44.1 kHz WAV check before sending.

**Tests:** both replace paths, a stale confirmation, and the format check.

**On the OP-1:** only if a side is empty. Otherwise, the simulator only.

**Relies on:** `album.write-exact`. `album.write-other-format` stays unknown until FieldCheck has run it.

## Part 5: Ready for beta

### 22. FieldCheck: comparing with the baseline, and the draft ADR (ADR 0003)

**Adds:**
- Results of pass, changed, fail or not run, against the right baseline.
- The report's ordering: changes and failures first.
- `draft-adr.md`, with suggested compatibility classes and the compatibility table.

**Tests:** recorded runs with a change of every class.

**On the OP-1 (reads, plus scratch writes):** a full run on 1.7.3. It should come back all pass.

### 23. The safety-rule suite

**Adds:**
- One test group per rule in ADR 0002, section 6, named by rule number.
- The rest of the simulator's fault injection: a disconnect mid-transfer, a corrupted read, and slow transfers at 20 and 7 MB/s.
- A release checklist, `docs/RELEASING.md`:
  - `diagnose-api-breaking-changes` against the last tag;
  - archive fixtures still open;
  - the safety suite passes.

**On the OP-1:** nothing new.

### 24. macOS

**Adds:**
- FieldCheck's macOS target.
- Whatever entitlement ImageCaptureCore needs on the Mac.
- `deviceInUse` detection, once it's seen how ImageCaptureCore reports another app holding the device.

**On the OP-1 (reads, plus scratch writes):** plug it into the Mac with Teenage Engineering's app and Image Capture closed. Run FieldCheck levels 1 to 3 and the conformance suite. Then run it once with Image Capture open, to see `deviceInUse`.

**Tag:** `1.0.0-beta.1`, once this run passes.

---

## Risks to watch

- **Timeouts:** whether ImageCaptureCore lets a ping through while an earlier request is still hung is unknown. The single 60-second hang never recurred, so step 2 is tested only on the simulator.
- **Steps 8 to 10 are checked on hardware only in step 11.** Until then they're simulator-tested.
- **Album writes** may never get a hardware check if both sides keep their audio.
- **`Subprogress`** is new API. If its shape makes progress awkward, steps 7 and 15 are where that shows first.
