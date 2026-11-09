# Status

Where the project stands, so a new session can pick it up. Update this when the state changes. The reasoning lives in the ADRs, and the evidence in [research/PROBE-NOTES.md](../research/PROBE-NOTES.md).

## As of 2026-11-09

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
- **Tape names:** at most 15 characters for a new tape, FieldTapeKit's own limit so names stay readable on the OP-1's screen. Names already on the OP-1 or in an archive are accepted at any length.
- **Free space:** FieldCheck checks whether GetStorageInfo's figure is accurate. Until then nothing refuses a write on it, and Store Full is reported as `insufficientSpace`.
- **Versioning:** strict semver, starting at `1.0.0-alpha.1`, then betas, then `1.0.0`. A major version protects the Swift API, the archive format, supported firmware and safety behavior.
- **Firmware support is additive:** each tested firmware keeps a profile, a baseline and simulator tests. Untested firmware works, with a warning (`isFirmwareTested`).

**Settled in ADR 0003, decided by the owner:**
- **Name:** FieldCheck.
- **The long check** (a 6-minute, 127 MB track) runs only when asked.
- **The scratch tape** is `fieldcheck #1-2`, exactly 15 characters. No longer names are tried.
- **No user `padding`** is copied onto the scratch tape. Shared `padding` stays a known risk.
- **`delete.folder-with-files`** runs on the scratch tape's own deletion, so only one free slot is needed.
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

## Next steps

1. Commit step 3.
2. Step 4 of the plan: FieldCheck's expectations, reports and first level 1 checks. Leave `research/` untouched.

## The OP-1 right now

- Firmware 1.7.3, with 7 of the 8 tape slots used. One slot is free, which FieldCheck's scratch tape `fieldcheck #1-2` needs.
- `tapes/2026-312#01` is the blank tape the probe tests used. It should be blank again after **Restore blank tape**, but check on the OP-1 before relying on it.
- Paired test devices: an iPad Pro 11-inch (M4), iPadOS 27.2, and an iPhone 17 Pro, iOS 27.0.1. Their IDs and the commands for pulling logs are in PROBE-NOTES.md.
- Paused: switching into MTP mode over MIDI. Its code was removed. The bytes and the Mac tools are kept in `research/`.
