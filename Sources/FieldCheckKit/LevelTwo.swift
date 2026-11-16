import CryptoKit
import FieldTapeKit
import Foundation
import System

/// FieldCheck's level 2: scratch writes, only to content FieldCheck makes itself (ADR 0003, sections 2 and 3).
///
/// It makes the scratch tape `fieldck #1-2`, and a second tape with a 13-character name, which the OP-1 should cut
/// to 12 once it leaves MTP mode. It writes the scratch tape a new tape's `tape.json`, then generated tones, which make the
/// OP-1 rebuild `tape.json` with its old size still listed, as the probe saw. It tries a name a tape doesn't allow,
/// replaces a track keeping a copy, and replaces `tape.json` with a generated one, last. When asked, the long check
/// replaces a track with a full 6-minute one and puts it back. It writes a preset to `drum/user/` and `synth/user/`,
/// then deletes both. Writes are timed for `write.speed`, and free space is read before, after the writes, and after
/// the presets are deleted. Where album writing is on, last, it copies an album side with audio off, side B if it
/// has any, and writes a tone of exactly its length over it with `restoreSide`, for level 3 to check it lasted and put
/// the side back. On 1.7.3 album writing is off (`album.write-again`), so the album isn't touched. The scratch tape
/// stays for level 3, or for `deleteLeftovers(on:)`.
///
/// Everything goes through FieldTapeKit's public file layer, so a run checks steps 8 to 10 of the plan on hardware,
/// apart from the refused name, which is sent raw because FieldTapeKit refuses it before sending. It stops at the
/// first failure and leaves what it made for cleanup.
public enum LevelTwo {
    /// Stored lowercase. 12 characters, the most the OP-1 keeps, using every kind of character FieldTapeKit allows
    /// (`names.maximum`).
    public static let scratchTape: FilePath = "tapes/fieldck #1-2"
    static let scratchName = "FIELDCK #1-2"
    /// One character too long, sent raw because FieldTapeKit refuses it. The OP-1 takes it, then cuts it to 12 once it
    /// leaves MTP mode, to `longTapeCut`, which differs from the scratch tape's name (`names.maximum`).
    public static let longTape: FilePath = "tapes/fieldck #2-13"
    static let longName = "FIELDCK #2-13"
    public static let longTapeCut: FilePath = "tapes/fieldck #2-1"
    /// The tapes level 2 makes, under every name they can have.
    public static let tapes: [FilePath] = [scratchTape, longTape, longTapeCut]
    /// Written and deleted within the run.
    public static let presets: [FilePath] = ["drum/user/fieldcheck.wav", "synth/user/fieldcheck.wav"]
    /// The tone written to an album side, and the copy kept of the side, in the run's folder.
    static let sideTone = "fieldcheck side tone.wav"
    static func sideCopy(_ side: Album.Side) -> String { "side_\(side.rawValue) before level 2.wav" }
    /// What level 2 makes, which it may delete as leftovers.
    public static var ownContent: [FilePath] { tapes + presets }

    /// What a run will do, for a person to confirm before it starts (ADR 0003, section 3).
    public struct Plan: Sendable, Hashable {
        public let deviceID: FieldDevice.ID
        /// What will be made, written, replaced and deleted, one line each.
        public let steps: [String]
        /// Why it can't run, or nil if it can.
        public let refusal: String?
        /// FieldCheck's own content left on the OP-1 by an earlier run, which `deleteLeftovers(on:)` deletes.
        public let leftovers: [FilePath]
        /// The album side the album check writes over, as listed: side B if it's sound with audio, or else side A.
        /// Nil if neither is. An empty side is never written: a tone would make it grow.
        public let albumSide: AlbumSide?
    }

    /// Looks at the OP-1 and says what a run would do, or why it can't: no free tape slot, or FieldCheck's content
    /// left from an earlier run. It only reads.
    public static func plan(for device: FieldDevice) async -> Plan {
        let writesAlbum = await device.albumWritesAllowed
        let listed = writesAlbum ? try? await device.album() : nil
        let albumSide = listed.flatMap { album in [album.b, album.a].first { $0.isSound && !$0.isEmpty } }
        let album = if !writesAlbum {
            "The album isn't touched: album writing is off on firmware \(device.info.firmware), since a side written over MTP hung the OP-1 when it was written again."
        } else if let albumSide {
            "\(albumSide.path) has \(albumSide.duration.formatted(.units(allowed: [.minutes, .seconds], width: .narrow))) of your audio: copy it to this run's folder and verify the copy, then write a tone of the same length over it. Until level 3 runs, \(albumSide.side) holds the tone. Level 3 checks the tone lasted after the reconnect, then puts your \(albumSide.side) back from the copy and checks it."
        } else {
            "Neither album side has sound audio, so the album isn't touched: a tone over an empty side would make it grow, which hangs the OP-1."
        }
        let steps = [
            "Make the tape \(scratchTape.lastComponent!.string) in a free slot (\(scratchName), 12 characters, the most the OP-1 keeps), and \(longTape.lastComponent!.string) in another (\(longName), 13 characters), with a new tape's tape.json and the same tones. Level 3 checks the OP-1 cut the second name to 12.",
            "Write a new tape's tape.json, then track_1.wav to track_4.wav, 2-second tones of \(Content.trackBytes.formatted()) bytes each.",
            "Try track_5.wav in it, which the OP-1 should refuse. If it's taken, it's deleted.",
            "Read the tape.json the OP-1 rebuilds, then replace track_1.wav with another tone, keeping a copy in this run's folder, and replace tape.json with a generated one, last.",
            "Only with the long check: replace track_2.wav with a 6-minute tone of 127 MB, read it back, then put the 2-second one back and tape.json again, last. It adds about half a minute.",
            "Write \(presets.map(\.string).joined(separator: " and ")), 25-second tones, then delete them, keeping a copy of the drum one in this run's folder.",
            album,
            "Leave both tapes on the OP-1, for level 3, which deletes them.",
        ]
        do {
            var leftovers: [FilePath] = []
            for path in ownContent where try await device.fileExists(at: path) { leftovers.append(path) }
            let tapes = try await device.contentsOfDirectory(at: .op1Tapes).filter(\.isDirectory)
            let refusal: String? = if !leftovers.isEmpty {
                "FieldCheck's content from an earlier run is on the OP-1: "
                    + leftovers.map(\.string).joined(separator: ", ") + ". Delete it first."
            } else if tapes.count + 2 > device.profile.maximumTapes {
                "\(tapes.count) of the \(device.profile.maximumTapes) tape slots are used, and level 2 needs two for its "
                    + "tapes. Move \(tapes.count + 2 - device.profile.maximumTapes == 1 ? "a tape" : "two tapes") off the OP-1 first."
            } else {
                nil
            }
            return Plan(deviceID: device.id, steps: steps, refusal: refusal, leftovers: leftovers, albumSide: albumSide)
        } catch {
            return Plan(deviceID: device.id, steps: steps,
                        refusal: "Couldn't look at the OP-1: \(error.localizedDescription)", leftovers: [], albumSide: nil)
        }
    }

    /// Runs level 2 as `plan` describes. `workspace` is a folder of this device's that the copies go in. The long
    /// check runs only when `longCheck` is true. A plan that refused, or that's for another connection, runs
    /// nothing.
    public static func run(on device: FieldDevice, plan: Plan, longCheck: Bool = false, workspace: URL,
                           host: CheckReport.Host) async -> CheckReport {
        let started = Date.now
        let results: [CheckResult]
        let checks = checks(for: device, plan: plan, longCheck: longCheck, workspace: workspace)
        if plan.deviceID != device.id || plan.refusal != nil {
            let reason = plan.refusal ?? "The plan was made on another connection."
            results = checks.map { CheckResult(expectation: $0.expectation, outcome: .notRun, summary: reason) }
        } else {
            results = await CheckRunner.run(checks, stopAtFirstFailure: true)
        }
        return CheckReport(level: 2, started: started, finished: .now, device: CheckReport.Device(device.info),
                           host: host, results: results)
    }

    /// Deletes what level 2 made, if it's there: the presets, then each of its tapes, files first and then the
    /// folder, through `prepareToRemove(at:)` and `removeItem(_:)`. That's `delete.files-then-folder`. Level 3 uses it
    /// too, and FieldCheck offers it after a run that didn't finish.
    public static func deleteLeftovers(on device: FieldDevice) async -> CheckResult {
        var deleted: [String] = []
        var removed: [(name: String, files: Int)] = []
        do {
            for path in presets where try await device.fileExists(at: path) {
                try await device.removeItem(try await device.prepareToRemove(at: path))
                deleted.append(path.string)
            }
            for tape in tapes where try await device.fileExists(at: tape) {
                let deletion = try await device.prepareToRemove(at: tape)
                try await device.removeItem(deletion)
                deleted += deletion.contents.map(\.path.string) + [deletion.item.path.string]
                removed.append((deletion.item.name, deletion.contents.count))
            }
            guard !removed.isEmpty else {
                let also = deleted.isEmpty ? "" : " Deleted \(deleted.joined(separator: ", "))."
                return CheckResult(expectation: "delete.files-then-folder", outcome: .notRun,
                                   summary: "There's no FieldCheck tape to delete." + also)
            }
            var left: [String] = []
            for tape in tapes where try await device.fileExists(at: tape) { left.append(tape.string) }
            let entries: [CheckValue] = removed.map { ["name": .string($0.name), "files": .int($0.files)] }
            let observed: CheckValue = ["tapes": .list(entries), "gone": .bool(left.isEmpty)]
            let what = removed.map { "\($0.name)'s \($0.files) files" }.joined(separator: " and ")
            return left.isEmpty
                ? CheckResult(expectation: "delete.files-then-folder", outcome: .pass,
                              summary: "Deleted \(what), each tape's files and then its folder, and "
                                  + (removed.count == 1 ? "it's gone." : "they're gone."), observed: observed)
                : CheckResult(expectation: "delete.files-then-folder", outcome: .fail,
                              summary: "Deleted \(what), but \(left.joined(separator: ", ")) is still listed.", observed: observed)
        } catch {
            let changed = (error as? FieldError)?.changed.map(\.string) ?? []
            return CheckResult(expectation: "delete.files-then-folder", outcome: .fail,
                               summary: "Couldn't delete: \(error.localizedDescription) Deleted: "
                                   + ((deleted + changed).isEmpty ? "nothing" : (deleted + changed).joined(separator: ", ")) + ".")
        }
    }

    // MARK: The checks

    /// What one run has seen so far, shared by its checks in order.
    actor Run {
        var freeBefore: Int?
        var freeAfterWrites: Int?
        var tapeBytes = 0
        var presetBytes = 0
        /// The `tape.json` that was written, and what was read after the replaced track.
        var rebuilt: (written: Data, listed: Int, read: Data)?
        /// Timed writes of audio, for `write.speed`.
        var writes: [TimedWrite] = []

        func set(freeBefore value: Int) { freeBefore = value }
        func set(freeAfterWrites value: Int) { freeAfterWrites = value }
        func add(tapeBytes count: Int) { tapeBytes += count }
        func add(presetBytes count: Int) { presetBytes += count }
        func set(rebuilt value: (written: Data, listed: Int, read: Data)) { rebuilt = value }
        func add(_ write: TimedWrite) { writes.append(write) }
    }

    /// One write, timed with its own read-back, and a read of the same file timed after it. The send is the
    /// difference, since FieldTapeKit's write reads the file back before it returns.
    struct TimedWrite: Sendable, Hashable {
        let name: String
        let bytes: Int
        let write: Duration
        let read: Duration
        var send: Duration { max(write - read, .zero) }
    }

    /// Writes `data` and reads it back, each timed, and records the write for `write.speed`.
    @Sendable static func timedWrite(_ data: Data, to path: FilePath, options: UploadOptions = .init(), as name: String? = nil,
                                     on device: FieldDevice, run: Run) async throws -> (item: FieldItem, read: Data) {
        let clock = ContinuousClock()
        let start = clock.now
        let item = try await device.write(data, to: path, options: options)
        let written = clock.now
        let read = try await device.contents(of: item.path, maximumSize: max(data.count, 1 << 20))
        await run.add(TimedWrite(name: name ?? item.name, bytes: data.count, write: written - start, read: clock.now - written))
        return (item, read)
    }

    static func checks(for device: FieldDevice, plan: Plan, longCheck: Bool, workspace: URL) -> [Check] {
        let run = Run()
        let tape = scratchTape
        @Sendable func free() async throws -> Int {
            Int(clamping: try await device.session.storageInfo(device.storageID).freeSpaceInBytes)
        }
        @Sendable func write(_ data: Data, to path: FilePath, options: UploadOptions = .init(),
                             as name: String? = nil) async throws -> (item: FieldItem, read: Data) {
            try await timedWrite(data, to: path, options: options, as: name, on: device, run: run)
        }
        return [
            Check("names.maximum") {
                await run.set(freeBefore: try await free())
                let item = try await device.createDirectory(at: FilePath("tapes/\(scratchName)"))
                // The long name is sent raw, as FieldTapeKit refuses it, then filled through FieldTapeKit like any tape.
                guard let tapes = try await device.locate(.op1Tapes) else { return .fail("tapes/ isn't listed.") }
                let lowered = longName.lowercased()
                let dataset = PTPObjectInfo.dataset(storageID: device.storageID, format: PTPObjectFormat.association,
                                                    size: 0, parent: tapes.handle, filename: lowered,
                                                    associationType: PTPAssociationType.genericFolder)
                _ = try await device.session.sendObjectInfo(storage: device.storageID, parent: tapes.handle, dataset: dataset)
                guard let long = try await device.item(at: longTape) else { return .fail("\(longTape) isn't listed after it was made.") }
                for (name, data) in [("tape.json", Content.blankTapeJSON)] + Content.tracks {
                    _ = try await device.write(data, to: longTape.appending(name))
                    await run.add(tapeBytes: data.count)
                }
                return namesMaximum(sent: scratchName, listed: item, long: longName, longListed: long)
            },
            Check("write.folder") {
                guard let found = try await device.locate(tape), let info = found.info else {
                    return .fail("\(tape) isn't listed after it was made.")
                }
                return folder(format: info.format, associationType: info.associationType,
                              contents: try await device.contentsOfDirectory(at: tape).count)
            },
            Check("write.exact") {
                // A new tape's tape.json first, then the tracks, which make the OP-1 rebuild it (`rebuild.tape-json`).
                var written: [(name: String, data: Data, read: Data)] = []
                let json = try await device.write(Content.blankTapeJSON, to: tape.appending("tape.json"))
                written.append((json.name, Content.blankTapeJSON, try await device.contents(of: json.path)))
                for (name, data) in Content.tracks {
                    let (item, read) = try await write(data, to: tape.appending(name))
                    written.append((item.name, data, read))
                }
                return exact(written)
            },
            Check("write.refused-name") {
                guard let found = try await device.locate(tape) else { return .fail("\(tape) isn't listed.") }
                let header = WAVHeader.bytes(format: device.profile.trackFormat, dataBytes: 0)
                let dataset = PTPObjectInfo.dataset(storageID: device.storageID, format: PTPObjectFormat.wav,
                                                    size: UInt32(header.count), parent: found.handle, filename: "track_5.wav")
                do {
                    let handle = try await device.session.sendObjectInfo(storage: device.storageID, parent: found.handle,
                                                                         dataset: dataset)
                    try await device.session.deleteObject(handle)
                    return refusedName(responseCode: nil)
                } catch MTPError.refused(_, let responseCode) {
                    return refusedName(responseCode: responseCode)
                }
            },
            Check("rebuild.tape-json") {
                let json = tape.appending("tape.json")
                guard let listed = try await device.item(at: json) else { return .fail("tape.json is gone after the tracks were written.") }
                let read = try await device.contents(of: json)
                await run.set(rebuilt: (Content.blankTapeJSON, listed.size, read))
                return rebuiltJSON(written: Content.blankTapeJSON, read: read)
            },
            Check("rebuild.stale-size") {
                guard let rebuilt = await run.rebuilt, rebuilt.read != rebuilt.written else {
                    return .notRun("The OP-1 didn't rebuild tape.json, so there's no size to compare.")
                }
                let finding = staleSize(written: rebuilt.written.count, listed: rebuilt.listed, read: rebuilt.read.count)
                guard finding.outcome == .pass else { return finding }
                // Both kinds of replace (step 10), and the scratch tape ends as generated, with tape.json written last
                // (ADR 0002, section 6).
                let track = tape.appending("track_1.wav")
                _ = try await device.write(Content.replacement, to: track,
                                           options: UploadOptions(existing: .replace(keepingCopyAt: workspace.appending(path: "track_1.wav"))))
                let json = tape.appending("tape.json")
                let deletion = try await device.prepareToRemove(at: json)
                _ = try await device.write(Content.tapeJSON, to: json, options: UploadOptions(existing: .replace(confirmed: deletion)))
                await run.add(tapeBytes: Content.tracks.reduce(0) { $0 + $1.1.count } + Content.tapeJSON.count)
                return .pass(finding.summary + " Then track_1.wav was replaced, keeping a copy, and the generated "
                             + "tape.json replaced the stale one, last. Both read back exactly.", observed: finding.observed)
            },
            Check("tape.track-limit") {
                guard longCheck else { return .notRun("The long check wasn't asked for.") }
                let track = tape.appending("track_2.wav")
                let long = Content.longTrack()
                let before = MemoryUse.now()
                let (_, read) = try await write(long, to: track, options: UploadOptions(existing: .replace(confirmed: try await device.prepareToRemove(at: track))),
                                                as: "track_2.wav (6 minutes)")
                let finding = trackLimit(sent: long, read: read, timed: await run.writes.last!, memoryBefore: before, memoryAfter: MemoryUse.now())
                guard finding.outcome == .pass else { return finding }
                // Put the 2-second tone back, then tape.json last, so the tape ends as it does without the long check.
                _ = try await device.write(Content.tracks[1].1, to: track,
                                           options: UploadOptions(existing: .replace(confirmed: try await device.prepareToRemove(at: track))))
                let json = tape.appending("tape.json")
                _ = try await device.write(Content.tapeJSON, to: json,
                                           options: UploadOptions(existing: .replace(confirmed: try await device.prepareToRemove(at: json))))
                return finding
            },
            Check("write.preset-converted") {
                var stored: [(path: FilePath, audio: PCMAudio, format: FieldFormat, size: Int)] = []
                for path in presets {
                    let item = try await device.write(Content.preset, to: path)
                    await run.add(presetBytes: item.size)
                    stored.append((item.path, try PCMAudio(try await device.contents(of: item.path)), item.format, item.size))
                }
                await run.set(freeAfterWrites: try await free())
                let finding = presetsConverted(sent: try PCMAudio(Content.preset), stored: stored)
                // Deleted as an app would: the drum one with a copy, the synth one with a confirmation (step 8).
                _ = try await device.removeItem(at: presets[0], keepingCopyAt: workspace.appending(path: "drum-user-fieldcheck.wav"))
                try await device.removeItem(try await device.prepareToRemove(at: presets[1]))
                for path in presets where try await device.fileExists(at: path) {
                    return .fail("\(path) is still listed after it was deleted.", observed: finding.observed)
                }
                return finding
            },
            Check("write.speed") {
                let writes = await run.writes
                guard !writes.isEmpty else { return .notRun("Nothing was written.") }
                return writeSpeed(writes)
            },
            Check("device.storage") {
                guard let before = await run.freeBefore, let afterWrites = await run.freeAfterWrites else {
                    return .notRun("Free space wasn't read before and after the writes.")
                }
                return freeSpace(before: before, afterWrites: afterWrites, afterCleanup: try await free(),
                                 tapeBytes: await run.tapeBytes, presetBytes: await run.presetBytes)
            },
            // Last, so a failure anywhere before it leaves the album untouched, and nothing after it can stop level 3.
            Check("album.write-exact") {
                guard await device.albumWritesAllowed else {
                    return .notRun("Album writing is off on firmware \(device.info.firmware), so the album wasn't touched.")
                }
                guard let planned = plan.albumSide else { return .notRun("Neither album side has sound audio, so the album wasn't touched.") }
                return try await writeTone(over: planned, on: device, workspace: workspace)
            },
        ]
    }

    /// Copies `planned` off into `workspace` and verifies it, writes a tone of the same length over it with
    /// `restoreSide`, and reads it back. If the tone doesn't read back, the side is put back from the copy at once.
    static func writeTone(over planned: AlbumSide, on device: FieldDevice, workspace: URL) async throws -> Finding {
        let side = planned.side
        guard try await device.album()[side] == planned else {
            return .notRun("\(planned.path) changed since level 2 was planned, so the album wasn't touched.")
        }
        let original = try await device.contents(of: planned.path, maximumSize: 1 << 27)
        let copy = workspace.appending(path: sideCopy(side))
        let toneData = Content.sideTone(bytes: planned.size)
        let tone = workspace.appending(path: sideTone)
        try toneData.write(to: tone, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: tone) }
        do {
            _ = try await device.restoreSide(side, from: tone, conflict: .replace(copyingExistingTo: copy))
        } catch let error as FieldError where !error.changed.isEmpty {
            // Stopped after the old side was deleted, so nothing more is written (ADR 0002, safety rule 6).
            return .fail("restoreSide stopped after deleting \(planned.path): \(error.localizedDescription) Its copy is in this "
                         + "run's folder as \(sideCopy(side)). The OP-1 may put its own side back once it leaves MTP mode.")
        }
        let kept = try Data(contentsOf: copy)
        let read = try await device.contents(of: planned.path, maximumSize: 1 << 27)
        var restored: Data?
        if read != toneData, kept == original {
            let replacement = try await device.prepareToReplace(side)
            _ = try await device.restoreSide(side, from: copy, conflict: .replace(confirmed: replacement))
            restored = try await device.contents(of: planned.path, maximumSize: 1 << 27)
        }
        return albumExact(side: planned, tone: toneData, read: read, original: original, copy: kept, restored: restored)
    }

    // MARK: Judging

    static func namesMaximum(sent: String, listed: FieldItem, long: String, longListed: FieldItem) -> Finding {
        let observed: CheckValue = ["name": .string(sent), "length": .int(sent.count), "listedAs": .string(listed.name),
                                    "longName": .string(long), "longLength": .int(long.count), "longListedAs": .string(longListed.name)]
        guard listed.isDirectory, listed.name == sent.lowercased() else {
            return .fail("Made \(sent), but it's listed as \(listed.name).", observed: observed)
        }
        guard longListed.isDirectory, longListed.name == long.lowercased() else {
            return .fail("Made \(long), but it's listed as \(longListed.name).", observed: observed)
        }
        return .pass("The OP-1 took \(sent), \(sent.count) characters, as \(listed.name), and \(long), \(long.count) characters, "
                     + "as \(longListed.name). What it keeps after a reconnect is level 3.", observed: observed)
    }

    static func folder(format: UInt16, associationType: UInt16, contents: Int) -> Finding {
        let observed: CheckValue = ["format": .string(LevelOne.hex(format)), "associationType": .int(Int(associationType)),
                                    "contents": .int(contents)]
        guard format == PTPObjectFormat.association, associationType == PTPAssociationType.genericFolder else {
            return .fail("The new tape is listed with format \(LevelOne.hex(format)) and association type \(associationType).",
                         observed: observed)
        }
        return .pass("SendObjectInfo alone made the tape, a folder (0x3001, association type 1) with \(contents) items in it.",
                     observed: observed)
    }

    static func exact(_ written: [(name: String, data: Data, read: Data)]) -> Finding {
        let files: [CheckValue] = written.map { file in
            ["name": .string(file.name), "size": .int(file.data.count),
             "sha256": .string(SHA256.hash(data: file.data).map { String(format: "%02x", $0) }.joined())]
        }
        let observed: CheckValue = ["files": .list(files)]
        if let wrong = written.first(where: { $0.read != $0.data }) {
            return .fail("\(wrong.name) read back as \(wrong.read.count) bytes that don't match the \(wrong.data.count) written.",
                         observed: observed)
        }
        let total = written.reduce(0) { $0 + $1.data.count }
        return .pass("\(written.count) files, \(total.formatted()) bytes, each read back byte for byte, again after the write's own check.",
                     observed: observed)
    }

    static func refusedName(responseCode: UInt16?) -> Finding {
        guard let responseCode else {
            return .fail("The OP-1 accepted SendObjectInfo for track_5.wav. The object it made was deleted.",
                         observed: ["accepted": true])
        }
        let observed: CheckValue = ["responseCode": .string(LevelOne.hex(responseCode))]
        guard responseCode == PTPResponseCode.generalError else {
            return .fail("track_5.wav was refused with \(LevelOne.hex(responseCode)), not 0x2002.", observed: observed)
        }
        return .pass("track_5.wav was refused with 0x2002, before any data was sent.", observed: observed)
    }

    static func rebuiltJSON(written: Data, read: Data) -> Finding {
        let observed: CheckValue = ["changed": .bool(read != written)]
        guard read != written else {
            return .fail("After the tracks were written, tape.json read back as it was written: no rebuild seen.", observed: observed)
        }
        return .pass("After the tracks were written, tape.json read back different from the one written before them.",
                     observed: observed)
    }

    static func staleSize(written: Int, listed: Int, read: Int) -> Finding {
        let observed: CheckValue = ["written": .int(written), "listed": .int(listed), "read": .int(read)]
        guard listed == written, read == written else {
            return .fail("The rebuilt tape.json is listed at \(listed) bytes and read \(read), not the \(written) written.",
                         observed: observed)
        }
        return .pass("The rebuilt tape.json is still listed and read at the \(written) bytes written.", observed: observed)
    }

    static func trackLimit(sent: Data, read: Data, timed: TimedWrite, memoryBefore: MemoryUse?, memoryAfter: MemoryUse?) -> Finding {
        var observed: [String: CheckValue] = [
            "bytes": .int(sent.count), "readBytes": .int(read.count),
            "sha256": .string(SHA256.hash(data: sent).map { String(format: "%02x", $0) }.joined()),
            "writeMilliseconds": .int(milliseconds(timed.write)), "readMilliseconds": .int(milliseconds(timed.read)),
        ]
        var varies = ["writeMilliseconds", "readMilliseconds"]
        if let memoryBefore, let memoryAfter {
            observed["footprintBefore"] = .int(memoryBefore.footprint)
            observed["footprintPeak"] = .int(memoryAfter.peak)
            varies += ["footprintBefore", "footprintPeak"]
        }
        guard read == sent else {
            return .fail("The 6-minute track read back as \(read.count.formatted()) bytes that don't match the "
                         + "\(sent.count.formatted()) written.", observed: .record(observed), varies: varies)
        }
        let memory = if let memoryBefore, let memoryAfter {
            " FieldCheck's memory went from \(megabytes(memoryBefore.footprint)) MB before it to a peak of \(megabytes(memoryAfter.peak)) MB."
        } else {
            ""
        }
        return .pass("A full 6-minute track of \(sent.count.formatted()) bytes was written in \(seconds(timed.write)) s, with the "
                     + "write's own read-back, and read back byte for byte in \(seconds(timed.read)) s.\(memory) Then the "
                     + "2-second track and tape.json were put back.", observed: .record(observed), varies: varies)
    }

    static func albumExact(side: AlbumSide, tone: Data, read: Data, original: Data, copy: Data, restored: Data?) -> Finding {
        var fields: [String: CheckValue] = ["side": .string(side.path.string), "sameLength": .bool(tone.count == side.size),
                                            "readBack": .bool(read == tone), "copy": .string(sideCopy(side.side))]
        if let restored { fields["restoredAsItWas"] = .bool(restored == original) }
        // Which side, and its copy, depend on what's on the OP-1.
        let observed = CheckValue.record(fields)
        let varies = ["side", "copy"]
        guard copy == original else {
            return .fail("The copy of \(side.path) in this run's folder doesn't hold what was read from the OP-1, so "
                         + "\(side.path) holds FieldCheck's tone. It wasn't put back from the copy.", observed: observed, varies: varies)
        }
        guard read == tone else {
            let back = restored == original ? "It was put back from the copy, and reads back as it was."
                : "Putting it back from the copy in this run's folder didn't read back as it was."
            return .fail("\(side.path) read back as \(read.count.formatted()) bytes that don't match the "
                         + "\(tone.count.formatted()) written. \(back)", observed: observed, varies: varies)
        }
        return .pass("\(side.path) was copied off and verified, then a tone of the same length, \(tone.count.formatted()) bytes, "
                     + "was written with restoreSide and read back byte for byte. It holds the tone until level 3 puts it back.",
                     observed: observed, varies: varies)
    }

    static func writeSpeed(_ writes: [TimedWrite]) -> Finding {
        let bytes = writes.reduce(0) { $0 + $1.bytes }
        let send = writes.reduce(Duration.zero) { $0 + $1.send }
        let entries: [CheckValue] = writes.map { write in
            ["name": .string(write.name), "bytes": .int(write.bytes), "writeMilliseconds": .int(milliseconds(write.write)),
             "readMilliseconds": .int(milliseconds(write.read)), "sendMilliseconds": .int(milliseconds(write.send))]
        }
        let observed: CheckValue = ["bytes": .int(bytes), "sendMilliseconds": .int(milliseconds(send)),
                                    "kilobytesPerSecond": .int(kilobytesPerSecond(bytes, send)), "writes": .list(entries)]
        let largest = writes.max { $0.bytes < $1.bytes }!
        // The long track is most of what's sent when it runs, and its speed alone is the clearest figure.
        let detail = writes.count > 1 && largest.bytes * 10 > bytes * 9
            ? " \(largest.name) alone: \(rate(largest.bytes, largest.send)) MB/s." : ""
        // How big a drop is reported, against a baseline, is step 22 of the plan.
        return .pass("Sent \(megabytes(bytes)) MB in \(writes.count) writes in \(seconds(send)) s, \(rate(bytes, send)) MB/s, timed as each "
                     + "write less a read of the same file.\(detail) On 1.7.3 the probe saw about 7 MB/s.", observed: observed,
                     varies: ["sendMilliseconds", "kilobytesPerSecond", "writes[].writeMilliseconds", "writes[].readMilliseconds",
                              "writes[].sendMilliseconds"])
    }

    static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    static func seconds(_ duration: Duration) -> String {
        (Double(milliseconds(duration)) / 1_000).formatted(.number.precision(.fractionLength(1)))
    }

    static func megabytes(_ bytes: Int) -> String {
        (Double(bytes) / 1_000_000).formatted(.number.precision(.fractionLength(1)))
    }

    static func kilobytesPerSecond(_ bytes: Int, _ duration: Duration) -> Int {
        let ms = milliseconds(duration)
        return ms > 0 ? bytes / ms : 0
    }

    static func rate(_ bytes: Int, _ duration: Duration) -> String {
        (Double(kilobytesPerSecond(bytes, duration)) / 1_000).formatted(.number.precision(.fractionLength(1)))
    }

    static func presetsConverted(sent: PCMAudio, stored: [(path: FilePath, audio: PCMAudio, format: FieldFormat, size: Int)]) -> Finding {
        let entries: [CheckValue] = stored.map { file in
            ["path": .string(file.path.string), "container": .string("\(file.audio.container)"), "frames": .int(file.audio.frames),
             "reportedFormat": .string("\(file.format)"), "size": .int(file.size)]
        }
        let observed: CheckValue = ["sentFrames": .int(sent.frames), "stored": .list(entries)]
        if let other = stored.first(where: { $0.audio.container != .aifc }) {
            return .fail("\(other.path) was stored as \(other.audio.container), not AIFC.", observed: observed)
        }
        let lengths = stored.map { file in
            let seconds = (Double(file.audio.frames) / Double(file.audio.format.sampleRate)).formatted(.number.precision(.fractionLength(3)))
            return "\(file.path.removingLastComponent().string)/ kept \(seconds) s"
        }
        return .pass("Both came back as AIFC under the same name, with the samples sent; of \(sent.frames / sent.format.sampleRate) s, "
                     + lengths.joined(separator: ", ") + ".", observed: observed)
    }

    static func freeSpace(before: Int, afterWrites: Int, afterCleanup: Int, tapeBytes: Int, presetBytes: Int) -> Finding {
        let observed: CheckValue = ["before": .int(before), "afterWrites": .int(afterWrites), "afterCleanup": .int(afterCleanup),
                                    "tapeBytes": .int(tapeBytes), "presetBytes": .int(presetBytes)]
        let fell = before - afterWrites
        let kept = before - afterCleanup
        // Judging how close is left to the baseline comparison in step 22 of the plan.
        return .pass("Free space fell \(fell.formatted()) bytes for \((tapeBytes + presetBytes).formatted()) written, and "
                     + "after the presets were deleted it was \(kept.formatted()) below the start, for the tapes' "
                     + "\(tapeBytes.formatted()).", observed: observed,
                     varies: ["before", "afterWrites", "afterCleanup"])
    }
}
