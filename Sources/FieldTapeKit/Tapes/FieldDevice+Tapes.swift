import Foundation
import System

extension FieldDevice {
    /// Lists every tape on the OP-1, read fresh: each folder in `tapes/`, its files, and its `tape.json`.
    ///
    /// A tape that isn't sound is listed too, with its ``Tape/problems``, so every slot shows. This reads one small
    /// `tape.json` per tape and lists each folder, so it takes a request or two per tape.
    ///
    /// - Returns: Every tape, sorted by name.
    /// - Throws: `FieldError` with `.disconnected`, `.timedOut` or `.deviceRefused`, or `CancellationError`.
    public func tapes() async throws -> [Tape] {
        do {
            var tapes: [Tape] = []
            for folder in try await contentsOfDirectory(at: .op1Tapes) where folder.isDirectory {
                try Task.checkCancellation()
                tapes.append(try await tape(in: folder))
            }
            return tapes.sorted { $0.name < $1.name }
        } catch {
            throw FieldError.wrapping(error, path: .op1Tapes)
        }
    }

    /// Reads one tape fresh, by name.
    ///
    /// - Parameter name: The tape's name, matched ignoring case.
    /// - Returns: The tape, or nil if there isn't one with that name.
    /// - Throws: As ``tapes()``.
    public func tape(named name: TapeName) async throws -> Tape? {
        let path = FilePath.op1Tapes.appending(name.string)
        do {
            guard let folder = try await item(at: path), folder.isDirectory else { return nil }
            return try await tape(in: folder)
        } catch {
            throw FieldError.wrapping(error, path: path)
        }
    }

    /// Counts the tape slots in use, from a fresh listing of `tapes/`.
    ///
    /// Every folder there takes a slot, sound or not.
    ///
    /// - Returns: The slots used, and the firmware's limit.
    /// - Throws: As ``tapes()``.
    public func tapeSlots() async throws -> TapeSlots {
        do {
            let used = try await contentsOfDirectory(at: .op1Tapes).filter(\.isDirectory).count
            return TapeSlots(used: used, limit: profile.maximumTapes)
        } catch {
            throw FieldError.wrapping(error, path: .op1Tapes)
        }
    }

    /// Reads one tape folder: its files, then its `tape.json`, and checks them against each other.
    private func tape(in folder: FieldItem) async throws -> Tape {
        let files = try await contentsOfDirectory(at: folder.path)
        let byName = Dictionary(files.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var problems: [String] = []

        let required = profile.tapeFiles.required
        let missing = required.filter { byName[$0] == nil }
        if !missing.isEmpty { problems.append("missing " + missing.joined(separator: ", ")) }
        let unexpected = files.map(\.name).filter { !required.contains($0) && !profile.tapeFiles.optional.contains($0) }.sorted()
        if !unexpected.isEmpty { problems.append("unexpected " + unexpected.joined(separator: ", ")) }

        let tracks = (1...4).compactMap { number -> TapeTrack? in
            guard let file = byName["track_\(number).wav"], !file.isDirectory else { return nil }
            return TapeTrack(number: number, path: file.path, size: file.size)
        }

        var manifest: TapeManifest?
        if let json = byName["tape.json"], !json.isDirectory {
            let data = try await contents(of: json.path)
            do {
                manifest = try TapeManifest(data)
            } catch {
                problems.append(error.description)
            }
            if manifest != nil, missing.isEmpty {
                let sizes = Dictionary(uniqueKeysWithValues: tracks.map { ("track_\($0.number).wav", $0.size) })
                problems += TapeConsistency.problems(json: data, trackSizes: sizes, profile: profile)
            }
        }
        return Tape(name: TapeName(listed: folder.name), path: folder.path, tracks: tracks, manifest: manifest,
                    problems: problems)
    }
}
