# The OP-1 Over USB

How the OP-1 Field's files are laid out, and how they differ from a disk.

## Overview

In MTP mode, the OP-1 Field shows its tapes, album and presets as files and folders. FieldTapeKit makes them feel like ordinary file access, but the OP-1 isn't a disk. It answers one request at a time over USB, has no way to move, copy or replace a file in place, and has rules about what each folder holds. Everything here was observed on firmware 1.7.3.

### Three layers on one device

``FieldDevice`` has three layers:

- **Tapes**, the main use: ``FieldDevice/tapes()``, ``FieldDevice/copyTape(_:to:compression:progress:)``, ``FieldDevice/moveTape(_:to:progress:)`` and ``FieldDevice/restoreTape(from:as:conflict:progress:)``.
- **The album**: ``FieldDevice/album()``, ``FieldDevice/copySide(_:to:progress:)`` and ``FieldDevice/side(_:matches:)``.
- **Files**, shaped like `FileManager`: ``FieldDevice/contentsOfDirectory(at:)``, ``FieldDevice/copyItem(at:to:progress:)``, ``FieldDevice/write(_:to:options:)`` and the rest.

The tape and album layers are built only on the file layer, so they follow the same rules.

### What's on the OP-1

| Folder | What it holds | What can be written there |
| --- | --- | --- |
| `tapes/` | One folder per tape, at most 8 | A tape's folder, and only `track_1.wav` to `track_4.wav` and `tape.json` in it |
| `mixdown/` | The album: `side_a.wav` and `side_b.wav` | Nothing on firmware 1.7.3 |
| `synth/user/`, `drum/user/` | Presets | Audio files, which the OP-1 converts |
| `synth/`, `drum/` and the rest | The OP-1's own folders, and a `readme.txt` in each | Nothing |

The rules come from the OP-1's own `readme.txt` files. FieldTapeKit checks them before it sends anything, so a write the OP-1 would refuse fails at once with ``FieldError/Code/notAllowed``, saying which rule.

### Tapes

A tape is a folder in `tapes/` with four WAV tracks and a `tape.json`:

- **Tracks** are 32-bit stereo PCM at 44.1 kHz, with a 44-byte header. A blank track is just the header. A tape holds at most 6 minutes, so a track is at most 127,008,044 bytes.
- **`tape.json`** records the clips on each track, the loop, the tempo, the mixer and the tape machine. ``TapeManifest`` reads it, and keeps the file exactly as it was, so restoring a tape writes back every key, including ones FieldTapeKit doesn't understand.
- **Names** are the folder's name. The OP-1 stores them lowercase, and keeps at most 12 characters. ``TapeName`` checks a new tape's name: letters, digits, `#`, `-` and space, and at most 12 characters, since the OP-1 cuts a longer one once it leaves MTP mode.
- **At most 8 tapes.** Every folder in `tapes/` takes a slot, so ``FieldDevice/tapeSlots()`` counts them, and every call that adds a tape checks for a free one first.

When a track changes, the OP-1 rebuilds `tape.json`. So a restore writes the tracks first and `tape.json` last, to keep the archived clips.

### Tape archives

``FieldDevice/copyTape(_:to:compression:progress:)`` writes a tape into one `.reelarchive` file: an Apple Archive of its four tracks and `tape.json`, exactly as they were on the OP-1, and a `reel.json` that records the tape and the size and SHA-256 of every file. It's one ordinary file, so it survives AirDrop, email and cloud storage unchanged.

Opening one with ``ReelArchive/init(contentsOf:)`` checks all of it, so a ``ReelArchive`` is always complete and undamaged. ``ReelArchive/currentFormat`` is the format this version writes. Every later version of FieldTapeKit reads every earlier format.

### The album

The album is always exactly two files, `mixdown/side_a.wav` and `mixdown/side_b.wav`, 16-bit stereo PCM at 44.1 kHz. The OP-1 replaces a side whenever the person records to it, so ``AlbumSideCopy`` records what a copy held, and ``FieldDevice/side(_:matches:)`` tells whether the side was recorded over since.

Writing the album is off on firmware 1.7.3. A side written over MTP hung the OP-1 when it was written again after a reconnect, until the OP-1 was restarted. Reading and copying the album work.

### Paths

A path on the OP-1 is a `FilePath` relative to its root, such as `tapes/2026-220#01/track_1.wav`. Local files are `URL`s. The well-known folders are static members of `FilePath`: ``System/FilePath/op1Tapes``, ``System/FilePath/op1Mixdown``, ``System/FilePath/op1Synth`` and ``System/FilePath/op1Drum``.

Paths match **ignoring case**, because the OP-1 stores names lowercase. Every item comes back as the OP-1 spells it, so use the paths you get back rather than retyping them. If a folder holds two names that differ only in case, which can happen briefly before the OP-1 lowercases a new name, a path that matches neither exactly is refused with ``FieldError/Code/ambiguousPath``.

### Snapshots, fresh reads and reconnects

- **Everything returned is a snapshot.** A ``Tape``, ``Album`` or ``FieldItem`` is what the OP-1 held when it was read. Every call reads the OP-1 fresh, so calling it again shows a change.
- **Sizes are never cached.** A file the OP-1 rewrote within a session, such as a rebuilt `tape.json`, still lists and reads at its old size until it leaves MTP mode. FieldTapeKit reads fresh info before every read, and its checks allow for this.
- **A reconnect is a new device.** Leaving MTP mode, or unplugging, ends the connection: every call on the old ``FieldDevice`` throws ``FieldError/Code/disconnected``, and ``FieldDevice/connections`` gives a new one. While it's out of MTP mode, the OP-1 may change its own files.

### Files the OP-1 converts

A file written to `synth/user/` or `drum/user/` is stored as AIFC under the name it was sent, `.wav` included, and may be shortened: to 20 seconds in `drum/user/` and 6 in `synth/user/`. The ``FieldItem`` returned is the file as stored, and the read-back checks its audio instead of its bytes.

### Not in FieldTapeKit yet

Editing `tape.json`, renaming a tape, copying and restoring presets as a set, erasing an album side, and switching the OP-1 into MTP mode from the app.

## See Also

- <doc:KeepingMusicSafe>
- <doc:Performance>
- <doc:FirmwareAndVersions>
