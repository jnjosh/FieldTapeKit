# ADR-0003: A repeatable firmware check for the OP-1 Field

**Status:** Accepted
**Date:** 2026-11-08

- **Builds on:** [ADR 0001](0001-op1-field-ios-transport.md) (transport, accepted) and [ADR 0002](0002-op1-field-public-api.md) (FieldTapeKit's API, accepted)

## Context

FieldTapeKit depends on how OP-1 firmware 1.7.3 behaves: which MTP operations it lists, which names each folder accepts, the `tape.json` format, the OP-1 rebuilding `tape.json` after a track write, stale sizes within a session, lowercased names, and more. ADR 0002's simulator copies those behaviors, and its safety rules rely on them.

All of that was learned with the probe app, which grew one exploratory button at a time. It works, but it can't answer the question that matters after a firmware update: **does the OP-1 still behave the way FieldTapeKit assumes, and if not, what exactly changed and what code depends on it?**

Some probe tests also changed the user's own content (the mixdown write-back, and copies onto a user tape). That was fine once, deliberately and with backups, but a routine check can't do it.

## Decision

Build **FieldCheck**, an app that runs a fixed list of checks against a connected OP-1 and compares the results with a saved baseline for a known firmware. It replaces the probe app as the way to test the device. The probe stays in the repository, frozen, as a record.

### 1. Expectations: one list of what FieldTapeKit assumes

Every behavior FieldTapeKit depends on becomes an **expectation** with a stable ID, a description, what's checked, and which parts of FieldTapeKit rely on it. The same list is used in three places:
- **FieldCheck** checks each expectation against a real OP-1.
- **The simulator** (ADR 0002, section 8) implements each one. Its tests are written against the same IDs.
- **Baselines** record what each expectation observed on a given firmware.

So when a check comes back different, its "used by" entry points straight at the code to change, and the simulator test with the same ID shows how to update the simulator.

The first list, from the probe's findings:

| ID | Expectation | Used by |
| --- | --- | --- |
| `device.operations` | The 21 operations logged on 1.7.3: 16 standard ones and 0x9801–0x9805. No MoveObject or CopyObject. | Replace is delete-then-send; duplicate copies through memory |
| `device.storage` | One storage, `0x00010001`. GetStorageInfo answers, and its free space falls by about the size of what level 2 writes, and rises again after cleanup. | Device info; free-space checks once the figure is trusted (ADR 0002, section 1) |
| `device.identity` | USB vendor 0x2367, MTP product 0x0102, the name "OP-1". | `FieldDevice.connections` filter |
| `session.implicit` | ImageCaptureCore's session is enough; no OpenSession. | Transport |
| `session.data-phase` | Data arrives without the 12-byte container header. | PTP parsing |
| `layout.folders` | `tapes/`, `mixdown/`, `synth/`, `drum/` exist, with the subfolders seen on 1.7.3. | `FilePath` well-known locations, safety rule 4 |
| `layout.readmes` | The text of every `readme.txt` matches the baseline. | Folder rules |
| `names.lowercase` | Names on the device are stored lowercase. | Case-insensitive paths, `TapeName` |
| `names.maximum` | A new tape with a 12-character name, using every kind of allowed character, is accepted over MTP and kept after a reconnect. A 13-character name is accepted, then cut to 12 after a reconnect (2026-11-15). | `TapeName.maximumLength` |
| `tape.files` | Each tape has `tape.json`, `track_1`–`4.wav`, and maybe `readme.txt`. Nothing else. | `Tape` |
| `tape.wav-format` | Tracks are 44-byte-header PCM WAV: 2 channels, 32 bits, 44.1 kHz. | Track sizes, consistency check |
| `album.files` | `mixdown/` holds exactly `side_a.wav` and `side_b.wav`, and an empty side is the 44-byte header. | `Album`, `AlbumSide.isEmpty` |
| `album.wav-format` | Sides are PCM WAV, 2 channels, 16 bits, 44.1 kHz. | `AlbumSide.format`, the restore format check |
| `album.write-exact` | A side written back reads back byte for byte. | `restoreSide` |
| `album.write-kept` | A side written over MTP is still there after leaving MTP mode and coming back. **Not yet known:** a side deleted over MTP comes back (PROBE-NOTES.md, 2026-11-16). | `restoreSide` |
| `album.write-other-format` | What the OP-1 does with a side written in another format, such as 32-bit. **Not yet known.** | The restore format check |
| `album.write-again` | A side written over MTP can be written again over MTP after a reconnect. **Not so on 1.7.3:** SendObjectInfo hangs the OP-1 until it's restarted, at any length, until the side is recorded over on the OP-1 (2026-11-16). Album writing is off until it's understood. | `restoreSide`, writes to `mixdown/` |
| `album.side-limit` | The longest side the OP-1 takes. **Not yet known:** FieldTapeKit refuses a side over 6 minutes, as a tape. | The restore length check |
| `tape.json-keys` | `tape.json` has exactly the known keys and versions. Unknown keys are reported. | `TapeManifest` |
| `tape.json-units` | Every track is `44 + 8 × last clip end` bytes; `ch` is 0-based. | Consistency check |
| `tape.types` | `tape_type` values are 0–3. | `TapeType` |
| `tape.track-limit` | A full 6-minute track of 127,008,044 bytes can be written and read back. Runs only when asked (section 2). | `tapeTooLong`, upload memory use |
| `read.partial` | GetPartialObject works at any offset with chunks up to 1 MiB. | `contents(of:range:)`, WAV header reads |
| `read.speed` | Reads at about 20 MB/s. A big drop is reported, not failed. | Timeouts, progress estimates |
| `write.speed` | Writes at about 7 MB/s, timed apart from the read-back. A big drop is reported, not failed. Split from `read.speed` on 2026-11-15. | Timeouts, progress estimates |
| `read.cost` | What a GetPartialObject's time grows with: its offset, or the number of reads before it. On 1.7.3 it's the offset. Added 2026-11-14. | Whole files read with one GetObject (ADR 0002, 2026-11-14) |
| `write.folder` | A tape folder can be made with SendObjectInfo alone (format 0x3001, association type 1). | `createTape`, `restoreTape` |
| `write.exact` | Tracks and `tape.json` written to a tape read back byte for byte. | Read-back verification |
| `write.refused-name` | A name a folder doesn't allow (`track_5.wav`) is refused with 0x2002. | Folder rules |
| `write.preset-converted` | Audio written to `drum/user/` or `synth/user/` comes back as AIFC under the same name, in the same format, with the same samples as the start of what was sent (cut to 20 s in `drum/user/` and 6 s in `synth/user/`). The format code stays the one it was sent with. | Preset writes: the read-back checks the audio |
| `rebuild.tape-json` | After a track write, the OP-1 rebuilds `tape.json` (one clip per track). | Restore order: tracks first, `tape.json` last |
| `rebuild.stale-size` | Within the session, the rebuilt `tape.json` still lists, and reads, at its old size. | Fresh info before every read |
| `delete.files-then-folder` | Deleting a tape's files, then its folder, removes it. | `deleteTape`, `moveTape` |
| `delete.folder-with-files` | What one DeleteObject on a folder with files in it does. On 1.7.3 it deletes the folder and its files (2026-11-15). | Could simplify `deleteTape` |
| `reconnect.kept` | After leaving MTP mode, a written tape and its `tape.json` are kept, apart from `pos`. | Restore |
| `reconnect.renamed` | After reconnecting, a created tape's name is lowercase and `readme.txt` has been added. | `TapeName`, `Tape` |
| `reconnect.handles` | Object handles change after reconnecting. | Handles stay private |

New expectations are added when FieldTapeKit starts relying on something new. Removing one needs a note on why.

### 2. Three levels, from harmless up

**Level 1: read only.** This is the default, and it changes nothing on the OP-1. It runs every expectation that only needs reading: device, storage, layout, readmes, names, every tape's files and `tape.json`, the WAV format, partial reads, and speed. It takes under a minute.

**Level 2: scratch writes.** These run only on things FieldCheck makes itself:
- **A scratch tape** named `FIELDCK #1-2`, stored as `fieldck #1-2`. It's 12 characters, FieldTapeKit's maximum and the most the OP-1 keeps, and uses letters, digits, `#`, `-` and space, so making it also checks `names.maximum`. It needs one free slot of the 8, and FieldCheck refuses to start this level without one, saying so. It never writes to a tape it didn't create.
- **Generated content.** The tracks are short synthetic tones, about 2 seconds each, and `tape.json` is generated with several clips, a loop, a custom tempo and a non-default type. Its `padding` values are all `-1`, as on a tape the OP-1 rebuilt. No user audio or `padding` is copied (Alternatives Considered).
- **A small generated WAV** at `drum/user/fieldcheck.wav`, deleted afterwards.
- **Free space** is read before the first write, after the last one, and after cleanup, for `device.storage`.
- **The long check**, off unless asked for: one full 6-minute track of 127 MB, to check `tape.track-limit` and memory use. It adds about 25 seconds of transfer. A person turns it on for a run; it isn't part of every firmware update.
- **Write speed:** the audio writes are timed for `write.speed`.

**Level 3: after a reconnect.** Some behaviors only show after leaving MTP mode:
1. After level 2, FieldCheck asks the person to leave MTP mode on the OP-1. Optionally they can play the scratch tape to hear the tones.
2. They reconnect.
3. FieldCheck checks the `reconnect.*` expectations and the rest of `names.maximum`.
4. It deletes the scratch tape, and that delete is the `delete.folder-with-files` check: one DeleteObject on the tape's folder with its files still in it. If the OP-1 refuses, FieldCheck deletes the files first, then the folder, as before, and records both results. The scratch tape holds only generated content, so nothing is at risk.

It remembers a pending level 3 across app launches. If it finds a scratch tape left from an interrupted run, it offers to delete it before doing anything else.

**The album is written only where album writing is on, and it's off on 1.7.3** (`album.write-again`, Change Log 2026-11-16). Where it's on, level 2 writes over side B if it has audio, or else side A, last of all its checks: it copies the side into the run's folder and verifies it, writes a tone of exactly the side's length with `restoreSide`, and reads it back (`album.write-exact`). Level 3, after the reconnect, reads the side (`album.write-kept`), and if the tone lasted, puts the side back from the copy with a confirmation. It does this after the tape checks, whatever they found, and even if the scratch tape is gone. If a side is left holding FieldCheck's tone, FieldCheck offers to put it back from level 2's copy, tracing every MTP request: the one album write it makes on 1.7.3, after a person confirms.

### 3. Safety

FieldCheck follows ADR 0002's safety rules, plus these:
- It reads anything, but writes and deletes only the scratch tape `tapes/fieldck #1-2`, the 13-character tape `tapes/fieldck #2-13` (`fieldck #2-1` once cut), `drum/user/fieldcheck.wav`, and one album side, which it copies off and verifies first and puts back in level 3 (section 2).
- Before level 2, it lists exactly what it will create and delete, and the person confirms.
- It stops at the first unexpected write result, leaves the scratch content for cleanup, and reports what it did.
- It never sends MIDI, vendor operations, or anything not listed in ADR 0002, safety rule 7.

### 4. Baselines and reports

- **Baselines** live in the repository, one per firmware: `firmware/1.7.3/baseline.json`. Each records what every expectation observed, such as the operation list, readme texts, `tape.json` keys and measured speeds. A field can be marked as expected to vary, for example speeds within a range.
- **The first baseline** comes from a FieldCheck run on 1.7.3, checked against [PROBE-NOTES.md](../../research/PROBE-NOTES.md).
- **Each run gives every expectation a result:**
  - **pass:** matches the baseline.
  - **changed:** works, but differs from the baseline. It shows the old and new values.
  - **fail:** the behavior FieldTapeKit relies on is gone.
  - **not run:** with the reason, such as "both album sides have audio" or "the long check wasn't asked for".
- **The report** starts with the firmware, OS and device, then the changes and failures, each with its "used by" entry. Everything else follows below.
- **Where reports go:** each run saves a report as JSON and Markdown in the app's Documents folder, which is visible in Files, and can be shared. Reports from real firmware go into `firmware/<version>/`.
- **Where FieldCheck gets them:** FieldCheckKit has each baseline built in, a copy of `firmware/<version>/baseline.json` in `Sources/FieldCheckKit/Baselines/`, and a test fails if a copy differs from the repository's. A new firmware's baseline means rebuilding FieldCheck, as its new profile does.
- **Which baseline a run compares against:** the baseline for the OP-1's firmware if there is one. Otherwise it's the one FieldTapeKit would use as that firmware's profile: the newest tested firmware older than it (ADR 0002, section 11).
- **Save as baseline:** once a change has been reviewed, and FieldTapeKit and its simulator are updated, this action writes the runs as the baseline for the new firmware: the launch's latest clean run of each level, one section per level. It's added next to the old baselines and never replaces one, because FieldTapeKit keeps supporting their firmware. Each baseline is also the source of that firmware's profile and its simulator.
- **A draft ADR** comes with any run that finds a change or a failure (section 5).

The workflow after an update:
1. Update the OP-1's firmware.
2. Run FieldCheck: levels 1 to 3 in one go, a few minutes plus a reconnect. Turn on the long check if the track limit or memory use is in question.
3. Read the report and the draft ADR. Each change names the FieldTapeKit code and simulator test it affects, and what it means for each group of people it can affect.
4. Decide, fill in the draft, and move it into `docs/adrs/` with the next number. It's accepted like any ADR, by the owner.
5. Make the changes, with a new profile if the firmwares differ. Re-run until it passes, then save the new baseline.
6. Release with the version bump the ADR names: minor to add the firmware, or major if an old one is dropped.

### 5. A draft ADR for each firmware change

When a run finds any `changed` or `fail` result, FieldCheck also writes `draft-adr.md` next to the report. It follows the repository's ADR template, starts as **Proposed**, and is numbered `NNNN`, because FieldCheck runs on the iPad and can't see the repository. FieldCheck fills in what the run measured. Deciding is left to a person, or to an agent working from the report and the code.

**What FieldCheck fills in:**
- **Context:**
  - The two firmwares compared, the device and the OS.
  - Every changed or failed expectation: its old and new values, its "used by" entry, and its simulator test.
- **A suggested compatibility class for each change,** marked as a suggestion to confirm:
  - **Additive:** something new appeared alongside what was there, such as a new operation, `tape.json` key or tape type. Usually one code path can handle both firmwares.
  - **Divergent:** a value changed or disappeared, but the behavior FieldTapeKit relies on still works. Each firmware gets its own profile.
  - **Incompatible:** a `fail`: the behavior is gone on the new firmware. Supporting it may mean a different approach, or dropping the old firmware.
- **A compatibility table for each change,** with one row for each group of people it can affect. FieldCheck fills in what it measured, and the rest stays a question:

| Who | Question for the person deciding |
| --- | --- |
| People on the old firmware, using the release that supports the new one | Does their firmware keep its own behavior and tests? Does anything they do change? The old baseline and its simulator answer most of this. |
| People on the new firmware, using an older release | They get the untested-firmware warning (ADR 0002, section 11). What does the old behavior FieldTapeKit assumes do on their OP-1 now, and can the safety rules catch it? |
| Archives made on the old firmware, restored onto the new | Does the new firmware accept them as they are? |
| Archives made on the new firmware, restored onto the old | Does the old firmware cope with what's new, such as an unknown `tape.json` key? |
| Apps using FieldTapeKit | Is the version bump minor (an added or divergent firmware), or major (a dropped firmware, an API break, a new archive format, or looser safety)? |

**What it leaves for a person:**
- Decision, Alternatives Considered and Consequences start as prompts, with the affected code listed under each change.
- FieldCheck makes no recommendation of its own.
- A draft is never treated as accepted. The owner reviews it, and accepting it follows the repository's working agreement, as for any ADR.

FieldCheck measures only the firmware installed, so the old-firmware rows come from the old baseline and the simulator, not from hardware.

### 6. Code and platforms

- **Where it lives:** FieldTapeKit will be a new project at the root of the repository, and FieldCheck lives there with it, not in `research/`.
  - **In the package:** FieldCheck's checks are a library target in the FieldTapeKit package, with `package` access to its PTP layer. The PTP layer starts from the probe's code, which is copied out of `research/OP1Probe/OP1ProbeApp.swift`. The probe itself stays untouched.
  - **The app:** a thin shell over that library.
  - **The expectation list** lives in FieldTapeKit, next to the simulator that implements it.
- **Checks are plain functions** over a small device interface, each returning a result for one expectation ID. They don't depend on any UI, so their logic can be unit-tested against recorded device replies.
- **The report and the draft ADR** are built from the run's results, also without UI. They're unit-tested against recorded runs, including one with changes in every compatibility class.
- **Order:** the PTP layer and the level 1 checks come first, so FieldCheck can record the 1.7.3 baseline before the rest of FieldTapeKit is built on it.
- **Platforms:** iOS and iPadOS 27 first, since that's where every behavior was observed. A macOS build of the same app is ADR 0002's first Mac test. Running FieldCheck on a Mac answers whether raw PTP works there.

## Alternatives Considered

- **Keep growing the probe app.** Rejected: its buttons are one-off experiments with no baseline to compare against, and some of them change the user's content. It stays frozen as the record of how the behaviors were found.
- **Rely on the simulator and unit tests alone.** Rejected: the simulator is only as faithful as what was observed. Nothing would notice a firmware update that changes a behavior.
- **Checks that write to the user's tapes or album.** Rejected for tapes: routine checks must never touch the user's music, so FieldCheck writes only to tapes it created. For the album, reversed on 2026-11-16 (Change Log): the OP-1 can't empty a side, so a check limited to an empty side would never run, and only a write can show whether a written side lasts. One side is written after a verified copy, and put back.
- **Checking `album.write-kept` within one connection.** Rejected (2026-11-16): a side deleted over MTP comes back after a reconnect, so only a reconnect can show whether a written side lasts. The conformance suite runs within one connection.
- **A second scratch folder for `delete.folder-with-files`.** Rejected: under `tapes/` it would need a second free slot, and no other folder the safety rules allow could hold it. The check runs on the scratch tape's own deletion instead (section 2, level 3).
- **The long check on every run.** Rejected by the owner: it adds about 25 seconds, and the track limit rarely needs checking. It runs when asked.
- **Trying scratch names longer than 15 characters.** Rejected: it could leave a tape the OP-1's screen shows badly, and FieldTapeKit never makes a longer name anyway. The scratch tape uses exactly 15.
- **Copying a real tape's `padding` values onto the scratch tape.** Rejected: if `padding` refers to data stored elsewhere on the OP-1, deleting the scratch tape at the end of level 3 might disturb the real tape that shares the values. Testing shared `padding` needs its own experiment, with the real tape archived and verified first.
- **A report with no draft ADR.** Rejected: every firmware change needs a decision record anyway, and starting it from the report's evidence, with the compatibility questions already asked, keeps any of them from being missed.
- **FieldCheck recommending the change itself,** from guidance each expectation records in advance. Rejected by the owner: that advice would be written before the change was seen. A person decides, or an agent working from the report.
- **Replacing the baseline on each update.** Rejected: FieldTapeKit keeps supporting old firmware (ADR 0002, section 11), so every baseline stays as that firmware's record and profile.
- **A Mac-only command-line tool.** Rejected: every behavior was observed on iOS and iPadOS, and macOS raw PTP is untested. An app that also builds for macOS covers both.

## Consequences

**Positive**
- A firmware update gets a clear answer in minutes: what changed, and what in FieldTapeKit depends on it.
- The simulator, the framework's assumptions and the device checks share one list, so they can't drift apart without a test noticing.
- Routine checks never touch the user's music.
- It answers open questions along the way: `delete.folder-with-files`, free space, and whether the OP-1 accepts a 15-character name over MTP.
- Every firmware change starts its ADR with the evidence and the compatibility questions already in place, including what happens to people who don't update.

**Negative / risks**
- Level 2 needs a free tape slot, so a full OP-1 can only run level 1 until a tape is moved off.
- Generated content may miss behavior that only real recordings trigger. The level 1 reads of real tapes cover the formats, but not, say, how the OP-1 treats copied `padding` values. That stays a known risk in ADR 0002.
- Level 3 needs a person to leave MTP mode and reconnect, so a full run can't be automated.
- The track limit isn't checked unless someone asks for the long check.
- If one DeleteObject on the scratch tape's folder half-works, the scratch tape may need cleaning up by hand on the OP-1. It holds only generated content.
- The suggested compatibility class is a heuristic from the kind of difference. A person has to confirm it.
- Only the installed firmware can be measured. After an update, the draft's old-firmware answers rely on the old baseline and the simulator.
- Carrying the PTP code into the package is the first refactor of code that has only ever been tested on a device. 16 of the probe's 21 tests move with it and must still pass: 12 for the PTP layer, and 4 for the tape checks. The other 5 test the probe's own test plans, which don't move, so they stay with the probe.

## Change Log

- **2026-11-08:** Restructured to the ADR template, with Alternatives Considered and this log.
- **2026-11-08:** Open questions settled by the owner:
  - **Name:** FieldCheck.
  - **The long check:** only when asked, not every run. It's now the `tape.track-limit` expectation.
  - **Long scratch names:** the scratch tape's name is exactly 15 characters, FieldTapeKit's maximum (ADR 0002), and nothing longer is tried. That's the new `names.maximum` expectation, and the scratch tape is renamed from `fieldcheck` to `fieldcheck #1-2`.
  - **Copied `padding`:** left out. Generated `tape.json` has `padding` all `-1`.
- **2026-11-08:** `delete.folder-with-files` moved from a second scratch folder, which would have needed a second tape slot, to the scratch tape's own deletion in level 3. `device.storage` now also checks the free-space figure is accurate, for ADR 0002's free-space decision.
- **2026-11-08:** Added section 5, decided by the owner, and renumbered Code and platforms to section 6. A run with changes or failures writes a draft ADR, with a suggested compatibility class and a compatibility table for each change, and leaves the decision to a person. Baselines are now kept for every firmware, to match ADR 0002, section 11.
- **2026-11-08:** Accepted by the owner.
- **2026-11-09:** Corrected the number of probe tests that move into FieldTapeKit from 21 to 16, as the implementation plan records.
- **2026-11-14:** Added `read.cost`, decided by the owner. Level 1 found that 1 MiB GetPartialObject chunks read in order get slower with the offset (PROBE-NOTES.md, 2026-11-13), and how FieldTapeKit reads whole files will depend on why. The check reads the same chunks in reverse, then all of them in one GetPartialObject, then the whole file in one GetObject, and reports whether the time grows with the offset or with the number of reads. It's a level 1 check, so every firmware update re-checks it, and the 1.7.3 baseline is saved again with it. On 1.7.3 it found the offset, and ADR 0002 now reads whole files with one GetObject. `read.partial`'s "used by" changed with it, since nothing streams in chunks any more.
- **2026-11-14:** Decided by the owner while building step 11a of the plan, level 2's first half:
  - **Step 11 is split.** 11a is the scratch tape, the refused name, the rebuild, presets, replacing and deleting, and free space. 11b is the album checks, the long check and write speed. Both album sides on the owner's OP-1 have audio, so 11b's album checks couldn't run yet anyway.
  - **The rebuild is checked within the session,** since a reconnect clears stale sizes. The scratch tape starts with a new tape's `tape.json`, the one the probe read from a blank tape. The tracks written after it make the OP-1 rebuild it longer, which is the case the probe saw read back truncated at its old size (`rebuild.tape-json`, `rebuild.stale-size`). Then `track_1.wav` is replaced with `.replace(keepingCopyAt:)`, and `tape.json` with the generated one through `.replace(confirmed:)`, last. So both kinds of replace run on hardware, and the tape ends as generated for level 3's `reconnect.kept`.
  - **Until level 3 exists,** FieldCheck has a **Delete FieldCheck's content** button. It deletes only `tapes/fieldcheck #1-2` and the two presets, files first and then the folder, through `prepareToRemove` and `removeItem`, and reports it as `delete.files-then-folder`. Level 3 in step 12 replaces it with the `delete.folder-with-files` check.
  - Also settled while building it:
    - Level 2 stops at its first failure of any kind, not only a failed write, and leaves what it made.
    - It refuses to start, changing nothing, if no tape slot is free or FieldCheck's content from an earlier run is on the OP-1.
    - All four tracks are tones, because `tape.files` and `tape.json-units` expect every track to be there and to match its clips.
    - `write.refused-name` is sent raw, because FieldTapeKit refuses `track_5.wav` before sending.
    - `device.storage` records free space before, after the writes and after the presets are deleted, without judging how close it comes. Judging waits for the comparison in step 22.
    - Copies of the replaced track and the drum preset go in a `level2-<time>` folder in Documents.
    - Baselines still cover level 1 only.
- **2026-11-15:** Decided by the owner while building step 12b of the plan, baselines for all three levels:
  - **A baseline has one section per level** (format 2), each with the run it came from. `device.storage` is checked at levels 1 and 2, and `names.maximum` at levels 2 and 3, with different fields, so one map by expectation would lose one of each. Step 22 compares a run with the same level's section. A format 1 baseline is still read, as level 1.
  - **FieldCheck saves it,** from this launch's latest run of each level, kept across reconnects since level 3 always runs on a new connection. Level 1 is needed, and a level with failures, or from another firmware, is left out.
  - **The 1.7.3 baseline is saved again from a fresh run of all three levels,** with the long check, on the same build.
- **2026-11-15:** Level 3 passed on the OP-1, all 6 checks. `delete.folder-with-files` is no longer unknown: one DeleteObject on the scratch tape's folder deleted it and its 6 files, and none of the files' handles answered afterwards. The simulator now does the same, and a refused folder delete is a test fault. Whether `deleteTape` uses it is step 18's decision.
- **2026-11-15:** **The scratch tape is now `FIELDCK #1-2`, 12 characters, and level 2 also makes `FIELDCK #2-13`, 13 characters,** decided by the owner. The first level 3 run found the OP-1 had cut `fieldcheck #1-2` to `fieldcheck #` after the reconnect, so 15 was more than it keeps, and ADR 0002 now limits new names to 12. This reverses part of "Trying scratch names longer than 15 characters" under Alternatives Considered: one name over the limit is now tried on purpose, to check where the OP-1 cuts, and it's deleted in level 3. Its first 12 characters differ from the scratch tape's, so the cut can't collide with it. Level 2 now needs two free slots. Sent raw, since FieldTapeKit refuses it, and filled like the scratch tape. `names.maximum` passes in level 3 only if the 12-character name is kept and the 13-character one is cut to its first 12.
  - Level 3's refusal now lists what `tapes/` holds when the scratch tape is gone, and only that refusal ends a waiting level 3. The first run's refusal cleared it, and FieldCheck lost track of the cut tape. `delete.files-then-folder` now always runs, since the cut tape is always left for it.
- **2026-11-16:** Decided by the owner while building step 22 of ADR 0002's plan, comparing with the baseline:
  - **The baselines are built into FieldCheckKit** (section 4), since FieldCheck runs on the iPad and can't read the repository. Bundling them in the app was rejected, since FieldCheckKit's tests couldn't use them, and picking one from Files, since it's a step every run and easy to get wrong.
  - **Fields that vary are left out of the comparison,** as the baseline and the run mark them, with no ranges. A range was rejected for now: today's write speeds varied from 4.0 to 4.3 MB/s against the probe's 7, so a range would flag noise. The checks still fail on what matters.
  - Also settled while building it:
    - Each level's report is compared with the built-in baseline for its firmware, or the closest one, as section 4 says, as soon as it runs. A pass that observed something else becomes `changed`, with each difference's path, old and new values, and a suggested class. A difference is additive if only something new appeared (a key, or a list that kept every element and gained more), and divergent otherwise. A fail suggests incompatible.
    - A check the baseline has no result for, or one it didn't run, still passes, with a note. A baseline without the run's level compares nothing, and says so.
    - The report says what it was compared with, and lists failures, then changes, then checks that didn't run, then passes. It's saved with `fieldcheck-<time>.draft-adr.md` beside it when it has a change or a failure.
    - A changed run can still be saved as a baseline, once reviewed. A failed one can't.
    - `write.speed` now marks `bytes` and `writes` as varying: comparing the real runs found they depend on whether the long check ran, which the 1.7.3 baseline's level 2 did.
  - **From the runs on the OP-1,** decided by the owner: levels 1 and 2 matched the baseline with 0 changed, and the 1.7.3 baseline stays as it is, since a new one from today has no level 3. A check the OP-1 stopped answering during gets no draft ADR, since a hang says nothing about the firmware, and the report says the run stopped. FieldCheck no longer reads the album when an OP-1 connects, traces every MTP request from the moment it connects, and logs a timed-out request's late answer as soon as it arrives.
- **2026-11-16:** Decided by the owner: **album writing is off on 1.7.3, as a future improvement.** After the hang that suggested a side can't grow, level 3 put side B back at exactly the same length, and that hung too, so growth wasn't the cause. Every side write that hung was over a side written over MTP in an earlier connection, and every one that worked was over a side recorded on the OP-1 (PROBE-NOTES.md). `album.side-grow`, added for the growth rule, is replaced by `album.write-again`. Level 2 doesn't write the album where album writing is off, so levels 2 and 3 don't check `album.write-exact` or `album.write-kept` on 1.7.3. A warm-up write before the put-back showed it isn't the first write after a reconnect. FieldCheck keeps the last 50 MTP requests during every run and logs them when one gets no answer. Its put-back of a side holding its tone is the one album write it makes, after a confirmation.
- **2026-11-16:** (Superseded the same day by the entry above.) The owner first decided a side can't grow, after three hangs, each writing a side longer than the one it replaced.
- **2026-11-16:** The first run of the album check on the OP-1 showed a written side lasts (`album.write-kept`), but level 3 hung putting side B back, and the report kept only "disconnected". Decided by the owner: FieldCheck gets "Put the side back from level 2's copy", offered when a side holds FieldCheck's tone and level 3 isn't waiting for it. It writes only over that tone, after a confirmation, with `restoreSide`, and logs every MTP request with its response and time, through a package-only trace on FieldTapeKit's session. It's a narrow exception to section 3's list: it writes only a side FieldCheck itself overwrote, from FieldCheck's own copy.
- **2026-11-16:** For step 21 of ADR 0002's plan, decided by the owner:
  - **FieldCheck writes over an album side with audio, after a verified copy,** reversing "only when one is empty" in sections 2 and 3. The owner found the OP-1 can't empty a side, only record over it, so the old check could never run. And a side deleted over MTP with the macOS companion app came back once the OP-1 left MTP mode (PROBE-NOTES.md), so whether a written side lasts is unknown, and `restoreSide` depends on it.
  - **A new expectation, `album.write-kept`, checked across levels 2 and 3.** Level 2 copies side B, or an empty side if there is one, writes a tone over it, and reads it back. Level 3 checks the tone lasted, then puts the side back from the copy. A check within one connection, in the conformance suite, was tried and dropped, since it can't show this.
  - **Side B, the owner's smaller side,** when neither is empty.
  - **A new expectation, `album.side-limit`,** for the longest side the OP-1 takes, which isn't known. FieldTapeKit refuses a side over 6 minutes until it is.
  - Also settled while building it: the album check is level 2's last, so an earlier failure leaves the album untouched. Level 3's album check runs after the tape checks, whatever they found, and also when the scratch tape is gone, which is then no longer a refusal. Deleting FieldCheck's leftovers keeps level 3 waiting when a side is to be put back. `Pending` records the side and its copy's folder, name and SHA-256, and level 3 refuses to write from a copy that's missing or changed. The simulator now holds the OP-1's own album: a deleted side is back after a reconnect, and a written side lasts unless a test fault says the OP-1 keeps its own.
- **2026-11-16:** The reading checks gain one, for step 20 of ADR 0002's plan: it copies the album off with `copyAlbum`, matches each side with audio by SHA-256 and by its header against the OP-1, checks `side(_:matches:)`, checks an empty side is `notFound`, and deletes the copies. With both sides empty it's skipped.
- **2026-11-16:** The writing checks gain a sixth, for step 19 of ADR 0002's plan: it makes the empty scratch tape, restores the smallest tape's archive over it, archiving it first, then restores that archive of the empty tape back over it with a confirmation, and matches each result to its archive by SHA-256.
- **2026-11-16:** The writing checks gain two, for step 18 of ADR 0002's plan, each on a duplicate of the smallest tape with audio as `tapes/conformance`: one moves it off into a temporary archive, matches the archive to the source by SHA-256, and deletes the archive; one deletes it keeping the source as its copy, and reports how long matching took. The scratch tape is now deleted with `prepareToDelete` and `deleteTape(_:)`, unless the check already deleted it.
- **2026-11-15:** The writing checks gain a third, for step 17 of ADR 0002's plan: the smallest tape with audio is copied into a temporary archive, restored as `tapes/conformance`, checked against the archive, and deleted with the archive.
- **2026-11-15:** Validate can run the conformance suite's **writing checks**, decided by the owner for step 16 of ADR 0002's plan. They're separate from the read-only suite, and FieldCheck asks first. Each makes the scratch tape `tapes/conformance` in a free slot, with `createTape` or `duplicateTape` from the person's smallest tape, checks it and deletes it. The person's tapes are only read. A leftover `tapes/conformance` is skipped, never deleted.
- **2026-11-15:** Explore can copy a whole tape off, asked for by the owner. A tape's folder shows what `tapes()` makes of it, and a sound tape can be copied to `Documents/explore` as a `.reelarchive` with `copyTape`, with progress and a share button. It still never changes the OP-1, so Explore stays read-only.
- **2026-11-15:** Decided by the owner while building step 12a of the plan, level 3:
  - **Step 12 is split.** 12a is level 3 and the reconnect flow. 12b makes baselines from several reports, so the 1.7.3 baseline can cover all three levels.
  - **Only a level 2 run with no failures leaves level 3 waiting.** FieldCheck saves it in Documents with the scratch tape's handles, so it survives a relaunch. After a run that stopped partway, FieldCheck offers to delete what it left instead. The **Delete FieldCheck's content** button now shows only then.
  - **`reconnect.kept` allows `pos` and `tempometronomelevel` to change,** and records both. The probe saw the metronome level change on a copied tape, perhaps as a global setting, and restore doesn't depend on either.
  - Also settled while building it:
    - Level 3 refuses, changing nothing, on the connection level 2 ran on, on another OP-1, or when the scratch tape is gone.
    - It stops at its first failure, and leaves the tape for cleanup. A relaunch without leaving MTP mode shows up as `reconnect.handles` failing, with every handle the same.
    - `reconnect.handles` records only how many handles changed, since the handles themselves differ every run.
    - `delete.folder-with-files` sends one raw DeleteObject on the folder, then checks the folder and each file's handle. A refusal that deleted nothing passes, and so does deleting everything. Files left without their folder fail, and are deleted by handle.
    - `delete.files-then-folder` deletes what's left through FieldTapeKit, or is "not run" when nothing is.
- **2026-11-15:** Decided by the owner while building step 11b of the plan, level 2's second half:
  - **Only `album.write-exact` is built.** On the first empty side, `side_a.wav` then `side_b.wav`, level 2 reads the side, checks it's still the 44-byte empty header, and replaces it with a 2-second 16-bit tone, keeping a copy. It reads the tone back, then puts the empty side back through a confirmation and reads that back too. With audio on both sides, it's "not run", and the plan says so. `album.write-other-format` stays unknown, since FieldTapeKit refuses other formats and nothing relies on what the OP-1 does with them.
  - **The long check replaces, then restores.** It replaces `track_2.wav` with a full 6-minute track of 127,008,044 bytes, through a confirmation, reads it back whole, then puts the 2-second tone back and `tape.json` again, last. So the scratch tape ends the same with or without it. It reports FieldCheck's memory before it and at its peak. FieldCheck asks for it with a second button in the level 2 confirmation.
  - **Write speed is its own expectation,** `write.speed`, split from `read.speed`, because only level 2 writes. FieldTapeKit's write reads the file back before it returns, so each audio write is timed, then a read of the same file, and the send is the difference. It's reported, never failed.
- **2026-11-15:** The first level 2 run on the OP-1 passed. `write.preset-converted` now states the cap it found in `synth/user/`, 6 seconds, and that a converted file keeps the format code it was sent with.
- **2026-11-14:** `write.preset-converted` now covers `synth/user/` as well as `drum/user/`, and the samples as well as the format, because step 9b's read-back relies on both (ADR 0002's change log). Level 2 writes to `synth/user/` too, since nothing has been written there yet.
- **2026-11-14:** Decided by the owner: FieldCheck has two tabs. **Validate** holds the checks, baselines and conformance suite. **Explore** is a low-fidelity browser of the OP-1 built only on FieldTapeKit's public API, so FieldTapeKit gets used the way an app uses it, and a change can be tried by hand. Explore is **read-only**: it lists, shows details and copies files to the device, and section 3's limit on writes is unchanged. Letting it write would need its own decision.
