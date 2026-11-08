# ADR 0001: Connect to OP-1 Field on iOS/iPadOS via ImageCaptureCore (PTP), not a USB driver

- **Status:** Accepted (2026-11-08). Reading, writing, and whole-tape backup and restore validated on iPad and iPhone
- **Date:** 2026-11-03

## Context

The Teenage Engineering OP-1 Field exposes its storage over USB using Media Transfer Protocol (MTP), which macOS reaches through a companion app. We want an iOS/iPadOS app that can browse and transfer the OP-1 Field's files (tapes, albums, synth/drum presets).

Constraints on iOS/iPadOS:

- There is no public MTP API and no generic USB-host API.
- iPhone cannot load third-party USB drivers.
- M-series iPads (iPadOS 16+) support USBDriverKit, but a driver extension requires a DriverKit USB entitlement granted by Apple, and it excludes iPhone.
- MTP is an extension of PTP. iOS's ImageCaptureCore framework can talk to PTP cameras and send raw PTP commands via `ICCameraDevice.requestSendPTPCommand(_:outData:completion:)`.

## Findings

1. **macOS:** In MTP mode the OP-1 Field appears in Image Capture as a camera device named "OP-1" with 0 items. That's expected, because Image Capture filters out non-image/video files. This confirms the device enumerates as a PTP/still-image class device.
2. **iPadOS:** With the OP-1 Field in MTP mode, Photos shows an Import option. iPadOS therefore recognizes the device as a PTP camera through the system ImageCaptureCore stack, with no driver required.
3. **iPadOS probe (2026-11-03):** Raw MTP operations sent through `requestSendPTPCommand` list the tapes and mixdowns and download audio, on iPadOS 27.2 with OP-1 firmware 1.7.3. A 12 MB WAV arrived at the expected size in 0.6 s. ImageCaptureCore's own catalog reported 0 items, and no separate OpenSession was needed. Details are in [PROBE-NOTES.md](../../research/PROBE-NOTES.md).
4. **iOS probe (2026-11-03):** iPhone 17 Pro on iOS 27.0.1 gave the same listing and downloaded a 16 MB WAV at the expected size in 0.8 s, so the same approach works on iPhone.
5. **Write test on iPadOS (2026-11-03):** SendObjectInfo, SendObject, and DeleteObject all work through `requestSendPTPCommand`. A preset copied back kept its size and audio, but the OP-1 rewrote its metadata (name and version fields), so preset writes can't be checked with a whole-file hash.
6. **WAV write attempt on iPadOS (2026-11-05):** The OP-1 refused a 12 MB WAV in `mixdown/` at SendObjectInfo with `0x2002` General Error. That folder's readme allows only the names `side_a.wav` and `side_b.wav`, which is the likely cause.
7. **WAV write to `drum/user/` on iPadOS (2026-11-05):** SendObject accepted the same 12 MB WAV in 4.3 s. The OP-1 imported it as a sample: AIFC data under the `.wav` name, cut to 20 seconds, with audio identical to the source. Preset folders therefore can't show an exact-bytes write.
8. **Tape write on iPadOS (2026-11-05):** A 1.5 MB tape track replaced a blank track by delete then send, in 0.26 s, and read back with the same SHA-256. Tape folders store files byte for byte under their allowed names. The blank track was then restored the same way.
9. **Tape write on iOS (2026-11-07):** iPhone 17 Pro on iOS 27.0.1 repeated the tape write with the same result: same SHA-256 read back, 0.26 s, blank track restored.
10. **Survival on iPadOS (2026-11-08):** The written track was still listed at full size after the OP-1 left MTP mode for about 3 minutes. The OP-1 rewrote `tape.json` files on its own while out of MTP mode, and played the written track.
11. **Full-size tape on iPadOS (2026-11-08):** A 22 MB tape track, the largest on the device, read at 19.7 MB/s, wrote at 7.4 MB/s, and read back with the same SHA-256. GetPartialObject works with chunks up to 1 MiB at any offset. One 1 MiB request hung for 60 seconds and didn't recur under the same conditions, so requests need timeouts and recovery.
12. **Checksum against macOS (2026-11-08):** `mixdown/side_b.wav` downloaded on iPadOS is byte-identical to the copy made by the Mac companion app.
13. **Mixdown write-back on iPadOS (2026-11-08):** `side_b.wav` was deleted, written back, and read back byte for byte. Every folder type accepts writes under its allowed names.
14. **Whole tape copy on iPadOS (2026-11-08):** Two tapes, the larger with four tracks, 16 clips and 78 MB, were each copied onto a blank tape, tracks first and `tape.json` last, and every file read back byte for byte. After a reconnect the OP-1 had kept the written `tape.json`, including its clips and tape type. Whole-tape backup and restore works over the same transport. One caveat: a file the OP-1 rewrites during a session (it rebuilds `tape.json` when a track changes) reads back cut off at its old size, so such files need listing again before they're read.
15. **Creating and deleting tapes on iPadOS (2026-11-08):** A tape folder was created with SendObjectInfo alone (format 0x3001, association type 1), filled, and played on the OP-1. It was then deleted over MTP, its files first and then the folder. The OP-1 stores tape names in lowercase and adds `readme.txt` once it leaves MTP mode. With item 14, every operation whole-tape backup and restore needs has worked: read, write, create and delete.
16. Not yet verified: why one GetPartialObject request hung.

## Decision

Use **ImageCaptureCore** (`ICDeviceBrowser` → `ICCameraDevice`) as the transport and implement the MTP operations we need on top of raw PTP command passthrough. Do **not** pursue a USBDriverKit driver unless the probe shows ImageCaptureCore can't reach the audio objects.

## Consequences

**Positive**
- No special Apple entitlement and no driver extension.
- Works on iPhone as well as iPad for listing and download.
- App Store–compatible, public frameworks only.

**Negative / risks**
- ImageCaptureCore's high-level `mediaFiles` will likely hide audio files, so we must build PTP/MTP containers ourselves: opcodes, parameters, and parsing of the data phase.
- Raw command passthrough behavior (session handling, large data transfers, write/upload ops like SendObjectInfo/SendObject) is not well-documented on iOS. It may be limited or need an exclusive session.
- If ImageCaptureCore holds its own session, our OpenSession may conflict with it. The probe needs to handle that.

**Fallback**
- USBDriverKit driver extension on M-series iPads (iPadOS 16+), which requires requesting the DriverKit USB entitlement from Apple. iPad-only.

## Next step: probe app (code session)

A single-file SwiftUI app that:

1. Starts `ICDeviceBrowser` with `browsedDeviceTypeMask = .camera` and requests contents/control authorization.
2. On `didAdd`, opens the `ICCameraDevice` session and logs device info.
3. Sends raw PTP commands via `requestSendPTPCommand` and logs response codes and data:
   - `0x1001` GetDeviceInfo, to see the MTP vendor extension and supported operations
   - `0x1004` GetStorageIDs
   - `0x1007` GetObjectHandles (all storages, all formats, root)
   - `0x1008` GetObjectInfo for each handle, to get filenames and formats
   - `0x1009` GetObject on one small file, to confirm data download
4. Success criteria: object handles for tapes/albums are listed, and at least one file downloads intact.

Run it on iPad first, then iPhone.
