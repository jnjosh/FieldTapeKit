import Foundation
import Testing
@testable import FieldCheckKit
@testable import FieldTapeKit

@Suite struct LevelOneContentTests {
    static let profile = FirmwareProfile.v1_7_3

    static func entry(_ path: String, size: Int = 44, folder: Bool = false) -> CatalogEntry {
        CatalogEntry(handle: 0, path: path, name: String(path.split(separator: "/").last!), isFolder: folder,
                     format: folder ? PTPObjectFormat.association : PTPObjectFormat.wav, size: size)
    }

    static func tape(_ name: String, files: [String]) -> (folder: CatalogEntry, contents: [CatalogEntry]) {
        (entry("tapes/\(name)", folder: true), files.map { entry("tapes/\(name)/\($0)") })
    }

    static let fullTape = ["tape.json", "readme.txt", "track_1.wav", "track_2.wav", "track_3.wav", "track_4.wav"]

    // MARK: On the simulated OP-1

    @Test func summariesOnASimulated173() async throws {
        let device = FieldDevice.simulated(await OP1Fixture.device())
        let summaries = Dictionary(uniqueKeysWithValues: (await LevelOne.run(on: device, host: LevelOneTests.host))
            .results.map { ($0.expectation, $0.summary) })
        #expect(summaries["tape.files"] == "All 2 tapes hold tape.json and track_1–4.wav, and nothing else but readme.txt.")
        #expect(summaries["tape.wav-format"] == "All 8 tape tracks are PCM, 2 channels, 32 bits, 44100 Hz, with headers that match their sizes.")
        #expect(summaries["tape.json-keys"] == "All 2 tape.json files have every known key, at version 1.")
        #expect(summaries["tape.types"] == "Every tape_type is 0–3. Seen: 1, 3.")
        #expect(summaries["album.files"] == "mixdown/ holds side_a.wav and side_b.wav, and nothing else but readme.txt: "
                + "side_a.wav has audio and side_b.wav is empty.")
        #expect(summaries["read.partial"] == "5 chunks of up to 1 MiB came back whole. Reads of 16 KiB at offset 1001, "
                + "64 KiB across the first chunk boundary, and 1 MiB from 100 bytes before the end matched.")
    }

    @Test func readsTheLargestAudioFile() async throws {
        let device = FieldDevice.simulated(await OP1Fixture.device())
        let result = try await LevelOneTests.run("read.speed", on: device)
        guard case .record(let observed) = result.observed else { Issue.record("no observation"); return }
        #expect(observed["bytes"] == .int(OP1Fixture.sideABytes))
        #expect(result.summary.hasPrefix("Read 5.0 MB in 1 MiB chunks in "))
    }

    @Test func anOP1WithNoTapesOrAudioSkipsThoseChecks() async {
        let simulator = SimulatedMTPDevice()
        await simulator.addFolder("tapes")
        let mixdown = await simulator.addFolder("mixdown")
        let side = OP1Fixture.wav(Self.profile.sideFormat, dataBytes: 0)
        await simulator.addFile("side_a.wav", data: side, in: mixdown)
        await simulator.addFile("side_b.wav", data: side, in: mixdown)
        let report = await LevelOne.run(on: FieldDevice.simulated(simulator), host: LevelOneTests.host)
        let outcomes = Dictionary(uniqueKeysWithValues: report.results.map { ($0.expectation, $0.outcome) })
        for id in ["tape.files", "tape.wav-format", "tape.json-keys", "tape.json-units", "tape.types", "read.partial",
                   "read.speed", "read.cost"] {
            #expect(outcomes[id] == .notRun, "\(id)")
        }
        #expect(outcomes["album.files"] == .pass)
        #expect(outcomes["album.wav-format"] == .pass)
    }

    // MARK: tape.files and album.files

    @Test func tapeFiles() {
        let result = LevelOne.tapeFiles([Self.tape("a", files: Self.fullTape),
                                         Self.tape("b", files: ["tape.json", "track_1.wav", "track_2.wav", "track_3.wav",
                                                                "track_5.wav"])], profile: Self.profile)
        #expect(result.outcome == .fail)
        #expect(result.summary == "Missing: tapes/b/track_4.wav. Not expected: tapes/b/track_5.wav.")
        #expect(LevelOne.tapeFiles([], profile: Self.profile).outcome == .notRun)
    }

    @Test func aFolderInsideATapeIsUnexpected() {
        var tape = Self.tape("a", files: Self.fullTape)
        tape.contents.append(Self.entry("tapes/a/extra", folder: true))
        #expect(LevelOne.tapeFiles([tape], profile: Self.profile).summary == "Not expected: tapes/a/extra/.")
    }

    @Test func albumFiles() {
        let folder = Self.entry("mixdown", folder: true)
        let missing = LevelOne.albumFiles([folder, Self.entry("mixdown/side_a.wav"), Self.entry("mixdown/notes.txt")],
                                          profile: Self.profile)
        #expect(missing.outcome == .fail)
        #expect(missing.summary == "Missing: mixdown/side_b.wav. Not expected: mixdown/notes.txt.")

        let short = LevelOne.albumFiles([folder, Self.entry("mixdown/side_a.wav", size: 10), Self.entry("mixdown/side_b.wav")],
                                        profile: Self.profile)
        #expect(short.summary == "mixdown/side_a.wav is 10 bytes, shorter than a header")

        #expect(LevelOne.albumFiles([], profile: Self.profile).summary == "There's no mixdown/ folder.")
    }

    // MARK: WAV formats

    @Test func wavFormats() throws {
        let good = try WAVHeader(OP1Fixture.wav(Self.profile.trackFormat, dataBytes: 8))
        let sixteen = try WAVHeader(OP1Fixture.wav(Self.profile.sideFormat, dataBytes: 8))
        let result = LevelOne.wavFormats([
            .init(path: "tapes/a/track_1.wav", size: 52, header: .success(good)),
            .init(path: "tapes/a/track_2.wav", size: 52, header: .success(sixteen)),
            .init(path: "tapes/a/track_3.wav", size: 60, header: .success(good)),
            .init(path: "tapes/a/track_4.wav", size: 44, header: .failure(.notWAV)),
        ], expected: Self.profile.trackFormat, kind: "tape tracks")
        #expect(result.outcome == .fail)
        #expect(result.summary == "4 problems, expecting PCM, 2 channels, 32 bits, 44100 Hz: "
                + "tapes/a/track_2.wav is PCM, 2 channels, 16 bits, 44100 Hz; "
                + "tapes/a/track_3.wav: RIFF size 44, not 52; tapes/a/track_3.wav: data size 8, not 16; "
                + "tapes/a/track_4.wav: not a RIFF WAVE file.")
        guard case .record(let observed) = result.observed, case .list(let formats) = observed["formats"] else {
            Issue.record("no observation")
            return
        }
        #expect(formats.count == 2)
        #expect(LevelOne.wavFormats([], expected: Self.profile.trackFormat, kind: "tape tracks").outcome == .notRun)
    }

    // MARK: tape.json

    static func json(_ text: String) -> (path: String, data: Data) { ("tapes/a/tape.json", Data(text.utf8)) }

    @Test func tapeJSONKeys() {
        let pass = LevelOne.tapeJSONKeys([Self.json(OP1Fixture.recordedTapeJSON), Self.json(OP1Fixture.blankTapeJSON)],
                                         shape: Self.profile.tapeJSON)
        #expect(pass.outcome == .pass)
        guard case .record(let observed) = pass.observed else { Issue.record("no observation"); return }
        #expect(observed["clipKeys"] == ["ch", "id", "padding", "start", "stop"])
        #expect(observed["versions"] == [1])

        let unknown = OP1Fixture.recordedTapeJSON.replacingOccurrences(of: #""version":1"#, with: #""version":1,"swing":3"#)
        let noted = LevelOne.tapeJSONKeys([Self.json(unknown)], shape: Self.profile.tapeJSON)
        #expect(noted.outcome == .pass)
        #expect(noted.summary.hasSuffix(" Unknown keys, which FieldTapeKit keeps as they are: swing."))

        let newer = OP1Fixture.blankTapeJSON.replacingOccurrences(of: #""version":1"#, with: #""version":2"#)
            .replacingOccurrences(of: #""pos":0,"#, with: "")
        let fail = LevelOne.tapeJSONKeys([Self.json(newer), Self.json("[1]")], shape: Self.profile.tapeJSON)
        #expect(fail.outcome == .fail)
        #expect(fail.summary == "tapes/a/tape.json lacks pos; tapes/a/tape.json is version 2; tapes/a/tape.json isn't a JSON object.")
    }

    @Test func aClipMissingAKeyFails() {
        let json = OP1Fixture.recordedTapeJSON.replacingOccurrences(of: #""padding":[112,113,-1,-1],"#, with: "")
        #expect(LevelOne.tapeJSONKeys([Self.json(json)], shape: Self.profile.tapeJSON).summary
                == "a clip in tapes/a/tape.json lacks padding.")
    }

    @Test func tapeTypes() {
        let five = OP1Fixture.blankTapeJSON.replacingOccurrences(of: #""tape_type":3"#, with: #""tape_type":4"#)
        let result = LevelOne.tapeTypes([Self.json(OP1Fixture.blankTapeJSON), Self.json(five)], shape: Self.profile.tapeJSON)
        #expect(result.outcome == .fail)
        #expect(result.summary == "tape_type 4 is outside 0–3.")
        #expect(result.observed == ["outsideRange": [4]])
    }

    @Test func tapeJSONUnits() {
        let sizes = ["track_1.wav": 1_164_852, "track_2.wav": 1_206_000, "track_3.wav": 44, "track_4.wav": 44]
        let result = LevelOne.tapeJSONUnits([.init(path: "tapes/a", json: Data(OP1Fixture.recordedTapeJSON.utf8),
                                                   trackSizes: sizes)], profile: Self.profile)
        #expect(result.outcome == .fail)
        #expect(result.summary == "tapes/a: track_2.wav is 1206000 bytes, clips imply 1206836.")
    }

    // MARK: read.partial

    static func sample(size: Int, chunks: [Int]) -> ReadSample {
        ReadSample(file: Self.entry("mixdown/side_a.wav", size: size),
                   chunks: chunks.map { Data(count: $0) }, elapsed: .milliseconds(500))
    }

    @Test func aShortChunkFails() {
        let result = LevelOne.readPartial(Self.sample(size: 3 << 20, chunks: [1 << 20, 1 << 19, 1 << 20]), checks: [])
        #expect(result.outcome == .fail)
        #expect(result.summary == "Reading mixdown/side_a.wav: chunk 2 came back with 524288 bytes, not 1048576; "
                + "the chunks held 2621440 bytes, not 3145728.")
    }

    @Test func aMismatchedReadFails() {
        let read = LevelOne.PartialRead(label: "16 KiB at offset 1001", offset: 1_001, length: 16_384,
                                        expected: Data(count: 16_384), expectedCount: 16_384, got: Data(repeating: 1, count: 16_384))
        let past = LevelOne.PartialRead(label: "1 MiB from 100 bytes before the end", offset: 100, length: 1 << 20,
                                        expected: nil, expectedCount: 100, got: Data(count: 99))
        let result = LevelOne.readPartial(Self.sample(size: 200, chunks: [200]), checks: [read, past])
        #expect(result.summary == "Reading mixdown/side_a.wav: 16 KiB at offset 1001 returned different bytes; "
                + "1 MiB from 100 bytes before the end returned 99 bytes, not 100.")
    }

    @Test func readSpeed() {
        let result = LevelOne.readSpeed(Self.sample(size: 4_000_000, chunks: [4_000_000]))
        #expect(result.outcome == .pass)
        #expect(result.observed == ["bytes": 4_000_000, "milliseconds": 500, "kilobytesPerSecond": 8_000,
                                    "chunkMilliseconds": []])
        #expect(result.summary.hasPrefix("Read 4.0 MB in 1 MiB chunks in 0.50 s, 8.0 MB/s. On 1.7.3"))
    }

    @Test func readSpeedShowsHowChunkTimesGrow() {
        // As 2026-11-13 would look if each chunk took 110 ms plus 56 ms for each MiB of offset.
        let times = (0..<16).map { Duration.milliseconds(110 + 56 * $0) }
        let sample = ReadSample(file: Self.entry("tapes/a/track_1.wav", size: 20 << 20),
                                chunks: Array(repeating: Data(count: 1 << 20), count: 16), elapsed: .milliseconds(8_480),
                                chunkTimes: times)
        let result = LevelOne.readSpeed(sample)
        #expect(result.summary.contains(" The first chunk took 110 ms and the last 950 ms, about 56 ms more for each MiB of offset."))
        guard case .record(let observed) = result.observed else { Issue.record("no observation"); return }
        #expect(observed["chunkMilliseconds"] == .list(times.map { .int(LevelOne.milliseconds($0)) }))
    }

    @Test func slope() {
        #expect(LevelOne.slope([500, 500, 500, 500]) == 0)
        #expect(LevelOne.slope([100, 200, 300, 400, 500]) == 100)
        #expect(LevelOne.slope([100, 200, 300]) == nil)
    }

    @Test func theSampleTimesEveryChunk() async throws {
        let device = FieldDevice.simulated(await OP1Fixture.device())
        let catalog = Catalog(device.session)
        let sample = try #require(try await ReadSampler(catalog).sample())
        #expect(sample.chunkTimes.count == sample.chunks.count)
        #expect(sample.chunks.count == 5)
    }
}
