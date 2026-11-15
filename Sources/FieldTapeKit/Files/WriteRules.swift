import Foundation
import System

/// What FieldTapeKit lets the file layer write, checked before anything is sent (ADR 0002, safety rules 3 and 4).
///
/// The rules come from the OP-1's `readme.txt` files and the firmware profile: a tape folder holds `tape.json` and
/// `track_1`–`4.wav`, `mixdown/` holds `side_a.wav` and `side_b.wav`, and new folders are tapes. Audio must be in
/// the format the OP-1 writes itself, because what it does with anything else is unknown (`album.write-other-format`).
/// A preset must be audio in a format the OP-1 has been seen to keep sample for sample (`write.preset-converted`).
struct WriteRules {
    let profile: FirmwareProfile

    /// How a write is checked once it's stored.
    enum ReadBack {
        /// Byte for byte, by SHA-256 (`write.exact`).
        case exact
        /// As audio: the OP-1 converts a preset, so what it stores must be the start of what was sent, sample for
        /// sample (`write.preset-converted`).
        case preset(PCMAudio)
    }

    /// Checks a new file, and says how to check it once it's stored. `names` is the path's lowercased names,
    /// relative to the root.
    @discardableResult
    func checkFile(_ names: [String], data: Data, path: FilePath) throws -> ReadBack {
        if names.count == 3, profile.presetFolders.contains(names[0...1].joined(separator: "/")) {
            return .preset(try checkPreset(names[2], data: data, path: path))
        }
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
        default:
            throw FieldError(.notAllowed, path: path, reason: "FieldTapeKit writes only tape files, album sides and presets")
        }
        return .exact
    }

    private func checkPreset(_ name: String, data: Data, path: FilePath) throws -> PCMAudio {
        let base = (name as NSString).deletingPathExtension
        guard profile.presetExtensions.contains((name as NSString).pathExtension),
              !base.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw FieldError(.notAllowed, path: path, reason: "a preset's name ends in .aif, .aiff, .aifc or .wav")
        }
        let audio: PCMAudio
        do {
            audio = try PCMAudio(data)
        } catch {
            throw FieldError(.notAllowed, path: path, reason: "it isn't audio the OP-1 takes as a preset: \(error)")
        }
        guard profile.presetFormats.contains(audio.format) else {
            let formats = profile.presetFormats.map(\.description).joined(separator: "; ")
            throw FieldError(.notAllowed, path: path, reason: "a preset must be \(formats), not \(audio.format)")
        }
        guard audio.frames > 0 else { throw FieldError(.notAllowed, path: path, reason: "it has no audio") }
        return audio
    }

    /// Checks a new folder, which can only be a tape, and its name.
    func checkFolder(_ names: [String], path: FilePath) throws {
        guard names.count == 2, names[0] == "tapes" else {
            throw FieldError(.notAllowed, path: path, reason: "FieldTapeKit makes folders only for tapes")
        }
        if let problem = TapeName.problem(with: names[1], maximumLength: profile.maximumTapeNameLength) {
            throw FieldError(.invalidName, path: path, reason: problem)
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
