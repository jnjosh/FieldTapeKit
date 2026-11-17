# OP-1 Probe notes

Build log for the probe in [ADR 0001](../docs/adrs/0001-op1-field-ios-transport.md), kept so the real app can start from it.

## Status (2026-11-08)

**The iPad and iPhone runs passed: ImageCaptureCore can list and download the OP-1 Field's audio files, with no driver.** Writing and deleting also work on iPad and iPhone: a tape track written back came back byte for byte on both, while preset folders convert what they receive. A written track also survived leaving MTP mode and played on the OP-1, and a 22 MB track wrote byte for byte. Chunked reads up to 1 MiB also passed, though one earlier 1 MiB request hung and that hasn't been reproduced. Still to do: and a checksum comparison with macOS.

| Check | Result |
| --- | --- |
| Parser and command-encoding unit tests | 21 of 21 pass on Xcode 27.2, iOS 27.2 simulator, including the write-test encoding and file choice |
| Run on iPad Pro 11-inch M4, iPadOS 27.2, OP-1 firmware 1.7.3 | **PASS** |
| Tapes and mixdowns listed | Yes: 47 files, 28 folders, 155.6 MB |
| Real audio downloaded | `mixdown/side_a.wav`, 12,235,308 bytes in 0.60 s (about 20 MB/s) |
| Downloaded file valid | Size matches, WAV header agrees with file length, `afinfo` reads 69.4 s of 16-bit 44.1 kHz stereo |
| SHA-256 compared with a copy from macOS | **PASS** (2026-11-08): `mixdown/side_b.wav` downloaded on the iPad and copied with the Mac companion app are identical, 3,992,876 bytes, SHA-256 `9204518b…5f361a97aa` |
| Run on iPhone 17 Pro, iOS 27.0.1 | **PASS**: same 47 files and 28 folders, `applefly.aif` (62 KB) and `mixdown/side_b.wav` (16.1 MB in 0.79 s, about 20 MB/s) at the expected sizes, with file headers that agree |
| Write and delete on iPad | **Works**: `SendObjectInfo`, `SendObject`, and `DeleteObject` all returned OK, and the copy was listed and readable |
| Written file byte-identical | **No, by design of the OP-1**: same size and identical audio, but it edited the preset metadata |
| Large write on iPad | **PASS** (2026-11-08): 22,056,500 bytes written to a tape in 2.99 s (7.4 MB/s) and read back with the same SHA-256 |
| GetPartialObject | **PASS** up to 1 MiB chunks at any offset, before and after a whole read (2026-11-08); one earlier 1 MiB request hung and didn't recur |
| Exact-bytes write of a non-preset file | **PASS on iPad**: a 1,514,988-byte tape track read back with the same SHA-256 |
| Written file survives leaving MTP mode | **PASS on iPad** (2026-11-08): after about 3 minutes out of MTP mode, `tapes/2026-220#02/track_1.wav` was still listed at 1,514,988 bytes |
| OP-1 plays the written track | **PASS on iPad** (2026-11-08): track 1 of tape 2026-220#02 played the copied audio |
| Write back to `mixdown/` | **PASS on iPad** (2026-11-08): `side_b.wav` deleted, written back, and read back with the same SHA-256 |
| Write on iPhone 17 Pro, iOS 27.0.1 | **PASS** (2026-11-07): the same 1,514,988-byte tape track read back with the same SHA-256, in 0.26 s (5.9 MB/s), and the blank track was restored |
| Whole tape copy on iPad | **PASS** (2026-11-08): 2026-220#02 (2 tracks) and 2026-276#01 (4 tracks, 16 clips, 78 MB, about 19 s) each copied onto a blank tape, every track and `tape.json` read back exactly |
| OP-1 keeps a written `tape.json` | **PASS** (2026-11-08): after a reconnect, clips, padding, loop, tempo, mix and tape type were as written; only the playhead and metronome level changed, and the OP-1 showed the copied type and clips |
| Create a tape over MTP | **PASS** (2026-11-08): the folder made with SendObjectInfo alone, filled and played on the OP-1; the OP-1 lowercases its name |
| Delete a whole tape over MTP | **PASS** (2026-11-08): files, then the folder; gone on the OP-1 |
| Largest file tested | 22 MB read and written byte for byte, the largest on this OP-1 |

Evidence is in `probe-results/`. The automatic PASS in the iPad log came from a 44-byte empty WAV, so `side_a.wav` is the real proof there. The probe now skips header-only files and counts `mixdown` as albums, and the iPhone log reflects that.

`side_a.wav` SHA-256: `65c9af35e997d6ea44e3370b90a0ff0473bb967862c275af494d68a0138aeb1a`

`side_b.wav` changed on 2026-11-08, from 16,076,844 bytes to 3,992,876 bytes. The older copy is in `probe-results/iphone-2026-11-03/`, and the current one, matching the Mac backup, is in `probe-results/mac-checksum-2026-11-08/`.

## What the runs showed

The iPhone log matched the iPad on capabilities, session behavior, transaction IDs, data phase, and speed.

- **Hidden from the high-level API:** ImageCaptureCore's catalog reports 0 media files, so raw PTP is required, as the ADR predicted.
- **Session:** ImageCaptureCore's session is enough. OpenSession was never needed.
- **Transaction IDs:** ImageCaptureCore rewrites them. We sent 1 and the response said 13, and the offset stayed at +12, so our value doesn't matter.
- **Data phase:** it arrives without the 12-byte container header.
- **Device:** MTP vendor extension 6, one storage (`0x00010001`). It supports DeleteObject, SendObjectInfo, SendObject, GetPartialObject, and the object property operations `0x9801`-`0x9805`.
- **Listing speed:** the walk took about 0.16 s for 75 objects using one call per object.
- **Layout:** `synth/`, `drum/`, `tapes/<tape>/` (`tape.json`, `track_1`-`4.wav`), and `mixdown/side_a.wav` and `side_b.wav`. Tape tracks are WAV, presets are AIFF, and an empty track is a 44-byte header.
- **Events:** PTP events arrive through the delegate. One logged `0x4006` DevicePropChanged for `0x5001` BatteryLevel.
- **Disconnect:** unplugging or leaving MTP mode reports the device as removed.
- **Permissions:** authorization callbacks fire on a real device after the prompts, and on later launches they return immediately.
- **Folder rules:** each probe run logs every `readme.txt`, which is read-only and shows what each folder accepts.

## Layout

- `project.yml`: XcodeGen spec. `OP1Probe.xcodeproj` is generated from it, so edit the spec.
- `OP1Probe/OP1ProbeApp.swift`: the whole app, as the ADR asked.
- `OP1ProbeTests/PTPParsingTests.swift`: parser tests. The PTP layer is the part to carry forward.

Run commands with `DEVELOPER_DIR=/Applications/Xcode-27.2.0.app/Contents/Developer`, because `xcode-select` currently points at the Command Line Tools, or `simctl`, `devicectl`, and `xcodebuild` won't be found.

Bundle ID `com.jnjosh.OP1Probe`, team `Q285243259`, iOS 17+, iPhone and iPad, Swift 5 language mode.

## Commands

Run these from `research/`, where `project.yml` is.

```bash
xcodegen generate
```

```bash
xcodebuild -project OP1Probe.xcodeproj -scheme OP1Probe -destination 'generic/platform=iOS' -derivedDataPath build -allowProvisioningUpdates build
```

```bash
xcrun devicectl device install app --device <device-id> build/Build/Products/Debug-iphoneos/OP1Probe.app
```

```bash
xcrun devicectl device info files --device <device-id> --domain-type appDataContainer --domain-identifier com.jnjosh.OP1Probe --subdirectory Documents
```

```bash
xcrun devicectl device copy from --device <device-id> --domain-type appDataContainer --domain-identifier com.jnjosh.OP1Probe --source Documents/<log-name>.txt --destination <log-name>.txt
```

Device IDs: iPad `0DE99179-EE7B-5706-B34A-D831AA66C3FB`, iPhone `9457E746-C560-5D0D-AF45-16F49A546E5D`.

## Write test

After a probe run finishes, tap **Tape write test**. It:

1. Picks the first tape whose four tracks are all blank, and the smallest real tape track as the source. On this OP-1 that's `tapes/2026-286#01/track_2.wav` (1.5 MB) into `tapes/2026-220#02/track_1.wav`.
2. Reads the source, then reads the blank track, checks it's a 44-byte RIFF header, and saves and verifies a copy on the iPad. It stops before deleting if any of that fails.
3. Deletes the blank track and sends the source under its name. If the send fails, it tries to put the blank back.
4. Lists the folder, reads the copy back, and compares every byte.

**Large tape test** does the same with the largest tape track, `tapes/2026-220#01/track_4.wav` (22 MB) on this OP-1. It logs read and write speeds. Chunked reads were taken out of it after they hung (below).

**Partial read test** is read-only. On the smallest audio file of at least 64 KiB (`applefly.aif`), it sends five 16 KiB GetPartialObject requests in an order that separates the possible causes: a nonzero offset first, offset 0 twice, the chunk after offset 0, then a skip ahead. It checks each chunk against a whole-file read, stops at the first failure, and then checks the OP-1 still answers.

**The Mixdown write test passed (iPad, 2026-11-08, `probe-results/mixdown-write-ipad-2026-11-08/`).** `side_b.wav` matched the Mac backup, was deleted, written back in 0.81 s (4.9 MB/s), and read back with the same SHA-256. So `mixdown/` accepts writes under its allowed names, and the earlier refusal was the `probe-copy.wav` name.

**Mixdown write test** writes `mixdown/side_b.wav` back to itself, after a confirmation. It reads the file and continues only if its SHA-256 matches the Mac backup from 2026-11-08 (`9204518b…5f361a97aa`), so a restore from the Mac is always possible. It saves and verifies a copy on the iPad, deletes `side_b.wav`, writes it back, retrying once if the send fails, and compares every byte of the read-back. If it fails, restore side B from the Mac backup.

**Chunk size test** is read-only. On the largest audio file, it reads two chunks, at offset 0 and then right after the first, at 64 KiB, 256 KiB, 512 KiB and 1 MiB, with no whole-file read first. Then it reads the whole file, repeats the 1 MiB pair, and checks every chunk against the whole read. It stops at the first failure and checks the OP-1 still answers. If it fails before the whole read, the chunk size is the trigger; if it fails only after, the earlier whole read is.

**The Chunk size test passed (iPad, 2026-11-08, `probe-results/chunk-size-ipad-2026-11-08/`).** On the same 22 MB track, pairs of 64 KiB, 256 KiB, 512 KiB and 1 MiB chunks all returned in 0.02-0.16 s, and so did the 1 MiB pair right after a 22 MB whole read. All 10 chunks matched the whole read. A 1 MiB chunk read at 6.5-9.5 MB/s, slower than a whole read at 19.7 MB/s. So the earlier hang didn't recur under the same conditions, and its cause is unknown. One difference: that run started its reads 2 seconds after connecting, and this one 5 seconds after, but that's only a guess. For the framework, treat any request as able to stall: give each one a timeout shorter than ImageCaptureCore's 60 seconds, then check whether the device still answers and reconnect if not.

**GetPartialObject hung on its second request (iPad, 2026-11-08, `probe-results/large-tape-ipad-2026-11-08/`).** The 22 MB whole read took 1.12 s (19.7 MB/s). The first 1 MiB GetPartialObject at offset 0 returned in 0.06 s with the correct length in its response param. The second, at offset 1 MiB, returned an empty response after 61.6 s, which looks like a timeout. The test stopped before deleting anything, so no tape changed. 

**The Partial read test passed on the iPad (2026-11-08, `probe-results/large-tape-ipad-2026-11-08b/`), twice.** On `synth/slots/8/vibrates.aif` (89,468 bytes), all five 16 KiB requests matched the whole-file read in about 0.01 s each, including a nonzero offset as the first request. So GetPartialObject works with offsets, and the earlier hang must depend on something that run had and this one didn't: 1 MiB chunks, a 22 MB file, or coming straight after a 22 MB whole read.

**The 22 MB write passed (iPad, 2026-11-08, same log).** A new tape made on the OP-1 appeared as `tapes/2026-312#01/` with four 44-byte tracks and a 251-byte `tape.json`. `tapes/2026-220#01/track_4.wav` (22,056,500 bytes) read in 1.12 s (19.7 MB/s), wrote to its `track_1.wav` in 2.99 s (7.4 MB/s), and read back in 1.1 s with the same SHA-256, `9aecf102…ecb69497`. The blank track was then restored. Holding about 66 MB in memory caused no trouble. A whole-file transfer of the largest track works in both directions, so chunked reads are an optimization for the framework, not a requirement at today's file sizes.

**WRITE PASS** means every byte matches. On WRITE FAIL, the log gives the sizes, the number of differing bytes, and the first offset, and both files are saved to Documents. To check that the copy survives, leave MTP mode and return, then tap **Run** and look at the track in the Files tab. **Restore blank track** then deletes the copy and writes the saved header back. The app remembers the track across launches until the restore succeeds.

Results from the iPad run on 2026-11-05 (`probe-results/tape-write-ipad-2026-11-05/`): `track_2.wav` from `tapes/2026-286#01` replaced the blank `track_1.wav` in `tapes/2026-220#02`. `SendObject` took 0.26 s (5.8 MB/s), and the read-back matched: SHA-256 `c02a591887eb7c23bd346ad09952e56a6295f34f4f9c628e3976393cb4be956c`. The restore came 8 seconds later in the same connection and also verified, so the tape ended as it began. This shows delete-then-send works as a replace in `tapes/`. It doesn't show whether the file survives leaving MTP mode or whether the OP-1 plays it.

Survival run on the iPad on 2026-11-08 (`probe-results/survival-ipad-2026-11-08/`): after WRITE PASS, the OP-1 left MTP mode for about 3 minutes. When it came back, the written track was listed at the full 1,514,988 bytes, and the blank was then restored and verified. Two other things changed while it was out of MTP mode:
- **`tape.json` is rewritten by the OP-1:** `tapes/2026-220#02/tape.json` went from 255 to 322 bytes, presumably to describe the new track. `tapes/2026-220#01/tape.json` also changed, from 323 to 319 bytes, though the test never touched that tape, so the OP-1 seems to update tape metadata on its own. The real app shouldn't treat a changed `tape.json` as a conflict, and it doesn't need to write one when replacing a track. The restore didn't put the 255-byte version back, so 2026-220#02's `tape.json` may still describe a track that's blank now.
- **Handles restarted from `0x01`** at the first connection of this run, then continued from `0x4D` after reconnecting. They are per-connection numbers.

The first write test copied a preset. Results from that iPad run on 2026-11-03 (`probe-results/write-test-ipad-2026-11-03/`, with both files):
- `outData` is the bare payload with no container header.
- Raw writes work even though the OP-1 doesn't report `ICCameraDeviceCanReceiveFile`.
- The `SendObjectInfo` response gives storage, parent, and new handle (`0x4C`) in its params.
- A 62 KB send took 0.07 s, which is too small to estimate write speed.

**The WRITE FAIL was the OP-1 editing the preset, not corruption.** `probe-copy.aif` was the same 62,012 bytes as `applefly.aif`, and the difference stayed the same across two reads. All 298 differing bytes are in the `op-1` JSON in the AIFF's `APPL` chunk, and the `SSND` audio is identical. The JSON changed in three ways: `name` went from `applefly` to `probe-copy`, `synth_version: 1` was removed, and `drum_version: 2` was added. The file stayed the same size because the chunk is padded.

`applefly.aif` is 16-bit mono at 22,050 Hz, by its `COMM` chunk, so the OP-1's own presets aren't all 44.1 kHz (found while building step 9b, 2026-11-14).

So the OP-1 reads presets it receives and normalizes them. For the real app:
- Don't verify preset writes with a whole-file hash. Compare the audio and the metadata fields that should survive.
- The filename sets the preset name, so renaming a file renames the preset.
- This run doesn't prove the transport is byte-exact for everything. The bytes outside the JSON matched, but a non-preset file is needed to show that.

**The first WAV attempt was refused (2026-11-05, `probe-results/write-test-wav-ipad-2026-11-05/`).** `SendObjectInfo` for a 12,235,308-byte WAV in `mixdown/` returned `0x2002` General Error, so no file data was sent. The likely cause is the filename, not a read-only folder: `mixdown/readme.txt` says the folder accepts 44100 Hz `.wav` files and allows only the names `side_a.wav` and `side_b.wav`. The `side_a.wav` read matched its 2026-11-03 SHA-256.

**The WAV sent to `drum/user/` was imported as a drum sample (2026-11-05, same folder).** `SendObject` accepted all 12,235,308 bytes, then the listing showed `probe-copy.wav` at 3,532,220 bytes. The file is AIFC (`sowt`, little-endian) with an `op-1` JSON `APPL` chunk, still named `.wav`, and holds exactly 20.000 s of stereo audio. Its 1,764,000 samples are identical to the first 20 seconds of `side_a.wav`. The test reported WRITE FAIL because a whole-file comparison can't apply here. The copy is deleted from the OP-1.

So for the real app:
- `drum/user/` and `synth/user/` import files. They convert them, cap their length, and keep the filename, so a `.wav` there may really be AIFC. Identify files by their contents.
- Each folder has its own write rules, so read the `readme.txt` or encode them in the app, and show a clear error when a write is refused. Tape folders and `mixdown/` state 44100 Hz `.wav` with fixed names (`track_1`-`4.wav`, `side_a.wav`, `side_b.wav`), and `synth/user/` and `drum/user/` state mono or stereo AIFF or WAV (`probe-results/folder-rules-ipad-2026-11-05/`).
- Object handles change between connections (`applefly.aif` was `0x29`, then `0x74`), so never store them.

MTP has no in-place overwrite, so replacing a file means DeleteObject followed by SendObject. This test doesn't cover replacing, because a failed send would lose the original.

## Running the probe

1. Install, open the app once, and accept any permission prompts.
2. Put the OP-1 Field in MTP mode and plug it in. Close Photos' import view first if it's open.
3. The probe runs on its own when the catalog is ready, or after 20 seconds. **Run** repeats it.
4. Each launch writes `probe-<timestamp>.txt` to Documents. It's reachable with the share button, the Files app, or `devicectl`.
5. Downloads land in Documents as `<handle>-<filename>`. Compare the logged SHA-256 with `shasum -a 256` on the same file copied through the macOS companion app, since a matching size alone doesn't prove the file is intact.
6. Tap any file in the Files tab to try a larger transfer, such as a tape track.

**PASS** means tape or mixdown files were listed and one non-empty audio file came back at the expected size. Run on iPad, then iPhone.

## Choices the ADR didn't spell out

- GetObjectHandles parent `0xFFFFFFFF` means root and `0` means every object. The ADR's "all storages, root" call is logged once, then the probe walks each storage folder by folder, because recursive `0` is optional for MTP devices.
- The probe doesn't send OpenSession up front. ImageCaptureCore owns the session, so OpenSession goes out only after a `0x2003` SessionNotOpen, and `0x201E` SessionAlreadyOpen counts as success.
- Whether the data phase includes its 12-byte container header is undocumented, so the header is stripped only when length, type, and opcode all match. The first real run will show which it is.
- GetDeviceInfo also logs whether DeleteObject, SendObjectInfo, SendObject, GetPartialObject, and GetObjectPropList are supported.

## Learned so far

- `xcodegen` and automatic signing work with the existing team; the device build used the wildcard team profile.
- ImageCaptureCore's authorization doesn't work on the simulator: the callbacks never fired on iOS 26.0, and on iOS 27.2 the method is missing and the app crashes. The simulator build now skips ImageCaptureCore. On a device, startup still continues after 15 seconds if no callback arrives.
- The simulator has no USB, so it can only check UI and parsers.
- `devicectl` installs need the device unlocked.
- The SDK headers name no usage-description key for ImageCaptureCore authorization. The camera and photo library strings are a precaution; find out which, if either, the real run needs.

## Product goal

The ideal result of this testing is a Swift framework that any iOS or iPadOS app can use to work with the OP-1. Open source is a possibility, not a decision.

A core feature is backing up whole tapes onto the iPhone or iPad and restoring them to the OP-1 later. Single tracks already round-trip, but whole tapes still need these answered:
- **`tape.json`:** what each field means, and whether the OP-1 accepts one written back or rewrites it from the tracks. The OP-1 updates these files itself, so restored metadata may be replaced.
- **Creating a tape folder:** restoring to a tape that no longer exists means making a `tapes/<name>/` folder through MTP, which hasn't been tried. The OP-1 names tapes like `2026-312#01`, so whether it accepts a folder name the app chooses is also open.
- **Restore order:** whether tracks or `tape.json` should go first, and what the OP-1 does when it sees a half-restored tape.

The first step is read-only: log every `tape.json` during the probe run to document the format. The probe now does this on every run (added 2026-11-08): for each tape it logs the four track sizes, any extra files, and the full `tape.json` text, and saves a copy to `Documents/tape-json/<tape>.json`.

### `tape.json` format (iPad, 2026-11-08, `probe-results/tape-json-ipad-2026-11-08/`)

Five tapes were read: one blank, three with one or two tracks, and 2026-276#01 with all four tracks and 16 clips. All units below were checked against every tape, and every one matched exactly.

- **Track WAVs:** 44-byte header, PCM, 2 channels, 32 bits, 44100 Hz, so 8 bytes per frame. Each file runs from frame 0 to the end of its last clip: `size = 44 + 8 × max(stop)` for that track. Gaps between clips are stored in the file.
- **`clips`:** one entry per region on the tape.
  - `ch`: track, 0-based (`ch` 3 is `track_4.wav`).
  - `start`, `stop`: frames at 44100 Hz.
  - `id`: clip number. Mostly sequential, but 2026-276#01 skips 15, so it's an identifier, not an index.
  - `padding`: four integers, `-1` for unused. The values rise across tapes (27 in the oldest, 115 in a newer one), so they look like references to something stored elsewhere on the OP-1, perhaps sample or edit buffers. Unknown, and the riskiest field for restore.
- **`loop`, `loop_in`, `loop_out`:** loop on or off, and its bounds in frames.
- **`pos`:** playhead position in frames.
- **`track`:** selected track, 0-based.
- **`mixer_params`:** eight numbers. Default `[1,1,1,1,0,0,0,0]`; 2026-276#01 has four levels between 0.6 and 0.91 and four values near ±0.09. These are probably the four track levels and four pans.
- **`tempobpmdecimal`:** tempo × 10 (1200 is 120 BPM, 800 is 80 BPM).
- **`tempometronomelevel`, `tempometronometype`, `temposyncout`, `temposynctype`:** metronome and sync settings.
- **`tape_type`:** the tape machine the tape uses. The user lists four on the OP-1 Field: Studio 4-Track, Vintage 4-Track, Porta 4-Track and Disk Mini. They gave the numbers as 1, 2, 3, 3, which has a duplicate. Since 0 appears on real tapes, the likely mapping is 0-based: 0 Studio, 1 Vintage, 2 Porta, 3 Disk Mini. Seen so far: 0 on 2026-220#01, 2026-276#01 and 2026-286#01, 1 on 2026-220#02, and 3 on the new blank 2026-312#01. The user confirmed 1 (2026-220#02 is Vintage) and 3 (2026-312#01 is Disk Mini) on the OP-1 on 2026-11-08, so the 0-based mapping holds; 0 and 2 are inferred. The OP-1 now has a tape of each type for the next run.
- **`version`:** 1 everywhere.

OP-1 limits, from the user:
- **At most 8 tapes** on the device. A restore that creates a tape must check there's room, and the probe now logs "Tapes: N of 8".
- **Each tape is at most 6 minutes**: 15,876,000 frames, so a track is at most 44 + 8 × 15,876,000 = 127,008,044 bytes. The consistency check flags any clip ending past that.

What this means for backup and restore:
- **A backup must include `tape.json`.** The WAVs hold audio with gaps, but clip boundaries, loop, tempo and mix exist only in `tape.json`. Restoring tracks alone would lose the clip layout; the earlier track write showed the OP-1 rebuilding `tape.json` itself after a track changed.
- **The framework can check a backup is consistent:** every clip's `ch` should name a real track, and each track's size should equal `44 + 8 × max(stop)`.
- **Still to test, on the blank tape:** whether the OP-1 accepts a `tape.json` written over MTP, keeps its clips, and what it does with `padding` values that refer to another tape. Copying a whole tape (four tracks and `tape.json`) onto 2026-312#01 would answer all three.

### Whole tape copy test (passed on iPad, 2026-11-08)

**Whole tape copy** copies the real tape with the least audio onto the blank tape. **Large tape copy** copies the one with the most, today 2026-276#01: four tracks, 16 clips, about 78 MB. The test runs in this order and stops at the first failure:
1. Read the source `tape.json` and check it against the source track sizes.
2. Read the blank tape's four tracks and `tape.json`, check they are header-only with no clips, and save them to `Documents/tape-backup/`, verified on disk.
3. Write each source track with audio, one at a time: delete, send, list, read back, compare. Tracks that are blank on both tapes are skipped.
4. Log the blank tape's `tape.json` as the OP-1 left it after the track writes.
5. Write the source `tape.json` last and read it back. It goes last because the OP-1 rewrote `tape.json` after the earlier track write.

If a write fails, the test puts the blank tape back from the backup. Otherwise **Restore blank tape** does it later; it survives app restarts. The other write tests are disabled until the tape is restored.

After a pass: leave MTP mode, open the copied tape on the OP-1, and check its clips, loop and tempo match the source. Then reconnect. The probe logs whether the OP-1 kept the copied `tape.json` or changed it, and checks every tape's tracks against its clips.

**Both copies passed (iPad, 2026-11-08, `probe-results/tape-copy-ipad-2026-11-08/`).** The source and target were the same tapes both times: the blank Disk Mini tape 2026-312#01 was the target.
- **Whole tape copy:** 2026-220#02 (Vintage, two tracks, 2.4 MB) onto 2026-312#01. Both tracks and `tape.json` read back byte for byte. The user then played it on the OP-1, reconnected, and restored the blank tape, which also verified.
- **Large tape copy:** 2026-276#01 (Studio, four tracks, 16 clips, 78 MB) onto 2026-312#01. All four tracks and the 1,454-byte `tape.json` read back exactly. It took about 19 s: reads at about 20 MB/s and writes at 7.3–7.4 MB/s. The copy is still on 2026-312#01; **Restore blank tape** puts the blank back.

What the OP-1 did with the copied `tape.json`, compared after a reconnect:
- **It kept it.** Clips, `padding`, loop, tempo, mix and `tape_type` all stayed as written. Only runtime state changed: `pos` (the playhead, after playing) and, on the large copy, `tempometronomelevel`, which became 22.955, the same as 2026-286#01, so it may be a global setting.
- **`tape_type` can be set by restore.** 2026-312#01 was made as Disk Mini (3) and became Vintage (1), then Studio (0), from the copied file. The user confirmed on the OP-1 that each copy showed the source tape's type (Vintage, then Studio) and its clips.
- **Copied `padding` values were accepted,** even though they now match another tape's. No problem was seen, but whether two tapes sharing them causes trouble later is untested.
- **Without `tape.json`, the clip layout is lost.** After the tracks were written, but before `tape.json` was, the OP-1 had already rebuilt it on its own: one clip per track from frame 0 to the end of the file, `padding` all `-1`, loop off, and the tape type unchanged. The 16-clip tape became 4 clips. So the order the test uses (tracks first, then `tape.json`) is the right one for restore.
- **A file the OP-1 rewrites mid-session reads back truncated.** The rebuilt `tape.json` came back as exactly 251 bytes, the size listed at the start of the session, cutting the JSON off mid-key. The framework mustn't trust a read of a file the OP-1 may have changed (like `tape.json`) without listing it again or reconnecting. The probe now also logs a fresh GetObjectInfo size and a GetPartialObject read at that point, to see whether either gets the new length.

### Create tape test (create and delete passed on iPad, 2026-11-08)

Restoring a tape that's no longer on the OP-1 means creating `tapes/<name>/` over MTP. **Create tape test** does this with the name typed in the field next to it, by default `PROBE 1-#A`. That name is 10 characters and uses every character the user has seen allowed: A–Z, 0–9, `#`, `-` and space. The field keeps its value, so later runs can try other names, such as lowercase, longer names, or other symbols. Each tape uses one of the 8 slots, so the test needs a free one, and the probe logs the count. The test:
1. Stops if a tape with that name already exists, and logs any characters in the name outside the expected set.
2. Reads the smallest real tape's four tracks and `tape.json` first, so a failed read leaves nothing behind.
3. Sends a folder ObjectInfo (format 0x3001, association type 1, generic folder) with no SendObject, as MTP does for folders, then lists `tapes/`. If no folder with that exact name appears, it logs everything in `tapes/` to show whether the OP-1 renamed it.
4. Logs what the OP-1 put in the new folder by itself, if anything (readme, blank tracks, `tape.json`).
5. Writes all four tracks, including blank ones, then `tape.json`, each read back and compared.

No existing tape is changed. **Delete test tape** deletes the folder's files, then the folder, and checks it's gone. That also tests whether a whole tape can be removed over MTP. The path is saved, so the button survives app restarts.

After a pass: leave MTP mode and check how the OP-1 shows the tape's name, and that it plays like the source. Then reconnect and delete it.

**Creating a tape works (iPad, 2026-11-08, `probe-results/create-tape-ipad-2026-11-08/`).** SendObjectInfo for a folder (format 0x3001, association type 1, the same type existing tapes report) made `tapes/PROBE 1-#A` with no SendObject. The OP-1 put nothing in it at first. All four tracks and `tape.json` (copied from 2026-220#02) read back exactly. The OP-1 then showed and played the tape. After leaving MTP mode, and on every reconnect since:
- **The OP-1 lowercased the folder name** to `probe 1-#a`. Within the session it was still listed as typed. The user's own tape is also stored lowercase, as `abc- 012#-#`, so names are lowercase on disk whatever the display shows. The framework should create names in lowercase, compare them ignoring case, and expect handles and names to change after the OP-1 leaves MTP mode.
- **It added `readme.txt`** (104 bytes), as other tapes have.
- **It kept the written `tape.json`,** apart from the playhead.
- 8 of 8 tape slots are now in use.

**The delete didn't run, because of a probe bug, not the OP-1.** Delete test tape looked for the exact name `PROBE 1-#A`, didn't find `probe 1-#a`, and cleared its record without sending DeleteObject. It's fixed: tape names now match ignoring case, including the check that the name isn't taken. The handle is read from a fresh listing. The button names the tape and asks before deleting. If the record is gone, the button falls back to a tape named like the name field.

**Deleting a whole tape works (iPad, 2026-11-08, second log in the same folder).** After the fix, Delete probe 1-#a deleted the six files (`tape.json`, `readme.txt` and four tracks) and then the folder, each with response OK, in 0.06 s. `tapes/` no longer listed it, leaving 7 of 8 tapes, and the user confirmed it was gone from the OP-1. Whether DeleteObject on a folder that still has files would delete them too is untested; deleting the files first works.

Tape names (from the user): A–Z, 0–9, `#`, `-` and space look allowed. The maximum length is unknown. The user's sample tape is stored as `abc- 012#-#`, 11 characters. The maximum length is still unknown.

Correction (2026-11-08): an earlier note here said `mixdown/side_b.wav` had changed to 3,992,876 bytes. It hadn't: that is the size of the Mac backup it already matched, and the 16 MB figure came from an older copy. The Mixdown write test still applies.

## Chunked reads get slower with the offset (FieldCheck, iPad, 2026-11-13)

This came from FieldCheck, not the probe, which is frozen. It's recorded here because it's a device behavior. The evidence is in `firmware/1.7.3/runs/`.

**Each GetPartialObject takes longer the further into the file it starts.** FieldCheck's level 1 `read.speed` reads the first 16 MiB of the largest tape track in 1 MiB chunks, in order.
- **First run (`fieldcheck-2026-11-13T134837Z`):** 16 MiB in 8.5 s, 2.0 MB/s. That's far below the 6.5–9.5 MB/s the probe measured for 1 MiB chunks, but the probe only ever read the chunks at offsets 0 and 1 MiB.
- **Second run, with each chunk timed (`fieldcheck-2026-11-13T135316Z`):** the same 2.0 MB/s, and the chunk times rise steadily: 62, 161, 221, 276, 333 ms… up to 960 ms for the chunk at 15 MiB. That's about 58 ms more for each MiB of offset, or about 18 MB/s, close to the whole-file read speed of about 20 MB/s.

So a read seems to cost about what reading the file from its start up to the end of the chunk would. The likely explanation is that the OP-1 reads from the start of the file every time, rather than seeking. That's an inference from the timings; the cause can't be seen over MTP.

What it means:
- **Reading a file in 1 MiB chunks takes time that grows with the square of its size.** For a full 6-minute track (127 MB), the formula gives about 7 minutes, against about 6 s for one GetObject. The first 16 MiB already take 8.5 s in chunks, against under 1 s whole.
- **Larger chunks help only partly.** With 16 MiB chunks, the formula gives about 35 s for 127 MB.
- **GetObject is linear, but holds the whole file in memory:** up to 127 MB for one track. The probe held about 66 MB with no trouble.
- **Every chunked read before this was small or near the start of a file,** so nothing earlier showed it. The one 60-second hang (2026-11-08) was a 1 MiB read at offset 1 MiB, so this doesn't explain it.

**Decided by the owner (2026-11-13): FieldTapeKit won't read large files in 1 MiB GetPartialObject chunks.** Both runs showed it's about 10 times slower than a whole-file read over the first 16 MiB, before any extrapolation.

Still open, and decided before step 7 of the plan:
- **What replaces them:** one GetObject, larger chunks, or a mix. ADR 0002 changes then, as one decision.
- ~~**Whether the cost grows with the offset or with the number of requests.**~~ Answered on 2026-11-14, below: the offset.
- **Past 16 MiB, the figures are extrapolated,** and iPhone and macOS weren't measured.

**The cost grows with the offset, not the number of reads (FieldCheck `read.cost`, iPad, 2026-11-14, `firmware/1.7.3/runs/fieldcheck-2026-11-14T172405Z`).** On the same 22 MB tape track:
- **The same 1 MiB chunks read in reverse,** last chunk first, still rose with the offset: 105 ms at offset 0, up to 918 ms at 15 MiB, about 56 ms per MiB. In order they rose by about 58 ms per MiB. A cost per read would have made the reverse times fall with the offset instead.
- **One GetPartialObject for all 16 MiB from offset 0** took 0.87 s, 19.2 MB/s, against 8.5 s in 1 MiB chunks.
- **One GetObject of the whole 22,056,500-byte track** took 1.17 s, 18.8 MB/s, and matched the chunks.

So a read costs about what reading the file from its start to the read's end would, at about 19 MB/s, however it's split. Reading a whole file once is linear. Reading it in pieces costs time that grows with the square of its size. A small read near the end of a large file costs nearly a whole read: about 6.7 s near the end of a full 127 MB track, if the rate holds that far. GetObject also worked on a 22 MB track, which partly answers the question below about full-size tapes.

**FieldTapeKit's copies match the probe's (FieldCheck conformance suite, iPad, 2026-11-14, `firmware/1.7.3/runs/fieldcheck-2026-11-14T213915Z.txt`).** `copyItem` read `mixdown/side_a.wav` and `tapes/2026-220#01/track_4.wav` with one GetObject each, read the copies back, and logged SHA-256s that equal the ones the probe recorded for the same files with its own code: `65c9af35…138aeb1a` (2026-11-03) and `9aecf102…ecb69497` (2026-11-08). The copies pulled to the Mac hash the same. Neither file changed in between.

## Level 2's scratch writes (FieldCheck, iPad, 2026-11-15)

FieldCheck's first level 2 run passed all 8 checks in 8.2 s (`firmware/1.7.3/runs/fieldcheck-2026-11-15T023343Z`, log `fieldcheck-2026-11-15T023305Z.txt`). It was FieldTapeKit's first write to the OP-1, through its public file layer: steps 8 to 10 of the plan, on hardware.
- **A 15-character tape name was taken:** `FIELDCHECK #1-2` was made with SendObjectInfo alone, listed as `fieldcheck #1-2`, a folder with association type 1 and nothing in it.
- **Writes are exact:** a new tape's 250-byte `tape.json` and four 705,644-byte tone tracks read back byte for byte. `track_5.wav` was refused with 0x2002, as in 2026-11-05's `mixdown/` refusal.
- **The rebuild and the stale size, again:** after the tracks were written, `tape.json` read back different, still listed and read at the 250 bytes written. That's what the probe saw on 2026-11-08, now in a single session with no restore around it.
- **Both kinds of replace worked:** `track_1.wav` was replaced keeping a copy, and the copy has the first tone's SHA-256 (`0b22dc9e…`). Then the stale `tape.json` was replaced through a confirmation, with the generated one, and read back exactly.
- **New: `synth/user/` keeps 6 seconds.** The same 25-second, 16-bit stereo WAV came back as AIFC with the samples sent, cut to exactly 264,600 frames (6.000 s) in `synth/user/`, and to 882,000 (20.000 s) in `drum/user/`, as on 2026-11-05. The drum copy is 3,532,220 bytes, the same size as the probe's.
- **New: a converted preset keeps its WAV format code.** Both converted files were still listed as WAV (0x3008), though they hold AIFC. So a file's format code in a preset folder says what was sent, not what's stored.
- **Deleting presets worked,** one with a copy and one with a confirmation.
- **Free space followed the writes closely.** It fell 7,414,784 bytes for 7,414,918 written, and after the presets were deleted it was 2,823,168 below the start, for the scratch tape's 2,823,150. Both changes are multiples of 512 and within 512 bytes of what was written, so free space may count in 512-byte units. One run isn't enough to say.

The scratch tape stays on the OP-1 until it's deleted with FieldCheck's **Delete FieldCheck's content**, or by level 3 once step 12 exists. After that first run it was deleted with the button, but that log was lost.

**A second run, with the cleanup recorded (2026-11-15, `firmware/1.7.3/runs/fieldcheck-2026-11-15T035517Z`, log `fieldcheck-2026-11-15T035505Z.txt`).** All 8 checks passed again in 8.0 s, with every figure the same as the first run's, free space included.
- **Deleting the scratch tape works:** **Delete FieldCheck's content** reported `delete.files-then-folder` passing. Its 5 files were deleted first, then its folder, and the tape was gone, in 0.1 s.
- **Deleting gives the space back exactly.** Both runs started at 6,285,685,760 bytes free, so the first run's cleanup returned all 2,823,168 bytes the scratch tape had taken.
- **A converted preset differs between runs by one byte.** The OP-1 writes an `mtime` into the JSON in the preset's `APPL` chunk. It was `1794692000.0` in the first run and `1794697000.0` in this one, the same size and samples otherwise. Read as Unix time, those are 21:33:20 and 22:56:40 UTC on 2026-11-14, about five hours before each run. That fits the OP-1's clock being on US Eastern local time. (They looked rounded to 1,000 seconds, but the next run's was `1794697625.0`, so they aren't.) So a byte-for-byte check can't compare one converted preset with another, which is one more reason the preset read-back checks samples. The kept `track_1.wav` copy again has the first tone's SHA-256.

## Level 2 with the long check (FieldCheck, iPad, 2026-11-15)

Level 2 with step 11b's checks, and the long check asked for: 10 passed and 1 didn't run, in 37.8 s (`firmware/1.7.3/runs/fieldcheck-2026-11-15T040647Z`, log `fieldcheck-2026-11-15T040612Z.txt`). Every check from 11a saw the same figures as the two runs before, free space included.
- **A full 6-minute track works both ways.** `track_2.wav` was replaced with 127,008,044 bytes, the most a track can hold. The send took 17.0 s, 7.5 MB/s. The whole file then read back byte for byte in one GetObject, twice: once in the write's own check and once by FieldCheck, in 6.1 s, 20.7 MB/s. This is the first full-size transfer in either direction, and nothing stalled. Then the 2-second tone and `tape.json` were put back, and the scratch tape ended as in the other runs.
- **Memory:** FieldCheck went from 292.7 MB before the long check to a peak of 543.3 MB, about 250 MB more, or two copies of the track: the one sent and the one read back. The peak is the app's highest since launch, so it's an upper bound for the check.
- **Write speed (`write.speed`):** 7.3 MB/s over all 5 audio writes, timed as each write less a read of the same file. The 705,644-byte tracks managed about 4 MB/s each (153–185 ms), so a small write's time is mostly the fixed cost of its requests, not the data. 7.5 MB/s for the full track matches the probe's 7.4 MB/s on a 22 MB track (2026-11-08).
- **The album wasn't touched:** both sides have audio, so `album.write-exact` didn't run.
- **The space came back exactly.** Free space after the writes, and after cleanup, was the same as in the runs without the long check, so replacing a 127 MB track with a 705 KB one gave all of it back.
- **The preset's `mtime`** was `1794697625.0` this time: 23:07:05 read as UTC, during the run, in US Eastern time. All three runs' values are within a minute and a half of their run, but the first was 23 seconds before its run started and the second 83 seconds after, so how the OP-1 sets it isn't clear.
- **Cleanup:** **Delete FieldCheck's content** passed `delete.files-then-folder` again, in 0.1 s. The kept `track_1.wav` copy has the first tone's SHA-256.

## The OP-1 cuts tape names to 12 characters (FieldCheck, iPad, 2026-11-15)

FieldCheck's first level 3 run (`firmware/1.7.3/runs/fieldcheck-2026-11-15T042019Z` for level 2, `...T042129Z` for level 3, log `fieldcheck-2026-11-15T041948Z.txt`). Level 2 passed 9 checks, with the same figures as before, and left level 3 waiting. The owner left MTP mode and entered it again, and level 3 found no `tapes/fieldcheck #1-2`, so it ran nothing.
- **The tape was there, renamed `fieldcheck #`.** The owner found it in FieldCheck's Explore tab. Free space after the reconnect was exactly level 2's figure with the tape on the OP-1, so its 2.8 MB were still there.
- **So the OP-1 keeps 12 characters of a tape's name.** It took the 15-character name over SendObjectInfo, listed it whole for the rest of the session, then cut it to its first 12 while out of MTP mode. It wasn't the `#`: the probe's `probe 1-#a` kept what followed its `#` (2026-11-08). That name had only 10 characters, which is why the cut wasn't seen before.
- **Not yet known:** what happens when two names cut to the same 12 characters, and whether the OP-1's own name editor stops at 12. FieldTapeKit now refuses new names over 12 (ADR 0002), so it can't cause either.
- **A FieldCheck gap it showed:** level 3's refusal cleared the waiting level 3, and the cleanup offer looked only for FieldCheck's own names, so FieldCheck lost track of the cut tape. Both are fixed. The owner deletes `fieldcheck #` on the OP-1.
- **Write speed with small tracks only:** 4.1 MB/s for the four 705,644-byte tracks, as in the long-check run, so the fixed cost per write holds.

## Level 3 passes, and a folder deletes with its files (FieldCheck, iPad, 2026-11-15)

Levels 2 and 3 with the 12-character scratch tape (`firmware/1.7.3/runs/fieldcheck-2026-11-15T043147Z` and `...T043206Z`, log `fieldcheck-2026-11-15T043130Z.txt`). The owner deleted `fieldcheck #` on the OP-1 first. Level 2 passed 9 checks, and the 2 not run were the long check and the album. The owner left MTP mode and entered it again about 3 seconds later, and level 3 passed all 6 checks in 0.9 s.
- **Names:** `fieldck #1-2` (12 characters) was kept, and `fieldck #2-13` (13) came back as `fieldck #2-1`, its first 12. So the cut is at 12, confirmed both ways.
- **Handles:** all 6 of the scratch tape's objects had new handles.
- **`readme.txt`:** the OP-1 added one of 104 bytes, the same size as on the probe's tape (2026-11-08).
- **Kept:** all four tracks read back byte for byte, and `tape.json` was unchanged, `pos` and `tempometronomelevel` included. `pos` stayed 0, so the tape probably wasn't played.
- **New: DeleteObject on a folder deletes its files too.** One DeleteObject on the scratch tape's folder, with its 6 files in it, was answered OK. The folder was gone, and GetObjectInfo on each file's old handle was refused, so nothing was left behind. This settles `delete.folder-with-files` on 1.7.3. FieldTapeKit still deletes files first, and step 18 decides whether to change that.
- **Deleting files then the folder** also passed again, on `fieldck #2-1`.
- **Free space** fell by within 512 bytes of what was written, as in every earlier run: 10,237,952 for 10,237,744, now with two tapes.

## The three-level baseline (FieldCheck, iPad, 2026-11-15)

One launch ran level 1, the conformance suite, level 2 with the long check, and level 3 after a reconnect, then saved them as `firmware/1.7.3/baseline.json` (format 2, one section per level; log `firmware/1.7.3/runs/fieldcheck-2026-11-15T161548Z.txt`, with the level 2 and 3 reports beside it). Everything passed, and only `album.write-exact` didn't run, since both sides have audio.
- **Nothing moved since the earlier runs.** Level 1 matches the previous baseline on every field that doesn't vary: the chunk times again rose from 61 to 959 ms, at 1,974 KB/s against 1,976. The long check sent at 7.5 MB/s and read at 20.7 MB/s, with the same memory peak, 543 MB. Free space, the preset caps, the 12-character cut and the folder delete all came out as before.
- **The conformance copies** of `mixdown/side_a.wav` and `tapes/2026-220#01/track_4.wav` have the same SHA-256s as the probe's and 2026-11-14's.
- The level 1 report file wasn't kept from this launch, but its results are in the baseline and the log.

## FieldTapeKit lists the tapes (FieldCheck conformance suite, iPad, 2026-11-15)

Step 13's tape layer, through the conformance suite (log `firmware/1.7.3/runs/fieldcheck-2026-11-15T163827Z.txt`): 17 of 17 passed. `tapes()` listed the 3 folders in `tapes/`, and `tapeSlots()` counted 3 of 8. All three are sound, Studio (type 0), with every track matching its clips:
- **2026-220#01:** track 4 only, 62.5 s. Its last clip ends at frame 2,757,057, as in the `tape.json` the probe logged on 2026-11-08, and `track_4.wav` is 44 + 8 × that.
- **2026-276#01:** all four tracks, 1:00.
- **2026-286#01:** tracks 1 and 2, 4.3 s, ending at frame 190,145 as on 2026-11-08.

So none of the three has changed since the probe read them. Each manifest's bytes equal `tape.json` read on its own, and `tape(named:)` gives the same tape as `tapes()`. The conformance copies of `side_a.wav` and `track_4.wav` have the same SHA-256s as every earlier run.

## Copying a tape off, and the memory it leaves (FieldCheck conformance suite, iPad, 2026-11-15)

Step 15's `copyTape`, through the conformance suite from a fresh launch (log `firmware/1.7.3/runs/fieldcheck-2026-11-15T193102Z.txt`): 18 of 18 passed. It copied 2026-276#01, the largest tape (four tracks of 21.2, 18.0, 18.0 and 21.2 MB, 16 clips), in about 4.3 s into a 78,328,519-byte `.reelarchive`. On the Mac, `aa extract` took the archive apart. Every track's SHA-256 matched the one logged, and every track is 44 + 8 × the end of its last clip in the archived `tape.json`. The other copies matched every earlier run.

**Memory, logged after each check:**
- FieldCheck started at 23.6 MB, so it's small at rest. The 300 MB seen before the long check on 2026-11-15 wasn't FieldCheck at rest.
- After `copyTape` returned, it held 153.6 MB, 129 MB more than before, though only one 21 MB track should be in memory at a time, and only during the copy.
- Copying `side_a.wav` (12 MB) after it brought it down to 132 MB. Copying `track_4.wav` (22 MB) then took it to 199 MB, about three times the file's size.
- On the Mac's simulator, copying an 84 MB simulated tape three times in a row kept about 2 MB in all. So FieldTapeKit's own code doesn't keep the data. What stays comes from the ImageCaptureCore path: its own buffers, or the `NSData` it returns being released late.
- **It levels off (three runs in one launch, log `fieldcheck-2026-11-15T193457Z.txt`).** After each copy of the 78 MB tape, FieldCheck held 151.9, then 148.9, then 132.6 MB. It never grew by the tape's size. Between runs it fell to about 112 MB, and early in the third run, with nothing transferring, to 47.4 MB. The highest it reached was 194.1 MB. So the ImageCaptureCore path keeps transferred data for a while and releases it later: a bounded cost of up to about 170 MB over the app's own, not a leak. All three copies had the same track hashes.

## A deleted album side comes back after a reconnect (the owner, macOS companion app, 2026-11-16)

**The OP-1 can't empty a side itself:** there's no way to clear or delete one on the device, only to record over it. So a side is never empty unless it was never recorded, and FieldCheck's `album.write-exact`, which needs an empty side, has never run on this OP-1.

**A side deleted over MTP was back after leaving MTP mode.** The owner deleted a side with the macOS companion app over MTP. The delete looked like it worked, but after leaving MTP mode and entering it again, the file was there again. No log was kept, and whether it came back with its old contents hasn't been checked, though nothing else could have made it.

**What it suggests, not yet shown:** the OP-1 keeps the album itself and rebuilds `mixdown/` from it when it leaves MTP mode, as it rebuilds `tape.json`. If so, a side written over MTP might also be replaced by the OP-1's own copy after a reconnect. The probe's 2026-11-08 mixdown write can't tell: it wrote `side_b.wav` back with the same bytes, and checked them only in the same session. FieldCheck now checks it across a reconnect (`album.write-kept`, ADR 0003).

## A written side lasts, but putting it back hung (FieldCheck levels 2 and 3, iPad, 2026-11-16)

Log `firmware/1.7.3/runs/fieldcheck-2026-11-16T035757Z.txt`, with the level 2 report `fieldcheck-2026-11-16T035851Z` and the level 3 report `fieldcheck-2026-11-16T035919Z`.

**Level 2 passed 10 of 10.** Its new last check copied side B (3,992,876 bytes) into `level2-2026-11-16T035851Z/side_b before level 2.wav` and verified it, then wrote FieldCheck's 2-second tone (352,844 bytes) over side B with `restoreSide`, and read it back byte for byte. The copy pulled to the Mac has SHA-256 `9204518b…5f361a97aa`, the same as the probe's 2026-11-08 backup and step 20's run, so side B can be put back exactly.

**A written side lasts after leaving MTP mode.** After the reconnect, free space was 6,283,678,720 bytes: level 2's 6,280,039,424 before the album step, plus 3,992,876 for side B, less 352,844 for the tone, is 6,283,679,456, within 736 bytes. So the OP-1 kept the tone, not its own side. The owner then played side B on the OP-1 and heard the 2-second tone. So `album.write-kept` holds on 1.7.3, and the 2026-11-16 delete that came back was the OP-1 refilling a missing side, not rebuilding a written one.

**Putting side B back hung.** Level 3's tape checks passed 6 of 6. Then `album.write-kept` stopped with "The OP-1 disconnected during this check": a request got no answer in 30 s, and the ping after it none in 5 s (level 3 took 37 s). The iPad logged no disconnect, so the OP-1 stopped answering MTP while still attached, as on 2026-11-08. Which request hung isn't known: the report kept only the disconnect. Side B still holds the tone. FieldCheck now traces every MTP request when it puts a side back, and offers that for a side holding its tone.


## Putting side B back hangs at SendObjectInfo (FieldCheck, iPad, 2026-11-16)

Log `firmware/1.7.3/runs/fieldcheck-2026-11-16T040711Z.txt`, FieldCheck's new "Put Side B back", with every MTP request traced.

**The OP-1 stopped answering at SendObjectInfo.** The reads all answered in under 30 ms. `DeleteObject 0x43`, side B holding the 352,844-byte tone, answered OK in 3 ms. Then `SendObjectInfo` into `mixdown/` (parent 0x41, a 78-byte dataset announcing 3,992,876 bytes for `side_b.wav`) got no answer in 30 s, nor a ping in 5 s. The OP-1 had to be restarted, as after level 3. **After the restart, side B was the tone again:** the OP-1 refilled the deleted side from its own album, which holds what was last written to it.

**What's the same in the two hangs, and what worked:**
- Both hung putting the 3,992,876-byte side B over the 352,844-byte tone, as the first write after a reconnect.
- Writes that worked: the probe's side B over itself at the same size (2026-11-08), and level 2's tone over side B, shorter, after several other writes in the session.
- So a side growing longer than the one it replaces, or a side being the first write after a reconnect, are both still possible causes. Neither is shown.

**Not the first write after a reconnect (log `fieldcheck-2026-11-16T041259Z.txt`).** With a warm-up first, in the same connection, `drum/user/fieldcheck.wav` was written and deleted without trouble: SendObjectInfo answered in 2 ms, SendObject sent 4,410,044 bytes in 2.4 s, and the read-back and delete answered. Then side B's delete answered OK in 2 ms, and its SendObjectInfo hung the same way, and the OP-1 needed a restart again. Side B is still the tone. So it's something about writing this side: most likely that a side can't grow past what the OP-1 holds for it (352,844 bytes now), since every side write that worked was the same size or shorter. Not yet shown.

**Side B is back, by writing a shorter side (log `fieldcheck-2026-11-16T041944Z.txt`).** The owner recorded about 28 s onto side B on the OP-1 (4,949,548 bytes). FieldCheck copied that recording off into the level 2 folder as `side_b replaced 2026-11-16T042001Z.wav` and verified it, deleted side B, and sent the 3,992,876-byte copy: SendObjectInfo answered in 3 ms, SendObject in 825 ms, and side B read back byte for byte. So a side written shorter than the one it replaces works right after a reconnect, as the tone did in level 2, and every write that hung was one where the side grew. That's strong support for "a side can't grow over MTP" on 1.7.3, though growth from an empty side hasn't been tried.

## A hang in level 2, away from the album (FieldCheck, iPad, 2026-11-16)

Log `firmware/1.7.3/runs/fieldcheck-2026-11-16T042721Z.txt`, level 2 report `fieldcheck-2026-11-16T042735Z`.

**Level 2 stopped at `write.preset-converted`** with "The OP-1 disconnected during this check": no answer for 30 s, nor to a ping, and the run took 45.8 s. The album check comes last, so it didn't run, and side B wasn't touched. There's no trace: level 2 doesn't trace its requests yet.

**Where it stopped, from free space.** After the reconnect, free space was 10,238,976 bytes below the start. The scratch tapes (5,645,976) and both presets as the OP-1 stores them (3,532,220 and 1,059,548) make 10,237,744, within 1,232 bytes. So both presets were written and are still there, and the drum preset's copy never reached the run folder. The hang was after the second preset was written: reading it back, reading free space, or reading the drum preset to copy it before deleting it. All of those are reads.

**What it changes.** It's the fourth hang today, and the first that isn't a side growing. Every earlier level 2 passed this check, including today's first, and the warm-up wrote and deleted the drum preset without trouble. So "a side can't grow" still fits the three side hangs, but the OP-1 can also stop answering elsewhere, and it may be getting more likely after several restarts in one day. Whether it was the same hang can't be told without a trace.

## Not growth: a side written over MTP can't be replaced after a reconnect (FieldCheck, iPad, 2026-11-16)

Log `firmware/1.7.3/runs/fieldcheck-2026-11-16T043311Z.txt`, level 2 `fieldcheck-2026-11-16T043329Z` and level 3 `fieldcheck-2026-11-16T043349Z`. FieldCheck's leftovers from the hung run were deleted first, without trouble.

**Level 2 passed 10 of 10**, with the tone exactly as long as side B, 3,992,876 bytes. **Level 3's tape checks passed 6 of 6.** Then putting side B back, at the same length, hung exactly as before: side B's `DeleteObject` answered OK in 2 ms, and the `SendObjectInfo` after it got no answer in 30 s, nor a ping in 5 s. The OP-1 froze and had to be restarted. So **the side didn't grow, and it still hung: the growth rule is wrong.**

**What fits all four side hangs, and all three side writes that worked:**

| Write | Side B held | Result |
|---|---|---|
| Probe, 2026-11-08 | audio, the same bytes | worked |
| Level 2, twice today | the owner's audio | worked |
| Put-back after the owner recorded over side B | a recording made on the OP-1 | worked |
| Level 3, and both put-backs, after a reconnect or restart | FieldCheck's tone, written over MTP in an earlier connection | **hung**, every time |

So the likely rule is: **once the OP-1 leaves MTP mode, a side written over MTP can't be written over MTP again**, at any length, until it's recorded over on the OP-1. A restart doesn't clear it: two of the hangs came right after one. Recording over the side on the OP-1 does. Not yet known: whether writing a side twice in one connection works, and whether anything visible, such as the side's ObjectInfo, tells the two kinds of side apart. A side's ObjectInfo is 142 bytes in both states.

**Decided by the owner: album writing is off on 1.7.3, as a future improvement** (ADR 0002's change log). The owner's app needs only to read and copy the album. Side B is left holding FieldCheck's 22.6-second tone for now. The verified copy is in `level2-2026-11-16T043329Z`, and putting it back means recording over side B on the OP-1 first, then FieldCheck's put-back.

## The OP-1 crashed on a side header read, right after connecting (FieldCheck, iPad, 2026-11-16)

Log `firmware/1.7.3/runs/fieldcheck-2026-11-16T130232Z.txt`, level 1 report `fieldcheck-2026-11-16T130249Z`.

**The owner recorded about 13.8 s onto side B on the OP-1, then entered MTP mode.** As it connected, FieldCheck's own check for a side to put back started reading: the album listing, then each side's 44-byte header with GetPartialObject. That check never finished. Level 1 started about 5 s later, and its first request queued behind it. **The GetPartialObject got no answer in 30 s, nor a ping in 5 s, and the OP-1 showed a crash stack on its screen.** It's the first crash, not just a hang. After a restart, the same check read side B, 2,435,116 bytes, without trouble.

**What it suggests, not shown:** reading a side right after recording it, as the OP-1 enters MTP mode, may catch the OP-1 while it's still finishing the album. Every hang today but one involved an album side.

**What changed in FieldCheck:** it no longer reads the album when an OP-1 connects, since album writing is off and the put-back offer was the only reason. It traces every MTP request from the moment an OP-1 connects, so a hang in its own checks names its request too. Before, only requests during a level or the cleanup were traced, so this one showed only as the `✕` line.

## Level 1 matches the baseline; level 2 hangs reading back a write (FieldCheck, iPad, 2026-11-16)

Log `firmware/1.7.3/runs/fieldcheck-2026-11-16T131147Z.txt`, with every MTP request traced from connect.

**Level 1 passed 18 of 18, twice, with 0 changed** against the built-in 1.7.3 baseline, so step 22's comparison finds no false change on hardware.

**Level 2 hung twice, each time on a GetObject reading back a file it had just written.** **The OP-1 wasn't stuck either time,** the owner says: unplugging and plugging it back in, with no restart, was enough, and the next connection worked at once.
- First run, in `names.maximum`: the 13-character tape's tracks were being written. `SendObject` of 705,644 bytes answered OK in 166 ms, then `GetObject 0x8F`, the read-back, got no answer in 30 s, nor a ping.
- Second run, in `write.preset-converted`: `GetObject 0xF0`, the drum preset just written, got no answer, the same way.

Neither involves the album. Both checks passed in every level 2 on 2026-11-15 and in two of today's. **Since the OP-1 was fine, the request was most likely lost or stuck on the iPad's side, in ImageCaptureCore,** which sends one request at a time: the ping queued behind the stuck GetObject, so it can't tell a lost reply from a dead OP-1. FieldTapeKit's session now logs when an abandoned request's answer arrives late, and how late, to tell slow from lost. Not yet known: which of today's earlier "stuck" hangs were the iPad's, since the OP-1 was restarted each time without checking whether a replug alone would do.

## Levels 1 and 2 match the baseline; level 3 hangs on a read (FieldCheck, iPad, 2026-11-16)

Log `firmware/1.7.3/runs/fieldcheck-2026-11-16T132015Z.txt`.

**Level 1 passed 18 of 18 and level 2 9 of 9, with 0 changed** against the built-in baseline, and 2 not run as expected: the long check, and the album, with album writing off. Level 3 ran after a reconnect, passed `reconnect.handles`, `names.maximum` and `reconnect.renamed`, then hung in `reconnect.kept`: `GetObject 0x1D4`, the scratch tape's `track_4.wav`, got no answer in 30 s, nor a ping. **The OP-1 wasn't stuck.** It's the third hang in a row on a GetObject of a small file, after its listing answered in about 1 ms.

The late-answer trace added after the last run didn't show whether an answer came later: it was kept in the trace, but logged only with a failure. FieldCheck now logs a late answer as soon as it arrives.

## The hang is a 60-second stall, and FieldTapeKit gives up on the session too soon (FieldCheck, iPad, 2026-11-16)

Log `firmware/1.7.3/runs/fieldcheck-2026-11-16T132641Z.txt`.

**Level 1 stopped in `read.cost`**, on its one 16 MiB GetPartialObject, which takes 0.89 s normally. It got no answer in 30 s, nor the ping in 5 s. The owner left the OP-1 connected for a minute: **the read answered after 60.5 s**, and was dropped. The OP-1 wasn't stuck. So today's hangs are most likely **stalls of about 60 s that end on their own**: the same as the probe's one GetPartialObject that "hung for 60 seconds and never recurred" (ADR 0002's table of findings), now recurring. The ping can't help: ImageCaptureCore sends one request at a time, so the ping waits behind the stalled request.

**And FieldTapeKit made it worse.** Once the ping failed, the session marked itself disconnected for good, though the OP-1 was still there. A second level 1, after the read had answered, failed at once ("took 0.0 s"), as did the cleanup and level 2's plan, until the OP-1 was replugged. So every stall today cost a replug, and the earlier ones a restart, when waiting about a minute might have been enough.

Not yet known: what causes the stall, why it's frequent today and rare before, whether the data of a request that answers late is right, and whether 60 s is a limit somewhere, such as in ImageCaptureCore or the OP-1's USB stack.

**Decided by the owner:** FieldTapeKit now notes a request as slow after 30 s and waits for it until 90 s, with no ping (ADR 0002's change log). A stall that ends within that is just a slow request, and its answer is checked as usual.

## A stalled request ends after about 60 s with nothing, and the next one stalls too (FieldCheck, iPad, 2026-11-16)

Log `firmware/1.7.3/runs/fieldcheck-2026-11-16T133647Z.txt`, with FieldTapeKit waiting up to 90 s.

**Level 1 passed 17 of 18.** In `read.cost`, the 1 MiB GetPartialObject at offset 0xA00000 stalled. FieldTapeKit noted it slow after 30 s and kept waiting. At about 60 s, the request came back, **but with no response container**: FieldTapeKit reported it as an unreadable response. So a stall doesn't end with the OP-1's answer. Most likely ImageCaptureCore gives up on the request itself after about 60 s, and the earlier "answered after 60.5 s" was the same empty give-up, not data.

**Then the next request stalled too.** Level 2's plan, a GetObjectHandles, got no answer for 30 s, with nothing on FieldCheck's screen to say it was waiting, so its button seemed to do nothing. So after one stall the connection stays stuck until a replug. The OP-1 itself seems fine each time.

**What it suggests:** the stuck part is on the iPad's side, in ImageCaptureCore or its background service. The OP-1 was restarted several times today and the stalls kept coming back. The iPad hasn't been restarted. That's the next thing to try.

## The control: FieldCheck from before the album work stalls too (FieldCheck at 21450d5, iPad, 2026-11-16)

Log `firmware/1.7.3/runs/fieldcheck-2026-11-16T135303Z.txt`.

To tell our changes from the OP-1's state, FieldCheck was built from commit `21450d5` (step 18), from before any album work, with the old 30 s timeout and ping. It's the build that passed every level on 2026-11-15. The iPad had been restarted. **Level 1 stalled in `read.cost` the same way**: "The OP-1 disconnected during this check" after 54.5 s, and level 2 couldn't start. So **the stall isn't caused by anything changed since step 18.** It's in the OP-1's state, the iPad, or the cable, and it began right after side B was written over MTP several times, late on 2026-11-15.

## The Mac copies every tape cleanly, with the same cable (the owner, macOS companion app, 2026-11-16)

Right after the control stalled on the iPad, the owner plugged the OP-1 into the Mac with the same cable and copied all three tapes off with the macOS companion app: 2026-286#01, 2026-220#01 and 2026-276#01, about 100 MB in all. **None stalled.** 2026-276#01's four tracks have the SHA-256s FieldCheck recorded for it on the iPad (`d47bbe1d…`, `46d0b9be…`, `4daf143e…`, `714da5ed…`), so the OP-1 served them exactly.

So the OP-1 and the cable work. **The stall is on the iPad's side:** its USB port, iPadOS's MTP service, or ImageCaptureCore on it. Restarting the iPad didn't clear it. Not yet tried: another iOS device, such as the iPhone the probe also ran on (2026-11-08).

## The iPhone passes all three levels: the stall is this iPad's (FieldCheck, iPhone, iOS 27.2, 2026-11-16)

Log `firmware/1.7.3/runs/fieldcheck-2026-11-16T140744Z.txt`, the same FieldCheck build, OP-1 and cable as the iPad's last runs.

**Every level passed, with 0 changed against the baseline:** level 1 18 of 18, level 2 9 of 9 (the long check and the album not run, as expected), and level 3 6 of 6, in 1.3 s. No request was slow. It's the first clean run of all three levels since 2026-11-15.

So **the stall belongs to this iPad**, iPad Pro on iPadOS 27.2.1: its USB-C port, or a state its MTP stack has kept since the evening of 2026-11-15, which a restart didn't clear. The OP-1, the cable, FieldTapeKit and FieldCheck all work. Not yet known: what on the iPad causes it, and whether it clears by itself.

## The second read before a delete passes on the OP-1 (FieldCheck, iPhone, iOS 27.2, 2026-11-17)

Log `firmware/1.7.3/runs/fieldcheck-2026-11-17T032616Z.txt`, FieldCheck built from `2905747` (step 23). Since step 23, any delete covered by a copy first reads the OP-1 again and matches it to the copy. A mismatch throws before anything is deleted, so each pass means the second read agreed.

- **The writing conformance passed 6 of 6.** `moveTape` moved a duplicate of 2026-286#01 (3,036,280 bytes) off in 3.2 s. The restore with `.replace(archivingExistingTo:)` archived the scratch tape and restored over it in 3.6 s. Every track's SHA-256 is the one from earlier runs.
- **Level 2 passed 9 of 9, with 0 changed,** in 10.4 s. The long check and the album didn't run, as expected. Its track replace and drum preset removal go through `keepingCopyAt:`. The kept `track_1.wav` has the SHA-256 `write.exact` recorded for it (`0b22dc9e…`). The kept drum preset is the 3,532,220 bytes the OP-1 stored.
- **Level 3 passed 6 of 6, with 0 changed,** after a reconnect.
- **No request was slow,** so the second read cost no visible time at these sizes.

The log doesn't list each request, so it can't show the second GetObject itself. What the passes show is that the second read agrees with the copy on real hardware, with no false mismatch. A real mismatch is tested only in the simulator.

## The Mac stalls the way the iPad does (FieldCheck, Mac, macOS 27.0.1, 2026-11-17)

Log `firmware/1.7.3/runs/fieldcheck-2026-11-17T125328Z.txt`, the first FieldTapeKit run on a Mac (step 24a, unsandboxed). ImageCaptureCore found the OP-1 and opened a session with no authorization request.

- **Level 1 passed 17 of 18,** with every pass matching the baseline. 1 MiB chunks cost about 59 ms more per MiB of offset, as on iOS.
- **`read.cost` failed on its one 16 MiB GetPartialObject,** the request the iPad stalled on (2026-11-16):
  - It was noted slow at 30 s.
  - At about 60 s, ImageCaptureCore called back with no error and no response container, so FieldTapeKit reported an unreadable response.
- **The next request stalled the same way.** Level 2's planning sent GetObjectHandles, which came back empty after about 60 s, so level 2 didn't start. Nothing was written.
- **A replug cleared it.**

So **the stall isn't only the iPad's.** Two hosts show it: the iPad and this Mac. The iPhone 17 Pro, also USB-C, has passed every run with the same OP-1 and cable.

The empty answer at about 60 s, with no error, looks like ImageCaptureCore giving up on the request. On the Mac, the companion app, FieldKit (Teenage Engineering's Mac app, confirmed by the owner), copied 100 MB cleanly with the same cable (2026-11-16). That copy didn't go through ImageCaptureCore. FieldKit bundles and links `libmtp` and `libusb`, and IOKit, not ImageCaptureCore (`otool -L`, 2026-11-17).

So the OP-1, the cable and the Mac's USB port carry 100 MB without a stall. That points the stall at ImageCaptureCore, on the Mac and the iPad, or at the requests we send through it. libmtp's requests may differ from ours, such as in how much each read asks for, so that isn't proven.

FieldCheck wrote a draft ADR calling `read.cost` incompatible. Its rule of no draft ADR for a check the OP-1 stopped answering during (2026-11-16) doesn't catch a stall that ends in an empty answer, so the draft is wrong and isn't kept.

### The second Mac run: whole-file copies work, chunked reads stall (2026-11-17)

Log `firmware/1.7.3/runs/fieldcheck-2026-11-17T130419Z.txt`, after a replug. The conformance suite ran first, then level 1.

- **The conformance suite passed 19 of 19** in 10 s.
  - `copyTape` copied 2026-276#01, 78 MB, in 4.3 s, and every track has the SHA-256 recorded on the iPad.
  - `side_a.wav` (`65c9af35…`) and `tapes/2026-220#01/track_4.wav` (`9aecf102…`) have the SHA-256s of every earlier run. `shasum` on the Mac's copies agrees.
  - So **FieldTapeKit's copy path, one GetObject per file, works on the Mac:** about 120 MB with no stall.
- **Level 1 stalled in `read.speed`.** It was on a 1 MiB GetPartialObject at offset 8 MiB, the 9th chunk of the 22 MB track, not on a 16 MiB read.
  - The request came back empty after about 60 s.
  - The next two requests, each a 1 MiB read at offset 0, came back empty after about 60 s too.
  - So `read.partial`, `read.speed` and `read.cost` failed, and level 1 took 184 s.

What the stalls on the iPad and the Mac have in common, so far:
- **Where they hit:** in a run of back-to-back GetPartialObject chunks of a large file. That was at offset 8 MiB here, on the 16 MiB read in the first Mac run, and at 0xA00000 on the iPad. The point varies, so **the size of the read isn't the cause.**
- **After a stall,** every request comes back empty after about 60 s until a replug, even a small read at offset 0.
- **Chunked reads are costly for the OP-1:** a chunk takes about 59 ms longer per MiB of offset, as if the OP-1 reads from the file's start each time. Whether that load is what trips the stall isn't known.
- **Whole-file GetObject:** on the Mac, it hasn't stalled yet. On the iPad, GetObject reads did stall (2026-11-16), so it isn't immune.

FieldCheck wrote a second wrong draft ADR, calling three reads incompatible. It isn't kept.

## Entering MTP mode from the app (paused 2026-11-08: possible, a future feature)

**Status:** paused by the user as too fragile for now, and kept as a possible future feature for the framework. What works: detecting a plugged-in OP-1 over USB MIDI, `greet`, and switching it into MTP mode with `mode`, from both the Mac and the iPad. What doesn't yet: on the iPad, ImageCaptureCore never saw the OP-1 after any switch in that session. Even MTP mode entered with the buttons failed until the OP-1 was restarted. Not tested: Leave MTP mode (closing the session), and a full app-triggered switch on a freshly restarted OP-1. To pick this up, start there, and restart the OP-1 whenever it shows connected but the app sees nothing. **The MIDI code was removed from the probe on 2026-11-08,** at the user's request, so it can't recreate the stuck state. That was `OP1MIDI.swift` (the `TESysEx` encoder and the CoreMIDI client), its tests, and the MIDI toggle and Enter and Leave MTP mode buttons. The format and bytes are kept below, and the Mac tools `tools/op1-midi-listen.swift` and `tools/op1-sysex.swift` remain. They only send when run by hand. The probe still logs each device's USB IDs.

Outside MTP mode, the OP-1 Field is a standard USB audio and MIDI device: USB product ID 0x8102, with interfaces "Audio In 0", "OP-1 Out 0" and "OP-1 Midi". In MTP mode it becomes 0x0102. FieldKit, Teenage Engineering's Mac app, sees it over MIDI and switches it with a SysEx request through CoreMIDI. Its log names the request `greet`. iPadOS has CoreMIDI and supports class-compliant USB MIDI, so an app can do the same.

**Message format**, from the OP-1's replies (captured with `tools/op1-midi-listen.swift`) and FieldKit's binary:
`F0 00 20 76 02 40 <flags> <request ID low 7 bits> <command> <payload> F7`
- `00 20 76` is TE's manufacturer ID, and `02` is the OP-1 Field's device ID.
- **Flags:** 0x40 marks a request, 0x20 says a request ID is present, and the low 5 bits are the ID's high bits.
- **Replies** clear 0x40 and start the payload with a status byte (0 is OK). Then comes the data, 7-bit packed: a byte holding the high bits, then up to 7 bytes.
- **Commands**, from FieldKit's list: 0x01 greet, 0x02 echo, 0x03 dfu, 0x04 mode, 0x05 rtc. **Never send 0x03.** It's probably the firmware updater.

**`greet` (0x01, no payload)** replies with text: `product:OP-1;mode:normal;serial:L1PXE14W;dsp_serial:…;os_version:1.7.3;sw_version:1.7.3;hw_rev:6;sku:TE002AS002`. FieldKit sends it on every connect.

**`mode` (0x04, payload `[0x01, value]`)** enters MTP. FieldKit picks the value from the USB product ID and the firmware version. For the OP-1 Field it uses 2 on firmware 1.5.7 or later and 3 before that, as read from FieldKit's x86_64 code. That comparison's direction is my reading of the disassembly.

**Verified on the Mac:** `tools/op1-sysex.swift` sent `f0 00 20 76 02 40 7d 30 04 00 01 02 f7` and got `… 3d 30 04 00 f7` (status OK). The OP-1 re-enumerated as 0x0102 and showed MTP connected. FieldKit's own clicks had the same reply and timing in the capture.

**In the probe (removed since):** the app started CoreMIDI beside ImageCaptureCore. When an "OP-1" MIDI endpoint appears, it logs it, sends `greet`, and shows "OP-1 plugged in, not in MTP mode". **Enter MTP mode** greets, checks the product is OP-1, sends `mode`, and logs how long ImageCaptureCore takes to find the device. Tests use the captured bytes.

**First iPad run (2026-11-08, `probe-results/midi-mtp-ipad-2026-11-08/`):** CoreMIDI found the OP-1 3.7 s after launch, under the name "OP-1", and `greet` replied in about 15 ms. `mode [0x01, 0x02]` returned OK, and the OP-1 left USB MIDI 2.8 s later. **But ImageCaptureCore never reported the device.** 17 s later it was back on MIDI, after the user left MTP mode. Earlier runs show ImageCaptureCore finding the OP-1 when the user enters MTP mode with its buttons while the app runs, so hot-plug works. Either the SysEx route gives a different MTP mode, or the device needs something more. Next checks:
- What the OP-1's screen shows after the iPad's command. **Answered: "MTP, connected"**, so the OP-1 entered MTP mode and something on the iPad opened a session with it. The app's ImageCaptureCore browser just didn't report it. If nothing is reported within 20 s, the probe now logs the browser's device list, restarts the browser with every device type and location, and logs the list again 10 s later.
- `tools/op1-icc-list.swift`, macOS's ImageCaptureCore listing devices with USB IDs, run after entering MTP mode by SysEx and then by the buttons. The probe also logs USB IDs when it finds a device now.
- Value 3 instead of 2, in case my reading of FieldKit's firmware comparison is backwards.

**Second iPad run (same folder, `probe-2026-11-08T163657Z.txt`):** same result. The mode command was accepted and MIDI was gone 0.8 s later. After 20 s the browser listed **0 devices**, and still 0 ten seconds after restarting it with every device type and location. So the app's ImageCaptureCore doesn't see the device at all, even though the OP-1 shows MTP connected. Next: enter MTP mode with the buttons while the probe runs, which now logs the device's USB IDs, and compare that with the 0x0102 the SysEx route gave on the Mac.

**Third iPad run (`probe-2026-11-08T164023Z.txt`): the buttons didn't work either.** The user entered MTP mode with the OP-1's buttons (MIDI gone from 4.7 s to 35.7 s), then by the app (accepted; the OP-1 showed connected). ImageCaptureCore reported neither, and the browser listed 0 devices. Before CoreMIDI was added, the probe found the OP-1 entering MTP mode by its buttons with the app running (`probe-results/create-tape-ipad-2026-11-08/`, Removed at 35.6 s and Found at 63.9 s). So the SysEx route isn't the cause. The app's open CoreMIDI client is the likely one, perhaps because it keeps iPadOS's USB MIDI driver attached to the device. The probe now has a **MIDI** toggle (saved between launches) to run with CoreMIDI off. It also disposes its MIDI client as soon as the mode command is accepted, and starts it again when MTP ends.

**Fourth iPad run (`probe-2026-11-08T164755Z.txt`): MIDI off, still not found.** The app was relaunched with CoreMIDI never started, and the user entered MTP mode with the OP-1's buttons. ImageCaptureCore reported nothing. So the app's MIDI client isn't the cause. Next: OP-1 in MTP mode before the app launches, which is the setup that always worked; then a cable replug; then an iPad restart, in case iPadOS's camera service is stuck.

**Resolved: the OP-1 was stuck (`probe-2026-11-08T171539Z.txt`).** Relaunching the app, replugging the cable and restarting the iPad didn't help. Restarting the OP-1 did: with MTP mode entered by its buttons before launch, ImageCaptureCore found it 0.6 s after browsing started, as USB `2367:0102`, and the probe passed. While stuck, the OP-1 showed MTP connected but iPadOS never offered it to apps, whichever way MTP mode was entered. The product ID matches the one the SysEx route gave on the Mac, so both routes give the same MTP mode. The likely trigger is the Mac session just before the first failed iPad run: two FieldKit switches, our `mode` command, and FieldKit leaving MTP through libmtp. That isn't proven. For the framework: if the OP-1 shows connected but nothing appears, tell the user to restart the OP-1. The probe's CoreMIDI client was a false lead.

**Leaving MTP mode:** FieldKit has no SysEx for it. Its only exit is libmtp's `LIBMTP_Release_Device`, which sends CloseSession and releases the device. In the earlier Mac capture, the user left MTP mode from FieldKit: MIDI vanished at 3.9 s and returned at 9.0 s, with no MIDI traffic in between. So closing the MTP session probably ends MTP mode. The probe's **Leave MTP mode** button calls ImageCaptureCore's `requestCloseSession` and logs whether the OP-1 comes back over MIDI. It hasn't been run yet.

Open questions:
- Does the iPad's CoreMIDI see the OP-1 the same way? **Yes:** the name is "OP-1" and the replies match the Mac's. Its endpoint name may differ, so the probe matches names starting with "OP-1".
- `rtc` (0x05) probably syncs the OP-1's clock. FieldKit logs "syncRTC". It's untested here.

## Questions for the real app

- Does GetObject work for full-size tapes? It worked on a 22 MB track at 18.8 MB/s (2026-11-14), and holds the whole file in memory. A full 127 MB track hasn't been tried. Reading in GetPartialObject chunks avoids holding it, but every read costs time in proportion to where it ends (2026-11-14, above), so chunked reads of large files are slow.
- Is `mixdown/` stored byte for byte like `tapes/`, and is 5.8 MB/s representative of large writes?
- Does a side written over MTP last past leaving MTP mode, or does the OP-1 put its own back (2026-11-16, above)?
- Does the OP-1 use a written file without a restart, and does replacing a tape track need `tape.json` updated?
- Do writes work the same from iPhone?
- Can the app keep the device if it's backgrounded mid-transfer? `ICDeviceBrowser` has suspend callbacks that the probe ignores.
