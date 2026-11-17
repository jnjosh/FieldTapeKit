// Copies two tapes off with one progress, as Concurrency shows, against the simulated OP-1.
import FieldTapeKit
import Foundation

// snippet.hide
let device = FieldDevice.simulated {
    SimulatedTape("2026-220#01", seconds: [3])
    SimulatedTape("2026-276#01", seconds: [3])
}
let tapes = try await device.tapes()
let folder = URL.temporaryDirectory.appending(path: "Progress \(UUID().uuidString)")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
// snippet.show

// snippet.two
let manager = ProgressManager(totalCount: 2)
let first = try await device.copyTape(tapes[0], to: folder, progress: manager.subprogress(assigningCount: 1))
let second = try await device.copyTape(tapes[1], to: folder, progress: manager.subprogress(assigningCount: 1))
// snippet.end
print(manager.fractionCompleted, first.name, second.name)
