# Firmware and Versions

Which OP-1 firmware FieldTapeKit supports, what happens on one it hasn't been tested on, and how its version numbers work.

## Overview

FieldTapeKit relies on how the OP-1 behaves over MTP, and a firmware update can change that. So each firmware it supports has been checked on a real OP-1, and FieldTapeKit tells an app when it's talking to one that hasn't.

### Tested firmware

| Firmware | Tested | Notes |
| --- | --- | --- |
| 1.7.3 | Yes | Writing album sides is off: a side written over MTP hung the OP-1 when written again after a reconnect. |

A tested firmware has a baseline: a record of every OP-1 behavior FieldTapeKit relies on, made by FieldCheck, an app that runs FieldTapeKit's checks against a real OP-1. FieldTapeKit keeps a profile for each tested firmware with what differs between them, such as the longest tape name or whether album writing is on.

### Untested firmware

``FieldDeviceInfo/firmware`` is the version the OP-1 reports, and ``FieldDeviceInfo/isFirmwareTested`` says whether this release has a baseline for exactly that version.

On an untested firmware, such as a new one the day it ships, everything still works, using the profile of the newest tested firmware older than it. Warn the person, so they know:

@Snippet(path: "WatchingForAnOP1", slice: "firmware")

The safety rules still hold there: nothing is deleted without a verified copy or a confirmation, and every write is read back. What they can't catch is the OP-1 treating something differently after it leaves MTP mode, such as a restored `tape.json`.

### Archives across firmware

A ``ReelArchive`` records the firmware it was made on, in ``ReelArchive/firmware``. Restoring it onto another firmware isn't refused, so an app can compare the two and warn.

### Version numbers

FieldTapeKit follows Semantic Versioning 2.0.0:

- **Pre-releases** come first: `1.0.0-alpha.N`, then `1.0.0-beta.N`, then `1.0.0`. They make no promise about compatibility, so depend on an exact pre-release, and read its release notes, which list every break.
- **From 1.0.0, a major version** for anything that breaks source compatibility, including a new case in a public enum: ``FieldDevice/ConnectionEvent``, ``Album/Side``, ``TapeCopy``, ``FieldFormat`` or ``ReelArchive/Compression``; writing an archive format earlier 1.x versions can't open; dropping a firmware; or loosening a safety rule or a default that protects music.
- **A minor version** for new API, a new firmware, reading a new archive format, or tightening a safety rule. New ``FieldError/Code`` and ``TapeType`` values are minor, since those are structs.
- **A patch** for bug fixes that change none of those.

Supporting a new firmware never drops an old one, except in a major version. Someone who keeps their OP-1 on an older firmware keeps its profile and its tests.

## See Also

- ``FieldDeviceInfo``
- <doc:KeepingMusicSafe>
