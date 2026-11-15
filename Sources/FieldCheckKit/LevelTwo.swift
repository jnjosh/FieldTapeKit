import CryptoKit
import FieldTapeKit
import Foundation
import System

/// FieldCheck's level 2: scratch writes, only to content FieldCheck makes itself (ADR 0003, sections 2 and 3).
///
/// It makes the scratch tape `fieldcheck #1-2` with a new tape's `tape.json`, then generated tones, which make the
/// OP-1 rebuild `tape.json` with its old size still listed, as the probe saw. It tries a name a tape doesn't allow,
/// replaces a track keeping a copy, and replaces `tape.json` with a generated one, last. It writes a preset to `drum/user/` and `synth/user/`, then deletes both. Free space is read before,
/// after the writes, and after the presets are deleted. The scratch tape stays for level 3, or for
/// `deleteLeftovers(on:)`.
///
/// Everything goes through FieldTapeKit's public file layer, so a run checks steps 8 to 10 of the plan on hardware,
/// apart from the refused name, which is sent raw because FieldTapeKit refuses it before sending. It stops at the
/// first failure and leaves what it made for cleanup. The album checks and the long check come in step 11b.
public enum LevelTwo {
    /// Stored lowercase. 15 characters, FieldTapeKit's maximum, using every kind it allows (`names.maximum`).
    public static let scratchTape: FilePath = "tapes/fieldcheck #1-2"
    static let scratchName = "FIELDCHECK #1-2"
    /// Written and deleted within the run.
    public static let presets: [FilePath] = ["drum/user/fieldcheck.wav", "synth/user/fieldcheck.wav"]
    /// What level 2 makes, which it may delete as leftovers.
    public static var ownContent: [FilePath] { [scratchTape] + presets }

    /// What a run will do, for a person to confirm before it starts (ADR 0003, section 3).
    public struct Plan: Sendable, Hashable {
        public let deviceID: FieldDevice.ID
        /// What will be made, written, replaced and deleted, one line each.
        public let steps: [String]
        /// Why it can't run, or nil if it can.
        public let refusal: String?
        /// FieldCheck's own content left on the OP-1 by an earlier run, which `deleteLeftovers(on:)` deletes.
        public let leftovers: [FilePath]
    }

    /// Looks at the OP-1 and says what a run would do, or why it can't: no free tape slot, or FieldCheck's content
    /// left from an earlier run. It only reads.
    public static func plan(for device: FieldDevice) async -> Plan {
        let steps = [
            "Make the tape \(scratchTape.lastComponent!.string) in a free slot (\(scratchName), 15 characters).",
            "Write a new tape's tape.json, then track_1.wav to track_4.wav, 2-second tones of \(Content.trackBytes.formatted()) bytes each.",
            "Try track_5.wav in it, which the OP-1 should refuse. If it's taken, it's deleted.",
            "Read the tape.json the OP-1 rebuilds, then replace track_1.wav with another tone, keeping a copy in this run's folder, and replace tape.json with a generated one, last.",
            "Write \(presets.map(\.string).joined(separator: " and ")), 25-second tones, then delete them, keeping a copy of the drum one in this run's folder.",
            "Leave the scratch tape on the OP-1, for level 3 or Delete FieldCheck's content.",
        ]
        do {
            var leftovers: [FilePath] = []
            for path in ownContent where try await device.fileExists(at: path) { leftovers.append(path) }
            let tapes = try await device.contentsOfDirectory(at: .op1Tapes).filter(\.isDirectory)
            let refusal: String? = if !leftovers.isEmpty {
                "FieldCheck's content from an earlier run is on the OP-1: "
                    + leftovers.map(\.string).joined(separator: ", ") + ". Delete it first."
            } else if tapes.count >= device.profile.maximumTapes {
                "All \(device.profile.maximumTapes) tape slots are used, and level 2 needs one for its scratch tape. "
                    + "Move a tape off the OP-1 first."
            } else {
                nil
            }
            return Plan(deviceID: device.id, steps: steps, refusal: refusal, leftovers: leftovers)
        } catch {
            return Plan(deviceID: device.id, steps: steps,
                        refusal: "Couldn't look at the OP-1: \(error.localizedDescription)", leftovers: [])
        }
    }

    /// Runs level 2 as `plan` describes. `workspace` is a folder of this device's that the drum preset's copy goes
    /// in. A plan that refused, or that's for another connection, runs nothing.
    public static func run(on device: FieldDevice, plan: Plan, workspace: URL, host: CheckReport.Host) async -> CheckReport {
        let started = Date.now
        let results: [CheckResult]
        if plan.deviceID != device.id || plan.refusal != nil {
            let reason = plan.refusal ?? "The plan was made on another connection."
            results = checks(for: device, workspace: workspace).map {
                CheckResult(expectation: $0.expectation, outcome: .notRun, summary: reason)
            }
        } else {
            results = await CheckRunner.run(checks(for: device, workspace: workspace), stopAtFirstFailure: true)
        }
        return CheckReport(level: 2, started: started, finished: .now, device: CheckReport.Device(device.info),
                           host: host, results: results)
    }

    /// Deletes what level 2 made, if it's there: the presets, then the scratch tape's files and then its folder,
    /// through `prepareToRemove(at:)` and `removeItem(_:)`. That's `delete.files-then-folder`. Until level 3 in
    /// step 12 of the plan, this is how the scratch tape comes off the OP-1.
    public static func deleteLeftovers(on device: FieldDevice) async -> CheckResult {
        var deleted: [String] = []
        do {
            for path in presets where try await device.fileExists(at: path) {
                try await device.removeItem(try await device.prepareToRemove(at: path))
                deleted.append(path.string)
            }
            guard try await device.fileExists(at: scratchTape) else {
                let also = deleted.isEmpty ? "" : " Deleted \(deleted.joined(separator: ", "))."
                return CheckResult(expectation: "delete.files-then-folder", outcome: .notRun,
                                   summary: "There's no scratch tape to delete." + also)
            }
            let deletion = try await device.prepareToRemove(at: scratchTape)
            try await device.removeItem(deletion)
            deleted += deletion.contents.map(\.path.string) + [scratchTape.string]
            let gone = try await !device.fileExists(at: scratchTape)
            let observed: CheckValue = ["files": .int(deletion.contents.count), "gone": .bool(gone)]
            return gone
                ? CheckResult(expectation: "delete.files-then-folder", outcome: .pass,
                              summary: "Deleted the scratch tape's \(deletion.contents.count) files, then its folder, and it's gone.",
                              observed: observed)
                : CheckResult(expectation: "delete.files-then-folder", outcome: .fail,
                              summary: "Deleted the scratch tape's files and folder, but it's still listed.", observed: observed)
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

        func set(freeBefore value: Int) { freeBefore = value }
        func set(freeAfterWrites value: Int) { freeAfterWrites = value }
        func add(tapeBytes count: Int) { tapeBytes += count }
        func add(presetBytes count: Int) { presetBytes += count }
        func set(rebuilt value: (written: Data, listed: Int, read: Data)) { rebuilt = value }
    }

    static func checks(for device: FieldDevice, workspace: URL) -> [Check] {
        let run = Run()
        let tape = scratchTape
        @Sendable func free() async throws -> Int {
            Int(clamping: try await device.session.storageInfo(device.storageID).freeSpaceInBytes)
        }
        return [
            Check("names.maximum") {
                await run.set(freeBefore: try await free())
                let item = try await device.createDirectory(at: FilePath("tapes/\(scratchName)"))
                return namesMaximum(sent: scratchName, listed: item)
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
                for (name, data) in [("tape.json", Content.blankTapeJSON)] + Content.tracks {
                    let item = try await device.write(data, to: tape.appending(name))
                    written.append((item.name, data, try await device.contents(of: item.path)))
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
            Check("device.storage") {
                guard let before = await run.freeBefore, let afterWrites = await run.freeAfterWrites else {
                    return .notRun("Free space wasn't read before and after the writes.")
                }
                return freeSpace(before: before, afterWrites: afterWrites, afterCleanup: try await free(),
                                 tapeBytes: await run.tapeBytes, presetBytes: await run.presetBytes)
            },
        ]
    }

    // MARK: Judging

    static func namesMaximum(sent: String, listed: FieldItem) -> Finding {
        let observed: CheckValue = ["name": .string(sent), "length": .int(sent.count), "listedAs": .string(listed.name)]
        guard listed.isDirectory, listed.name == sent.lowercased() else {
            return .fail("Made \(sent), but it's listed as \(listed.name).", observed: observed)
        }
        return .pass("The OP-1 took \(sent), \(sent.count) characters, as \(listed.name). Whether it's kept after a "
                     + "reconnect is level 3.", observed: observed)
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
                     + "after the presets were deleted it was \(kept.formatted()) below the start, for the scratch tape's "
                     + "\(tapeBytes.formatted()).", observed: observed,
                     varies: ["before", "afterWrites", "afterCleanup"])
    }
}
