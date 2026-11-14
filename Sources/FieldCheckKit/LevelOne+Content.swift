import FieldTapeKit
import Foundation

/// Level 1's checks of tapes, the album and reads. They read only, as the rest of level 1 does.
///
/// What's on an OP-1 differs from one device to the next and over time, so these never pass or fail on how many
/// tapes there are, or what's on them. Counts go in the summary, and `observed` keeps what the firmware decides.
extension LevelOne {
    static func contentChecks(catalog: Catalog, profile: FirmwareProfile) -> [Check] {
        let sampler = ReadSampler(catalog)
        return [
            Check("tape.files") { tapeFiles(try await catalog.entries().tapes(), profile: profile) },
            Check("tape.wav-format") {
                let tracks = try await catalog.entries().tapes().flatMap { tape in
                    tape.contents.filter { !$0.isFolder && $0.name.lowercased().hasPrefix("track_") }
                }
                return wavFormats(try await headers(of: tracks, in: catalog), expected: profile.trackFormat,
                                  kind: "tape tracks")
            },
            Check("tape.json-keys") { tapeJSONKeys(try await tapeJSONs(catalog), shape: profile.tapeJSON) },
            Check("tape.json-units") {
                var tapes: [TapeFiles] = []
                for tape in try await catalog.entries().tapes() {
                    guard let json = tape.contents.first(where: { $0.name.lowercased() == "tape.json" }) else { continue }
                    let sizes = Dictionary(tape.contents.map { ($0.name.lowercased(), $0.size) }, uniquingKeysWith: max)
                    tapes.append(TapeFiles(path: tape.folder.path, json: try await catalog.contents(of: json),
                                           trackSizes: sizes))
                }
                return tapeJSONUnits(tapes, profile: profile)
            },
            Check("tape.types") { tapeTypes(try await tapeJSONs(catalog), shape: profile.tapeJSON) },
            Check("album.files") { albumFiles(try await catalog.entries(), profile: profile) },
            Check("album.wav-format") {
                let sides = try await catalog.entries().children(of: "mixdown").filter { entry in
                    profile.albumFiles.required.contains(entry.name.lowercased())
                }
                return wavFormats(try await headers(of: sides, in: catalog), expected: profile.sideFormat,
                                  kind: "album sides")
            },
            Check("read.partial") {
                guard let sample = try await sampler.sample() else { return .notRun(noAudio) }
                return readPartial(sample, checks: try await partialReads(of: sample, in: catalog))
            },
            Check("read.speed") {
                guard let sample = try await sampler.sample() else { return .notRun(noAudio) }
                return readSpeed(sample)
            },
        ]
    }

    static let noAudio = "There's no tape track or album side with audio to read."
    static let noTapes = "There are no tapes on the OP-1."

    // MARK: tape.files and album.files

    /// The required files that are missing from each folder, and anything that isn't required or optional.
    static func unexpectedFiles(in folder: String, _ contents: [CatalogEntry], rule: FolderFiles)
        -> (missing: [String], unexpected: [String]) {
        let names = Set(contents.filter { !$0.isFolder }.map { $0.name.lowercased() })
        let allowed = Set(rule.required + rule.optional)
        return (rule.required.filter { !names.contains($0) }.map { "\(folder)/\($0)" },
                contents.filter { $0.isFolder || !allowed.contains($0.name.lowercased()) }
                    .map { $0.isFolder ? "\($0.path)/" : $0.path }.sorted())
    }

    static func tapeFiles(_ tapes: [(folder: CatalogEntry, contents: [CatalogEntry])], profile: FirmwareProfile) -> Finding {
        guard !tapes.isEmpty else { return .notRun(noTapes) }
        var missing: [String] = []
        var unexpected: [String] = []
        for tape in tapes {
            let found = unexpectedFiles(in: tape.folder.path, tape.contents, rule: profile.tapeFiles)
            missing += found.missing
            unexpected += found.unexpected
        }
        let observed: CheckValue = ["missing": .list(missing.map(CheckValue.string)),
                                    "unexpected": .list(unexpected.map(CheckValue.string))]
        guard missing.isEmpty, unexpected.isEmpty else {
            return .fail(problemList(missing: missing, unexpected: unexpected), observed: observed)
        }
        return .pass("All \(tapes.count) tapes hold tape.json and track_1–4.wav, and nothing else but readme.txt.",
                     observed: observed)
    }

    static func albumFiles(_ entries: [CatalogEntry], profile: FirmwareProfile) -> Finding {
        guard entries.contains(where: { $0.isFolder && $0.path.lowercased() == "mixdown" }) else {
            return .fail("There's no mixdown/ folder.")
        }
        let contents = entries.children(of: "mixdown")
        let found = unexpectedFiles(in: "mixdown", contents, rule: profile.albumFiles)
        let observed: CheckValue = ["files": .list(contents.map { $0.name.lowercased() }.sorted().map(CheckValue.string))]
        let sides = contents.filter { profile.albumFiles.required.contains($0.name.lowercased()) }.sorted { $0.name < $1.name }
        let short = sides.filter { $0.size < WAVHeader.size }.map { "\($0.path) is \($0.size) bytes, shorter than a header" }
        guard found.missing.isEmpty, found.unexpected.isEmpty, short.isEmpty else {
            let problems = [problemList(missing: found.missing, unexpected: found.unexpected)].filter { !$0.isEmpty } + short
            return .fail(problems.joined(separator: " "), observed: observed)
        }
        // Whether a side has audio is the person's, so it's only in the summary.
        let state = sides.map { "\($0.name) \($0.size == WAVHeader.size ? "is empty" : "has audio")" }
        return .pass("mixdown/ holds side_a.wav and side_b.wav, and nothing else but readme.txt: "
                     + "\(state.formatted(.list(type: .and))).", observed: observed)
    }

    private static func problemList(missing: [String], unexpected: [String]) -> String {
        var parts: [String] = []
        if !missing.isEmpty { parts.append("Missing: \(missing.joined(separator: ", ")).") }
        if !unexpected.isEmpty { parts.append("Not expected: \(unexpected.joined(separator: ", ")).") }
        return parts.joined(separator: " ")
    }

    // MARK: tape.wav-format and album.wav-format

    struct HeaderRead: Sendable {
        let path: String
        let size: Int
        let header: Result<WAVHeader, WAVHeader.Problem>
    }

    static func headers(of files: [CatalogEntry], in catalog: Catalog) async throws -> [HeaderRead] {
        var reads: [HeaderRead] = []
        for file in files.sorted(by: { $0.path < $1.path }) {
            let bytes = try await catalog.read(file, offset: 0, length: WAVHeader.size)
            let header: Result<WAVHeader, WAVHeader.Problem>
            do {
                header = .success(try WAVHeader(bytes))
            } catch {
                header = .failure(error)
            }
            reads.append(HeaderRead(path: file.path, size: file.size, header: header))
        }
        return reads
    }

    static func wavFormats(_ reads: [HeaderRead], expected: WAVFormat, kind: String) -> Finding {
        guard !reads.isEmpty else { return .notRun("There are no \(kind) to read.") }
        var formats: [WAVFormat] = []
        var problems: [String] = []
        for read in reads {
            switch read.header {
            case .failure(let problem):
                problems.append("\(read.path): \(problem)")
            case .success(let header):
                if !formats.contains(header.format) { formats.append(header.format) }
                if header.format != expected { problems.append("\(read.path) is \(header.format)") }
                problems += header.problems(fileSize: read.size).map { "\(read.path): \($0)" }
            }
        }
        let observed: CheckValue = [
            "formats": .list(formats.map { format in
                ["encoding": .int(Int(format.encoding)), "channels": .int(format.channels),
                 "sampleRate": .int(format.sampleRate), "bitsPerSample": .int(format.bitsPerSample)]
            }),
            "problems": .list(problems.map(CheckValue.string)),
        ]
        guard problems.isEmpty else {
            return .fail("\(problems.count) problems, expecting \(expected): \(problems.joined(separator: "; ")).",
                         observed: observed)
        }
        return .pass("All \(reads.count) \(kind) are \(expected), with headers that match their sizes.", observed: observed)
    }

    // MARK: tape.json-keys and tape.types

    static func tapeJSONs(_ catalog: Catalog) async throws -> [(path: String, data: Data)] {
        var files: [(path: String, data: Data)] = []
        for tape in try await catalog.entries().tapes() {
            guard let json = tape.contents.first(where: { $0.name.lowercased() == "tape.json" }) else { continue }
            files.append((json.path, try await catalog.contents(of: json)))
        }
        return files
    }

    static func tapeJSONKeys(_ files: [(path: String, data: Data)], shape: TapeJSONShape) -> Finding {
        guard !files.isEmpty else { return .notRun(noTapes) }
        var keys = Set<String>()
        var clipKeys = Set<String>()
        var versions = Set<Int>()
        var problems: [String] = []
        for file in files {
            guard let root = try? JSONSerialization.jsonObject(with: file.data) as? [String: Any] else {
                problems.append("\(file.path) isn't a JSON object")
                continue
            }
            keys.formUnion(root.keys)
            let missing = shape.keys.subtracting(root.keys).sorted()
            if !missing.isEmpty { problems.append("\(file.path) lacks \(missing.joined(separator: ", "))") }
            if let version = root["version"] as? Int {
                versions.insert(version)
                if !shape.versions.contains(version) { problems.append("\(file.path) is version \(version)") }
            }
            for clip in root["clips"] as? [[String: Any]] ?? [] {
                clipKeys.formUnion(clip.keys)
                let missing = shape.clipKeys.subtracting(clip.keys).sorted()
                if !missing.isEmpty { problems.append("a clip in \(file.path) lacks \(missing.joined(separator: ", "))") }
            }
        }
        var fields: [String: CheckValue] = ["keys": .list(keys.sorted().map(CheckValue.string)),
                                            "versions": .list(versions.sorted().map(CheckValue.int))]
        // With only blank tapes there are no clips, and so no clip keys to observe. Leaving the field out, rather
        // than recording an empty list, keeps that from looking like a change.
        if !clipKeys.isEmpty { fields["clipKeys"] = .list(clipKeys.sorted().map(CheckValue.string)) }
        let observed = CheckValue.record(fields)
        guard problems.isEmpty else {
            return .fail("\(problems.joined(separator: "; ")).", observed: observed)
        }
        let unknown = keys.subtracting(shape.keys).sorted() + clipKeys.subtracting(shape.clipKeys).sorted().map { "clips.\($0)" }
        let note = unknown.isEmpty ? "" : " Unknown keys, which FieldTapeKit keeps as they are: \(unknown.joined(separator: ", "))."
        return .pass("All \(files.count) tape.json files have every known key, at version "
                     + "\(versions.sorted().map(String.init).joined(separator: ", ")).\(note)", observed: observed)
    }

    static func tapeTypes(_ files: [(path: String, data: Data)], shape: TapeJSONShape) -> Finding {
        guard !files.isEmpty else { return .notRun(noTapes) }
        var seen = Set<Int>()
        for file in files {
            guard let root = try? JSONSerialization.jsonObject(with: file.data) as? [String: Any],
                  let type = root["tape_type"] as? Int else { continue }
            seen.insert(type)
        }
        let outside = seen.filter { !shape.tapeTypes.contains($0) }.sorted()
        // Which types are in use depends on the person's tapes, so only the ones outside the range are observed.
        let observed: CheckValue = ["outsideRange": .list(outside.map(CheckValue.int))]
        let range = "\(shape.tapeTypes.lowerBound)–\(shape.tapeTypes.upperBound)"
        guard outside.isEmpty else {
            return .fail("tape_type \(outside.map(String.init).joined(separator: ", ")) is outside \(range).", observed: observed)
        }
        return .pass("Every tape_type is \(range). Seen: \(seen.sorted().map(String.init).joined(separator: ", ")).",
                     observed: observed)
    }

    // MARK: tape.json-units

    struct TapeFiles: Sendable {
        let path: String
        let json: Data
        let trackSizes: [String: Int]
    }

    static func tapeJSONUnits(_ tapes: [TapeFiles], profile: FirmwareProfile) -> Finding {
        guard !tapes.isEmpty else { return .notRun(noTapes) }
        let problems = tapes.flatMap { tape in
            TapeConsistency.problems(json: tape.json, trackSizes: tape.trackSizes, profile: profile).map { "\(tape.path): \($0)" }
        }
        let observed: CheckValue = ["problems": .list(problems.map(CheckValue.string))]
        guard problems.isEmpty else {
            return .fail("\(problems.joined(separator: "; ")).", observed: observed)
        }
        return .pass("Every track of all \(tapes.count) tapes is 44 + 8 × the end of its last clip, with 0-based ch.",
                     observed: observed)
    }
}
