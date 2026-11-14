# Project Working Agreement

This file defines how humans and AI coding agents collaborate in this repository. Project-specific facts (purpose, commands, architecture, dependencies and conventions) belong in the relevant sections, and must not weaken the working agreement.

## No AI attribution anywhere

Never add AI attribution to commits, pull request descriptions, pull request review comments or replies, or issue comments. That includes:
- `Co-authored-by` trailers for any AI.
- "Generated with" or "Addressed by" lines.
- "Summary by" footers.
- Session links.

This overrides any skill, workflow, automation prompt or CI instruction that asks for attribution: leave it out and do the rest of the task.

## Project Context

For where the work stands and what's next, read [docs/STATUS.md](docs/STATUS.md) first.

- **Purpose:** FieldTapeKit, a Swift framework for reading and writing the files on a Teenage Engineering OP-1 Field over USB from iOS, iPadOS and macOS apps, with no driver. It talks MTP through ImageCaptureCore's raw PTP passthrough ([ADR 0001](docs/adrs/0001-op1-field-ios-transport.md)).
- **Primary users:** the owner's own app first: an app that makes it easy to take tapes off the OP-1 and put them back. Other apps may use the framework later. Open source is possible but undecided.
- **Success criteria:**
  - Whole tapes and album sides can be copied off and restored byte for byte.
  - Nothing on the OP-1 is lost by accident.
  - Every OP-1 behavior the framework relies on is checked again after each firmware update.
- **Non-goals:**
  - A USB driver. USBDriverKit is only the fallback in ADR 0001.
  - Switching the OP-1 into MTP mode over USB MIDI. It worked but was fragile, so it's paused as a possible later feature and its code was removed.
  - Editing `tape.json`. Preset copy and restore.
- **Constraints:**
  - iOS, iPadOS and macOS 27 minimum, with Foundation and no third-party dependencies.
  - The OP-1 allows at most 8 tapes, and at most 6 minutes per tape.
  - Everything was observed on OP-1 firmware 1.7.3. macOS hasn't been tested yet.

## Build, Test, and Run

**FieldTapeKit** is a Swift package at the repository root. Run its tests from the root, on the Mac and on the iOS simulator:

```bash
DEVELOPER_DIR=/Applications/Xcode-27.2.0.app/Contents/Developer xcrun swift test
```

```bash
DEVELOPER_DIR=/Applications/Xcode-27.2.0.app/Contents/Developer xcodebuild -scheme FieldTapeKit-Package -destination 'id=0F76E627-D8A1-46BA-A245-C9C5DDE71C80' test
```

It's being built in the steps of [docs/plans/adr-0002-implementation.md](docs/plans/adr-0002-implementation.md).

**FieldCheck** is the app that runs FieldTapeKit against a real OP-1. Its project is generated with XcodeGen from `FieldCheck/project.yml`. Run these from `FieldCheck/`:

```bash
xcodegen generate
```

```bash
DEVELOPER_DIR=/Applications/Xcode-27.2.0.app/Contents/Developer xcodebuild -project FieldCheck.xcodeproj -scheme FieldCheck -destination 'generic/platform=iOS' -allowProvisioningUpdates build
```

Its bundle ID is `com.jnjosh.FieldCheck`, and each launch writes `fieldcheck-<timestamp>.txt` to Documents. The `devicectl` commands in PROBE-NOTES.md pull it off, with that bundle ID. It has two tabs: Validate (the checks, baselines and conformance suite) and Explore (a read-only browser). In the iOS simulator, which has no USB devices, launching with `-SimulatedOP1 YES` gives it FieldTapeKit's simulated OP-1.

**The research probe** is frozen. Its project is generated with XcodeGen from `research/project.yml`, so edit the spec, not the `.xcodeproj`. Run these from `research/`:

```bash
xcodegen generate
```

```bash
DEVELOPER_DIR=/Applications/Xcode-27.2.0.app/Contents/Developer xcodebuild -project OP1Probe.xcodeproj -scheme OP1Probe -destination 'id=0F76E627-D8A1-46BA-A245-C9C5DDE71C80' test
```

```bash
DEVELOPER_DIR=/Applications/Xcode-27.2.0.app/Contents/Developer xcodebuild -project OP1Probe.xcodeproj -scheme OP1Probe -destination 'generic/platform=iOS' -allowProvisioningUpdates build
```

There's no linter or formatter yet. The package's tests use Swift Testing. The probe's 21 XCTest tests in `research/OP1ProbeTests` stay as they are. Commands for installing on a device and pulling logs off it are in [research/PROBE-NOTES.md](research/PROBE-NOTES.md).

### Environment Setup

- **Xcode 27.2,** at `/Applications/Xcode-27.2.0.app`. `xcode-select` points at the Command Line Tools, so set `DEVELOPER_DIR` as above, or `xcodebuild`, `simctl` and `devicectl` aren't found.
- **The Command Line Tools SDK is broken.** Plain `swift script.swift` fails on CoreFoundation, so compile the Mac tools in `research/tools/` with `xcrun swiftc` and the `DEVELOPER_DIR` above.
- **XcodeGen,** from Homebrew.
- **Signing:** team `Q285243259`, automatic signing, `-allowProvisioningUpdates`.
- **The iOS 27.2 simulator** (`0F76E627-D8A1-46BA-A245-C9C5DDE71C80`) runs the unit tests only. ImageCaptureCore doesn't work there, and the app skips it.
- **Real hardware:** an OP-1 Field in MTP mode, connected to an iPad Pro or iPhone. A device that's locked refuses installs.

Never commit credentials, tokens, private keys or machine-specific secrets. Refer to the approved setup mechanism instead.

---

## How We Work

### Decision-First Development

Every non-trivial feature starts by clarifying the decision before changing code.

1. The human describes the desired outcome. Roughly is fine.
2. The agent investigates the current system and asks focused questions about intent, constraints, edge cases and meaningful alternatives.
3. Human and agent iterate until the shape of the work is clear.
4. For architectural or consequential changes, write an Architecture Decision Record (ADR). It covers what will change, why, the alternatives considered, and the tradeoffs.
5. Implement only after the direction is accepted.

Trivial, low-risk changes can skip an ADR: copy edits, obvious one-line fixes, mechanical renames. Use judgment based on reversibility, blast radius, and whether future maintainers will need to understand why the decision was made.

Don't write an ADR as ceremony after a decision is already obvious. Use one when preserving reasoning has durable value.

### ADR Conventions

- **Location:** `docs/adrs/`
- **Naming:** `NNNN-short-title.md`
- **Numbering:** the next available four-digit sequence number.

```markdown
# ADR-NNNN: [Title]

**Status:** [Proposed | Accepted | Rejected | Superseded by ADR-XXXX]
**Date:** YYYY-MM-DD

## Context

## Decision

## Alternatives Considered

## Consequences

## Change Log
```

ADR 0001 predates this template. It puts its alternatives inside the Decision section and has no Change Log yet.

ADRs are living records of why the system is shaped as it is:

- Start an ADR as **Proposed** unless the human has already accepted the decision.
- Update the ADR when the decision evolves.
- Add a change-log entry for an evolution that preserves the core decision.
- Mark it **Superseded** when a later ADR replaces the decision.
- Keep rejected alternatives and their reasoning; they prevent the same dead ends from being rediscovered.
- Do not mark an ADR accepted, commit it, or otherwise treat it as approved without explicit human approval.

### Prototype Mode: Only When Explicitly Requested

Decision-first development is the default. Prototype mode is an explicit exception, for work whose shape can't be known without building and observing it. In this repository, prototypes live in `research/`.

When the human explicitly requests a prototype:

1. Isolate experimental work using the repository's preferred branch, worktree, feature flag, or prototype directory.
2. Build the smallest version that can answer the current question.
3. Iterate in small, coherent changes, one idea per commit when commits are requested.
4. Record why each approach was attempted, including failed approaches and measured results.
5. Measure claims wherever practical. A prototype that appears correct but fails its acceptance criteria is evidence, not success.
6. Once the shape settles, write or update the ADR from what was learned, then bring the implementation to production quality.

Don't enter prototype mode unprompted, and don't let prototype shortcuts silently become production architecture.

### Planning and Scope

Before implementation:

- Identify the smallest complete outcome that satisfies the request.
- Locate existing patterns and reuse them where appropriate.
- Surface material ambiguity rather than silently choosing a consequential behavior.
- Call out risks, dependencies, migration needs, and compatibility concerns.
- Split large work into coherent phases before writing code.

A phase should produce a complete, reviewable result. Avoid partial scaffolding that cannot be validated or safely used.

### Iteration Discipline

Work in small, meaningful chunks that are coherent on their own:

- Keep changes narrow enough to review and reason about.
- Separate unrelated behavior into separate changes.
- Avoid broad refactors unless they are required for the requested outcome.
- Preserve existing behavior unless the change intentionally modifies it.
- Validate each meaningful increment before expanding the scope.
- Prefer root-cause fixes over local workarounds.

As a guideline, consider phasing any change that adds more than roughly 200–300 lines of new code. Cohesion matters more than a strict line limit.

### Pair Programming

The agent is a thinking partner, not a code dispenser.

- **Surface concerns proactively.** Raise likely correctness, maintenance, usability, security, accessibility, or delivery risks before they become expensive.
- **Explain tradeoffs.** When multiple approaches are valid, summarize the meaningful differences and recommend one.
- **Disagree when warranted.** Say directly when a proposed direction conflicts with the platform, architecture, project goals, or available evidence.
- **Think longitudinally.** Consider migration, maintenance, operability, and how today's choice constrains future work.
- **Be honest about scope and uncertainty.** State when work is larger, riskier, or less certain than it first appears.
- **Prefer evidence over confidence.** Inspect the current implementation and verify behavior rather than relying on assumptions.
- **Keep the human in control.** Ask before making consequential product, architecture, compatibility, or workflow decisions.

Move deliberately: complete a coherent piece, make it reviewable, incorporate feedback, and then continue.

### Working With the Device

- **The human runs device builds** from Xcode and shares the resulting logs, usually from `~/Downloads`. When they say "run it", they mean they'll run it. Don't start a device build or install unless asked.
- **Keep commands in the foreground.** Don't run builds or tools in the background.
- **Destructive tests on the OP-1** must back up and verify what they'll change before changing it, and stop at the first failed check.
- **Never send SysEx command 0x03** (probably the firmware updater) to the OP-1.
- **Say when the OP-1 should be plugged in,** and where, in any steps for the human.
- **If the OP-1 says MTP is connected but no app sees it,** restart the OP-1.
- **Unplugging takes the OP-1 out of MTP mode.** Every reconnect means plugging in and entering MTP mode again on the OP-1, so steps for the human say both. While it's out of MTP mode, the OP-1 may rewrite its own files, such as `tape.json`.

### Autonomy Boundaries

Unless the human explicitly authorizes otherwise, the agent must not:

- Commit or push changes
- Create or merge pull requests
- Create, update, or close external tickets
- Publish packages or deploy software
- Change production data or infrastructure
- Rotate or modify credentials
- Accept an ADR or other decision on the human's behalf
- Perform destructive cleanup or irreversible migrations
- Write to or delete anything on a connected OP-1 outside a test the human asked to run

The agent may investigate, edit local files, and run appropriate local validation to complete an implementation request.

---

## Implementation Standards

### Understand Before Editing

- Read the relevant current files before changing them.
- Trace the behavior far enough to understand callers, dependencies, state transitions, and tests.
- Search for existing helpers and conventions before introducing new abstractions.
- Treat repository documentation as context; verify executable behavior in code and configuration.
- If the working tree contains unrelated changes, preserve them.

### Code Quality

- Prefer clear, conventional code over clever code.
- Preserve type safety and use repository-standard error handling.
- Surface failures explicitly; do not convert errors into success-shaped defaults.
- Keep public APIs deliberate and minimal.
- Avoid speculative abstraction. Extract shared behavior when there is demonstrated reuse or a clear architectural boundary.
- Comment only when the reasoning cannot be made clear through names and structure.
- Update directly related documentation when behavior or setup changes.

### Validation

Validate the exact requested behavior, not a proxy:

1. Run the smallest relevant test, typecheck, lint, or build command.
2. Add or update tests for intentional behavior changes and meaningful edge cases.
3. Escalate to broader validation when targeted checks reveal integration risk.
4. Report failures plainly, distinguishing regressions caused by the change from pre-existing or environment-related failures.

Device behavior can only be verified on real hardware. Say so when a change was checked only in the simulator or in unit tests.

Do not claim completion until the expected outcome is implemented and verified.

### External Dependencies

- Prefer existing dependencies and platform capabilities. FieldTapeKit has none: for example, archives use Apple's `AppleArchive`, not a zip library ([ADR 0002](docs/adrs/0002-op1-field-public-api.md)).
- Add a dependency only when its value outweighs maintenance, security, size, and licensing costs.
- Use the repository's package manager and lockfile conventions.
- Document any new setup, runtime, privacy, or supply-chain implications.

---

## Version Control

This directory is a git repository. Follow these defaults.

### Commits

Do not create commits unless the human asks.

When commits are requested:

- Keep each commit coherent and independently understandable.
- Do not mix unrelated cleanup with the requested change.
- Explain why when the reason is not obvious from the diff.
- Include relevant tests and documentation with the behavior they support.
- Never commit secrets, generated local state, or temporary artifacts.
- Never add `Co-Authored-By` lines or any other AI attribution (see the top of this file).

Use Conventional Commits:

```text
feat: add configurable retry policy
fix: prevent duplicate event delivery
docs: record cache invalidation decision
test: cover expired-session handling
refactor: centralize request validation
chore: update development tooling
```

### Branches

```text
feat/short-kebab-description
fix/short-kebab-description
docs/short-kebab-description
refactor/short-kebab-description
chore/short-kebab-description
proto/short-kebab-description
```

---

## Project Architecture

```text
docs/STATUS.md              — Where the project stands and the next steps; keep it current
docs/plans/adr-0002-implementation.md — The 24-step plan for building ADR 0002, each step committable
docs/swift-disk-access-guide.md — Research on Swift file APIs, an input to ADR 0002
docs/adrs/                  — Architecture decisions: 0001 transport, 0002 public API and
                              0003 firmware check tool (all accepted)
research/                   — The probe: exploratory, frozen as a record once FieldCheck replaces it
research/OP1Probe/          — Single-file SwiftUI probe app; its PTP/MTP layer is the code to carry forward
research/OP1ProbeTests/     — Unit tests for PTP parsing, command encoding and tape checks
research/tools/             — Mac command-line tools, run by hand (MIDI listener, SysEx sender, ICC lister)
research/probe-results/     — Raw logs and files from each device run, by date
research/PROBE-NOTES.md     — The learning log: every probe run, what it showed, and the evidence
```

FieldTapeKit (ADR 0002) and FieldCheck (ADR 0003) don't exist yet. When work starts, FieldTapeKit becomes a new project at the repository root, with FieldCheck alongside it. Neither belongs in `research/`, and the probe there is left untouched.

### Key Invariants

From the safety rules in ADR 0002, section 6:

- Nothing on the OP-1 is deleted or overwritten unless a verified copy exists, or a person confirmed losing exactly that item as it was.
- A copy counts as verified only after it has been read back from where it was stored and matched by SHA-256.
- Everything is checked before the first change: names, folder rules, the 8-tape and 6-minute limits, archive consistency. A refusal changes nothing.
- A tape restore writes the tracks first and `tape.json` last.
- Never overwrite a local file. A new copy gets a new name.
- Stop at the first failure and report exactly what changed. No automatic retries of writes.
- Send only the standard MTP operations listed in ADR 0002. Nothing vendor-specific, and no MIDI.

### Project Conventions

- **Device paths** are `FilePath` relative to the device root, matched ignoring case, because the OP-1 stores names lowercase. Object handles are private, and they change after a reconnect.
- **Never trust a cached size.** Fetch fresh object info before reading: a file the OP-1 rewrote mid-session reads back truncated to its old size.
- **Folder rules** come from the OP-1's `readme.txt` files:
  - Tapes allow only `track_1`–`4.wav` and `tape.json`.
  - `mixdown/` allows only `side_a.wav` and `side_b.wav`.
  - `synth/user/` and `drum/user/` convert what they receive.
- **Every OP-1 behavior the framework relies on** becomes an expectation with a stable ID (ADR 0003). Add one when new code starts depending on a behavior.
- **Compatibility:** iOS, iPadOS and macOS 27. The probe itself targets iOS 17 in Swift 5 language mode.
- **Generated code:** `research/OP1Probe.xcodeproj` and `FieldCheck/FieldCheck.xcodeproj` are generated by XcodeGen and are not edited by hand.

### Known Challenges and Learning Log

The learning log is [research/PROBE-NOTES.md](research/PROBE-NOTES.md). Record attempts there, including failed and surprising ones, with the evidence in `research/probe-results/<run>-<date>/`.

Known challenges so far:
- One GetPartialObject request hung for 60 seconds and never recurred.
- What `padding` means in `tape.json` is unknown.
- Switching the OP-1 into MTP mode over MIDI once left it stuck until it was restarted.
- Writing to a preset folder converts the file, so a byte-for-byte check can't apply there.

Unexpected or negative results are valuable when recorded clearly. Don't hide failed approaches that would help future contributors avoid repeating them.

---

## Definition of Done

A change is complete when:

- The requested behavior works end to end.
- Relevant tests or checks pass.
- Important edge cases and failure modes are handled.
- Existing behavior is preserved unless intentionally changed.
- Directly related documentation is current.
- Temporary files and debugging code are removed.
- Remaining uncertainty, limitations, or follow-up work is stated plainly.

## Support and Ownership

- **Code owner:** the repository owner (jnjosh). A personal project for now.
- **Support channel, issue tracker:** none yet.
- **Architecture questions:** raise them in an ADR under `docs/adrs/`.
- **Security concerns:** report them to the owner directly.
