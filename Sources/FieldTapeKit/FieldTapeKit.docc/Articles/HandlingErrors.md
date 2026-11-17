# Handling Errors

What FieldTapeKit throws, what each error means, and how to tell "nothing happened" from "half done".

## Overview

Every call throws ``FieldError``, or `CancellationError` when its task is cancelled. Each method's documentation lists the codes it can throw.

A ``FieldError`` has:

- ``FieldError/code``, which says what went wrong.
- ``FieldError/path``, the path on the OP-1 it's about, if any.
- ``FieldError/changed``, every file already written or deleted on the OP-1 before the error. It's empty whenever the OP-1 wasn't touched.
- ``FieldError/responseCode``, the MTP response code when the OP-1 refused a request.
- ``FieldError/underlying``, the error behind it, such as the system's error for a local file.

It's a `LocalizedError`, with a description and a recovery suggestion for each code, ready to show a person.

### Check what changed

The most important question after a failure is whether the OP-1 changed. ``FieldError/changed`` answers it:

```swift
do {
    let tape = try await device.restoreTape(from: archive, conflict: .replace(archivingExistingTo: backup))
    show("Restored \(tape.name)")
} catch let error as FieldError where !error.changed.isEmpty {
    // The tape on the OP-1 is half restored. The archive at `backup` holds what was there.
    show("Restore stopped after changing \(error.changed.count) files. Your earlier tape is in \(backup.lastPathComponent).")
} catch let error as FieldError {
    // Nothing on the OP-1 changed.
    show(error.localizedDescription)
}
```

FieldTapeKit never retries a write, so the app decides what happens next: try again from the same archive, or stop.

### Match a code

``FieldError/Code`` is a struct, not an enum, so a later version can add codes without breaking an app's `switch`. Compare with the codes you handle, and keep a default:

```swift
catch let error as FieldError {
    switch error.code {
    case .tapeLimitReached: offerToMoveATapeOff()
    case .disconnected: showReconnectPrompt()
    default: show(error)
    }
}
```

### The codes

**The connection**

| Code | Meaning |
| --- | --- |
| ``FieldError/Code/disconnected`` | The OP-1 was unplugged, left MTP mode, or stopped answering for 90 seconds. Every later call on that ``FieldDevice`` throws it too. |
| ``FieldError/Code/notAuthorized`` | The person didn't allow access to connected devices. It ends ``FieldDevice/connections``. |
| ``FieldError/Code/deviceRefused`` | The OP-1 refused a request, or sent a reply that couldn't be read. ``FieldError/responseCode`` says which, if known. |
| ``FieldError/Code/timedOut`` | Not thrown since 2026-11-16. A request with no answer ends in `disconnected`. |
| ``FieldError/Code/deviceInUse`` | Not thrown on firmware 1.7.3: ImageCaptureCore never reports another app holding the OP-1. |

**Paths**

| Code | Meaning |
| --- | --- |
| ``FieldError/Code/notFound`` | Nothing is at the path, or a tape or album side is gone or empty. |
| ``FieldError/Code/alreadyExists`` | Something is at the path, or a tape has the name, and the call was told not to replace it. |
| ``FieldError/Code/notADirectory`` | A folder on the way is a file. |
| ``FieldError/Code/isADirectory`` | The path is a folder, where a file was needed. |
| ``FieldError/Code/ambiguousPath`` | Two names in a folder differ only in case, and the path matches neither exactly. |

**The OP-1's rules**

| Code | Meaning |
| --- | --- |
| ``FieldError/Code/notAllowed`` | The folder doesn't allow it, it belongs to the OP-1, or it's a tape that isn't sound. The description says which rule. |
| ``FieldError/Code/invalidName`` | A new tape's name has characters the OP-1 doesn't use, or is over 12 characters. |
| ``FieldError/Code/tapeLimitReached`` | All 8 tape slots are in use. |
| ``FieldError/Code/tapeTooLong`` | A track is over 6 minutes. |
| ``FieldError/Code/insufficientSpace`` | The OP-1 is full. |
| ``FieldError/Code/tooLarge`` | A file is bigger than ``FieldDevice/contents(of:maximumSize:)`` was allowed to hold in memory. |

**Safety**

| Code | Meaning |
| --- | --- |
| ``FieldError/Code/verificationFailed`` | A copy or a write didn't read back as it should, or the OP-1 changed while it was copied. Nothing unverified is kept. |
| ``FieldError/Code/changedSinceConfirmation`` | What a person confirmed losing changed since, or the confirmation is from another connection. Nothing changed. |
| ``FieldError/Code/confirmationAlreadyUsed`` | Each confirmation works once. Nothing changed. |

**Local files and archives**

| Code | Meaning |
| --- | --- |
| ``FieldError/Code/localFileFailed`` | A file on this device couldn't be read or written: a full disk, a missing folder, a taken URL, or no permission. ``FieldError/underlying`` is the system's error. |
| ``FieldError/Code/invalidArchive`` | A `.reelarchive` can't be opened: it isn't one, it's from a newer FieldTapeKit, or it's incomplete. |
| ``FieldError/Code/archiveMismatch`` | A file in a `.reelarchive` doesn't match its recorded size or SHA-256, so it changed after it was written. |

### An OP-1 that can't be opened

When ImageCaptureCore finds an OP-1 but can't open it, ``FieldDevice/connections`` yields ``FieldDevice/ConnectionEvent/couldNotOpen(_:)`` instead of throwing, and goes on watching. Its error is ``FieldError/Code/deviceRefused``, with ImageCaptureCore's error in ``FieldError/underlying``.

If the OP-1 says MTP is connected but nothing appears at all, restart the OP-1. On a Mac, quit FieldKit first: it takes the OP-1 for itself.

### Cancellation

Long calls check for cancellation between files, and throw `CancellationError`. A request already sent finishes first. Once a replace has deleted something on the OP-1, cancelling no longer stops it, so nothing is left half-written by a cancel. <doc:Concurrency> has the details.

## See Also

- ``FieldError``
- <doc:KeepingMusicSafe>
