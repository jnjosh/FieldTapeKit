// Copies every tape off an OP-1 into .reelarchive files, then restores one, as Getting Started shows.
// It runs against the simulated OP-1, so `swift run CopyingTapes` works without one.
import FieldTapeKit
import Foundation

// snippet.hide
let device = FieldDevice.simulated {
    SimulatedTape("2026-220#01", type: .vintage, seconds: [12, 0, 4.5])
    SimulatedTape("2026-276#01", seconds: [3, 3, 3, 3])
}
let folder = URL.temporaryDirectory.appending(path: "CopyingTapes \(UUID().uuidString)")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
// snippet.show

// snippet.list
let tapes = try await device.tapes()
for tape in tapes {
    print(tape.name, tape.type?.description ?? "unknown type", tape.duration, tape.recordedTracks)
}
let slots = try await device.tapeSlots()
print("\(slots.used) of \(slots.limit) tape slots used")
// snippet.end

// snippet.copy
for tape in tapes where tape.isSound && !tape.isEmpty {
    let archive = try await device.copyTape(tape, to: folder)
    print("Saved \(archive.url.lastPathComponent)")
}
// snippet.end

// snippet.restore
let url = folder.appending(path: "2026-220#01.reelarchive")
let archive = try ReelArchive(contentsOf: url)

// Archive the tape that's there first, to exactly this URL, then replace it.
let backup = folder.appending(path: "\(archive.name) before restore.reelarchive")
let replaced = try await device.restoreTape(from: archive, conflict: .replace(archivingExistingTo: backup))

// Or restore it under another name, as a new tape.
let copy = try await device.restoreTape(from: archive, as: TapeName("2026-220#05"))
// snippet.end
print("Restored \(replaced.name) and \(copy.name)")
