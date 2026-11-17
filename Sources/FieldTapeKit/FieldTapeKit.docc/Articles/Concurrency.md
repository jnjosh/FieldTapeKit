# Concurrency

How FieldTapeKit uses Swift concurrency: the device actor, overlapping calls, cancellation and progress.

## Overview

The OP-1 answers one request at a time over USB, and every request takes real time. So every call in FieldTapeKit is `async`, there's no synchronous API, and ``FieldDevice`` is an actor.

### The device is an actor

``FieldDevice`` is an `actor`, so calls on it can come from any task or actor, including the main actor. Its ``FieldDevice/id-swift.property`` and ``FieldDevice/info`` are `nonisolated`, so reading them needs no `await`, and a device can be used as an `Identifiable` element in a SwiftUI `List`.

Every value FieldTapeKit returns, such as ``Tape``, ``ReelArchive``, ``FieldItem`` and ``FieldError``, is `Sendable`. None of it depends on the main actor.

### Calls on one device can overlap

Calls on the same device can overlap. Their requests to the OP-1 queue up and go one at a time, but a call that makes several requests can have another call's requests in between:

- **Reads can overlap freely,** such as listing tapes while copying one off. They take longer, since they share the one connection.
- **Don't overlap calls that change the OP-1 on the same device,** such as two restores, or a delete while copying. Each call checks the OP-1 fresh before its first change, but another call's change can land between that check and the change it guards. Run them one after another.

In SwiftUI, disabling the buttons that change the OP-1 while one such call runs is enough.

### Watching for connections

``FieldDevice/connections`` can be iterated from any context, by several tasks at once. They share one connection to ImageCaptureCore, which starts with the first and stops when the last is cancelled. Each new iteration starts with every OP-1 already connected.

### Cancellation

Every long call cancels the normal Swift way, by cancelling its task, such as when a view with a `.task` goes away:

- **It's checked between files,** and between tracks for a tape. The call then throws `CancellationError`.
- **A request already sent can't be cancelled,** so it finishes first: up to about 7 seconds to read a full track, and about 18 seconds to write one.
- **A copy off the OP-1 that's cancelled leaves nothing behind.** Its temporary file is deleted.
- **A write to the OP-1 that's cancelled** deletes the file it had started.
- **Once a replace has deleted something on the OP-1, cancelling no longer stops it.** A tape, side or file isn't left half-written by a cancel. The call runs to the end, or to its first failure.

### Progress

Long calls take an optional `Subprogress`, from a `ProgressManager` the caller owns:

@Snippet(path: "Progress", slice: "two")

It's `consuming`, so a subprogress is used once. Each call's documentation says what its units are, usually bytes, and progress moves as each file is done.

### Timeouts

A request the OP-1 doesn't answer is waited for: it's noted as slow after 30 seconds, and after 90 seconds the connection is treated as gone, and the call throws ``FieldError/Code/disconnected``, as does every later call on that device. Unplugging is noticed at once.

On a Mac and on an iPad, a stalled request has instead come back empty after about 60 seconds. That throws ``FieldError/Code/deviceRefused``, and the connection stays open, but every later request stalled the same way until the OP-1 was reconnected. <doc:Performance> has more.

## See Also

- <doc:Performance>
- <doc:IntegratingWithYourApp>
- ``FieldDevice``
