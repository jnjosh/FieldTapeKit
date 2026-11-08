# Status

Where the project stands, so a new session can pick it up. Update this when the state changes. The reasoning lives in the ADRs, and the evidence in [research/PROBE-NOTES.md](../research/PROBE-NOTES.md).

## As of 2026-11-08

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

## Next steps

1. Make the repository a git repository before the first release. Checking for API breaks needs release tags.
2. Create FieldTapeKit as a new project at the repository root. Leave `research/` untouched.
3. Start by copying the probe's PTP layer and its tests into the package, then add FieldCheck's read-only checks (level 1). Run them on the OP-1 to record the 1.7.3 baseline.
4. Build the rest of FieldTapeKit on top of that, phase by phase.

## The OP-1 right now

- Firmware 1.7.3, with 7 of the 8 tape slots used. One slot is free, which FieldCheck's scratch tape `fieldcheck #1-2` needs.
- `tapes/2026-312#01` is the blank tape the probe tests used. It should be blank again after **Restore blank tape**, but check on the OP-1 before relying on it.
- Paired test devices: an iPad Pro 11-inch (M4), iPadOS 27.2, and an iPhone 17 Pro, iOS 27.0.1. Their IDs and the commands for pulling logs are in PROBE-NOTES.md.
- Paused: switching into MTP mode over MIDI. Its code was removed. The bytes and the Mac tools are kept in `research/`.
