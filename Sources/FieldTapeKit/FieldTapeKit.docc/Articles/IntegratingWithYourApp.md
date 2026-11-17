# Integrating with Your App

Watch for an OP-1, show progress, ask before deleting, and open archives, in SwiftUI, UIKit or AppKit.

## Overview

FieldTapeKit has no SwiftUI or UIKit module of its own. Its asynchronous sequence of connections, its ``FieldError`` and its progress reporting already work with both. This article shows the common patterns, then what each platform needs.

### Watch for an OP-1 in SwiftUI

Iterate ``FieldDevice/connections`` in a `.task`, so watching stops when the view goes away:

```swift
import FieldTapeKit
import SwiftUI

struct DevicesView: View {
    @State private var devices: [FieldDevice] = []
    @State private var failure: FieldError?

    var body: some View {
        List(devices) { device in
            Text("OP-1, firmware \(device.info.firmware)")
        }
        .task {
            do {
                for try await event in FieldDevice.connections {
                    switch event {
                    case .connected(let device): devices.append(device)
                    case .disconnected(let id): devices.removeAll { $0.id == id }
                    case .couldNotOpen(let error): failure = error
                    }
                }
            } catch let error as FieldError {
                failure = error
            } catch {}
        }
    }
}
```

Several views can iterate the sequence at once. They share one connection to ImageCaptureCore, and each starts with every OP-1 already connected.

### Watch for an OP-1 in UIKit or AppKit

Keep the task, and cancel it when you're done:

```swift
final class DevicesViewController: UIViewController {
    private var watching: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        watching = Task { [weak self] in
            do {
                for try await event in FieldDevice.connections { self?.handle(event) }
            } catch {
                self?.show(error)   // FieldError with notAuthorized
            }
        }
    }

    deinit { watching?.cancel() }
}
```

The same works in a command-line tool or a background service.

### Show progress

Long calls take an optional `Subprogress`. Make a `ProgressManager`, hand the call a part of it, and show its `fractionCompleted`:

```swift
@State private var progress: ProgressManager?

func copyOff(_ tape: Tape, from device: FieldDevice, to folder: URL) async throws -> ReelArchive {
    let manager = ProgressManager(totalCount: 1)
    progress = manager
    defer { progress = nil }
    return try await device.copyTape(tape, to: folder, progress: manager.subprogress(assigningCount: 1))
}

// In the view:
if let progress { ProgressView(value: progress.fractionCompleted) }
```

Each call's documentation says what its units are. Progress moves file by file: a read or write of one file can't report anything until it's done, which takes up to about 7 seconds for a full track. <doc:Performance> has the figures.

### Ask before deleting

When there's no copy, deleting needs a person's confirmation. ``FieldDevice/prepareToDelete(_:)`` reads the tape fresh and returns a ``TapeDeletion`` saying what would be lost. Show it, and pass it back only if the person agrees:

```swift
@State private var deletion: TapeDeletion?

Button("Delete Tape…") {
    Task { deletion = try? await device.prepareToDelete(tape) }
}
.confirmationDialog("Delete this tape?", isPresented: .constant(deletion != nil), presenting: deletion) { deletion in
    Button("Delete \(deletion.tape.name), \(deletion.audio.formatted(.time(pattern: .minuteSecond)))",
           role: .destructive) {
        Task { try await device.deleteTape(deletion) }
    }
} message: { deletion in
    Text("\(deletion.clipCount) clips will be lost. There's no copy.")
}
```

A confirmation works once, only on the connection that made it, and only while the tape is as it was. ``TapeDeletion/losesNothing`` is true for an empty tape, where you can skip the prompt. Files and album sides work the same way, with ``FileDeletion`` and ``SideReplacement``. <doc:KeepingMusicSafe> explains why.

### Show errors

``FieldError`` is a `LocalizedError`, with a description and a recovery suggestion for each code, so SwiftUI's alerts show it as it is:

```swift
.alert(isPresented: .constant(failure != nil), error: failure) { _ in
    Button("OK") { failure = nil }
} message: { error in
    Text(error.recoverySuggestion ?? "")
}
```

When a call fails after it changed something on the OP-1, ``FieldError/changed`` lists what. <doc:HandlingErrors> covers what each code means.

### Open archives from Files and other apps

A `.reelarchive` has the type ``UniformTypeIdentifiers/UTType/reelArchive``, `com.jnjosh.fieldtapekit.reelarchive`. Every app that uses FieldTapeKit shares it. A framework can't declare a type, so declare it in your app's Info.plist under `UTImportedTypeDeclarations`, as the symbol's documentation shows. Then a document picker or `fileImporter` can ask for it:

```swift
.fileImporter(isPresented: $importing, allowedContentTypes: [.reelArchive]) { result in
    guard let url = try? result.get(), url.startAccessingSecurityScopedResource() else { return }
    defer { url.stopAccessingSecurityScopedResource() }
    archive = try? ReelArchive(contentsOf: url)
}
```

A `.reelarchive` is an Apple Archive. On a Mac, Archive Utility and the `aa` command open it. iOS has no built-in way, so an app that shares archives should also offer the tracks as WAV files, with ``ReelArchive/extractTrack(_:to:)``.

### Set up each platform

- **iOS and iPadOS:** the first use of ``FieldDevice/connections`` asks the person for access to connected devices. FieldCheck, the app that checks FieldTapeKit on real OP-1s, declares `NSCameraUsageDescription` and `NSPhotoLibraryUsageDescription`, because ImageCaptureCore treats the OP-1 as a camera. Whether either is needed isn't known yet, so declare both. The iOS simulator has no USB devices, so there ``FieldDevice/connections`` never yields anything. Use ``FieldDevice/simulated(_:)`` there.
- **macOS:** ImageCaptureCore finds the OP-1 without asking. FieldTapeKit has only been run in an app without the App Sandbox. Which entitlement a sandboxed app needs isn't known yet.
- **FieldKit on a Mac:** Teenage Engineering's FieldKit takes the OP-1 for itself, so it never appears to your app, and there's no error. Tell the person to quit FieldKit when no OP-1 appears.
- **Image Capture on a Mac:** it can hold the OP-1 at the same time as your app, and it could send requests to the OP-1 in between yours. Don't run long writes while it's open.

## See Also

- <doc:GettingStarted>
- <doc:Concurrency>
- <doc:HandlingErrors>
