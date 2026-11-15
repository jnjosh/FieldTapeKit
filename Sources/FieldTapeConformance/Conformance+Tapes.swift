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
        Check("Copying the largest tape off makes an archive that matches the OP-1", copying: { device, workspace in
            let sound = try await device.tapes().filter(\.isSound)
            guard let largest = sound.max(by: { $0.tracks.reduce(0) { $0 + $1.size } < $1.tracks.reduce(0) { $0 + $1.size } }) else {
                throw Skip(reason: "There's no sound tape on the OP-1.")
            }
            let archive = try await device.copyTape(largest, to: workspace)
            try expect(archive.name == largest.name, "the archive is named \(archive.name), not \(largest.name)")
            try expect(archive.tracks.map(\.size) == largest.tracks.map(\.size), "the archive's tracks aren't the tape's sizes")
            try expect(archive.manifest.data == largest.manifest?.data, "the archive's tape.json isn't the tape's")
            try expect(try await device.tape(named: largest.name) == largest, "\(largest.name) changed on the OP-1")
            let bytes = (try FileManager.default.attributesOfItem(atPath: archive.url.path)[.size] as? Int) ?? 0
            let tracks = archive.tracks.map { "track_\($0.number) \($0.sha256)" }.joined(separator: ", ")
            return "\(archive.url.lastPathComponent): \(bytes) bytes. \(tracks)"
        }),
    ]
}
