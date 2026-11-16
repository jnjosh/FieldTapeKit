import CryptoKit
import FieldTapeKit
import Foundation
import System

extension Conformance {
    // MARK: Reading and copying

    static let readingChecks: [Check] = [
        Check("A whole read matches a range read of the same file") { device in
            let path: FilePath = "mixdown/readme.txt"
            let item = try await device.item(at: path)
            let whole = try await device.contents(of: path)
            try expect(whole.count == item?.size, "\(path) read \(whole.count) bytes, but lists \(item?.size ?? 0)")
            let ranged = try await device.contents(of: path, range: 0..<whole.count)
            try expect(ranged == whole, "\(path) read differently whole and as a range")
        },
        Check("A range past the end gives what's there") { device in
            let path: FilePath = "mixdown/readme.txt"
            let whole = try await device.contents(of: path)
            let end = whole.count
            let tail = try await device.contents(of: path, range: (end - 5)..<(end + 100))
            try expect(tail == whole.suffix(5), "a range past the end of \(path) gave \(tail.count) bytes, not its last 5")
            let after = try await device.contents(of: path, range: end..<(end + 5))
            try expect(after.isEmpty, "a range from the end of \(path) gave \(after.count) bytes")
        },
        Check("Reads refuse a file over the limit, and a folder") { device in
            let side: FilePath = "mixdown/side_a.wav"
            try await expectError(.tooLarge, path: side) { _ = try await device.contents(of: side, maximumSize: 43) }
            try await expectError(.isADirectory, path: .op1Tapes) { _ = try await device.contents(of: .op1Tapes) }
        },
        Check("Copying album side A off matches the OP-1", copying: { device, workspace in
            try await copyAndCompare("mixdown/side_a.wav", from: device, to: workspace.appending(path: "side_a.wav"))
        }),
        Check("Copying the album off makes WAVs that match the OP-1, and each matches its side", copying: { device, workspace in
            let album = try await device.album()
            let recorded = album.sides.filter { !$0.isEmpty }
            guard !recorded.isEmpty else { throw Skip(reason: "Both album sides are empty.") }
            for side in recorded { try expect(side.isSound, "\(side.path) isn't sound: \(side.problems.joined(separator: "; "))") }
            for side in album.sides where side.isEmpty {
                try await expectError(.notFound, path: side.path) { _ = try await device.copySide(side.side, to: workspace) }
            }

            let copies = try await device.copyAlbum(to: workspace)
            defer { for copy in copies { try? FileManager.default.removeItem(at: copy.url) } }
            try expect(copies.map(\.side) == recorded.map(\.side),
                       "copied \(copies.map(\.side.description)), not the sides with audio, \(recorded.map(\.side.description))")
            var details: [String] = []
            for (side, copy) in zip(recorded, copies) {
                let data = try Data(contentsOf: copy.url)
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                try expect(data.count == side.size && copy.size == side.size,
                           "the copy of \(side.path) is \(data.count) bytes, but it lists \(side.size)")
                try expect(digest == copy.sha256, "the copy of \(side.path) doesn't hold the SHA-256 it records")
                let header = try await device.contents(of: side.path, range: 0..<44)
                try expect(data.prefix(44) == header, "the copy of \(side.path) starts differently from the OP-1's")
                try expect(try await device.side(side.side, matches: copy), "\(side.path) doesn't match its own copy")
                details.append("\(side.side) \(side.size) bytes, \(side.duration.formatted(.units(allowed: [.minutes, .seconds], width: .narrow))), SHA-256 \(digest)")
            }
            return details.joined(separator: "; ")
        }),
        Check("Copying the largest tape track off matches the OP-1", copying: { device, workspace in
            var largest: FieldItem?
            for tape in try await device.contentsOfDirectory(at: .op1Tapes) where tape.isDirectory {
                for track in try await device.contentsOfDirectory(at: tape.path)
                where track.name.hasPrefix("track_") && track.size > 44 && track.size > (largest?.size ?? 0) {
                    largest = track
                }
            }
            guard let track = largest else { throw Skip(reason: "There's no tape track with audio on the OP-1.") }
            // The tape's name keeps tracks from different tapes apart.
            let tapeName = track.path.removingLastComponent().lastComponent?.string ?? "tape"
            return try await copyAndCompare(track.path, from: device,
                                            to: workspace.appending(path: "\(tapeName) \(track.name)"))
        }),
    ]

    /// Copies `path` off twice, and checks both copies against the listing, against a header read straight from the
    /// OP-1, and against each other. The first copy is kept, and the second, made under a numbered name because
    /// the first took the name, is deleted.
    static func copyAndCompare(_ path: FilePath, from device: FieldDevice, to destination: URL) async throws -> String {
        guard let item = try await device.item(at: path) else { throw Skip(reason: "There's no \(path) on the OP-1.") }
        let first = try await device.copyItem(at: path, to: destination)
        let copy = try Data(contentsOf: first)
        try expect(copy.count == item.size, "the copy of \(path) is \(copy.count) bytes, but it lists \(item.size)")
        let header = try await device.contents(of: path, range: 0..<44)
        try expect(copy.prefix(44) == header, "the copy of \(path) starts differently from the OP-1's")
        try expect(header.prefix(4) == Data("RIFF".utf8) && header.dropFirst(8).prefix(4) == Data("WAVE".utf8),
                   "\(path) isn't a WAV file")

        let second = try await device.copyItem(at: path, to: destination)
        defer { try? FileManager.default.removeItem(at: second) }
        try expect(second != first, "a second copy of \(path) overwrote the first")
        try expect(try Data(contentsOf: second) == copy, "two copies of \(path) differ")

        let digest = SHA256.hash(data: copy).map { String(format: "%02x", $0) }.joined()
        return "\(path): \(copy.count) bytes, SHA-256 \(digest), copied to \(first.lastPathComponent)"
    }
}
