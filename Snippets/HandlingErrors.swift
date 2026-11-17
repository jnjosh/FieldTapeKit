// Tells a failure that changed the OP-1 from one that didn't, and matches error codes, as Handling Errors shows.
// It restores a tape onto the simulated OP-1, where the name is free, so it succeeds.
import FieldTapeKit
import Foundation

// snippet.hide
func show(_ message: String) { print(message) }
func offerToMoveATapeOff() { print("Move a tape off first.") }
func showReconnectPrompt() { print("Connect the OP-1 again.") }

let device = FieldDevice.simulated { SimulatedTape("2026-220#01", seconds: [3]) }
let folder = URL.temporaryDirectory.appending(path: "HandlingErrors \(UUID().uuidString)")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let archive = try await device.copyTape(try await device.tapes()[0], to: folder)
let backup = folder.appending(path: "before restore.reelarchive")
// snippet.show

// snippet.changed
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
// snippet.end

// snippet.codes
do {
    _ = try await device.createTape(named: TapeName("new tape"))
} catch let error as FieldError {
    switch error.code {
    case .tapeLimitReached: offerToMoveATapeOff()
    case .disconnected: showReconnectPrompt()
    default: show(error.localizedDescription)
    }
}
// snippet.end
