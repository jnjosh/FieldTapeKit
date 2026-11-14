import Foundation
import System

/// What FieldTapeKit lets the file layer write, checked before anything is sent (ADR 0002, safety rules 3 and 4).
///
/// The rules come from the OP-1's `readme.txt` files and the firmware profile: a tape folder holds `tape.json` and
/// `track_1`–`4.wav`, `mixdown/` holds `side_a.wav` and `side_b.wav`, and new folders are tapes. Audio must be in
/// the format the OP-1 writes itself, because what it does with anything else is unknown (`album.write-other-format`).
/// Preset folders come in step 9b of the plan.
struct WriteRules {
    let profile: FirmwareProfile

    /// Characters a new tape's name may use, lowercased (ADR 0002, section 4).
    static let tapeNameCharacters = Set("abcdefghijklmnopqrstuvwxyz0123456789#- ")
    /// FieldTapeKit's own limit for a new tape's name, so it stays readable on the OP-1's screen.
    static let tapeNameMaximumLength = 15

    /// Checks a new file. `names` is the path's lowercased names, relative to the root.
    func checkFile(_ names: [String], data: Data, path: FilePath) throws {
        switch names.count {
        case 3 where names[0] == "tapes":
            let name = names[2]
            guard profile.tapeFiles.required.contains(name) else {
                throw FieldError(.notAllowed, path: path, reason: "a tape holds only tape.json and track_1.wav to track_4.wav")
            }
            if name == "tape.json" {
                guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                    throw FieldError(.notAllowed, path: path, reason: "it isn't a JSON object")
                }
            } else {
                let header = try checkWAV(data, format: profile.trackFormat, kind: "a tape track", path: path)
                if header.dataSize / profile.trackFormat.frameBytes > profile.maximumTapeFrames {
                    throw FieldError(.tapeTooLong, path: path)
                }
            }
        case 2 where names[0] == "mixdown":
            guard profile.albumFiles.required.contains(names[1]) else {
                throw FieldError(.notAllowed, path: path, reason: "mixdown holds only side_a.wav and side_b.wav")
            }
            _ = try checkWAV(data, format: profile.sideFormat, kind: "an album side", path: path)
        case 3 where (names[0] == "synth" || names[0] == "drum") && names[1] == "user":
            throw FieldError(.notAllowed, path: path, reason: "writing presets isn't supported yet")
        default:
            throw FieldError(.notAllowed, path: path, reason: "FieldTapeKit writes only tape files and album sides")
        }
    }

    /// Checks a new folder, which can only be a tape, and its name.
    func checkFolder(_ names: [String], path: FilePath) throws {
        guard names.count == 2, names[0] == "tapes" else {
            throw FieldError(.notAllowed, path: path, reason: "FieldTapeKit makes folders only for tapes")
        }
        let name = names[1]
        let unexpected = name.filter { !Self.tapeNameCharacters.contains($0) }
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            throw FieldError(.invalidName, path: path, reason: "it's empty")
        }
        if !unexpected.isEmpty {
            let listed = Array(Set(unexpected)).sorted().map { "“\($0)”" }.joined(separator: ", ")
            throw FieldError(.invalidName, path: path, reason: "it uses \(listed)")
        }
        if name.count > Self.tapeNameMaximumLength {
            throw FieldError(.invalidName, path: path, reason: "it's longer than \(Self.tapeNameMaximumLength) characters")
        }
    }

    private func checkWAV(_ data: Data, format: WAVFormat, kind: String, path: FilePath) throws -> WAVHeader {
        let header: WAVHeader
        do {
            header = try WAVHeader(data)
        } catch {
            throw FieldError(.notAllowed, path: path, reason: "it isn't a WAV file the OP-1 writes: \(error)")
        }
        guard header.format == format else {
            throw FieldError(.notAllowed, path: path, reason: "\(kind) must be \(format), not \(header.format)")
        }
        if let problem = header.problems(fileSize: data.count).first {
            throw FieldError(.notAllowed, path: path, reason: "its WAV header doesn't match its size: \(problem)")
        }
        return header
    }

    /// The format code to send a file as: what the OP-1 reports for the same name.
    static func format(of name: String) -> UInt16 {
        SimulatedNode.format(of: name)
    }
}
