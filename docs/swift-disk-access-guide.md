# Swift Disk-Access APIs: A Design Guide for a Simulated File System Framework

*Research notes compiled November 2026. Use this as context for designing a Swift framework that simulates disk access while feeling native to Apple platforms and the wider Swift ecosystem.*

---

## 1. TL;DR: Design takeaways

1. **Model your API on two layers, the way the ecosystem already does.** One layer is a value-type *path* currency (`FilePath`). The other is a *file system* service that does the I/O. Keep paths pure: no I/O on the path type. The Swift community pushed hard on this during the stdlib `FilePath` review.
2. **Protocol-first, with a "live" and a "simulated" conformer.** SwiftNIO (`FileSystemProtocol`), SwiftPM (`FileSystem` + `InMemoryFileSystem`) and SwiftPM's newer `AsyncFileSystem` actor protocol all work this way. Your framework is that pattern made into a product.
3. **Go async-first, but be honest about it.** Most OS file I/O is blocking under the hood. "async" in Swift file APIs mostly means "won't block a cooperative-pool thread." A simulator can *model* latency honestly, which is a selling point.
4. **Use scoped resource handles.** `withFileHandle(...) { handle in ... }` and `closeAfter { }` are the idiomatic Swift answer to fd leaks. Make handles non-escaping or `~Copyable` where you can.
5. **Use typed, code-based errors.** Use an error struct with a `Code` (NIO style), or POSIX `Errno`. Swift 6 typed throws is an option. Code that's tested against your simulator must hit the *same error shapes* it would hit in production.
6. **Simulate the hard parts.** Atomic-write semantics, fd exhaustion, ENOSPC, permission denial, case-insensitivity and Unicode normalization (APFS), symlinks and TOCTOU races, partial reads and writes. These are where real bugs live, and where a simulator adds value over a `[URL: Data]` dictionary mock.
7. **Keep the core UI-agnostic and adapt it to each UI framework.** For SwiftUI that means an `@Entry` environment value, a `PreviewModifier` and document reader/writer harnesses. For UIKit it means initializer injection plus a custom trait bridged to the same environment key. Both frameworks can share `@Observable` state (§7).

---

## 2. The landscape at a glance

| API / library | Owner | Path type | Sync/async | Abstraction/testability | Notes |
|---|---|---|---|---|---|
| `FileManager` + `URL` + `Data` | Apple (Foundation) | `URL` (file URL) / `String` | Sync (blocking) | Class singleton (`.default`), not protocol-based | The baseline every Apple dev knows; now implemented in Swift in swift-foundation |
| `FileHandle` | Apple (Foundation) | `URL` / path | Sync, plus `AsyncBytes` | Class | Offset-based reading/writing/seeking |
| `FileWrapper`, `NSFileCoordinator` / `NSFilePresenter` | Apple | `URL` | Sync / callback | — | Document packages, coordinated access, iCloud |
| **Swift System** (`System` / `SystemPackage`) | Apple, open source | `FilePath` | Sync | Thin, typed syscall wrappers | `FileDescriptor`, `Errno`, `FilePermissions` |
| **stdlib `FilePath`** (SE-0529) | Swift project | `FilePath` | — | Currency type | Accepted June 2026 |
| **`_NIOFileSystem`** | Apple (SwiftNIO) | `FilePath` | **async/await native** | `FileSystemProtocol` + handle protocols | Best "Apple-authored" model for an abstract, async FS |
| `NonBlockingFileIO` | SwiftNIO | `String` | Futures | — | Older; used by Vapor |
| SwiftPM `Basics.FileSystem` / TSCBasic `FileSystem` | Swift project | `AbsolutePath` | Sync | **Protocol + `InMemoryFileSystem` + `VFSOverlay`** | Closest prior art to a "simulated FS" |
| SwiftPM `_AsyncFileSystem` | Swift project | `FilePath` | async, **Actor-constrained protocol** | Protocol | Package-internal, but instructive |
| Tuist `FileSystem` | Tuist | `AbsolutePath` (tuist/Path) | async | Protocol | "Paths are always absolute" |
| John Sundell `Files` | Community | `File` / `Folder` objects | Sync | OO wrapper | Scripting ergonomics |
| `Pathman` | Community | Typed `FilePath` / `DirectoryPath` | Sync | POSIX-based | Type-safe file-vs-directory paths |
| coenttb `swift-file-system` | Community | Own path type | Sync and async with the same names | Foundation-free | Typed throws, durability options |

---

## 3. Apple's first-party APIs

### 3.1 Foundation: `FileManager`, `URL`, `Data`

The idioms people will expect your API to echo:

```swift
let fm = FileManager.default
let docs = URL.documentsDirectory                    // iOS 16+/macOS 13+
let file = docs.appending(path: "notes.json")        // directoryHint: .inferFromPath / .isDirectory / .notDirectory / .checkFileSystem

try data.write(to: file, options: [.atomic, .completeFileProtection])
let loaded = try Data(contentsOf: file)

try fm.createDirectory(at: dir, withIntermediateDirectories: true)
let items = try fm.contentsOfDirectory(at: dir,
                                       includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                                       options: [.skipsHiddenFiles])
let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
try fm.moveItem(at: a, to: b)
try fm.removeItem(at: a)
_ = try fm.replaceItemAt(original, withItemAt: temp)   // safe-save pattern
```

Things worth copying:
- **Option sets for behavior** (`Data.WritingOptions`, `DirectoryEnumerationOptions`). Swift developers reach for these by reflex.
- **Resource keys / prefetching.** `includingPropertiesForKeys` lets the caller batch-fetch metadata during enumeration. A simulator can count and charge "stat" costs for metadata that wasn't prefetched.
- **Well-known directories** (`.documentsDirectory`, `.cachesDirectory`, `temporaryDirectory`, `url(for:in:appropriateFor:create:)`). A simulated FS should expose a sandbox-shaped root with these locations.
- **`replaceItemAt` / `.atomic`.** Write to a temp file, then rename. Apps rely on this for crash safety, so simulate a crash mid-write.

Things people complain about (the opportunities):
- **Not protocol-based, so not mockable.** The standard workaround is to wrap it behind your own protocol (see §6).
- **Blocking.** Wrapping `FileManager` in `async` doesn't help, because it still blocks the thread. Tuist's Pedro Piñera argues foundational APIs need to be designed for concurrency to get any real performance benefit.
- **Stringly-typed attributes** (`FileAttributeKey`) and `ObjCBool` out-params (`fileExists(atPath:isDirectory:)`). Pathman's author cites these as the reason they wrote their own library.
- **Errors are `CocoaError` / `NSError`** with codes like `.fileNoSuchFile` and `.fileWriteOutOfSpace`. Your simulator should be able to throw *these exact* errors when used through a Foundation-shaped facade.
- **`DirectoryHint.checkFileSystem`** (a newer `URL` API) hits the disk during path construction. That's awkward for async designs, and a sign to keep path construction pure.

### 3.2 `FileHandle` and async bytes

```swift
let h = try FileHandle(forReadingFrom: url)
defer { try? h.close() }
try h.seek(toOffset: 11)
let chunk = try h.read(upToCount: 10)

for try await line in url.lines { ... }             // URL.AsyncBytes / lines
for try await byte in h.bytes { ... }
```

`FileHandle` keeps an offset that starts at 0 and moves as you read, write or seek. Note that `AsyncBytes` just blocks a Swift Concurrency executor thread. A simulator can make this visible, for example with a diagnostic when cooperative threads get blocked.

### 3.3 Coordinated and document access (Apple-platform specific)

- **`NSFileCoordinator` / `NSFilePresenter`.** These coordinate reads and writes across processes and extensions (iCloud Drive, File Provider, app groups). Simulating presenter callbacks (`presentedItemDidChange`, relinquish-to-writer) is a hard problem with a lot of value, and almost nobody tests this well.
- **`FileWrapper`.** An in-memory tree of regular files, directories and symlinks used by document-based apps. It's arguably Apple's own "in-memory file system" value type, and good inspiration for snapshots.
- **Security-scoped URLs and bookmarks** (`startAccessingSecurityScopedResource`). Sandboxed apps lose access when scopes aren't balanced. Simulate permission revocation.
- **Data protection classes** (`.completeFileProtection` and friends). Files can be unreadable while the device is locked. A simulator can toggle a "device locked" state.

### 3.4 Swift System (`import System` / `SystemPackage`)

Apple's idiomatic layer over syscalls. This is **the strongest signal of what "idiomatic Swift" looks like at a low level**:

```swift
let path: FilePath = "/tmp/log"
let fd = try FileDescriptor.open(path, .writeOnly, options: [.append, .create],
                                 permissions: .ownerReadWrite)
try fd.closeAfter { _ = try fd.writeAll(message.utf8) }
```

Design patterns to borrow:
- Syscalls become **static functions with defaulted, labeled arguments** on a namespace type (`FileDescriptor.open`). The Swift System launch post presents this as the way to replace weakly typed, error-prone C interfaces.
- **Strong types for flags**: `AccessMode` (exactly one of read/write/readWrite), `OpenOptions` (option set), `FilePermissions` (option set), `Errno` (struct with static members such as `.noSuchFileOrDirectory`).
- **`retryOnInterrupt: Bool = true`** handles EINTR, so callers don't have to.
- **`closeAfter {}`** gives scoped lifetimes.
- One API-design detail: `open` with `.create` traps (`fatalError`) if `permissions` is nil. Swift System prefers a loud precondition to a silent default.
- `FilePath` is `Sendable`, `Hashable` and `Codable`. It normalizes separators (removes redundant ones and strips trailing ones) and has a component view (`root`, `components`, `lastComponent`, `extension`, `stem`, `lexicallyNormalized()`). The package has been actively maintained through 2026: 1.8.x builds on Swift 6.3 with zero data-race errors.

### 3.5 `FilePath` in the standard library (SE-0529, accepted June 2026)

This is a major development for your framework's path type:
- The Language Steering Group accepted a stdlib `FilePath` that represents a path on the current system, calling it a good direction for the standard library.
- **Non-portable APIs (e.g. `driveLetter`) are platform-conditional**, so portable code gets flagged where it assumes a specific target.
- **`resolve()` was kept.** It's the stdlib's first I/O operation. It's synchronous because operating systems don't offer async path resolution yet, and on Apple platforms it adds `/.nofollow` automatically.
- In the review thread, people asked for `FilePath` to act as a currency type with no interactions with the actual file system, and for any resolution step to be named so that it's clearly hitting the file system.

**Implication:** Build on `FilePath` (stdlib where available, `SystemPackage` otherwise) rather than inventing a path type. Your simulator then plugs into NIO, Swift System and Swift Concurrency code without conversions. Watch how the `System.FilePath` → stdlib migration plays out: the acceptance post doesn't cover it, though reviewers supported ABI redirection. Note that `resolve()` touches the *real* file system, so your simulated FS needs its own `resolve(_:)`.

---

## 4. SwiftNIO's `_NIOFileSystem`: the best Apple-authored model for an abstract async FS

NIO describes it as a cross-platform file system library with a concrete `FileSystem` implementation for the local file system and **a set of protocols for building custom file system implementations**. That second part is exactly your use case.

Status: the module is underscored (`_NIOFileSystem`) because the API is still being polished. The NIO team calls it relatively stable, and they tell people using async/await to prefer it over `NonBlockingFileIO`.

### Shape of the API

```swift
import _NIOFileSystem

let fs = FileSystem.shared
let tmp = try await fs.temporaryDirectory
let path = tmp.appending("hello.txt")

// Scoped handle: closed for you when the closure returns or throws
try await fs.withFileHandle(forWritingAt: path, options: .newFile(replaceExisting: true)) { h in
    try await h.write(contentsOf: Array("hi".utf8), toAbsoluteOffset: 0)
}

let bytes = try await fs.withFileHandle(forReadingAt: path) { h in
    try await h.readToEnd(maximumSizeAllowed: .megabytes(1))
}

try await fs.withDirectoryHandle(atPath: tmp) { dir in
    for try await entry in dir.listContents() { print(entry.name) }
}

if let info = try await fs.info(forFileAt: path) { print(info.size) }
```

*(Signatures are approximate; check current docs.)*

### What to steal
- **`FileSystemProtocol: Sendable` with associated handle types**: `ReadFileHandle`, `WriteFileHandle`, `ReadWriteFileHandle` and a directory handle, each with its own protocol (`ReadableFileHandleProtocol`, etc.). Capabilities are encoded in the type system: you can't write through a read handle.
- **Separate `OpenOptions.Read` and `OpenOptions.Write`**, e.g. `.newFile(replaceExisting:)` and `.modifyFile(createIfNecessary:)`. These are clearer than raw `O_CREAT|O_EXCL`.
- **`FileSystemError` with a `Code` struct** (`.notFound`, `.invalidArgument`, …). Each method's doc comment lists the codes it can throw. Your simulator can treat those lists as a contract and fuzz them.
- **`maximumSizeAllowed:` on whole-file reads.** It's a guard against unbounded memory, and worth mirroring.
- **`AsyncSequence` directory listing**, plus `BufferedReader` / `BufferedWriter` for streaming.
- `copyItem(at:to:shouldProceedAfterError:)`: error callbacks for recursive operations.

### Known criticisms (design around them)
- Tuist moved from `FileManager` to `NIOFileSystem` and reported **worse performance than `FileManager`'s blocking API**. They also found that it **doesn't protect callers from running out of file handles**. A simulator that enforces an fd limit would catch exactly this class of bug. Tuist's `FileSystem` package appears to have since dropped its swift-nio dependency (0.18.0 builds without it), which suggests they replaced the backend.
- The underscore makes library authors wary of depending on it.

---

## 5. Prior art for *simulated* file systems in Swift

### 5.1 SwiftPM / swift-tools-support-core: `FileSystem` + `InMemoryFileSystem`

The most mature in-memory FS in the Swift ecosystem. SwiftPM's `Basics/FileSystem` folder contains `InMemoryFileSystem.swift`, `VFSOverlay.swift` and `VirtualFileSystem.swift`, alongside `AbsolutePath` and `RelativePath`.

- A synchronous `FileSystem` protocol (`exists`, `isDirectory`, `isFile`, `isSymlink`, `getDirectoryContents`, `readFileContents`, `writeFileContents`, `createDirectory(_:recursive:)`, `removeFileTree`, `copy`, `move`, `chmod`, `withLock`, …) with a global `localFileSystem` and a test-time `InMemoryFileSystem`.
- **`AbsolutePath` vs `RelativePath`** as distinct types. Because of the type distinction, you can't accidentally resolve against the CWD.
- **VFS overlays** layer virtual files over the real disk. That's a powerful mode for a simulator: "real disk, but with these files faked or failing."
- Tools such as sourcekit-lsp build test helpers as extensions on this protocol.

### 5.2 SwiftPM `_AsyncFileSystem`

A newer, package-internal protocol, documented as an abstract file system with first-class support for Swift Concurrency. It's declared as `package protocol AsyncFileSystem: Actor` and uses `SystemPackage.FilePath` and `Errno`. Two choices are notable: **an actor-constrained protocol**, so isolation is guaranteed, and **`Errno` as the error currency**.

### 5.3 Tuist `FileSystem`

A cross-platform Swift package that powers Tuist. Its stated motivations include providing an API where paths are always absolute, which makes file system operations easier to reason about. It's async, protocol-based and Swift 6 clean.

### 5.4 Other community libraries
- **John Sundell's `Files`.** A thin wrapper around `FileManager` with an object-oriented API (`File`, `Folder`), aimed at scripting and tooling. Good inspiration for ergonomics (`folder.createFile(named:)`, `folder.subfolders.recursive`).
- **Pathman.** Built on POSIX C APIs instead of `FileManager`, citing inconsistent cross-platform Foundation behavior and `FileAttributeKey` clunkiness. It has type-distinct paths and very granular errors.
- **coenttb `swift-file-system`.** Async-first and Foundation-free (no `URL`, `Data` or `String` bridging), with pull-based batched async iteration for bounded memory. It uses nested-namespace naming (`File.Directory.Contents.Async`), **the same method names for sync and async** (overload resolution picks by context), typed throws across the async API, and configurable durability for atomic writes (`durability: .full`).

### 5.5 Cross-language prior art worth a look
Rust `vfs` (`MemoryFS`, `OverlayFS`, `AltrootFS`), Go `io/fs` + `testing/fstest.MapFS` + `afero`, Python `pyfakefs`, Dart `package:file` (`MemoryFileSystem`), LLVM `llvm::vfs` (`InMemoryFileSystem`, `OverlayFileSystem`; Swift's compiler uses this). LLVM's `OverlayFileSystem` and Go's `fstest.TestFS` (a conformance checker for any FS implementation) are especially relevant ideas.

---

## 6. How people test disk code in Swift today (your target users' current pain)

1. **Mirror `FileManager` in a protocol** (`protocol FileManagerProtocol { func fileExists(...) }; extension FileManager: FileManagerProtocol {}`). It's fast to do, but you inherit FileManager's API warts, and it's easy to drift from the real behavior.
2. **"Own your abstractions"**: define a *semantic* protocol (`FileReader`) with a thin live implementation. The live implementation can't be tested directly, and the argument is that it's so simple it doesn't matter.
3. **Small, focused `Sendable` protocols per boundary** (`FileSystemProviding`, `FileAccessorProviding`), injected via default parameters. Mocks are often `final class … @unchecked Sendable` over a dictionary. Common advice: don't build one giant protocol, and don't use `#if DEBUG` instead of injection.
4. **Use the real disk under `temporaryDirectory`**: realistic, but slow, flaky in parallel (Swift Testing runs tests in parallel by default), and unable to produce ENOSPC, EACCES or crashes on demand.
5. **Dependency containers** (Point-Free's swift-dependencies, Factory, or `@Environment` in SwiftUI) to swap live and test implementations.

**Gap your framework fills:** dictionary mocks are too naive, and the real disk is too uncontrollable. A *behaviorally faithful* simulator with fault injection sits between them.

---

## 7. SwiftUI and UIKit integration patterns

Goal: one UI-agnostic core, plus thin adapters that make it feel native in each UI framework. Suggested packaging:

| Module | Contents |
|---|---|
| `DiskSim` (core) | `FileSystem` protocol, `LiveFileSystem`, `SimulatedFileSystem`, errors, fixtures. No UI imports. |
| `DiskSimSwiftUI` | Environment entry, `PreviewModifier`, document reader/writer adapters, `Transferable` helpers |
| `DiskSimUIKit` | Custom trait bridged to the SwiftUI environment, `UIDocument` helpers, picker/URL-scope simulation |
| `DiskSimTesting` | Swift Testing traits, assertions, the conformance suite |

### 7.1 Dependency injection: the idiom each framework expects

**SwiftUI: the environment.** SwiftUI developers expect to swap a dependency with a modifier:

```swift
extension EnvironmentValues {
    @Entry var fileSystem: any FileSystem = LiveFileSystem()      // @Entry macro, Xcode 16+
}

ContentView()
    .environment(\.fileSystem, SimulatedFileSystem { Directory("Documents") { … } })

struct NotesView: View {
    @Environment(\.fileSystem) private var fs
    @State private var store: NotesStore?                         // created once in .task
    var body: some View {
        List(store?.notes ?? []) { … }
            .task { store = await NotesStore(fs: fs) }            // auto-cancelled on disappear
    }
}
```

Precedents you're mirroring: SwiftData's `.modelContainer(for:inMemory: true)` / `ModelConfiguration(isStoredInMemoryOnly:)`, and `.defaultAppStorage(UserDefaults(suiteName:))`. Both swap storage with a single modifier. A `.simulatedFileSystem(...)` convenience modifier would read the same way.

**Previews.** Ship a `PreviewModifier` so a whole preview canvas shares one seeded simulated disk:

```swift
struct SampleDisk: PreviewModifier {
    static func makeSharedContext() async throws -> SimulatedFileSystem { .fixture(.sampleNotes) }
    func body(content: Content, context: SimulatedFileSystem) -> some View {
        content.environment(\.fileSystem, context)
    }
}
extension PreviewTrait where T == Preview.ViewTraits {
    static var sampleDisk: Self { .modifier(SampleDisk()) }
}

#Preview(traits: .sampleDisk) { NotesView() }
```

Also offer named fixtures for preview states: empty disk, disk full, slow disk, permission denied, corrupt file. Then a designer can preview error UI without touching code. Use `@Previewable @State` for interactive previews.

**UIKit: initializer injection plus traits.** UIKit developers mostly inject through initializers (`NotesViewController(fileSystem:)`). For hierarchy-wide injection, iOS 17 added **custom traits** (`UITraitDefinition` / `UIObjectTraitDefinition`) that flow down the view-controller tree like the SwiftUI environment. **`UITraitBridgedEnvironmentKey`** bridges a UIKit trait and a SwiftUI environment key. Define the dependency once, and it propagates across `UIHostingController` boundaries in both directions. This is the strongest "works in both" pattern. Check the `Equatable` requirements on object traits: an `any FileSystem` probably needs an identity-equatable box.

### 7.2 Observation: the shared state model

- Expose an `@Observable` store (or have `SimulatedFileSystem` itself be observable: file tree, open-handle count, used capacity, recent operations). SwiftUI tracks it automatically. **UIKit on iOS 26+ also tracks `@Observable` reads** in `layoutSubviews()`, `updateProperties()` and similar methods, so the same model drives both UIs. For older UIKit, also offer an `AsyncSequence` of change events, plus `NotificationCenter` notifications if you want to match `UIDocument.stateChangedNotification` habits.
- **`@State` is now lazy for classes (Xcode 27).** The value is initialized and stored only once, which makes it safe to hold an FS-backed `@Observable` model directly in `@State`.
- **Honor `Task` cancellation.** `.task {}` cancels when a view disappears. Simulated slow reads should throw `CancellationError` promptly, so developers can test the "navigated away mid-load" path.

### 7.3 Concurrency defaults in app targets

Since Swift 6.2, Xcode app targets often use **default `MainActor` isolation** ("approachable concurrency"). Make the core types explicitly `nonisolated` and `Sendable`, with `async` I/O methods that hop off the main actor, so they behave the same whether the client module defaults to `MainActor` or not. Optionally, add a diagnostic mode that flags *synchronous* I/O issued from the main actor. That's a common cause of hangs, and something UIKit and SwiftUI developers would value.

### 7.4 Document-based apps (both frameworks)

**SwiftUI's classic layer:** `DocumentGroup` + `FileDocument` (value type, `init(configuration:)` / `fileWrapper(configuration:)`) or `ReferenceFileDocument` (class with `snapshot(contentType:)`). Both are `FileWrapper`-based, so your simulator should convert both ways between a subtree and a `FileWrapper`.

**The new 2026 layer (iOS 27 / macOS 27, Xcode 27).** WWDC26 expanded SwiftUI's Document API:
- **`ReadableDocument` / `WritableDocument`** read directly from a file URL, so large files and URL-based frameworks work. They use `DocumentReader` / `DocumentWriter` for custom logic, or `FileWrapperDocumentReader` / `FileWrapperDocumentWriter` for simpler cases.
- **Snapshot diffing.** `snapshot(contentType:)` runs on the main actor and returns a plain value. The writer's nonisolated, async `write(snapshot:to:previous:progress:)` receives the *previous* snapshot so it can write incrementally, and reports progress through Foundation's **`Subprogress`**.
- **`URLDocumentConfiguration`** exposes the document's file URL and last-modified date, and lets you coordinate additional file access.
- **`DocumentCreationSource`** + `NewDocumentButton` declare multiple ways to create a document. `fileExporter` can now export a `WritableDocument`.

Implications for your framework:
- These APIs hand you **real `URL`s** (the destination for `write`, the document URL). Your framework needs a story for that. Option 1: a "materialize" mode that mirrors a simulated subtree into a real temp directory, then captures the result back. Option 2: the overlay mode (§8.3). Option 3: a `DocumentWriter`/`DocumentReader` test harness that calls the writer with a simulated destination and asserts on the result. Option 3 is the most valuable: you could ship `DocumentWriterHarness` that runs `write` against snapshot pairs, injects latency and failures, and records `Subprogress` updates.
- Simulate **slow, failing and partial writes** so developers can test progress UI, autosave and the edited indicator, and recovery after a failed save.

**UIKit:** `UIDocument` (`load(fromContents:ofType:)`, `contents(forType:)`, autosave, `documentState` / `stateChangedNotification`, conflict versions), `UIDocumentBrowserViewController` and `UIDocumentPickerViewController`. `UIDocument` is an `NSFilePresenter` and uses `NSFileCoordinator` internally. That's where simulating coordination, conflicts (`.inConflict`) and `.savingError` states pays off. A `SimulatedDocumentHost` that drives a `UIDocument` subclass through open, edit, autosave, conflict and close would be a strong UIKit feature.

### 7.5 Files that cross the app boundary

- **`fileImporter` / `fileExporter` / `fileMover`** (SwiftUI) and **`UIDocumentPickerViewController`** (UIKit) return **security-scoped URLs**. Simulate unbalanced `startAccessingSecurityScopedResource` calls, revoked access and stale bookmarks.
- **`Transferable` + `FileRepresentation`** (drag and drop, `ShareLink`, paste). The received file is often a temporary copy that's only valid during the import closure. Simulate the system deleting it afterwards to catch "used the URL too late" bugs.
- **App groups and extensions** (widgets, share extensions) sharing a container. Model multiple "processes" mounting the same simulated volume, with coordination.

### 7.6 Errors in the UI

SwiftUI added `alert(error:actions:)` and `alert(_:item:actions:)` in 2026. Make `FileSystemError` conform to **`LocalizedError`** (and `CustomNSError` for UIKit and `NSError` bridging), with human-readable `errorDescription` and `recoverySuggestion`, so `.alert(error: $lastError)` and `UIAlertController(error-derived)` "just work."

---

## 8. Recommended shape for your framework

### 8.1 Core types

```swift
public protocol FileSystem: Sendable {
    associatedtype ReadHandle: ReadableFile
    associatedtype WriteHandle: WritableFile

    func withFile<R>(readingAt path: FilePath,
                     _ body: (ReadHandle) async throws -> R) async throws(FileSystemError) -> R
    func withFile<R>(writingAt path: FilePath, options: WriteOptions,
                     _ body: (WriteHandle) async throws -> R) async throws(FileSystemError) -> R

    func info(at path: FilePath, followSymlinks: Bool) async throws(FileSystemError) -> FileInfo?
    func contents(ofDirectory path: FilePath) -> some AsyncSequence<DirectoryEntry, FileSystemError>
    func createDirectory(at: FilePath, intermediates: Bool, permissions: FilePermissions?) async throws(FileSystemError)
    func removeItem(at: FilePath, recursively: Bool) async throws(FileSystemError)
    func moveItem(at: FilePath, to: FilePath) async throws(FileSystemError)      // atomic rename semantics
    func copyItem(at: FilePath, to: FilePath) async throws(FileSystemError)
    func resolve(_ path: FilePath) async throws(FileSystemError) -> FilePath       // FS-aware, NOT on FilePath

    var temporaryDirectory: FilePath { get }
}

public struct LiveFileSystem: FileSystem { ... }          // System / NIO / Foundation backed
public final class SimulatedFileSystem: FileSystem { ... } // or an actor
```

Decisions to make deliberately (see open questions):
- **Errors:** a `FileSystemError` with `code` (`.notFound`, `.permissionDenied`, `.noSpace`, `.tooManyOpenFiles`, `.exists`, `.notDirectory`, `.isDirectory`, `.crossDevice`, `.interrupted`, `.io`), `path`, `underlying: Errno?` and source location. Offer bridging to `CocoaError` so Foundation-shaped call sites behave identically.
- **Sync and async.** Consider overload-by-context like swift-file-system, or a separate `SyncFileSystem`. Many app call sites (Codable caches, `@MainActor` code) are still synchronous.
- **Bytes currency:** `[UInt8]` / `Span` / `RawSpan` (Swift 6.2+), with `Data` conveniences in a `Foundation` extension module so the core stays Foundation-free.

### 8.2 Foundation-flavored facade
Ship an optional module that looks like Foundation (`url.resourceValues`, `Data(contentsOf:in:)`, `write(to:options:)` with `.atomic`) on top of the core. That lowers adoption cost for app developers and keeps the core clean.

### 8.3 Simulator features (the differentiators)
- **Deterministic by default**: injectable `Clock` (`ContinuousClock` vs a test clock), seeded randomness, ordered directory listing (or *deliberately shuffled*, because real `readdir` order is undefined).
- **Latency model**: per-operation cost (open, stat, read per byte, fsync), optionally device profiles ("iPhone NAND", "network volume", "slow SD card").
- **Fault injection**: scripted ("third write to `/cache/*` fails with ENOSPC"), probabilistic, or quota-based (`capacity: .megabytes(50)`). Include short reads and writes and EINTR.
- **Resource limits**: max open fds. This catches the NIOFileSystem-style handle exhaustion.
- **Crash and durability simulation**: "power loss" discards writes that weren't fsynced, or truncates. This verifies `.atomic` and safe-save code.
- **Platform semantics flags**: case-insensitive but case-preserving (default APFS on macOS) vs case-sensitive, Unicode normalization behavior, max path and component length, symlinks and hard links, permissions and ownership, data-protection "device locked."
- **Concurrency and race injection**: interleave a second writer between `exists` and `open` to expose TOCTOU bugs.
- **Observability**: an operation log or `AsyncStream` of events, assertions like `#expect(fs.operations.count(of: .fsync) == 1)`, and snapshot/diff of the tree (`FileWrapper`-like value).
- **Fixtures**: build trees with a result builder, e.g.
  ```swift
  let fs = SimulatedFileSystem {
      Directory("Documents") {
          File("notes.json", contents: #"{"a":1}"#)
          Symlink("latest", to: "notes.json")
      }
  }
  ```
- **Overlay mode** (à la SwiftPM `VFSOverlay` / LLVM `OverlayFileSystem`): real disk underneath, simulated layer on top.
- **Conformance test suite** (à la Go's `fstest.TestFS`): one Swift Testing suite, run against both `LiveFileSystem` and `SimulatedFileSystem`, proves the simulator is faithful. This is probably the most important thing for credibility.

### 8.4 Naming and API-design idioms to follow
- Follow the Swift API Design Guidelines: argument labels that read as phrases (`moveItem(at:to:)`, `createDirectory(at:withIntermediateDirectories:)`), and Bool parameters labeled for what they mean.
- Use option sets for flags and static factory members for common configurations (`.newFile(replaceExisting:)`).
- Use `with…` scoped-resource functions over manual `close()`. Consider `~Copyable` handles (Swift 5.9+) to make use-after-close a compile error.
- Make everything `Sendable`. Isolate the simulator's state in an `actor` or behind `Mutex` (Synchronization, Swift 6). Avoid `@unchecked Sendable` dictionary mocks.
- Put doc comments on every method that list the error codes it can throw, as NIO does.

---

## 9. Pitfalls a faithful simulator must model

| Real-world behavior | Why it matters |
|---|---|
| `rename` is atomic on the same volume; cross-device fails (`EXDEV`) | Safe-save and `replaceItemAt` depend on it |
| Writes aren't durable until `fsync` / `F_FULLFSYNC` (Darwin) | Data loss on crash |
| APFS on macOS is case-insensitive by default; iOS is case-sensitive | "Works on my Mac" bugs |
| Unicode normalization (NFC vs NFD) in file names | Lookups fail with accented names |
| Directory enumeration order is unspecified | Tests that pass by accident |
| Short reads and writes, EINTR | Loops that assume full transfers |
| fd limits (`ulimit -n`, often 256 on macOS) | Concurrency fan-out crashes |
| Symlink loops, dangling links, `/.nofollow` | Security and traversal bugs |
| TOCTOU between `fileExists` and `open` | Races, security issues |
| Sandbox and security-scoped access, data-protection locks | iOS-only failures in production |
| Disk full (`ENOSPC`), quota exceeded (`EDQUOT`) | Rarely tested, common in the field |
| File coordination with extensions and iCloud | Corruption across processes |

---

## 10. Open questions for the next session

1. **Path type:** adopt stdlib `FilePath` (and its minimum toolchain), `SystemPackage.FilePath`, or both behind a typealias? Do you also want absolute vs relative path types like SwiftPM and Tuist?
2. **Scope:** a pure simulator (test-only target), or a full FS abstraction with a production `LiveFileSystem`? The latter makes the conformance suite possible.
3. **Async model:** async-only, sync-only, or both? Is the simulator an `actor`, or a `Sendable` class with internal locking? (Actors force `await` even for sync-shaped APIs.)
4. **Error strategy:** typed throws with your own `FileSystemError`, or `Errno` and `CocoaError` passthrough to stay drop-in compatible?
5. **Foundation:** keep the core Foundation-free (Linux, Embedded Swift) with a Foundation compat module?
6. **Interop adapters:** conform to NIO's `FileSystemProtocol`, and provide a `FileManager`-shaped facade, so existing code can test with zero changes?
7. **UI minimums:** what deployment targets do the SwiftUI and UIKit modules support? The new `ReadableDocument`/`WritableDocument` APIs need the 2027 releases, `@Observable` in UIKit needs iOS 26, and custom traits need iOS 17. Do you gate features with `@available`, or set the floor?
8. **Real-URL bridging:** for document and picker APIs that require real `URL`s, which approach do you pick: materialize, overlay, or writer harness?
9. **Determinism vs realism defaults:** should the default simulator be "perfect disk" or "realistic disk"?

---

## Sources

- [SE-0529: Add FilePath to the Standard Library (review thread)](https://forums.swift.org/t/se-0529-add-filepath-to-the-standard-library/86194)
- [[Accepted with modifications] SE-0529: FilePath](https://forums.swift.org/t/accepted-with-modifications-se-0529-filepath/87125)
- [Apple Developer: FilePath (System)](https://developer.apple.com/documentation/system/filepath)
- [Swift.org: Swift System is Now Open Source](https://swift.org/blog/swift-system/)
- [Swift Package Index: swift-system builds](https://swiftpackageindex.com/builds/CA868590-C408-40B5-97A5-B62F46033378)
- [SwiftNIO documentation index](https://docsearch.algolia.com/mcp/docs/repo/apple/swift-nio)
- [NIO `FileSystemProtocol.swift` source](https://sources.debian.org/src/swiftlang/6.1.3-1/swift-nio/Sources/NIOFileSystem/FileSystemProtocol.swift)
- [Swift Forums: NIO's FileSystem vs NonBlockingFileIO](https://forums.swift.org/t/nios-filesystem-vs-nonblockingfileio/72318)
- [Swift Forums: What is the best way to work with the file system?](https://forums.swift.org/t/what-is-the-best-way-to-work-with-the-file-system/71020)
- [Swift Forums: Task-safe way to write a file asynchronously](https://forums.swift.org/t/task-safe-way-to-write-a-file-asynchronously/54639)
- [Swift on Server: NIO file system](https://kelaenderkoe.pages.dev/optimizing-https-swiftonserver.com/nio-file-system)
- [Pedro Piñera: If system APIs were awaitable](https://pepicrft.me/blog/if-system-apis-were-awaitable/)
- [SwiftPM `Basics/FileSystem` sources](https://sources.debian.org/src/swiftlang/6.0.3-2/swiftpm/Sources/Basics/FileSystem)
- [SwiftPM `_AsyncFileSystem/AsyncFileSystem.swift`](https://sources.debian.org/src/swiftlang/6.1.3-1/swiftpm/Sources/_AsyncFileSystem/AsyncFileSystem.swift)
- [tuist/FileSystem](https://github.com/tuist/FileSystem)
- [Swift Package Index: tuist/FileSystem 0.18.0 build](https://swiftpackageindex.com/builds/5601D529-B6CE-4FD6-AF2F-E38C3CFC509D)
- [swift-file-system (coenttb)](https://swiftpackageregistry.com/coenttb/swift-file-system)
- [John Sundell: Files](https://github.com/adamdahan/Files) · [Swift by Sundell: Working with files and folders](https://swiftbysundell.com/articles/working-with-files-and-folders-in-swift)
- [Pathman](https://awesome.ecosyste.ms/projects/github.com%2FPonyboy47%2FPathman)
- [Steve On Stuff: Own Your Abstractions](https://www.steveonstuff.com/2019/09/12/own-your-abstractions)
- [Swift protocol-DI testing pattern (example)](https://skills.sh/mark393295827/house-maint-ai/swift-protocol-di-testing)
- [Educative: FileHandle in Swift](https://www.educative.io/answers/how-to-file-handle-in-swift-using-filehandler)
- [Apple: SwiftUI updates (June 2026 Documents changes)](https://developer.apple.com/tutorials/data/documentation/updates/swiftui.md)
- [Apple: What's new in SwiftUI (WWDC26 guide)](https://developer.apple.com/wwdc26/guides/swiftui/)
- [WWDC Notes: What's new in SwiftUI (WWDC26 session 269)](https://wwdcnotes.com/documentation/wwdc26-269-whats-new-in-swiftui/)
- [InfoQ: SwiftUI adds new Document protocol](https://infoq.com/news/2026/07/swiftui-wwdc26)
- [Vapor docs: Files (NonBlockingFileIO)](https://docs.vapor.codes/advanced/files/index.md)
