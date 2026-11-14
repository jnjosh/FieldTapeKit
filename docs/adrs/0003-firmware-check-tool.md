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
| `names.maximum` | A new tape with a 15-character name, using every kind of allowed character, is accepted over MTP and kept after a reconnect. | `TapeName.maximumLength` |
| `tape.files` | Each tape has `tape.json`, `track_1`–`4.wav`, and maybe `readme.txt`. Nothing else. | `Tape` |
| `tape.wav-format` | Tracks are 44-byte-header PCM WAV: 2 channels, 32 bits, 44.1 kHz. | Track sizes, consistency check |
| `album.files` | `mixdown/` holds exactly `side_a.wav` and `side_b.wav`, and an empty side is the 44-byte header. | `Album`, `AlbumSide.isEmpty` |
| `album.wav-format` | Sides are PCM WAV, 2 channels, 16 bits, 44.1 kHz. | `AlbumSide.format`, the restore format check |
| `album.write-exact` | A side written back reads back byte for byte. | `restoreSide` |
| `album.write-other-format` | What the OP-1 does with a side written in another format, such as 32-bit. **Not yet known.** | The restore format check |
| `tape.json-keys` | `tape.json` has exactly the known keys and versions. Unknown keys are reported. | `TapeManifest` |
| `tape.json-units` | Every track is `44 + 8 × last clip end` bytes; `ch` is 0-based. | Consistency check |
| `tape.types` | `tape_type` values are 0–3. | `TapeType` |
| `tape.track-limit` | A full 6-minute track of 127,008,044 bytes can be written and read back. Runs only when asked (section 2). | `tapeTooLong`, upload memory use |
| `read.partial` | GetPartialObject works at any offset with chunks up to 1 MiB. | `contents(of:range:)`, WAV header reads |
| `read.speed` | Reads at about 20 MB/s, writes at about 7 MB/s. A big drop is reported, not failed. | Timeouts, progress estimates |
| `read.cost` | What a GetPartialObject's time grows with: its offset, or the number of reads before it. On 1.7.3 it's the offset. Added 2026-11-14. | Whole files read with one GetObject (ADR 0002, 2026-11-14) |
| `write.folder` | A tape folder can be made with SendObjectInfo alone (format 0x3001, association type 1). | `createTape`, `restoreTape` |
| `write.exact` | Tracks and `tape.json` written to a tape read back byte for byte. | Read-back verification |
| `write.refused-name` | A name a folder doesn't allow (`track_5.wav`) is refused with 0x2002. | Folder rules |
| `write.preset-converted` | A WAV written to `drum/user/` comes back as AIFC under the same name. | Preset writes |
| `rebuild.tape-json` | After a track write, the OP-1 rebuilds `tape.json` (one clip per track). | Restore order: tracks first, `tape.json` last |
| `rebuild.stale-size` | Within the session, the rebuilt `tape.json` still lists, and reads, at its old size. | Fresh info before every read |
| `delete.files-then-folder` | Deleting a tape's files, then its folder, removes it. | `deleteTape`, `moveTape` |
| `delete.folder-with-files` | What one DeleteObject on a folder with files in it does. **Not yet known.** | Could simplify `deleteTape` |
| `reconnect.kept` | After leaving MTP mode, a written tape and its `tape.json` are kept, apart from `pos`. | Restore |
| `reconnect.renamed` | After reconnecting, a created tape's name is lowercase and `readme.txt` has been added. | `TapeName`, `Tape` |
| `reconnect.handles` | Object handles change after reconnecting. | Handles stay private |

New expectations are added when FieldTapeKit starts relying on something new. Removing one needs a note on why.

### 2. Three levels, from harmless up

**Level 1: read only.** This is the default, and it changes nothing on the OP-1. It runs every expectation that only needs reading: device, storage, layout, readmes, names, every tape's files and `tape.json`, the WAV format, partial reads, and speed. It takes under a minute.

**Level 2: scratch writes.** These run only on things FieldCheck makes itself:
- **A scratch tape** named `FIELDCHECK #1-2`, stored as `fieldcheck #1-2`. It's 15 characters, FieldTapeKit's maximum, and uses letters, digits, `#`, `-` and space, so making it also checks `names.maximum`. It needs one free slot of the 8, and FieldCheck refuses to start this level without one, saying so. It never writes to a tape it didn't create.
- **Generated content.** The tracks are short synthetic tones, about 2 seconds each, and `tape.json` is generated with several clips, a loop, a custom tempo and a non-default type. Its `padding` values are all `-1`, as on a tape the OP-1 rebuilt. No user audio or `padding` is copied (Alternatives Considered).
- **A small generated WAV** at `drum/user/fieldcheck.wav`, deleted afterwards.
- **Free space** is read before the first write, after the last one, and after cleanup, for `device.storage`.
- **The long check**, off unless asked for: one full 6-minute track of 127 MB, to check `tape.track-limit` and memory use. It adds about 25 seconds of transfer. A person turns it on for a run; it isn't part of every firmware update.

**Level 3: after a reconnect.** Some behaviors only show after leaving MTP mode:
1. After level 2, FieldCheck asks the person to leave MTP mode on the OP-1. Optionally they can play the scratch tape to hear the tones.
2. They reconnect.
3. FieldCheck checks the `reconnect.*` expectations and the rest of `names.maximum`.
4. It deletes the scratch tape, and that delete is the `delete.folder-with-files` check: one DeleteObject on the tape's folder with its files still in it. If the OP-1 refuses, FieldCheck deletes the files first, then the folder, as before, and records both results. The scratch tape holds only generated content, so nothing is at risk.

It remembers a pending level 3 across app launches. If it finds a scratch tape left from an interrupted run, it offers to delete it before doing anything else.

**Album sides are written only when one is empty.** `mixdown/` only allows `side_a.wav` and `side_b.wav`, which are the user's. The `album.write-*` checks run only on a side that's empty (44 bytes): they write generated tones, read them back, then put the empty header back. If both sides have audio, they're reported as "not run".

### 3. Safety

FieldCheck follows ADR 0002's safety rules, plus these:
- It reads anything, but writes and deletes only the scratch tape `tapes/fieldcheck #1-2`, `drum/user/fieldcheck.wav`, and an album side that was empty when it started.
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
- **Which baseline a run compares against:** the baseline for the OP-1's firmware if there is one. Otherwise it's the one FieldTapeKit would use as that firmware's profile: the newest tested firmware older than it (ADR 0002, section 11).
- **Save as baseline:** once a change has been reviewed, and FieldTapeKit and its simulator are updated, this action writes the run as the baseline for the new firmware. It's added next to the old baselines and never replaces one, because FieldTapeKit keeps supporting their firmware. Each baseline is also the source of that firmware's profile and its simulator.
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
- **Checks that write to the user's tapes or album.** Rejected: routine checks must never touch the user's music. FieldCheck writes only to content it created, and to an album side only when it's empty.
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
- **2026-11-14:** Decided by the owner: FieldCheck has two tabs. **Validate** holds the checks, baselines and conformance suite. **Explore** is a low-fidelity browser of the OP-1 built only on FieldTapeKit's public API, so FieldTapeKit gets used the way an app uses it, and a change can be tried by hand. Explore is **read-only**: it lists, shows details and copies files to the device, and section 3's limit on writes is unchanged. Letting it write would need its own decision.
