# Keeping Music Safe

The rules FieldTapeKit follows so that nothing on the OP-1 is lost by accident.

## Overview

People's music often lives only on the OP-1. So FieldTapeKit's calls that delete or overwrite anything follow seven rules, and its tests check each one. This article describes what the rules mean for an app: what each call needs before it changes anything, and what you get back when something goes wrong.

### Rule 1: a verified copy or a person's confirmation

Nothing on the OP-1 is deleted or overwritten unless a verified copy of it exists, or a person confirmed losing exactly that. Every call that deletes or overwrites takes one of the two:

| With a verified copy | With a person's confirmation |
| --- | --- |
| ``FieldDevice/moveTape(_:to:progress:)`` makes the archive first | ``FieldDevice/prepareToDelete(_:)``, then ``FieldDevice/deleteTape(_:)`` |
| ``FieldDevice/deleteTape(_:keeping:progress:)`` with a ``TapeCopy`` | ``TapeConflict/replace(confirmed:)`` |
| ``TapeConflict/replace(archivingExistingTo:)`` | ``FieldDevice/prepareToRemove(at:)``, then ``FieldDevice/removeItem(_:)`` |
| ``FieldDevice/removeItem(at:keepingCopyAt:)`` | ``ExistingFile/replace(confirmed:)`` |
| ``ExistingFile/replace(keepingCopyAt:)`` | ``SideConflict/replace(confirmed:)`` |
| ``SideConflict/replace(copyingExistingTo:)`` | |

Every one of them defaults to changing nothing: ``TapeConflict/fail``, ``SideConflict/fail`` and ``ExistingFile/fail`` throw ``FieldError/Code/alreadyExists`` instead.

A confirmation, a ``TapeDeletion``, ``FileDeletion`` or ``SideReplacement``, describes what would be lost, as it was when it was read. It's refused with ``FieldError/Code/changedSinceConfirmation`` if anything changed since, works once, and only on the ``FieldDevice`` that made it, so it doesn't survive a reconnect.

Nothing stops an app from asking for a confirmation and using it straight away, without a person. That's deliberate: it's visible in the code, and can't happen by accident. Each confirmation's `losesNothing` says when skipping the prompt is harmless, such as for an empty tape.

### Rule 2: verified means read back and matched

A copy counts as verified only once it's been read back from where it was stored and matched by SHA-256:

- **A copy off the OP-1,** an archive or a file, is written to a temporary file, read back from disk and matched, and only then moved into place.
- **A write to the OP-1** is read back and matched, unless the caller turns that off with ``UploadOptions/verify``. A file written to a preset folder is converted, so its audio is checked instead of its bytes.
- **Before a copy covers a delete,** the OP-1 is read a second time and matched to the copy. A single read that went wrong can't leave a bad copy that passes. If the two reads disagree, nothing is deleted, the copy is kept, and the call throws ``FieldError/Code/verificationFailed``. This costs one more read, about 25 seconds for a full tape.

### Rule 3: everything is checked first

Before the first change, every call checks everything it can: names, folder rules, the 8-tape and 6-minute limits, the archive, the copy and the confirmation. A refusal changes nothing, and its ``FieldError/changed`` is empty.

### Rule 4: only what it was asked to touch

FieldTapeKit deletes only the paths it was asked to, and only once it has listed them. It refuses to delete the OP-1's own folders and files on their own, such as `tapes/`, `mixdown/` and any `readme.txt`. A tape's `readme.txt` goes only when its whole tape is deleted. It never writes anywhere but `tapes/`, `mixdown/`, `synth/user/` and `drum/user/`.

### Rule 5: never over a local file

A copy off the OP-1 never overwrites a local file. A taken name gets a number, as Finder does: `side_a 2.wav`. Where a call takes an exact URL for its copy, such as ``TapeConflict/replace(archivingExistingTo:)``, the URL must be free, or the call throws ``FieldError/Code/localFileFailed`` before it changes anything.

### Rule 6: stop at the first failure

A call stops at the first failure and reports exactly what it changed:

- **``FieldError/changed``** lists every file already written or deleted on the OP-1. It's empty when nothing on the OP-1 changed.
- **There's no automatic retry,** and no rollback of an existing tape. A second round of writes to a device that just failed is more likely to make things worse. The copy or the confirmation covers what was there, and the app can offer to restore again.
- **The one cleanup:** a new tape that fails partway is deleted once, since it holds nothing that isn't elsewhere and would use up a slot. If that fails too, it's in ``FieldError/changed``.
- **Once a replace has deleted something, cancelling no longer stops it,** so a tape or file isn't left half-written by a cancel.
- **A request that gets no answer** is waited for up to 90 seconds, then the connection is treated as gone.

### Rule 7: only standard MTP

FieldTapeKit sends only ten standard MTP operations:

- **To read:** GetDeviceInfo, GetStorageIDs, GetStorageInfo, GetObjectHandles, GetObjectInfo, GetObject and GetPartialObject.
- **To write:** SendObjectInfo, SendObject and DeleteObject.

It sends nothing vendor-specific, and no MIDI.

### What the rules can't cover

- **Another app at the same time.** On a Mac, Image Capture can hold the OP-1 alongside your app, and its requests can come between FieldTapeKit's.
- **Firmware FieldTapeKit hasn't been tested on.** The rules still hold, and read-back still catches a write that didn't land. What they can't catch is the OP-1 treating something differently after it leaves MTP mode. <doc:FirmwareAndVersions> explains ``FieldDeviceInfo/isFirmwareTested``.

## See Also

- <doc:HandlingErrors>
- <doc:IntegratingWithYourApp>
- <doc:TheOP1>
