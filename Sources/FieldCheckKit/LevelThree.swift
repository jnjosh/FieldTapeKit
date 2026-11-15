import FieldTapeKit
import Foundation
import System

/// FieldCheck's level 3: what the OP-1 does with level 2's scratch tape once it has left MTP mode and come back
/// (ADR 0003, section 2).
///
/// A clean level 2 run leaves a `Pending` level 3, which the app saves so it survives a relaunch. After the person
/// leaves MTP mode on the OP-1 and enters it again, level 3 reads the scratch tape: its handles, its name, the
/// `readme.txt` the OP-1 adds, and whether the tracks and `tape.json` were kept, and that the 13-character tape's
/// name was cut to 12. Then it deletes the scratch tape with one DeleteObject on its folder, to see what that does,
/// and deletes what's left, files first and then the folder, as FieldTapeKit does. It stops at the first failure
/// and leaves the tapes for cleanup.
public enum LevelThree {
    /// What level 2 left for level 3 to check, saved between app launches.
    public struct Pending: Sendable, Hashable, Codable {
        public let serialNumber: String
        public let levelTwoStarted: Date
        /// The scratch tape's handles in level 2's connection, by path: the folder and each file (`reconnect.handles`).
        let handles: [String: UInt32]
        /// The connection level 2 ran on, while the app is still running. It isn't saved, because after a relaunch
        /// every connection is a new one.
        public var connection: FieldDevice.ID?

        private enum CodingKeys: String, CodingKey {
            case serialNumber, levelTwoStarted, handles
        }

        public func jsonData() throws -> Data {
            try ReportFiles.encoder().encode(self)
        }

        public init(json: Data) throws {
            self = try ReportFiles.decoder().decode(Self.self, from: json)
        }

        init(serialNumber: String, levelTwoStarted: Date, handles: [String: UInt32], connection: FieldDevice.ID?) {
            self.serialNumber = serialNumber
            self.levelTwoStarted = levelTwoStarted
            self.handles = handles
            self.connection = connection
        }
    }

    /// Why level 3 can't run on a connection.
    public enum Refusal: Sendable, Hashable, CustomStringConvertible {
        case anotherOP1(waitingFor: String, connected: String)
        /// The OP-1 hasn't left MTP mode since level 2.
        case sameConnection
        /// The scratch tape isn't there, so there's nothing to check. `tapes` is what `tapes/` holds instead.
        case tapeGone(tapes: [String])
        case couldntLook(String)

        public var description: String {
            switch self {
            case .anotherOP1(let waiting, let connected):
                "Level 3 is waiting for the OP-1 with serial \(waiting), not \(connected)."
            case .sameConnection:
                "The OP-1 hasn't left MTP mode since level 2. Leave MTP mode on the OP-1, then enter it again."
            case .tapeGone(let tapes):
                "The scratch tape \(LevelTwo.scratchTape.lastComponent!.string) isn't on the OP-1 any more, so there's "
                    + "nothing for level 3 to check. tapes/ holds: "
                    + (tapes.isEmpty ? "nothing." : tapes.joined(separator: ", ") + ".")
            case .couldntLook(let reason):
                "Couldn't look at the OP-1: \(reason)"
            }
        }

        /// Whether level 3 can never run on this OP-1 now, so it's no longer waiting. A wrong OP-1 or connection
        /// can be put right, and the pending level 3 is kept for it.
        public var endsLevelThree: Bool {
            if case .tapeGone = self { true } else { false }
        }
    }

    /// What level 3 will do, for a person to confirm before it starts.
    public static let steps = [
        "Read the scratch tape \(LevelTwo.scratchTape.lastComponent!.string): its handles, its name, its files, and its tracks and tape.json, which should be as level 2 left them.",
        "Look for \(LevelTwo.longTapeCut.lastComponent!.string), the 13-character tape cut to 12.",
        "Delete the scratch tape with one DeleteObject on its folder, with its files still in it, to see what the OP-1 does.",
        "Delete what's left of both tapes, files first and then each folder.",
    ]

    /// The level 3 that `levelTwo` leaves, or nil if it doesn't leave one: only a level 2 run with no failures
    /// does, and only while its scratch tape is on the OP-1. It only reads.
    public static func pending(after levelTwo: CheckReport, on device: FieldDevice) async -> Pending? {
        guard levelTwo.level == 2, !levelTwo.results.contains(where: { $0.outcome == .fail }),
              levelTwo.results.contains(where: { $0.expectation == "rebuild.stale-size" && $0.outcome == .pass }) else {
            return nil
        }
        do {
            guard let folder = try await device.locate(LevelTwo.scratchTape) else { return nil }
            var handles = [folder.path.string: folder.handle]
            for item in try await device.contentsOfDirectory(at: folder.path) {
                if let file = try await device.locate(item.path) { handles[file.path.string] = file.handle }
            }
            return Pending(serialNumber: device.info.serialNumber, levelTwoStarted: levelTwo.started, handles: handles,
                           connection: device.id)
        } catch {
            return nil
        }
    }

    /// Why level 3 can't run on this connection, or nil if it can. It only reads.
    public static func refusal(on device: FieldDevice, pending: Pending) async -> Refusal? {
        if device.info.serialNumber != pending.serialNumber {
            return .anotherOP1(waitingFor: pending.serialNumber, connected: device.info.serialNumber)
        }
        if pending.connection == device.id { return .sameConnection }
        do {
            guard try await device.fileExists(at: LevelTwo.scratchTape) else {
                return .tapeGone(tapes: try await device.contentsOfDirectory(at: .op1Tapes).filter(\.isDirectory).map(\.name).sorted())
            }
        } catch {
            return .couldntLook(error.localizedDescription)
        }
        return nil
    }

    /// Runs level 3. If it can't run on this connection, every check is reported as not run, with the reason.
    public static func run(on device: FieldDevice, pending: Pending, host: CheckReport.Host) async -> CheckReport {
        let started = Date.now
        let checks = checks(for: device, pending: pending)
        let results: [CheckResult]
        if let refusal = await refusal(on: device, pending: pending) {
            results = checks.map { CheckResult(expectation: $0.expectation, outcome: .notRun, summary: refusal.description) }
        } else {
            results = await CheckRunner.run(checks, stopAtFirstFailure: true)
        }
        return CheckReport(level: 3, started: started, finished: .now, device: CheckReport.Device(device.info),
                           host: host, results: results)
    }

    // MARK: The checks

    static func checks(for device: FieldDevice, pending: Pending) -> [Check] {
        let tape = LevelTwo.scratchTape
        return [
            Check("reconnect.handles") {
                var now: [String: UInt32] = [:]
                for path in pending.handles.keys {
                    if let found = try await device.locate(FilePath(path)) { now[path] = found.handle }
                }
                return handles(before: pending.handles, after: now)
            },
            Check("names.maximum") {
                guard let item = try await device.item(at: tape) else { return .fail("\(tape) isn't listed after the reconnect.") }
                let whole = try await device.item(at: LevelTwo.longTape)
                let cut = try await device.item(at: LevelTwo.longTapeCut)
                return nameKept(sent: LevelTwo.scratchName, listed: item, long: LevelTwo.longName, longListed: (whole ?? cut)?.name)
            },
            Check("reconnect.renamed") {
                guard let item = try await device.item(at: tape) else { return .fail("\(tape) isn't listed after the reconnect.") }
                let files = try await device.contentsOfDirectory(at: tape)
                return renamed(listed: item.name, files: files.map(\.name),
                               readmeBytes: files.first { $0.name == "readme.txt" }?.size)
            },
            Check("reconnect.kept") {
                var tracks: [(name: String, matches: Bool)] = []
                for (name, data) in expectedTracks {
                    let path = tape.appending(name)
                    let read = try await device.fileExists(at: path) ? try await device.contents(of: path) : nil
                    tracks.append((name, read == data))
                }
                let json = tape.appending("tape.json")
                let read = try await device.fileExists(at: json) ? try await device.contents(of: json) : nil
                return kept(tracks: tracks, written: LevelTwo.Content.tapeJSON, read: read)
            },
            Check("delete.folder-with-files") {
                guard let folder = try await device.locate(tape) else { return .fail("\(tape) isn't listed.") }
                var files: [UInt32] = []
                for item in try await device.contentsOfDirectory(at: tape) {
                    if let file = try await device.locate(item.path) { files.append(file.handle) }
                }
                var responseCode: UInt16?
                do {
                    try await device.session.deleteObject(folder.handle)
                } catch MTPError.refused(_, let code) {
                    responseCode = code
                }
                let folderGone = try await !device.fileExists(at: tape)
                var left: [UInt32] = []
                for handle in files where try await exists(handle, on: device) { left.append(handle) }
                var finding = folderWithFiles(responseCode: responseCode, files: files.count, folderGone: folderGone,
                                              filesLeft: left.count)
                // Files left without their folder would be out of reach, and still take space, so they're deleted
                // by handle. They're the scratch tape's own.
                if folderGone, !left.isEmpty {
                    for handle in left { try await device.session.deleteObject(handle) }
                    finding = .fail(finding.summary + " They were then deleted one by one.", observed: finding.observed)
                }
                return finding
            },
            Check("delete.files-then-folder") {
                // The cut tape is always left for this, and the scratch tape too if one DeleteObject didn't delete it.
                let result = await LevelTwo.deleteLeftovers(on: device)
                return Finding(outcome: result.outcome, summary: result.summary, observed: result.observed)
            },
        ]
    }

    /// The tracks as level 2 leaves them: `track_1.wav` replaced, the others as first written.
    static var expectedTracks: [(String, Data)] {
        [("track_1.wav", LevelTwo.Content.replacement)] + LevelTwo.Content.tracks.dropFirst()
    }

    /// The `tape.json` keys the OP-1 may change on its own: the playhead, and the metronome level, which the probe
    /// saw change on a copied tape to the same value as another tape's, so it may be a global setting (2026-11-08).
    static let runtimeKeys: Set<String> = ["pos", "tempometronomelevel"]

    private static func exists(_ handle: UInt32, on device: FieldDevice) async throws -> Bool {
        do {
            _ = try await device.session.objectInfo(handle)
            return true
        } catch MTPError.refused {
            return false
        }
    }

    // MARK: Judging

    static func handles(before: [String: UInt32], after: [String: UInt32]) -> Finding {
        let compared = before.keys.filter { after[$0] != nil }
        let changed = compared.filter { before[$0] != after[$0] }
        // The handles themselves differ from run to run, so only the counts are recorded.
        let observed: CheckValue = ["compared": .int(compared.count), "changed": .int(changed.count)]
        guard !compared.isEmpty else {
            return .fail("None of the scratch tape's \(before.count) objects from level 2 could be found to compare.",
                         observed: observed)
        }
        guard !changed.isEmpty else {
            return .fail("All \(compared.count) of the scratch tape's objects kept their handles. If the OP-1 didn't "
                         + "leave MTP mode between levels 2 and 3, run level 2 again.", observed: observed)
        }
        return .pass("\(changed.count) of the scratch tape's \(compared.count) objects have new handles since level 2.",
                     observed: observed)
    }

    /// The 12-character name is kept, and the 13-character one is cut to its first 12 (`longListed` is nil if
    /// neither form is listed).
    static func nameKept(sent: String, listed: FieldItem, long: String, longListed: String?) -> Finding {
        var fields: [String: CheckValue] = ["name": .string(sent), "length": .int(sent.count), "listedAs": .string(listed.name),
                                            "longName": .string(long), "longLength": .int(long.count)]
        if let longListed { fields["longListedAs"] = .string(longListed) }
        let observed = CheckValue.record(fields)
        guard listed.isDirectory, listed.name == sent.lowercased() else {
            return .fail("After the reconnect, \(sent) is listed as \(listed.name).", observed: observed)
        }
        let cut = String(long.lowercased().prefix(sent.count))
        guard let longListed else {
            return .fail("After the reconnect, \(sent) is still listed as \(listed.name), but \(long) is listed neither "
                         + "whole nor as \(cut).", observed: observed)
        }
        guard longListed == cut else {
            return .fail("After the reconnect, \(sent) is still listed as \(listed.name), but \(long) is listed as "
                         + "\(longListed), not cut to \(cut).", observed: observed)
        }
        return .pass("After the reconnect, \(sent), \(sent.count) characters, is still listed as \(listed.name), and \(long), "
                     + "\(long.count) characters, was cut to \(longListed).", observed: observed)
    }

    static func renamed(listed: String, files: [String], readmeBytes: Int?) -> Finding {
        var fields: [String: CheckValue] = ["listedAs": .string(listed), "files": .list(files.sorted().map { .string($0) })]
        if let readmeBytes { fields["readmeBytes"] = .int(readmeBytes) }
        let observed = CheckValue.record(fields)
        guard listed == listed.lowercased() else { return .fail("The tape is listed as \(listed), not lowercase.", observed: observed) }
        guard let readmeBytes else {
            return .fail("The tape is listed lowercase, as \(listed), but the OP-1 didn't add a readme.txt.", observed: observed)
        }
        return .pass("The tape is listed lowercase, as \(listed), and the OP-1 added a \(readmeBytes)-byte readme.txt.",
                     observed: observed)
    }

    static func kept(tracks: [(name: String, matches: Bool)], written: Data, read: Data?) -> Finding {
        let different = tracks.filter { !$0.matches }.map(\.name)
        guard let read, let after = try? JSONSerialization.jsonObject(with: read) as? [String: Any],
              let before = try? JSONSerialization.jsonObject(with: written) as? [String: Any] else {
            let observed: CheckValue = ["tracksDifferent": .list(different.map { .string($0) })]
            return .fail(read == nil ? "tape.json is gone after the reconnect." : "tape.json isn't a JSON object after the reconnect.",
                         observed: observed)
        }
        let changed = Set(before.keys).union(after.keys).filter { key in
            guard let old = before[key] as? NSObject, let new = after[key] as? NSObject else { return true }
            return !old.isEqual(new)
        }.sorted()
        var fields: [String: CheckValue] = ["tracksDifferent": .list(different.map { .string($0) }),
                                            "changedKeys": .list(changed.map { .string($0) })]
        for key in runtimeKeys.sorted() {
            if let value = after[key] { fields[key] = .string("\(value)") }
        }
        let observed = CheckValue.record(fields)
        let varies = runtimeKeys.sorted() + ["changedKeys"]
        guard different.isEmpty else {
            return .fail("After the reconnect, \(different.joined(separator: ", ")) read back different from what level 2 left.",
                         observed: observed, varies: varies)
        }
        let unexpected = changed.filter { !runtimeKeys.contains($0) }
        guard unexpected.isEmpty else {
            return .fail("After the reconnect, tape.json changed in \(unexpected.joined(separator: ", ")).",
                         observed: observed, varies: varies)
        }
        let runtime = changed.isEmpty ? "unchanged" : "the same apart from \(changed.joined(separator: " and "))"
        return .pass("After the reconnect, all \(tracks.count) tracks read back byte for byte, and tape.json is \(runtime).",
                     observed: observed, varies: varies)
    }

    static func folderWithFiles(responseCode: UInt16?, files: Int, folderGone: Bool, filesLeft: Int) -> Finding {
        var fields: [String: CheckValue] = ["files": .int(files), "folderGone": .bool(folderGone), "filesLeft": .int(filesLeft)]
        if let responseCode { fields["responseCode"] = .string(LevelOne.hex(responseCode)) }
        let observed = CheckValue.record(fields)
        switch (responseCode, folderGone, filesLeft) {
        case (nil, true, 0):
            return .pass("One DeleteObject on the folder deleted it and its \(files) files.", observed: observed)
        case (let code?, false, files):
            return .pass("DeleteObject on the folder, with its \(files) files in it, was refused with \(LevelOne.hex(code)), "
                         + "and nothing was deleted. So the files go first.", observed: observed)
        case (nil, true, _):
            return .fail("One DeleteObject deleted the folder but left \(filesLeft) of its \(files) files without one.",
                         observed: observed)
        default:
            let answer = responseCode.map { "was refused with \(LevelOne.hex($0))" } ?? "was answered OK"
            return .fail("DeleteObject on the folder \(answer), but the folder is \(folderGone ? "gone" : "still there") and "
                         + "\(filesLeft) of its \(files) files are left.", observed: observed)
        }
    }
}
