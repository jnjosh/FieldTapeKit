# Changelog

All notable changes to FieldTapeKit are recorded here, newest first. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and FieldTapeKit follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html), as [ADR 0002](docs/adrs/0002-op1-field-public-api.md), section 11, describes. Pre-releases make no promise about compatibility, so each lists everything that broke, marked **Breaking**. **Known Limits** lists what a release doesn't do yet.

## [Unreleased]

### Documentation Diff

- **Every public declaration has a doc comment,** with its parameters, return value and errors. The known limits are callouts, such as album writing being off on 1.7.3 and the stall in long runs of `contents(of:range:)`.
- **A DocC catalog:** a landing page, `FieldDevice`'s members grouped by task, and nine articles. They cover:
  - Getting Started, and Integrating with Your App.
  - The OP-1 Over USB, and Keeping Music Safe.
  - Testing with the Simulated OP-1, and Handling Errors.
  - Concurrency, Performance, and Firmware and Versions.
- **Code examples are Snippets** in `Snippets/`, compiled by every build. Most run against the simulated OP-1.
- **A README, this CHANGELOG, and [docs/DOCUMENTATION_GUIDE.md](docs/DOCUMENTATION_GUIDE.md).** `scripts/build-docs.sh` builds the docs with their snippets and fails on any DocC warning.

### Changed

- **`FieldError.Code.timedOut`'s documentation** now says it isn't thrown since 2026-11-16.

## [1.0.0-beta.1] - 2026-11-17

The API is ready to try for real. FieldTapeKit runs on the Mac, and has a safety-rule suite.

### Added

- **`FieldDevice.ConnectionEvent.couldNotOpen(FieldError)`,** for an OP-1 that ImageCaptureCore found but couldn't open. Watching goes on.
- **macOS.** The read-only conformance suite passes on a Mac, and its copies match every earlier run. FieldCheck builds for macOS, without the App Sandbox.
- **The safety-rule suite,** one test group for each rule in ADR 0002, section 6. The simulator can now inject a corrupted read, an unplug mid-transfer, and the OP-1's real transfer speeds.
- **FieldCheck compares each run with its firmware's baseline,** and drafts an ADR for a change or a failure.
- **[docs/RELEASING.md](docs/RELEASING.md),** the checks before tagging a release.

### Changed

- **Before anything is deleted because a copy covers it, the OP-1 is read again and matched to the copy.** That applies to `moveTape`, a restore with `.replace(archivingExistingTo:)`, and `keepingCopyAt:`. This tightens safety rule 2:
  - **Newly refused:** a delete where the second read differs. It throws `verificationFailed`, deletes nothing, and keeps the copy.
  - **The cost:** about 25 seconds more per full tape.
- **A request that gets no answer** is noted as slow after 30 seconds, and waited for until 90 seconds, with no ping. A transport that reports the device gone leaves the session disconnected at once.
- **Breaking: `ConnectionEvent` has a new case,** `couldNotOpen`, so an exhaustive `switch` over the events needs to handle it.

### Known Limits

- **On the Mac and on one iPad, a run of chunked `GetPartialObject` reads of a large file can stall.** The request comes back empty after about 60 seconds, and so does every later request until the OP-1 is reconnected. Whole-file copies haven't stalled on the Mac, and the iPhone hasn't shown it.
- **On the Mac, quit FieldKit,** or the OP-1 never appears. `deviceInUse` isn't thrown: ImageCaptureCore never reports another app holding the OP-1.
- **On the Mac, Image Capture can hold the OP-1 alongside your app,** and its requests can come between FieldTapeKit's.
- **Levels 2 and 3 and the writing checks haven't run on the Mac.**
- **Album writing is off on firmware 1.7.3.**

## [1.0.0-alpha.3] - 2026-11-15

### Added

- **Reading and copying the album:** `album()`, `copySide(_:to:progress:)`, `copyAlbum(to:progress:)` and `side(_:matches:)`. A copy is a WAV file, and `AlbumSideCopy` records what it held.
- **Restoring album sides:** `restoreSide(_:from:conflict:progress:)`, with `SideConflict.replace(copyingExistingTo:)`, or `.replace(confirmed:)` with a `SideReplacement` from `prepareToReplace(_:)`.

### Known Limits

- **Album writing is off on firmware 1.7.3.** Writing a side again, once it was written over MTP in an earlier connection, hung the OP-1 until it was restarted. `restoreSide` and writes to the sides throw `notAllowed`. Reading and copying the album work.

## [1.0.0-alpha.2] - 2026-11-15

### Added

- **Making tapes on the OP-1:** `createTape(named:type:)` and `duplicateTape(_:as:progress:)`.
- **Restoring a tape** under its archived name or a new one: `restoreTape(from:as:conflict:progress:)`.
- **Deleting and moving tapes:**
  - `deleteTape(_:keeping:progress:)` with a matching copy.
  - `prepareToDelete(_:)`, then `deleteTape(_:)`, with a person's confirmation.
  - `moveTape(_:to:progress:)`, which archives a tape and then frees its slot.
- **Restoring over an existing tape,** with `TapeConflict.replace(archivingExistingTo:)` or `.replace(confirmed:)`. It writes the tracks first and `tape.json` last, and from the first delete runs to the end.

### Changed

- **Breaking: `TapeConflict` is a struct,** since two enum cases can't share the name `replace`.

## [1.0.0-alpha.1] - 2026-11-15

The first release: reading the OP-1, writing and deleting its files safely, and taking tapes off.

### Added

- **Finding an OP-1:** `FieldDevice`, an actor, and `FieldDevice.connections`, an asynchronous sequence of connection events.
- **The file layer,** shaped like `FileManager`:
  - **Listing:** `contentsOfDirectory(at:)`, `item(at:)` and `fileExists(at:)`.
  - **Reading:** `contents(of:maximumSize:)`, `contents(of:range:)`, and `copyItem(at:to:progress:)` to a local file.
  - **Writing:** `write(_:to:options:)`, `copyItem(at:to:options:progress:)` and `createDirectory(at:)`.
  - **Replacing and deleting,** with a verified copy or a person's confirmation: `removeItem(at:keepingCopyAt:)`, `prepareToRemove(at:)` and `removeItem(_:)`.
  - Paths match ignoring case, as the OP-1 stores names lowercase, and the folder rules are checked before anything is sent.
- **Reading tapes:** `tapes()`, `tape(named:)` and `tapeSlots()`, with `Tape`, `TapeName`, `TapeType` and `TapeManifest`.
- **Tape archives:** `.reelarchive` files and `ReelArchive`, an Apple Archive of a tape's files checked by SHA-256, with the file type `UTType.reelArchive`.
- **Copying tapes off:** `copyTape(_:to:compression:progress:)`, which reads each track with one request, checks the archive, and never writes over a file.
- **A simulated OP-1** for tests and previews: `FieldDevice.simulated(_:)`.
- **`FieldError`,** one error type with a code, and `changed` listing what was already written or deleted.

[Unreleased]: https://github.com/jnjosh/FieldTapeKit/compare/1.0.0-beta.1...HEAD
[1.0.0-beta.1]: https://github.com/jnjosh/FieldTapeKit/compare/1.0.0-alpha.3...1.0.0-beta.1
[1.0.0-alpha.3]: https://github.com/jnjosh/FieldTapeKit/compare/1.0.0-alpha.2...1.0.0-alpha.3
[1.0.0-alpha.2]: https://github.com/jnjosh/FieldTapeKit/compare/1.0.0-alpha.1...1.0.0-alpha.2
[1.0.0-alpha.1]: https://github.com/jnjosh/FieldTapeKit/releases/tag/1.0.0-alpha.1
