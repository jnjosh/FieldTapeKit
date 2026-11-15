import Foundation
import System
import Testing
@testable import FieldTapeKit

@Suite struct TapeNameTests {
    /// The probe's tape name test, carried over: the OP-1's own names and the probe's test name are allowed.
    @Test func allowsTheOP1sCharacters() throws {
        #expect(try TapeName("2026-312#01").string == "2026-312#01")
        #expect(try TapeName("PROBE 1-#A").string == "probe 1-#a")
        #expect(try TapeName("FIELDCK #1-2").string == "fieldck #1-2")
    }

    @Test(arguments: [("probe_1_é", "it uses “_”, “é”"), ("fieldck #2-13", "it's longer than 12 characters"),
                      ("   ", "it's empty"), ("", "it's empty")])
    func refusesANameANewTapeCantHave(name: String, reason: String) {
        #expect { try TapeName(name) } throws: { error in
            let error = error as? FieldError
            return error?.code == .invalidName && error?.reason == reason
        }
    }

    @Test func comparesIgnoringCase() throws {
        #expect(try TapeName("ABC") == TapeName("abc"))
        #expect(Set([try TapeName("ABC"), try TapeName("abc")]).count == 1)
        #expect(try TapeName("a") < TapeName("B"))
    }

    /// A name already on the OP-1 is accepted at any length, with any characters.
    @Test func acceptsAListedNameAsItIs() {
        #expect(TapeName(listed: "A Tape Named On The OP-1").string == "a tape named on the op-1")
        #expect(TapeName.maximumLength == 12)
    }
}

@Suite struct TapeManifestTests {
    /// Every real `tape.json` the probe logged reads, and keeps its bytes.
    @Test(arguments: ProbeTapeJSON.all.map(\.json))
    func readsAndKeepsARealTapeJSON(_ json: String) throws {
        let data = Data(json.utf8)
        let manifest = try TapeManifest(data)
        #expect(manifest.data == data)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(manifest.clips.count == (root["clips"] as? [Any])?.count)
        #expect(manifest.type.rawValue == root["tape_type"] as? Int)
        #expect(manifest.tempo == Double(root["tempobpmdecimal"] as? Int ?? 0) / 10)
        #expect(manifest.mixerParameters.count == 8)
        #expect(manifest.clips.allSatisfy { (1...4).contains($0.track) && $0.start <= $0.end })
    }

    @Test func decodesTheProbesFields() throws {
        // 2026-220#02, a Vintage tape with two tracks, as the probe copied it.
        let json = try #require(ProbeTapeJSON.all.first { $0.json.contains(#""padding":[112,113,-1,-1]"#) }?.json)
        let manifest = try TapeManifest(Data(json.utf8))
        #expect(manifest.type == .vintage && manifest.type.description == "Vintage")
        #expect(manifest.clips.map(\.track) == [1, 2])
        #expect(manifest.clips.first == TapeManifest.Clip(id: 0, track: 1, start: 0, end: 145_601))
        #expect(manifest.loop == TapeManifest.Loop(isOn: true, start: 0, end: 264_600))
        #expect(manifest.tempo == 120)
        #expect(manifest.endFrame == 150_849)
    }

    @Test func aBlankTapeHasNoClips() throws {
        let json = try #require(ProbeTapeJSON.all.first { $0.json.hasPrefix(#"{"clips":[],"#) && $0.json.contains(#""tape_type":3"#) }?.json)
        let manifest = try TapeManifest(Data(json.utf8))
        #expect(manifest.clips.isEmpty && manifest.endFrame == 0 && manifest.type == .diskMini)
    }

    @Test(arguments: [("[]", "tape.json isn't a JSON object"), ("{}", "tape.json has no clips list"),
                      (#"{"clips":[{"ch":0}]}"#, "tape.json's id isn't a whole number"),
                      (#"{"clips":[],"loop":1}"#, "tape.json's loop isn't true or false")])
    func saysWhatsWrong(json: String, problem: String) {
        #expect(throws: TapeManifest.Problem(description: problem)) { try TapeManifest(Data(json.utf8)) }
    }

    @Test func namesUnknownTypes() {
        #expect(TapeType(rawValue: 7).description == "Type 7")
        #expect([TapeType.studio, .vintage, .porta, .diskMini].map(\.description) == ["Studio", "Vintage", "Porta", "Disk Mini"])
    }
}

@Suite struct TapeListingTests {
    static let header = WAVHeader.bytes(format: FirmwareProfile.v1_7_3.trackFormat, dataBytes: 0)

    /// Three sound tapes, and four that aren't: no tape.json, tape.json that isn't JSON, a track that doesn't match
    /// its clips, and a file a tape shouldn't hold.
    static func device() -> FieldDevice {
        FieldDevice.simulated {
            SimulatedTape("2026-220#02", type: .vintage, seconds: [3, 0, 1.5])
            SimulatedTape("2026-312#01", type: .diskMini)
            SimulatedTape("long one", seconds: [0, 0, 0, 360])
            Directory("tapes") {
                Directory("no json") {
                    for track in 1...4 { File("track_\(track).wav", data: header) }
                }
                Directory("bad json") {
                    File("tape.json", data: Data("not json".utf8))
                    for track in 1...4 { File("track_\(track).wav", data: header) }
                }
                Directory("short") {
                    File("tape.json", data: SimulatedTape.tapeJSON(type: .studio, frames: [100, 0, 0, 0]))
                    File("track_1.wav", data: header + Data(count: 8 * 99))
                    for track in 2...4 { File("track_\(track).wav", data: header) }
                }
                Directory("extra") {
                    File("tape.json", data: SimulatedTape.tapeJSON(type: .studio, frames: [0, 0, 0, 0]))
                    for track in 1...4 { File("track_\(track).wav", data: header) }
                    File("notes.txt", data: Data("hi".utf8))
                }
            }
        }
    }

    @Test func listsEveryTapeFolderByName() async throws {
        let tapes = try await Self.device().tapes()
        #expect(tapes.map(\.name.string) == ["2026-220#02", "2026-312#01", "bad json", "extra", "long one", "no json", "short"])
        #expect(tapes.filter(\.isSound).map(\.name.string) == ["2026-220#02", "2026-312#01", "long one"])
    }

    @Test func describesASoundTape() async throws {
        let tape = try #require(try await Self.device().tape(named: TapeName("2026-220#02")))
        #expect(tape.path == "tapes/2026-220#02")
        #expect(tape.type == .vintage)
        #expect(tape.tracks.map(\.number) == [1, 2, 3, 4])
        #expect(tape.recordedTracks == [1, 3])
        #expect(!tape.isEmpty)
        #expect(tape.duration == .seconds(3))
        #expect(tape.tracks[2].duration == .milliseconds(1_500))
        #expect(tape.tracks[1].isBlank && tape.tracks[1].frames == 0)
        #expect(tape.manifest?.clips.map(\.track) == [1, 3])
        #expect(tape.problems.isEmpty)
    }

    @Test func emptyAndFullLengthTapes() async throws {
        let device = Self.device()
        let blank = try #require(try await device.tape(named: TapeName("2026-312#01")))
        #expect(blank.isEmpty && blank.recordedTracks.isEmpty && blank.duration == .zero && blank.type == .diskMini)
        let long = try #require(try await device.tapes().first { $0.name.string == "long one" })
        #expect(long.duration == .seconds(360))
        #expect(long.tracks[3].size == 127_008_044)
    }

    @Test func saysWhyATapeIsntSound() async throws {
        let tapes = Dictionary(uniqueKeysWithValues: try await Self.device().tapes().map { ($0.name.string, $0) })
        #expect(tapes["no json"]?.problems == ["missing tape.json"])
        #expect(tapes["no json"]?.manifest == nil && tapes["no json"]?.type == nil)
        #expect(tapes["bad json"]?.problems == ["tape.json isn't a JSON object"])
        #expect(tapes["short"]?.problems == ["track_1.wav is 836 bytes, clips imply 844"])
        #expect(tapes["short"]?.manifest != nil)
        #expect(tapes["extra"]?.problems == ["unexpected notes.txt"])
    }

    @Test func findsATapeIgnoringCaseOrNot() async throws {
        let device = Self.device()
        #expect(try await device.tape(named: TapeName("LONG ONE"))?.name.string == "long one")
        #expect(try await device.tape(named: TapeName("missing")) == nil)
        #expect(try await FieldDevice.simulated().tapes().isEmpty)
    }

    @Test func countsEverySlot() async throws {
        let slots = try await Self.device().tapeSlots()
        #expect(slots == TapeSlots(used: 7, limit: 8))
        #expect(slots.available == 1)
        #expect(try await FieldDevice.simulated().tapeSlots().available == 8)
    }

    /// A tape the OP-1 adds a readme.txt to after a reconnect is still sound (`reconnect.renamed`).
    @Test func aReadmeIsAllowed() async throws {
        let device = FieldDevice.simulated {
            SimulatedTape("a", seconds: [1])
            Directory("tapes") { Directory("a") { File("readme.txt", data: Data("allowed".utf8)) } }
        }
        #expect(try await device.tape(named: TapeName("a"))?.isSound == true)
    }

    @Test func theBuildersTapeJSONIsLikeTheOP1s() throws {
        let built = SimulatedTape.tapeJSON(type: .diskMini, frames: [0, 0, 0, 0])
        let blank = try #require(ProbeTapeJSON.all.first { $0.json.hasPrefix(#"{"clips":[],"#) && $0.json.contains(#""tape_type":3"#) }?.json)
        #expect(String(decoding: built, as: UTF8.self) == blank)
    }
}
