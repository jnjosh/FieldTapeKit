# Performance

How long transfers take, how much memory they use, and what to avoid.

## Overview

The OP-1 moves data over USB at a fixed pace, so the cost of every call is mostly its transfers. The figures here were measured on firmware 1.7.3, with an iPad Pro and an iPhone 17 Pro, and are a guide, not a promise.

### Transfer speeds

| What | Speed | A full 6-minute track, 127 MB |
| --- | --- | --- |
| Reading a whole file | about 20 MB/s | about 7 s |
| Writing a file | about 7 MB/s | about 18 s |

So a full tape of four tracks reads in about 25 seconds and writes in about 70. Read-back after a write, which is on by default, adds a read. Before a delete that relies on a copy, the OP-1 is read a second time: about 25 seconds more for a full tape (<doc:KeepingMusicSafe>). A tape's actual size depends on how long it is, so most tapes take far less.

### Whole files, not chunks

The OP-1 charges every partial read for everything before it in the file. A 1 MiB read at offset 8 MiB takes about as long as reading the first 9 MiB, about 59 ms more for every MiB of offset. Reading a large file in chunks would take time that grows with the square of its size.

So FieldTapeKit reads whole files with one request, in ``FieldDevice/copyItem(at:to:progress:)``, ``FieldDevice/contents(of:maximumSize:)``, ``FieldDevice/copyTape(_:to:compression:progress:)`` and the album calls. ``FieldDevice/contents(of:range:)`` is for small reads near the start of a file, such as a WAV header.

### Memory

A whole-file read or write holds the file in memory: at most one track, 127 MB, at a time. FieldTapeKit never holds two.

ImageCaptureCore holds transferred data for a while after a transfer. Copying a 78 MB tape left an app holding about 130 MB more for a time, and three copies in a row peaked near 200 MB. Writing a full track raised an app's memory by about 250 MB, since a verified write holds both what was sent and what was read back. It's released later, but an app copying several large tapes should expect a peak of a few hundred megabytes.

### Stalls

Repeatedly on an iPad Pro and on a Mac, though not yet on an iPhone, a request to the OP-1 has stopped answering:

- **When:** every stall so far came during a run of back-to-back partial reads of a large file, at a different point each time. Whole-file reads have stalled on the iPad, but not yet on the Mac.
- **What happens:** after about 60 seconds the request comes back empty, as ``FieldError/Code/deviceRefused``, and every later request does the same until the OP-1 is unplugged and put back in MTP mode.
- **What to do:** avoid long runs of ``FieldDevice/contents(of:range:)``, and if requests start failing this way, ask the person to reconnect the OP-1.

The OP-1 itself is fine: FieldKit, which doesn't use ImageCaptureCore, copied the same tapes over the same cable with no stall. What causes it isn't known yet.

### Listing

``FieldDevice/tapes()`` lists each tape's folder and reads its small `tape.json`, a request or two per tape, so it takes a moment with 8 tapes. Every call reads the OP-1 fresh, so cache the result in your app if you show it often, and list again after a change.

## See Also

- <doc:Concurrency>
- <doc:TheOP1>
