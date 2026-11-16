import CryptoKit
import FieldTapeKit
import Foundation
import System

extension Conformance {
    /// The tape the writing checks make and delete. It's FieldTapeKit's own name, never level 2's scratch tape, so
    /// a level 3 waiting on the OP-1 isn't touched.
    public static let scratchTape = "conformance"

    /// Checks that write to the OP-1, so an app asks before running them. Each makes the scratch tape in a free
    /// slot, checks it, and deletes it, so nothing is left behind. The person's own tapes are only read. The restore
    /// check copies a tape into the workspace first, and deletes that archive when it's done.
    public static let writingChecks: [Check] = [
        Check("Creating a tape makes an empty, sound tape, and deleting it frees its slot", copying: { device, _ in
            let name = try TapeName(scratchTape)
            let before = try await scratchSlot(on: device, name)
            return try await withScratch(on: device, slotsBefore: before, make: { try await device.createTape(named: name) }) { tape in
                try expect(tape.path == FilePath.op1Tapes.appending(scratchTape), "the tape is at \(tape.path)")
                try expect(tape.isSound, "the new tape isn't sound: " + tape.problems.joined(separator: "; "))
                try expect(tape.isEmpty && tape.type == .studio, "the new tape isn't an empty Studio tape")
                try expect(tape.tracks.map(\.size) == [44, 44, 44, 44], "the tracks are \(tape.tracks.map(\.size)) bytes, not 44 each")
                try expect(tape.manifest?.clips.isEmpty == true && tape.manifest?.loop.isOn == false, "tape.json has clips or a loop")
                try expect(try await device.tape(named: TapeName(scratchTape.uppercased())) == tape,
                           "looking it up in capitals didn't find the same tape")
                try expect(try await device.tapeSlots().used == before.used + 1, "it doesn't take a slot")
                return "\(tape.path): \(tape.type?.description ?? "no type"), 4 blank tracks, tape.json \(tape.manifest?.data.count ?? 0) bytes"
            }
        }),
        Check("Duplicating the smallest tape makes a copy that matches it", copying: { device, _ in
            let name = try TapeName(scratchTape)
            let source = try await smallestTape(on: device)
            let before = try await scratchSlot(on: device, name)
            return try await withScratch(on: device, slotsBefore: before, make: { try await device.duplicateTape(source, as: name) }) { copy in
                try expect(copy.isSound, "the copy isn't sound: " + copy.problems.joined(separator: "; "))
                try expect(copy.manifest?.data == source.manifest?.data, "the copy's tape.json isn't the source's")
                try expect(copy.tracks.map(\.size) == source.tracks.map(\.size), "the copy's tracks aren't the source's sizes")
                var digests: [String] = []
                for (original, copied) in zip(source.tracks, copy.tracks) {
                    let a = SHA256.hash(data: try await device.contents(of: original.path, maximumSize: 1 << 30))
                    let b = SHA256.hash(data: try await device.contents(of: copied.path, maximumSize: 1 << 30))
                    try expect(a == b, "track_\(original.number) of the copy doesn't match the source")
                    digests.append("track_\(original.number) \(a.map { String(format: "%02x", $0) }.joined())")
                }
                try expect(try await device.tape(named: source.name) == source, "\(source.name) changed on the OP-1")
                return "\(source.name) to \(copy.name), \(size(source)) bytes. " + digests.joined(separator: ", ")
            }
        }),
        Check("Restoring an archive of the smallest tape makes a tape that matches the archive", copying: { device, workspace in
            let name = try TapeName(scratchTape)
            let source = try await smallestTape(on: device)
            let before = try await scratchSlot(on: device, name)
            let archive = try await device.copyTape(source, to: workspace)
            defer { try? FileManager.default.removeItem(at: archive.url) }
            return try await withScratch(on: device, slotsBefore: before, make: { try await device.restoreTape(from: archive, as: name) }) { tape in
                try expect(tape.isSound, "the restored tape isn't sound: " + tape.problems.joined(separator: "; "))
                try expect(tape.manifest?.data == archive.manifest.data, "the restored tape.json isn't the archive's")
                try expect(tape.tracks.map(\.size) == archive.tracks.map(\.size), "the restored tracks aren't the archive's sizes")
                for (restored, archived) in zip(tape.tracks, archive.tracks) {
                    let digest = SHA256.hash(data: try await device.contents(of: restored.path, maximumSize: 1 << 30))
                    try expect(digest.map { String(format: "%02x", $0) }.joined() == archived.sha256,
                               "track_\(archived.number) on the OP-1 doesn't match the archive")
                }
                try expect(try await device.tape(named: source.name) == source, "\(source.name) changed on the OP-1")
                let tracks = archive.tracks.map { "track_\($0.number) \($0.sha256)" }.joined(separator: ", ")
                return "\(archive.url.lastPathComponent) to \(tape.path). \(tracks)"
            }
        }),
    ]

    private static func size(_ tape: Tape) -> Int { tape.tracks.reduce(0) { $0 + $1.size } }

    /// The smallest sound tape with audio, so a track's bytes are compared, or else any sound tape.
    private static func smallestTape(on device: FieldDevice) async throws -> Tape {
        let sound = try await device.tapes().filter(\.isSound)
        guard let source = sound.filter({ !$0.isEmpty }).min(by: { size($0) < size($1) }) ?? sound.first else {
            throw Skip(reason: "There's no sound tape on the OP-1.")
        }
        return source
    }

    /// The slots before the scratch tape is made. Skips if there's no free slot, or the scratch tape is already
    /// there from a run that didn't finish, which this never deletes.
    private static func scratchSlot(on device: FieldDevice, _ name: TapeName) async throws -> TapeSlots {
        if try await device.tape(named: name) != nil {
            throw Skip(reason: "\(FilePath.op1Tapes.appending(name.string)) is already on the OP-1, from a run that didn't "
                + "finish. Delete it on the OP-1 first.")
        }
        let slots = try await device.tapeSlots()
        if slots.available == 0 { throw Skip(reason: "All \(slots.limit) tape slots are used, and this needs one.") }
        return slots
    }

    /// Makes the scratch tape, runs `body` on it, and deletes it whatever `body` found. Making it either succeeds
    /// or leaves nothing, as FieldTapeKit removes a half-made tape itself.
    private static func withScratch(on device: FieldDevice, slotsBefore: TapeSlots, make: () async throws -> Tape,
                                    _ body: (Tape) async throws -> String) async throws -> String {
        let tape = try await make()
        let outcome: Swift.Result<String, any Error>
        do {
            outcome = .success(try await body(tape))
        } catch {
            outcome = .failure(error)
        }
        let deletion = try await device.prepareToRemove(at: tape.path)
        try await device.removeItem(deletion)
        let detail = try outcome.get()
        try expect(try await device.tape(named: tape.name) == nil, "\(tape.path) is still there after it was deleted")
        try expect(try await device.tapeSlots().used == slotsBefore.used, "deleting it didn't free its slot")
        return detail
    }
}
