# Status

Where the project stands, so a new session can pick it up. Update this when the state changes. The reasoning lives in the ADRs, and the evidence in [research/PROBE-NOTES.md](../research/PROBE-NOTES.md).

## As of 2026-11-13

**Research is done.** The probe in `research/` showed that ImageCaptureCore's raw PTP passthrough can do everything FieldTapeKit needs, on iPad and iPhone with OP-1 firmware 1.7.3: list, read, write, create, and delete, including whole-tape copies and album sides byte for byte. Its 21 unit tests pass from `research/`.

**Decisions:**

| ADR | Decision | Status |
| --- | --- | --- |
| [0001](adrs/0001-op1-field-ios-transport.md) | Transport: ImageCaptureCore raw PTP, not a USB driver | **Accepted** 2026-11-08 |
| [0002](adrs/0002-op1-field-public-api.md) | FieldTapeKit's public API: file, tape and album layers, safety rules, simulator, versioning | **Accepted** 2026-11-08 |
| [0003](adrs/0003-firmware-check-tool.md) | FieldCheck: repeatable checks against a baseline for each firmware, and a draft ADR for each change | **Accepted** 2026-11-08 |

**Settled in ADR 0002, decided by the owner:**
- **Name:** FieldTapeKit. It must end in "Kit", and FieldKit is taken by Teenage Engineering's Mac app.
- **Types:** `FieldDevice`, `FieldItem`, `FieldError`, `Tape`, `TapeName`, `ReelArchive`, `Album`.
- **Platforms:** iOS, iPadOS and macOS 27. macOS is untested.
- **Device discovery:** `FieldDevice.connections`, an `AsyncSequence`.
- **Tape calls:**
  - `copyTape`, `moveTape`, `restoreTape`, `createTape` and `duplicateTape`.
  - One shared check of the 8-tape limit.
  - Filtering is left to the app.
- **Album calls:** `copySide`, `copyAlbum` and `restoreSide`, for `mixdown/side_a.wav` and `side_b.wav`.
- **Backups:** `<tape name>.reelarchive`, an Apple Archive file, uncompressed by default, with no zip or tar code of our own.
- **Safety:** nothing is deleted or overwritten without a verified copy, or a person's confirmation (`prepareToDelete` → `TapeDeletion`). Read-back is on by default.
- **Tape names:** at most 12 characters for a new tape, the most the OP-1 keeps (15 until 2026-11-15, when the OP-1 was found cutting longer names after a reconnect). Names already on the OP-1 or in an archive are accepted at any length.
- **Free space:** FieldCheck checks whether GetStorageInfo's figure is accurate. Until then nothing refuses a write on it, and Store Full is reported as `insufficientSpace`.
- **Versioning:** strict semver, starting at `1.0.0-alpha.1`, then betas, then `1.0.0`. A major version protects the Swift API, the archive format, supported firmware and safety behavior.
- **Firmware support is additive:** each tested firmware keeps a profile, a baseline and simulator tests. Untested firmware works, with a warning (`isFirmwareTested`).

**Settled in ADR 0003, decided by the owner:**
- **Name:** FieldCheck.
- **The long check** (a 6-minute, 127 MB track) runs only when asked.
- **The scratch tape** is `fieldck #1-2`, exactly 12 characters, and level 2 also makes `fieldck #2-13`, 13 characters, to check the OP-1 cuts it to 12 (2026-11-15).
- **No user `padding`** is copied onto the scratch tape. Shared `padding` stays a known risk.
- **`delete.folder-with-files`** runs on the scratch tape's own deletion. Level 2 needs two free slots, for its two tapes.
- **A draft ADR** comes with every run that finds a change: what changed, a suggested compatibility class, and who each change affects, including people who don't update. A person makes the decision.

**Open questions:** none in ADRs 0002 or 0003.

**Building FieldTapeKit:** following [the implementation plan](plans/adr-0002-implementation.md), one committed step at a time.
- **Step 1 is done:** the package and the PTP wire format, all internal, with the probe's 12 PTP tests ported to Swift Testing and new StorageInfo tests. All 15 pass on the Mac and the iOS simulator. Nothing on the OP-1 has been run against it yet.
- **Step 2 is done:** `MTPSession` sends one request at a time, with a timeout and a ping, and never sends OpenSession. The simulated OP-1 answers the read operations as 1.7.3 does, and can inject faults: no answer, going silent, a refusal. All internal, with 34 tests passing on the Mac and the iOS simulator. The session's timeouts are tested only on the simulator, because the one real hang never recurred.
- **Step 3 is done, and passed its first run on the OP-1** (iPad Pro, 2026-11-09, log in [firmware/1.7.3/runs](../firmware/1.7.3/runs/fieldcheck-2026-11-09T131756Z.txt)):
  - The first public API: `FieldDevice` with `info` and `isConnected`, `FieldDevice.connections`, `FieldError`, and `FieldDevice.simulated()`.
  - Inside: the ImageCaptureCore transport and the 1.7.3 firmware profile.
  - The FieldCheck app shell, which shows connections and device info.
  - 53 tests pass on the Mac and the iOS simulator. FieldCheck builds for iOS devices.
  - On the OP-1: it connected as OP-1, firmware 1.7.3 (tested), serial L1PXE14W. Both ways of disconnecting were reported: unplugging, which also takes the OP-1 out of MTP mode, and leaving MTP mode with the cable still in. After the unplug, plugging in and entering MTP mode again connected as a new device. The stream never ended.
  - The OP-1 reports 6,429,185,024 bytes of capacity, now the simulator's default.
  - Free space fell by 1,024 bytes between the two connections, with nothing written by FieldCheck. That fits what the probe found: the OP-1 rewrites files such as `tape.json` while it's out of MTP mode (PROBE-NOTES.md, survival run). `device.storage` must allow for it.
- **Step 4 is split into 4a and 4b** (decided 2026-11-13, recorded in the plan). Until baselines exist, checks give pass, fail or not run on the behavior FieldTapeKit relies on, and record what they observed. `changed` waits for step 22.
- **Step 4a is done** (committed): the expectation list, `Expectation.all`, in FieldTapeKit with `package` access, and `FieldCheckKit`, a second library product for the app, with results, a runner, and reports saved as JSON and Markdown that never overwrite a file. The simulator tests now run with `-scheme FieldTapeKit-Package`.
- **Step 4b is done, and passed its run on the OP-1** (iPad Pro, iPadOS 27.2.1, 2026-11-13, report in [firmware/1.7.3/runs](../firmware/1.7.3/runs/fieldcheck-2026-11-13T133444Z.md)):
  - Eight level 1 checks, which only read: `device.identity`, `device.operations`, `device.storage`, `session.implicit`, `session.data-phase`, `layout.folders`, `layout.readmes` and `names.lowercase`. Each fetches what it needs, then a plain function judges it.
  - FieldTapeKit's session and PTP layer now has `package` access, so FieldCheckKit can send raw operations. `FieldDevice` keeps the USB identity ImageCaptureCore reported, a reply says whether its data had a container header, and the 1.7.3 profile holds the expected folders and the names each `readme.txt` allows.
  - FieldCheck has a **Run level 1 (reads only)** button for each connected OP-1. It shows the results and saves `fieldcheck-<time>.json` and `.md` to Documents, next to the log.
  - 86 tests pass on the Mac and the iOS simulator (57 FieldTapeKit, 29 FieldCheckKit), against a simulated OP-1 laid out from the probe's 1.7.3 listing. FieldCheck builds for iOS devices.
  - On the OP-1: all 8 checks passed in 0.1 s, and match PROBE-NOTES.md. The same 21 operations in the same order, one storage with the capacity from 2026-11-09, all 24 folders, the readme texts from 2026-11-05 word for word, and 68 names, all lowercase. It found 3 tapes, which is right: the owner removed the others on the OP-1 after the probe runs.
  - For step 5: the report's JSON stores times to the second, so a report read back loses its duration. Store it explicitly when reports are read back.

- **Step 5 is split into 5a and 5b** (decided 2026-11-13, recorded in the plan). 5a reads up to 16 MiB in 1 MiB chunks for `read.partial` and `read.speed`, with no whole-file read.
- **Step 5a is done, and passed two runs on the OP-1** (iPad Pro, 2026-11-13, reports in [firmware/1.7.3/runs](../firmware/1.7.3/runs/fieldcheck-2026-11-13T135316Z.md)):
  - Nine more level 1 checks, which only read: `tape.files`, `tape.wav-format`, `tape.json-keys`, `tape.json-units`, `tape.types`, `album.files`, `album.wav-format`, `read.partial` and `read.speed`. Level 1 now has 17.
  - In FieldTapeKit, with `package` access: the probe's tape consistency check as `TapeConsistency`, a reader for the OP-1's 44-byte WAV headers, and the 1.7.3 profile's tape and album files, `tape.json` keys, versions and types, and track and side formats.
  - None of them passes or fails on what's on the OP-1. With no tapes, the tape checks don't run, and with no audio, the read checks don't.
  - 110 tests pass on the Mac and the iOS simulator (64 FieldTapeKit, 46 FieldCheckKit), including the probe's three `tapeProblems` tests. FieldCheck builds for iOS devices.
  - On the OP-1: all 17 checks passed in 10.5 s and match PROBE-NOTES.md: 3 tapes and 12 tracks in the 1.7.3 format, every `tape.json` with exactly the known keys at version 1, the consistency check passing, and both album sides 16-bit. Both sides have audio, so level 2's album write checks won't be able to run.
  - **New: chunked reads get slower with the offset** (PROBE-NOTES.md, 2026-11-13). The second run timed each 1 MiB chunk: 62 ms at offset 0, rising about 58 ms for each MiB, to 960 ms at 15 MiB, so 2.0 MB/s overall. It looks as if the OP-1 reads from the start of the file for every GetPartialObject. Reading a full 127 MB track in 1 MiB chunks would take about 7 minutes, against about 6 s for one GetObject.

- **Step 5b is done, so step 5 is: the 1.7.3 baseline is committed** as [firmware/1.7.3/baseline.json](../firmware/1.7.3/baseline.json), from a level 1 run on the iPad Pro on 2026-11-14 (report in [firmware/1.7.3/runs](../firmware/1.7.3/runs/fieldcheck-2026-11-14T042609Z.md)):
  - `Baseline`, saved by FieldCheck's new **Save as baseline** button as `baseline-<firmware>.json` in Documents, never overwriting. It refuses a run with any failure, records a check that didn't run as not observed, and leaves out the serial number (decided 2026-11-13).
  - Each check now names the fields of its observation that vary between runs, such as free space and read times, as `varies`. Ranges for them come with the comparison in step 22.
  - Reports keep their duration in milliseconds, and `tape.json-keys` leaves out `clipKeys` when there are no clips. Older reports still read.
  - A test checks a committed `firmware/1.7.3/baseline.json` against the 1.7.3 profile and simulator: operations, storage, folders, `tape.json` keys and versions, album files, WAV formats and folder rules. It passes on the committed baseline, and on a baseline made from the 2026-11-13 report.
  - 121 tests pass on the Mac and the iOS simulator (64 FieldTapeKit, 57 FieldCheckKit), with none skipped. FieldCheck builds for iOS devices.
  - The run: all 17 checks passed and match PROBE-NOTES.md, and the baseline has no serial number. The chunk times came back the same for the third time: 61 ms rising to 960 ms, about 58 ms more per MiB.

- **Step 6 is split into 6a and 6b** (decided 2026-11-13, recorded in the plan and ADR 0002's change log).
- **Step 6a is done, and needed no OP-1 run:**
  - The second public API, the start of the file layer: `FilePath.op1Tapes`, `.op1Mixdown`, `.op1Synth` and `.op1Drum`, `FieldItem`, `FieldFormat`, and `contentsOfDirectory(at:)`, `item(at:)` and `fileExists(at:)`.
  - Lookups walk the path from the root with fresh object info at every step, match names ignoring case, and answer with the OP-1's spelling. An exact match wins. Several matches that differ only in case throw `ambiguousPath`. There's no handle cache.
  - New `FieldError` codes: `notFound`, `notADirectory` and `ambiguousPath`.
  - `FieldDevice.simulated { Directory … File … }`, starting from the 1.7.3 layout with no tapes. `File(_:seconds:)` makes silent WAVs: 32-bit in a tape, 16-bit anywhere else.
  - Tests check that level 1 passes on the default simulated OP-1, and that its readme texts are the baseline's.
  - 137 tests pass on the Mac and the iOS simulator (78 FieldTapeKit, 59 FieldCheckKit). FieldCheck builds for iOS devices.

- **Step 6b is done, so step 6 is, and it passed on the OP-1** (iPad Pro, 2026-11-14, log in [firmware/1.7.3/runs](../firmware/1.7.3/runs/fieldcheck-2026-11-14T044246Z.txt)): all 10 conformance checks passed in about 0.2 s, the tape check included, so the simulator and a real 1.7.3 OP-1 agree on the listing API.
  - `FieldTapeConformance`, a third library product. It has 10 read-only checks of the listing API that use only FieldTapeKit's public API and don't depend on what's on the OP-1: the well-known folders, paths and spelling, lowercase names, case-insensitive lookups, `item(at:)` agreeing with listings, formats, and the `notFound` and `notADirectory` errors. The tape check is skipped when there are no tapes.
  - A Swift Testing wrapper runs every check against an empty and a populated simulated OP-1.
  - FieldCheck has a **Run conformance suite (reads only)** button, and logs each result.
  - It settled one detail: a lookup through a file throws `notADirectory` with that file as the error's path, which is now documented.
  - 141 tests pass on the Mac and the iOS simulator (78 FieldTapeKit, 59 FieldCheckKit, 4 conformance tests with 22 cases). FieldCheck builds for iOS devices.

- **The large-file read decision is made** (owner, 2026-11-14), and recorded in ADR 0002's change log: **whole files are read with one GetObject**, and `bytes(of:chunkSize:)` is dropped from the API. `copyItem(at:to:)` and `copyTape` hold at most one track in memory, as uploads already do, with progress and cancellation per file. `contents(of:range:)` stays, for small reads near the start of a file. The plan's steps 7, 14 and 15 are updated to match.
- **It came from a new level 1 check, `read.cost`,** added to ADR 0003's expectations. It passed on the OP-1 (iPad Pro, 2026-11-14, report in [firmware/1.7.3/runs](../firmware/1.7.3/runs/fieldcheck-2026-11-14T172405Z.md)):
  - After `read.speed`'s forward chunks, it reads the same chunks in reverse, then all of them in one GetPartialObject, then the whole file in one GetObject, checking every read's bytes. Only `costGrowsWith` and the byte checks go in the baseline; the times vary.
  - **The cost grows with the offset.** In reverse the chunks still rose about 56 ms per MiB of offset. One 16 MiB GetPartialObject from offset 0 took 0.87 s (19.2 MB/s), and one GetObject of the 22 MB track 1.17 s (18.8 MB/s). So a read costs about what reading from the file's start to its end would, however it's split (PROBE-NOTES.md, 2026-11-14).
  - All 18 level 1 checks passed in 21 s. `firmware/1.7.3/baseline.json` is replaced by this run's, which adds `read.cost`.
  - 149 tests pass on the Mac and the iOS simulator (78 FieldTapeKit, 67 FieldCheckKit, 4 conformance tests). FieldCheck builds for iOS devices.
- **Not yet tried on hardware:** a GetObject of a full 6-minute, 127 MB track. Step 11's long check (`tape.track-limit`) is its first test.

- **Step 7 is split into 7a and 7b** (decided 2026-11-14, recorded in the plan and ADR 0002's change log).
- **Step 7a is done, and needed no OP-1 run:**
  - Public: `contents(of:maximumSize:)` and `copyItem(at: FilePath, to: URL, progress:)`, each reading the whole file with one GetObject, and `contents(of:range:)` with one GetPartialObject.
  - `copyItem` never overwrites a local file: a taken name gets a number, as Finder does (`side_a 2.wav`), and it returns the URL it wrote. It checks the read's length against the fresh size, writes, reads the copy back and matches it by SHA-256, and deletes a copy that doesn't match. Progress is three steps: read, write and read back.
  - New `FieldError` codes: `tooLarge`, `isADirectory`, `verificationFailed` and `localFileFailed`.
  - The simulator rebuilds a file as the OP-1 does, still listing and serving its old size (`rebuild.stale-size`), and can cut a data phase short. A copy of a rebuilt file is of what the OP-1 serves; nothing over MTP shows the new size.
  - Not tested: a copy that reads back wrong from disk, which needs a way to corrupt a local file between write and read-back.
  - 165 tests pass on the Mac and the iOS simulator (94 FieldTapeKit, 67 FieldCheckKit, 4 conformance tests). FieldCheck builds for iOS devices.

- **Step 7b is done, so step 7 is, and it passed on the OP-1** (iPad Pro, 2026-11-14, log in [firmware/1.7.3/runs](../firmware/1.7.3/runs/fieldcheck-2026-11-14T213915Z.txt)): all 15 conformance checks passed in about 4 s. The copies of `mixdown/side_a.wav` (12,235,308 bytes) and `tapes/2026-220#01/track_4.wav` (22,056,500 bytes) have the SHA-256s the probe recorded for the same files with its own code: `65c9af35…138aeb1a` on 2026-11-03, and `9aecf102…ecb69497` on 2026-11-08. The copies pulled to the Mac hash the same. So FieldTapeKit's one-GetObject copies match the OP-1 byte for byte.
  - Five more conformance checks, 15 in all. They read, and never change, the OP-1: a whole read against a range read, a range past the end, `tooLarge` and `isADirectory`, and copying album side A and the largest tape track off.
  - Each copy is made twice, and both are checked against the listing's size, a header read straight from the OP-1, and each other. The first copy is kept, the second, which got a numbered name, is deleted, and the check reports the copy's SHA-256.
  - Checks now take a folder for copies. FieldCheck makes `conformance-<time>` in Documents for each run and keeps the copies there, so they can be compared with copies made on a Mac. The log has each SHA-256.
  - 166 tests pass on the Mac and the iOS simulator (94 FieldTapeKit, 67 FieldCheckKit, 5 conformance tests with 33 cases). FieldCheck builds for iOS devices.

- **Step 8 is done, tested only on the simulator,** as the plan says. Hardware checks it in step 11, the first step that writes something safe to delete:
  - Public: `removeItem(at:keepingCopyAt:)`, which copies and verifies a file, checks it's listed as it was, then deletes it, and returns the copy's URL. `prepareToRemove(at:)` returns a `FileDeletion`, and `removeItem(_:)` deletes what it describes.
  - A confirmation works once, only on the connection that made it, and only while the item and everything in it are listed exactly as they were. A folder's contents go deepest first, then the folder. A failure partway stops, and `changed` lists what was deleted.
  - The root, the OP-1's own folders, and its own files (`readme.txt`, `you may create folders here`) are refused with `notAllowed`. A tape folder can still be deleted, with its `readme.txt`.
  - New `FieldError` codes: `notAllowed`, `changedSinceConfirmation` and `confirmationAlreadyUsed`.
  - The simulator now deletes, refuses a folder with files in it (an assumption: `delete.folder-with-files` is still unknown), records what it deleted in order, and can refuse deleting a named file.
  - 182 tests pass on the Mac and the iOS simulator (110 FieldTapeKit, 67 FieldCheckKit, 5 conformance tests). FieldCheck builds for iOS devices.

- **Step 8b, FieldCheck's Explore tab, is done** (added by the owner on 2026-11-14, in the plan and ADR 0003's change log):
  - FieldCheck has two tabs: **Validate**, everything it did before, and **Explore**, a read-only browser built only on FieldTapeKit's public API. It lists folders, shows an item's path, size and format, and copies a file to the device with `copyItem`, to share from there.
  - In the iOS simulator, `-SimulatedOP1 YES` gives FieldCheck the simulated OP-1. Both tabs were checked there: Explore listed the folders and `mixdown/`, and copied side A.
  - The owner tried it on the OP-1 on 2026-11-14, and it worked. No log was kept of that try. FieldCheck builds for iOS devices, and the package's 182 tests are unchanged.

- **Step 9 is split into 9a and 9b** (decided 2026-11-14, recorded in the plan and ADR 0002's change log).
- **Step 9a is done, tested only on the simulator,** as the plan says. Hardware checks it in step 11:
  - Public: `write(_:to:options:)`, `copyItem(at: URL, to: FilePath, options:progress:)` and `createDirectory(at:)`, with `UploadOptions` (`verify` on by default) and `ExistingFile`, which has only `.fail` until step 10.
  - Everything is checked before anything is sent: the folder exists, the path is free, the folder allows the name, and audio is in the profile's format. Names are sent lowercase. A send that fails, is cancelled or reads back wrong deletes its half-made file, and `changed` lists it only if that delete fails.
  - `createDirectory` makes only tape folders, with names of at most 15 characters (12 since 2026-11-15) from A–Z, 0–9, `#`, `-` and space, and only while one of the 8 slots is free.
  - New `FieldError` codes: `alreadyExists`, `invalidName`, `tapeLimitReached`, `tapeTooLong` and `insufficientSpace` (Store Full). Preset folders are refused with `notAllowed` until 9b.
  - The simulator now accepts SendObjectInfo and SendObject, refuses names a folder doesn't allow with 0x2002, refuses a full store with 0x200C, rebuilds `tape.json` after a track write with the old size still listed, and can corrupt a stored file or refuse a SendObject. How the OP-1 refuses a ninth tape isn't known; the simulator's 0x2002 is a guess, and FieldTapeKit refuses first anyway.
  - 205 tests pass on the Mac and the iOS simulator (133 FieldTapeKit, 67 FieldCheckKit, 5 conformance tests). FieldCheck builds for iOS devices.

- **Step 9b is done, so step 9 is, tested only on the simulator.** Hardware checks it in step 11:
  - `write` and `copyItem(at: URL, to: FilePath)` now write presets to `synth/user/` and `drum/user/`. The public API is unchanged.
  - A preset must be 16-bit PCM, at 44.1 kHz mono or stereo, or 22,050 Hz mono, in WAV, AIFF or AIFC, with a name ending `.aif`, `.aiff`, `.aifc` or `.wav`. The OP-1 converts it to AIFC under the same name, so the read-back checks the audio: the same format, not empty, no longer, and the same samples as the start of what was sent. A shortened preset isn't reported (decided 2026-11-14, in ADR 0002's change log).
  - Inside: `PCMAudio`, a reader for WAV, AIFF and AIFC that walks their chunks. It reads the probe's real files correctly: `applefly.aif` is 22,050 Hz mono, its copy has the same samples, and the converted WAV is exactly 882,000 stereo frames.
  - The simulator converts what `synth/user/` and `drum/user/` receive to AIFC with `sowt`, cuts `drum/user/` to 20 seconds, and `corruptStored` now changes the last byte, so for a preset it's a sample.
  - Unknown until step 11: what `synth/user/` does, and the format code the OP-1 reports for a converted file.
  - 218 tests pass on the Mac and the iOS simulator (146 FieldTapeKit, 67 FieldCheckKit, 5 conformance tests).

- **Step 10 is done, tested only on the simulator.** Hardware checks it in step 11:
  - `UploadOptions.existing` takes `.replace(keepingCopyAt:)` and `.replace(confirmed:)`, for `write` and `copyItem(at: URL, to: FilePath)`. Each checks the rules, then covers the old file with a verified copy or a confirmation, then deletes it and sends the new one.
  - The copy's URL must be free (`localFileFailed`), so the copy is exactly there. With nothing at the path, the write goes ahead as new, though a confirmation for something that's gone is refused. A replacement that reads back wrong is deleted, and `changed` lists the path (decided 2026-11-14, in ADR 0002's change log).
  - Once the old file is deleted, cancelling no longer stops the write. That isn't tested: the simulator has no way to cancel in the middle of a send.
  - `ExistingFile` is now a struct with static members, because Swift can't match two enum cases both named `replace`. Callers write the same code.
  - 232 tests pass on the Mac and the iOS simulator (160 FieldTapeKit, 67 FieldCheckKit, 5 conformance tests).

- **Step 11 is split into 11a and 11b** (decided 2026-11-14, recorded in the plan and ADR 0003's change log).
- **Step 11a is done, and passed on the OP-1** (iPad Pro, 2026-11-15, report in [firmware/1.7.3/runs](../firmware/1.7.3/runs/fieldcheck-2026-11-15T023343Z.md)). All 8 checks passed in 8.2 s, so FieldTapeKit's writes, replaces and deletes work on hardware. Two things were new, now in the simulator and PROBE-NOTES.md: `synth/user/` keeps only 6 seconds of a preset, where `drum/user/` keeps 20, and a converted preset is still listed with the WAV format code it was sent with. The copies the run kept match: the replaced track has the first tone's SHA-256. A second run ([report](../firmware/1.7.3/runs/fieldcheck-2026-11-15T035517Z.md)) passed the same way, with the same figures, and **Delete FieldCheck's content…** then passed `delete.files-then-folder`: the scratch tape's 5 files were deleted first, then its folder, and the space came back exactly. A converted preset differs between runs only by an `mtime` the OP-1 writes into its metadata.
  - `LevelTwo` in FieldCheckKit has 8 checks: `names.maximum`, `write.folder`, `write.exact`, `write.refused-name`, `rebuild.tape-json`, `rebuild.stale-size`, `write.preset-converted` and `device.storage`. They're built on FieldTapeKit's public file layer, so they check steps 8 to 10 on hardware. They stop at the first failure.
  - **What it does to the OP-1:**
    - It makes `tapes/fieldcheck #1-2` with a new tape's `tape.json`, then four 2-second tones, which make the OP-1 rebuild `tape.json`.
    - It tries `track_5.wav`, which the OP-1 should refuse.
    - It replaces `track_1.wav`, keeping a copy, then replaces `tape.json` with a generated one, last.
    - It writes 25-second presets to `drum/user/` and `synth/user/`, then deletes them.
    - The scratch tape stays on the OP-1.
  - **In FieldCheck:** **Run level 2 (scratch writes)…** shows the plan and asks before writing. It refuses with no free slot, or with FieldCheck's content left from an earlier run. **Delete FieldCheck's content…** deletes only the scratch tape and the presets, files first and then the folder, as `delete.files-then-folder`, until level 3. Copies go in `level2-<time>` in Documents.
  - **What the simulator showed while building it:** a rebuild shorter than the old `tape.json` lists at the shorter size there. That's a guess, since the probe only saw a longer one, so the run starts from a blank `tape.json` to reproduce the observed case.
  - 240 tests pass on the Mac and the iOS simulator (160 FieldTapeKit, 75 FieldCheckKit, 5 conformance tests). FieldCheck builds for iOS devices, and in the iOS simulator with `-SimulatedOP1 YES` a level 2 run passed all 8 checks.

- **Step 11b is done, and passed on the OP-1 with the long check** (iPad Pro, 2026-11-15, [report](../firmware/1.7.3/runs/fieldcheck-2026-11-15T040647Z.md)). 10 checks passed and the album check didn't run, in 37.8 s. A full 6-minute track was sent at 7.5 MB/s and read back whole at 20.7 MB/s, the first full-size transfer either way. FieldCheck peaked at 543 MB, about two copies of the track above where it started. All 5 audio writes together ran at 7.3 MB/s. Cleanup passed `delete.files-then-folder` again. `album.write-exact` is still unchecked on hardware, since both sides have audio. Decided 2026-11-15, and recorded in the plan and ADR 0003's change log. Level 2 now has 11 checks:
  - **`tape.track-limit`,** the long check, only when asked for with **Write, with the long check**. It replaces `track_2.wav` with a full 6-minute track of 127,008,044 bytes, reads it back, then puts the 2-second tone and `tape.json` back, last. It reports FieldCheck's memory before and at its peak. It's the first full 127 MB transfer on hardware.
  - **`album.write-exact`,** on the first empty side only: copy it, write a 2-second tone, read it back, then put the empty side back. Both sides of this OP-1 have audio, so it will show "not run" here.
  - **`write.speed`,** a new expectation split from `read.speed`: each audio write, timed less a read of the same file. Reported, never failed.
  - 245 tests pass on the Mac and the iOS simulator (160 FieldTapeKit, 80 FieldCheckKit, 5 conformance tests). FieldCheck builds for iOS.

- **Step 12 is split into 12a and 12b** (decided 2026-11-15, recorded in the plan and ADR 0003's change log).
- **Step 12a is done, and passed on the OP-1** (iPad Pro, 2026-11-15, [level 2](../firmware/1.7.3/runs/fieldcheck-2026-11-15T043147Z.md) and [level 3](../firmware/1.7.3/runs/fieldcheck-2026-11-15T043206Z.md) reports). Level 2 passed 9 checks, with 2 not run (the long check, and the album). After a reconnect, level 3 passed all 6: every handle changed, `fieldck #1-2` was kept and `fieldck #2-13` cut to `fieldck #2-1`, the OP-1 added a 104-byte `readme.txt`, and the tracks and `tape.json` were unchanged. **One DeleteObject on the scratch tape's folder deleted it and its 6 files**, so `delete.folder-with-files` is known, and the simulator now does the same. 257 tests pass on the Mac and the iOS simulator (162 FieldTapeKit, 90 FieldCheckKit, 5 conformance tests).
- **How 12a was built:** `LevelThree` in FieldCheckKit has 6 checks: `reconnect.handles`, `names.maximum` (kept after a reconnect), `reconnect.renamed`, `reconnect.kept`, `delete.folder-with-files` and `delete.files-then-folder`.
  - **The flow:** a clean level 2 leaves level 3 waiting, saved as `level3-pending.json` in Documents. FieldCheck says to leave MTP mode and enter it again. On the next connection, **Run level 3 (after the reconnect)…** asks, then checks the scratch tape and deletes it. After a run that didn't finish, FieldCheck instead lists what it left and offers **Delete FieldCheck's content…**.
  - **The simulator now reconnects** (`leaveAndReenterMTPMode`): names lowercase, a `readme.txt` in a tape made over MTP, new handles, and real sizes again. It still refuses DeleteObject on a folder with files in it, so on the simulator level 3 falls back to deleting the files first. The app's `-SimulatedOP1` mode can't reconnect, so the flow in the app is only checked on hardware.
  - 254 tests pass on the Mac and the iOS simulator (161 FieldTapeKit, 88 FieldCheckKit, 5 conformance tests). FieldCheck builds for iOS.

- **The first level 3 run on the OP-1 found that the OP-1 cuts tape names to 12 characters** (iPad Pro, 2026-11-15, [level 2](../firmware/1.7.3/runs/fieldcheck-2026-11-15T042019Z.md) and [level 3](../firmware/1.7.3/runs/fieldcheck-2026-11-15T042129Z.md) reports). Level 2 passed. After the reconnect, `fieldcheck #1-2` was `fieldcheck #`, so level 3 found no scratch tape and ran nothing. Decided by the owner, and recorded in ADR 0002's and ADR 0003's change logs:
  - **FieldTapeKit limits new tape names to 12,** from the firmware profile's new `maximumTapeNameLength`. The simulator cuts tape names to 12 on a reconnect.
  - **The scratch tape is `FIELDCK #1-2`,** and level 2 also makes `FIELDCK #2-13`, sent raw. Level 3 checks the first is kept and the second is cut to `fieldck #2-1`, then deletes both. Level 2 now needs two free slots.
  - **Level 3 keeps waiting when it's refused,** unless the scratch tape is gone, and that refusal lists what `tapes/` holds.
  - 256 tests pass on the Mac and the iOS simulator (162 FieldTapeKit, 89 FieldCheckKit, 5 conformance tests). FieldCheck builds for iOS.

- **Step 12b is done, so step 12 is: the 1.7.3 baseline covers all three levels** (iPad Pro, 2026-11-15, [firmware/1.7.3/baseline.json](../firmware/1.7.3/baseline.json)). One launch ran level 1 (18 pass), the conformance suite (15 of 15), level 2 with the long check (10 pass, the album not run), and level 3 after a reconnect (6 pass), then saved them together. Level 1's figures match the previous baseline on every field that doesn't vary, and the committed-baseline test passes with levels 2 and 3 included. The conformance copies have the same SHA-256s as on 2026-11-14. Decided 2026-11-15, recorded in the plan and ADR 0003's change log:
  - **Baselines are format 2,** with one section per level and the run each came from, so `device.storage` and `names.maximum` keep each level's fields. `Baseline(reports:)` refuses failures, mixed firmware, or two runs of one level. A format 1 file, like the committed 1.7.3 baseline, still reads as level 1.
  - **In FieldCheck,** a Baseline section shows this launch's latest run of each level, kept across reconnects, and **Save as baseline** writes them together. Level 1 is needed, and a level with failures is left out.
  - **The committed-baseline test** now also checks levels 2 and 3 when they're there: the refused name, the preset caps, the long track's size, the 12-character cut, the folder delete and the tape's files.
  - 260 tests pass on the Mac and the iOS simulator (162 FieldTapeKit, 93 FieldCheckKit, 5 conformance tests). FieldCheck builds for iOS.

- **Step 13 is done, and passed on the OP-1** (iPad Pro, 2026-11-15, log `firmware/1.7.3/runs/fieldcheck-2026-11-15T163827Z.txt`). The conformance suite passed 17 of 17. `tapes()` listed all 3 tapes, each sound and Studio: 2026-220#01 (track 4, 62.5 s), 2026-276#01 (all four tracks, 1:00) and 2026-286#01 (tracks 1 and 2, 4.3 s). The lengths match the clips in the `tape.json` files the probe logged on 2026-11-08, and both copies have the same SHA-256s as before. Decided 2026-11-15, recorded in the plan and ADR 0002's change log:
  - **`TapeName`:** lowercase, compared ignoring case. A new name must be one the OP-1 keeps (letters, digits, `#`, `-`, space, at most 12), and its rule is the one `createDirectory(at:)` uses. A listed name is taken as it is.
  - **`TapeManifest`:** `tape.json` kept byte for byte in `data`, with clips, loop, tempo in BPM, `mixerParameters` and `TapeType`. All 11 distinct `tape.json` files the probe logged read and keep their bytes.
  - **`Tape`, `TapeTrack` and `TapeSlots`; `tapes()`, `tape(named:)` and `tapeSlots()`.** Every folder in `tapes/` is a tape. One that isn't sound lists its `problems`, and its manifest is nil without a readable `tape.json`.
  - **`SimulatedTape(…)`** builds a sound tape for tests and previews, with a `tape.json` like the OP-1's. FieldCheck's `-SimulatedOP1` now uses it, so level 1 passes on the simulated OP-1 (17 pass, `read.cost` not run).
  - **The conformance suite** checks that `tapes()` lists every folder and `tapeSlots()` counts them, and that each tape's details agree with its files. It records each tape's type, length and tracks.
  - 277 tests pass on the Mac and the iOS simulator (179 FieldTapeKit, 93 FieldCheckKit, 5 conformance tests). FieldCheck builds for iOS.

- **Step 14 is done** (decided 2026-11-15, recorded in the plan and ADR 0002's change log). It's all local files, so there's nothing to run on the OP-1.
  - **`ReelArchive(contentsOf:)`** opens a `.reelarchive` and checks all of it: exactly a tape's files and `reel.json`, every size and SHA-256, a format it can read, and `tape.json` against the tracks. It refuses with the new `invalidArchive` or `archiveMismatch`.
  - **`extractTrack(_:to:)`** streams one track out to a WAV file, never overwriting, checking its SHA-256.
  - **An internal writer** for step 15 adds one file at a time, hashing as it goes, and writes `reel.json` last. Compression is off by default, with `lz4`, `lzfse`, `zlib` and `lzma` as options. `UTType.reelArchive` is `com.jnjosh.fieldtapekit.reelarchive`, one identifier every app imports, as its documentation shows.
  - **Tests** cover a round trip with each compression, a damaged track, every kind of refusal, extracting, the Mac's `aa extract`, and a kept format 1 fixture.
  - 289 tests pass on the Mac and 288 on the iOS simulator, where the `aa` test doesn't run (191 and 190 FieldTapeKit, 93 FieldCheckKit, 5 conformance tests). FieldCheck builds for iOS.

- **Step 15 passed on the OP-1** (iPad Pro, 2026-11-15, log `firmware/1.7.3/runs/fieldcheck-2026-11-15T193102Z.txt`). The conformance suite passed 18 of 18. `copyTape` copied 2026-276#01 (78 MB, 16 clips) in about 4 s into a 78,328,519-byte archive. On the Mac, `aa extract` took it apart, every track's SHA-256 matched the log, and every track is 44 + 8 × the end of its last clip. **Memory levels off:** FieldCheck starts at about 22 MB. After copying the 78 MB tape it held about 150 MB, but three copies in one launch left 152, 149 and 133 MB, and it fell to 47 MB between them, peaking at 194 MB. On the simulator, copying an 84 MB tape three times kept about 2 MB. So FieldTapeKit's own code holds nothing, and the ImageCaptureCore path keeps transferred data for a while and releases it later: a bounded cost, not a leak. Decided 2026-11-15, recorded in the plan and ADR 0002's change log:
  - **`copyTape(_:to:compression:progress:)`** reads the tape fresh, refuses one that isn't sound, reads each track and then `tape.json` with one GetObject into a hidden temporary archive, lists the tape again, finishes `reel.json`, reopens the archive and checks it against the SHA-256 of what came off the OP-1, and moves it into place as `<tape name>.reelarchive`, never over a file. One track is in memory at a time.
  - **A tape that changes mid-copy is refused,** whether it's caught as a file is read or when the tape is listed again, and nothing is left behind. So is a cancelled copy.
  - **The simulator** has two new faults for this: a file that changes after it's read, and a short read.
  - **The conformance suite** copies the largest sound tape off, and FieldCheck now runs it one check at a time and logs its memory after each.
  - `notAllowed` and `verificationFailed`'s descriptions were reworded to fit copying as well as writing.
  - 299 tests pass on the Mac and 298 on the iOS simulator (201 and 200 FieldTapeKit, 93 FieldCheckKit, 5 conformance tests). FieldCheck builds for iOS.

- **Explore copies tapes** (2026-11-15, asked for by the owner): a tape's folder shows its type, length and recorded tracks, or why it isn't sound, and **Copy tape to this device** saves it to `Documents/explore` as a `.reelarchive` with `copyTape`, with progress and a share button. Explore still never changes the OP-1. Tried in the iOS simulator on the simulated OP-1, not yet on hardware.

## Next steps

1. Step 16: creating and duplicating tapes.
2. `album.write-exact` on hardware, whenever an album side is empty.

## The OP-1 right now

- Firmware 1.7.3, with 3 of the 8 tape slots used (2026-11-13), after the owner removed the rest on the OP-1. FieldCheck's level 2 needs two free slots. The owner deleted `tapes/fieldcheck #`, left from the first level 3 run, on the OP-1, and level 3 then deleted everything FieldCheck made.
- Which 3 tapes are left isn't recorded, so don't assume the probe's blank tape `tapes/2026-312#01` is still there.
- Paired test devices: an iPad Pro 11-inch (M4), iPadOS 27.2, and an iPhone 17 Pro, iOS 27.0.1. Their IDs and the commands for pulling logs are in PROBE-NOTES.md.
- Paused: switching into MTP mode over MIDI. Its code was removed. The bytes and the Mac tools are kept in `research/`.
