import FieldTapeKit
import Foundation
import System

extension Conformance {
    // MARK: Tapes

    static let tapeChecks: [Check] = [
        Check("Tapes list every tape folder, and the slots count them") { device in
            let folders = try await device.contentsOfDirectory(at: .op1Tapes).filter(\.isDirectory).map(\.name).sorted()
            let tapes = try await device.tapes()
            try expect(tapes.map(\.name.string) == folders,
                       "tapes() listed \(tapes.map(\.name.string)), but tapes/ holds \(folders)")
            try expect(tapes.allSatisfy { $0.path == FilePath.op1Tapes.appending($0.name.string) }, "a tape's path isn't tapes/<name>")
            let slots = try await device.tapeSlots()
            try expect(slots.used == folders.count, "tapeSlots() says \(slots.used) used, for \(folders.count) folders")
            try expect(slots.used + slots.available == slots.limit, "the slots don't add up: \(slots)")
        },
        // It copies nothing, but records what it found, as the copying checks do.
        Check("A tape's details agree with its files", copying: { device, _ in
            let tapes = try await device.tapes()
            guard !tapes.isEmpty else { throw Skip(reason: "There are no tapes on the OP-1.") }
            var details: [String] = []
            for tape in tapes {
                let files = Dictionary(uniqueKeysWithValues: try await device.contentsOfDirectory(at: tape.path).map { ($0.name, $0) })
                for track in tape.tracks {
                    try expect(files["track_\(track.number).wav"]?.size == track.size, "\(track.path) isn't the size listed")
                }
                try expect(tape.recordedTracks == tape.tracks.filter { $0.size > 44 }.map(\.number),
                           "\(tape.name)'s recorded tracks don't match its track sizes")
                if let manifest = tape.manifest {
                    try expect(try await device.contents(of: tape.path.appending("tape.json")) == manifest.data,
                               "\(tape.name)'s manifest isn't tape.json as stored")
                }
                if tape.isSound {
                    try expect(tape.tracks.count == 4, "\(tape.name) is sound but doesn't have four tracks")
                    let longest = tape.tracks.map(\.duration).max() ?? .zero
                    try expect(tape.duration == longest, "\(tape.name) lasts \(tape.duration), but its longest track \(longest)")
                }
                try expect(try await device.tape(named: tape.name) == tape, "tape(named: \(tape.name)) differs from tapes()")
                let type = tape.type.map(\.description) ?? "no type"
                let tracks = tape.recordedTracks.isEmpty ? "empty" : "tracks " + tape.recordedTracks.map(String.init).joined(separator: ", ")
                let state = tape.isSound ? "" : ", not sound: " + tape.problems.joined(separator: "; ")
                details.append("\(tape.name): \(type), \(tape.duration.formatted(.time(pattern: .minuteSecond))), \(tracks)\(state)")
            }
            return details.joined(separator: ". ")
        }),
    ]
}
