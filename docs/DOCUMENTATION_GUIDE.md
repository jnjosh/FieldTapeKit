# Documentation Guide

This guide sets the documentation standard for this library. It draws on the official Swift API Design Guidelines, the Swift-DocC toolchain, and the habits of well-documented open-source Swift projects: GRDB.swift, The Composable Architecture (TCA), SwiftNIO, swift-collections, swift-argument-parser and Apple's own swift-docc-plugin.

The goal is to make the library easy to understand **at the call site**, then in Xcode's Quick Help, then in the hosted docs, and last in the README.

## How FieldTapeKit Applies This Guide

Decided by the owner on 2026-11-17. FieldTapeKit isn't open source yet, but it's documented as if it were. Where this guide and the project differ, this section wins.

- **The simulated-vs-real list (§4)** is in *Testing with the Simulated OP-1*.
- **Only `FieldTapeKit` gets the full treatment:** its doc comments, a DocC catalog, articles and snippets. `FieldCheckKit` and `FieldTapeConformance` are products only so the FieldCheck app can use them, so they keep doc comments but get no catalog.
- **No swift-docc-plugin.** FieldTapeKit has no dependencies, not even a build tool (CLAUDE.md), so §9.1's plugin and its `swift package generate-documentation` commands aren't used. Xcode builds and checks the docs instead, with DocC warnings as errors, from the repository root:

  ```bash
  DEVELOPER_DIR=/Applications/Xcode-27.2.0.app/Contents/Developer xcodebuild docbuild -scheme FieldTapeKit -destination 'platform=macOS' OTHER_DOCC_FLAGS="--warnings-as-errors"
  ```

- **There's no CI yet,** so §9.4's check runs before every release, in [RELEASING.md](RELEASING.md).
- **Release notes go in `CHANGELOG.md`,** in Keep a Changelog format (§8), from phase 3. The tagged commit's message then points to it. Until then, they're in the tagged commit's message, as RELEASING.md says.
- **Waiting for open source:** hosting (§9.2, §9.3), tutorials (§5.4), badges, `LICENSE`, `CONTRIBUTING.md` and the pull request checklist (§10).
- **The guide's "File System Semantics" article (§4)** is, for FieldTapeKit, *Keeping Music Safe*, with *The OP-1 Over USB* for the layout and paths: paths matched ignoring case, what a replace does, what's verified, and what happens after a failure. ADR 0002 stays the record of why.
- **Doc comments here also cite their evidence:** an expectation ID such as `read.cost`, an ADR section, or a date in PROBE-NOTES.md. Keep those: they're how a reader finds out why the OP-1 behaves as described.
- **The phases:**
  1. Doc comments, with the docs build clean with warnings as errors (2026-11-17).
  2. The DocC catalog, `Sources/FieldTapeKit/FieldTapeKit.docc`: a landing page with Topics, `FieldDevice`'s Topics by task, and nine articles (2026-11-17). Its examples are fenced code until phase 3, checked by compiling them once.
  3. Snippets that compile, a README and the CHANGELOG.

---

## 1. Principles

1. **Clarity at the point of use is the main goal.** If you can't describe an API simply, the design probably needs another look. Write the doc comment *before* or *while* you design an API, not after it ships.
2. **Every public and `open` declaration gets a doc comment.** No exceptions for "obvious" members. A short summary is enough for most of them.
3. **One source of truth.** Reference documentation lives in `///` comments next to the code. Conceptual material lives in the DocC catalog. The README summarizes and links out instead of copying the catalog.
4. **Docs are code.** They build in CI, warnings fail the build, examples compile, and pull requests that change behavior update the docs too.
5. **Write in layers.** Someone deciding whether to adopt the library, someone integrating it and someone debugging an edge case need different depths. Provide all three (see §6).

---

## 2. Repository Layout

```
MyLibrary/
├── Package.swift
├── README.md                     # Pitch, quick start, links into DocC
├── CHANGELOG.md                  # Keep a Changelog format, newest first
├── CONTRIBUTING.md               # Includes a "Documentation" section pointing here
├── DOCUMENTATION_GUIDE.md        # This file
├── LICENSE
├── .spi.yml                      # Swift Package Index docs hosting
├── Snippets/                     # Compiled, runnable code examples
│   ├── QuickStart.swift
│   └── SimulatedDisk/
│       └── InjectingFaults.swift
├── Sources/
│   └── MyLibrary/
│       ├── *.swift
│       └── MyLibrary.docc/
│           ├── MyLibrary.md      # Landing page (module overview + Topics)
│           ├── Articles/
│           │   ├── GettingStarted.md
│           │   ├── UsingWithSwiftUI.md
│           │   ├── UsingWithUIKit.md
│           │   ├── Testing.md
│           │   ├── Concurrency.md
│           │   ├── ErrorHandling.md
│           │   ├── FAQ.md
│           │   └── MigrationGuides/
│           │       └── MigratingTo2.0.md
│           ├── Extensions/       # Extension files that curate/extend symbol pages
│           │   └── FileStore.md
│           ├── Tutorials/        # Optional: interactive tutorials
│           │   ├── Table of Contents.tutorial
│           │   └── BuildYourFirstStore.tutorial
│           └── Resources/
│               ├── hero.png / hero@2x.png / hero~dark@2x.png
│               └── code-files/
└── Tests/
```

Name the catalog after the module (`MyLibrary.docc`) and the landing page after the module (`MyLibrary.md`). If the package has more than one public module, give each its own catalog and landing page.

---

## 3. Writing Doc Comments

### 3.1 Format

- Use `///` line comments, not `/** */` blocks.
- Use Swift's Markdown dialect: backticks for code, double backticks to link symbols (``` ``FileStore/write(_:to:)`` ```).
- Wrap lines at about 100 columns so they read well in Xcode.

### 3.2 The Summary

The summary is the most important part. Many good doc comments are nothing more than a good summary.

- Use **one sentence fragment, ending with a period**.
- Say what the declaration **is** or **does**, depending on what it is:

| Declaration | Summary describes | Example |
|---|---|---|
| Function / method | What it does and returns | `/// Writes the given data to a file at the specified path.` |
| Initializer | What it creates | `/// Creates a store rooted at the given directory.` |
| Property | What it *is* | `/// The directory that all relative paths resolve against.` |
| Type | What an instance *is* | `/// A file system that keeps every file in memory.` |
| Subscript | What it accesses | `/// Accesses the contents of the file at the given path.` |
| Enum case | What the case represents | `/// The file doesn't exist.` |
| Protocol | What conforming types *are* or *can do* | `/// A type that can read and write files.` |

- Don't repeat the symbol name ("`write(_:to:)` writes…"). Don't open with "This method…".

### 3.3 Discussion and Callouts

After the summary, leave a blank line and add discussion only when it helps. Use these recognized callouts:

```swift
/// Moves a file or directory to a new location.
///
/// If `destination` is in another volume, the move falls back to a copy
/// followed by a delete, and it is no longer atomic.
///
/// ```swift
/// try store.move(at: "drafts/note.txt", to: "archive/note.txt")
/// ```
///
/// - Parameters:
///   - source: The path of the item to move.
///   - destination: The new path. Intermediate directories must already exist.
/// - Returns: The resolved URL of the moved item.
/// - Throws: ``FileStoreError/notFound(_:)`` if `source` doesn't exist;
///   ``FileStoreError/alreadyExists(_:)`` if `destination` is taken.
///
/// - Important: Hold no open handles to `source` during the move.
/// - Note: Symbolic links are moved, not resolved.
/// - Complexity: O(1) on the same volume; O(*n*) in the file size across volumes.
/// - SeeAlso: ``copy(at:to:)``
@discardableResult
public func move(at source: FilePath, to destination: FilePath) throws -> URL
```

Callout reference: `Parameters`/`Parameter`, `Returns`, `Throws`, `Precondition`, `Postcondition`, `Requires`, `Invariant`, `Complexity`, `Important`, `Warning`, `Attention`, `Note`, `Tip`, `Experiment`, `SeeAlso`, `Since`, `Version`, `Author`.

### 3.4 Rules of Thumb

- **Document `Throws` every time a function throws**, and name the specific error cases. Typed throws (`throws(FileStoreError)`) help here, and the doc should still say *when* each case happens.
- **Document complexity** for any computed property or method that isn't O(1). This is a firm convention in the standard library and in swift-collections.
- **Document preconditions** that trap rather than throw.
- **Document `async` behavior:** whether it suspends, what it awaits and whether it's cancellable.
- **Document `Sendable` and isolation** when they aren't obvious. If a type isn't safe to share, say so.
- **Document defaults** for parameters that have them, and why you picked that default.
- **Link generously** with double-backtick symbol links. DocC checks them, so broken links show up as warnings.
- **Mark deprecated APIs** with `@available(*, deprecated, renamed:)` or `message:`, *and* link the migration guide in the message (TCA does this well).

---

## 4. File-System Libraries: What to Spell Out

File-based APIs have more hidden behavior than most. Every public API that touches disk (real or simulated) should answer these questions in its docs when they apply:

| Concern | What to state |
|---|---|
| **Side effects** | What gets created, modified or deleted on disk. Are intermediate directories created? |
| **Atomicity** | Is the write atomic (temp file + rename)? What state is left behind after a crash mid-way? |
| **Overwrite semantics** | What happens if the destination exists: overwrite, throw or merge? |
| **Path handling** | Absolute vs. relative, how `~` is treated, symlink resolution, trailing slashes, case sensitivity (APFS case-insensitive by default vs. case-sensitive volumes). |
| **Errors** | Every error case, mapped to the condition that causes it. Say whether underlying `POSIXError`/`CocoaError` values are wrapped or passed through. |
| **Threading and isolation** | Which actor or queue it runs on, whether it blocks, whether concurrent calls on the same path are safe. |
| **Performance** | Whether it reads the whole file into memory or streams it; complexity in file size and in directory entry count. |
| **Platform and sandbox** | iOS/macOS/visionOS/Linux availability, behavior inside the App Sandbox, security-scoped URLs, file protection classes, iCloud/`NSFileCoordinator` interaction. |
| **Simulated vs. real disk** | If there's a simulated/in-memory backend, list every place its behavior differs from the real file system (permissions, timestamps, free space, case sensitivity, latency). Put this in one canonical article and link to it from affected symbols. |

Have one **"File System Semantics"** article in the catalog that holds the shared rules (path resolution, atomicity guarantees, error mapping) so individual symbol docs can stay short and link to it.

---

## 5. The DocC Catalog

DocC offers three kinds of pages: **reference** (generated from your comments), **articles** (conceptual, task-oriented prose) and **tutorials** (step-by-step guided projects). Plan for all three, even if tutorials come later.

### 5.1 Landing Page (`MyLibrary.md`)

```markdown
# ``MyLibrary``

Read, write, and simulate file systems with an API that feels native to Swift.

## Overview

MyLibrary gives you a single ``FileSystem`` protocol with two backends: ``DiskFileSystem``
for production and ``SimulatedFileSystem`` for tests and previews. …

![Diagram of the two backends](hero)

## Topics

### Essentials

- <doc:GettingStarted>
- ``FileSystem``
- ``FilePath``

### Reading and Writing

- ``FileSystem/read(at:)``
- ``FileSystem/write(_:to:options:)``
- ``WriteOptions``

### Testing

- <doc:Testing>
- ``SimulatedFileSystem``
- ``FaultInjection``

### Integrations

- <doc:UsingWithSwiftUI>
- <doc:UsingWithUIKit>

### Errors

- <doc:ErrorHandling>
- ``FileSystemError``

### Migration

- <doc:MigratingTo2.0>
```

**Curate every symbol on purpose.** Without a `## Topics` section, DocC sorts symbols automatically by kind, which reads like a phone book. Group by *task* ("Reading and Writing"), not by kind ("Structures"). Put the most important entry points first.

### 5.2 Extension Files

Use an extension file to curate a type's members or add long-form discussion without cluttering the source:

```markdown
# ``MyLibrary/SimulatedFileSystem``

@Metadata {
    @DocumentationExtension(mergeBehavior: append)
}

## Topics

### Creating a Simulated File System
- ``init()``
- ``init(contents:)``

### Injecting Failures
- ``inject(_:at:)``
- ``FaultInjection``
```

### 5.3 Articles

The best Swift libraries share a set of articles. Aim for these:

| Article | Purpose | Seen in |
|---|---|---|
| **Getting Started** | Install, first working example in under 5 minutes, next steps | TCA, GRDB |
| **Core concepts** | The mental model (e.g., backends, paths, handles) | GRDB, NIO |
| **Integration guides** | One per UI framework or environment (SwiftUI, UIKit, Linux/server) | TCA (SwiftUI, UIKit, Swift concurrency) |
| **Testing** | How to test code that uses the library; for this library, the simulated disk is the selling point | TCA ("Testing") |
| **Concurrency** | Isolation model, `Sendable`, cancellation | TCA ("Adopting Swift concurrency") |
| **Error handling** | Error taxonomy and recovery patterns | GRDB |
| **Performance** | Cost model, streaming vs. buffering, benchmarks | TCA ("Performance") |
| **Recommended practices** | Opinionated guidance on structuring app code | GRDB ("Recommended Practices for Designing Record Types") |
| **FAQ** | Real questions from issues and discussions | TCA, GRDB |
| **Why adopt this?** | Honest comparison with alternatives (`FileManager`, other libraries) | GRDB ("Why Adopt GRDB?") |
| **Migration guides** | One per major version, in order; tell readers to follow earlier guides first | TCA, GRDB |

Article structure:

```markdown
# Testing with a Simulated File System

Write fast, deterministic tests for code that reads and writes files.

## Overview

One or two paragraphs: what problem this solves and when to use it.

### Inject the file system

…

### Simulate failures

@Snippet(path: "SimulatedDisk/InjectingFaults", slice: "diskFull")

## See Also

- ``SimulatedFileSystem``
- <doc:FileSystemSemantics>
```

- The first paragraph after the title is the article's **abstract**. It shows up in lists and search, so keep it to one sentence.
- Use `##` for top-level sections and `###` for tasks inside them.
- Use `@Metadata { @PageImage(...) @Available(...) }` for cards and availability badges where useful.
- Use `@Comment { … }` for notes to maintainers that shouldn't render.

### 5.4 Tutorials (Optional, High Impact)

Interactive tutorials (`.tutorial` files with `@Tutorials`, `@Tutorial`, `@Section`, `@Steps`, `@Step`, `@Code`) take more effort, but they're the most welcoming entry point a library can have. TCA's "Meet the Composable Architecture" is the standard example. Start with one tutorial that builds a small but real feature end to end, such as a notes app that persists to disk and is tested against the simulated file system.

### 5.5 Images

- Supply `@2x` PNGs and a `~dark` variant for each image.
- Put them in `Resources/` and refer to them by name without extension: `![Alt text](hero)`.
- Always write meaningful alt text.

---

## 6. Code Examples

### 6.1 Prefer Snippets Over Fenced Code

Use **Swift Snippets** for every non-trivial example. Snippets are `.swift` files in a top-level `Snippets/` directory. SwiftPM compiles them on every build and fails the build if they don't compile, so examples can't drift out of date.

```swift
// Snippets/SimulatedDisk/InjectingFaults.swift
import MyLibrary

// snippet.hide
let path: FilePath = "notes.txt"
// snippet.show

// snippet.diskFull
let fs = SimulatedFileSystem()
fs.inject(.diskFull, at: path)

do {
    try fs.write(Data("hello".utf8), to: path)
} catch FileSystemError.insufficientSpace {
    // Show a "storage full" message.
}
// snippet.end
```

Embed in articles with `@Snippet(path: "SimulatedDisk/InjectingFaults", slice: "diskFull")`. (Recent DocC accepts the path relative to `Snippets/`. Older toolchains, before Swift-DocC 6.2.1, need `my-package/Snippets/...`.) Run one with `swift run InjectingFaults`.

**Caveat:** snippets build for the host platform. Snippets that import UIKit won't build on macOS or Linux, so keep UIKit and SwiftUI examples as fenced code in articles, or check them in a separate example app target.

### 6.2 Example Guidelines

- Each example should show **one idea**, run as written and include the `import`.
- Show the **common case first**, then variations.
- Show **error handling** for file operations instead of `try!`, except where brevity is the point and you say so.
- Use realistic names (`notes/2026-11-14.md`), not `foo`/`bar`.
- Include a **demo app** (GRDB ships several) for integration patterns that don't fit in a snippet, and link it from the README and the relevant articles.

---

## 7. README

The README is a storefront and a map, not the manual. Model it on GRDB and TCA:

1. **Name and one-line pitch**, optionally with a logo (use `<picture>` with light and dark sources).
2. **Badges**: Swift Package Index Swift-version and platform compatibility badges (they stay current automatically), CI status, license.
3. **"Latest release" line**: version, date, links to CHANGELOG and the newest migration guide.
4. **Requirements**: minimum OS versions, Swift version, Xcode version.
5. **A short, compelling example**: 10–20 lines showing the core idea (e.g., "Start using the file system in three steps").
6. **Installation**: the SwiftPM `.package(url:from:)` line and the Xcode steps. Say plainly which package managers you *don't* support.
7. **Documentation**: a prominent link to the hosted DocC reference, plus direct links to Getting Started, the main articles, the FAQ and demo apps.
8. **Community and support**: GitHub Discussions, Swift Forums category, how to report bugs.
9. **License.**

Keep reference material out of the README. Link to DocC instead, so there's only one copy to maintain.

---

## 8. Changelog, Releases and Migration

- Keep `CHANGELOG.md` in [Keep a Changelog](https://keepachangelog.com) style with `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed` and `Security` sections. Follow [Semantic Versioning](https://semver.org).
- GRDB includes a **"Documentation Diff"** section in each changelog entry that lists new and updated guides. Copy that habit.
- GitHub release notes should link to the changelog entry and any migration guide. Credit contributors.
- Write **a migration guide for every major version**, and for minor versions that soft-deprecate APIs (TCA writes them for minor releases too). Include before/after code for each change.
- Every deprecation message should point to its migration guide section.

---

## 9. Building, Hosting and Enforcing

### 9.1 Add the DocC Plugin

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.0"),
],
```

Preview locally:

```bash
swift package --disable-sandbox preview-documentation --target MyLibrary
```

In Xcode: **Product ▸ Build Documentation** (⌃⇧⌘D).

### 9.2 Host on Swift Package Index (Recommended)

Add `.spi.yml` at the repo root, and SPI builds and hosts versioned docs for every release:

```yaml
version: 1
builder:
  configs:
    - documentation_targets: [MyLibrary]
      # platform: ios   # set if the target requires UIKit
```

List multiple public modules in the order you want them to appear; the first is the landing page. SPI also includes documentation in its package score.

### 9.3 Or Host on GitHub Pages

```bash
swift package --allow-writing-to-directory ./docs \
  generate-documentation --target MyLibrary \
  --disable-indexing \
  --transform-for-static-hosting \
  --hosting-base-path MyLibrary \
  --output-path ./docs
```

The site lives at `https://USER.github.io/REPO/documentation/mylibrary/`. Add a redirect `index.html` at the root. For **iOS-only targets** (UIKit), `swift package generate-documentation` fails with "no such module 'UIKit'" because it builds for macOS. Use `xcodebuild docbuild -destination "generic/platform=iOS Simulator"` followed by `docc process-archive transform-for-static-hosting`.

### 9.4 CI Enforcement

SwiftNIO and the swiftlang soundness checks treat DocC warnings as errors in CI. Do the same:

```yaml
# .github/workflows/docs.yml
- name: Check documentation
  run: swift package generate-documentation --target MyLibrary --analyze --warnings-as-errors
```

This catches broken symbol links, malformed `Topics` sections and stale parameter names. Also:

- Build `Snippets/` in CI (a normal `swift build` does this).
- Optionally track coverage with `--experimental-documentation-coverage --level brief` (still experimental, but useful).
- Turn on SwiftLint's `missing_docs` rule for `public`/`open` declarations.

---

## 10. Contribution Checklist

Copy this into the pull request template:

```markdown
### Documentation
- [ ] Every new or changed `public`/`open` symbol has a doc comment with a one-line summary.
- [ ] `Parameters`, `Returns`, `Throws` (with specific cases) are documented.
- [ ] Disk side effects, atomicity, overwrite behavior, and threading are stated where relevant.
- [ ] Simulated-vs-real behavior differences are noted and linked to the semantics article.
- [ ] New symbols are curated in the landing page or an extension file's `## Topics`.
- [ ] Non-trivial examples are Snippets, not fenced code.
- [ ] Docs build cleanly with `--warnings-as-errors`.
- [ ] CHANGELOG updated (including Documentation Diff if guides changed).
- [ ] Deprecations include a `renamed:`/`message:` pointing to a migration guide.
```

---

## 11. References

- [Swift API Design Guidelines](https://swift.org/documentation/api-design-guidelines/): naming and doc-comment fundamentals
- [Swift-DocC documentation](https://www.swift.org/documentation/docc/): markup, directives, catalogs
- [Swift-DocC Plugin](https://github.com/swiftlang/swift-docc-plugin): building, previewing, static hosting
- [`@Snippet` directive](https://swiftlang.github.io/swift-docc/documentation/swiftdocc/snippet/)
- [Swift Package Index DocC hosting](https://swiftpackageindex.com/blog/auto-generating-auto-hosting-and-auto-updating-docc-documentation)
- WWDC21 "Meet DocC documentation in Xcode", "Elevate your DocC documentation in Xcode", "Build interactive tutorials using DocC", "Host and automate your DocC documentation"; WWDC23 "Create rich documentation with Swift-DocC"
- Exemplars: [GRDB.swift](https://github.com/groue/GRDB.swift), [swift-composable-architecture](https://github.com/pointfreeco/swift-composable-architecture), [swift-nio](https://github.com/apple/swift-nio), [swift-collections](https://github.com/apple/swift-collections), [swift-argument-parser](https://github.com/apple/swift-argument-parser), [swift-system](https://github.com/apple/swift-system) (for `FilePath` conventions)
