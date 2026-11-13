import Foundation
import Testing
@testable import FieldTapeKit

/// The probe's three `tapeProblems` tests, ported from `research/OP1ProbeTests`.
@Suite struct TapeConsistencyTests {
    /// tapes/2026-220#02 as read from the OP-1 on 2026-11-08.
    static let realTapeJSON = Data(#"{"clips":[{"ch":0,"id":0,"padding":[112,113,-1,-1],"start":0,"stop":145601},{"ch":1,"id":1,"padding":[114,115,-1,-1],"start":0,"stop":150849}],"loop":true,"loop_in":0,"loop_out":264600,"mixer_params":[1.0,1.0,1.0,1.0,0.0,0.0,0.0,0.0],"pos":0,"tape_type":1,"tempobpmdecimal":1200,"tempometronomelevel":0.0,"tempometronometype":0,"temposyncout":1,"temposynctype":0,"track":1,"version":1}"#.utf8)
    static let realTrackSizes = ["track_1.wav": 1_164_852, "track_2.wav": 1_206_836, "track_3.wav": 44, "track_4.wav": 44]

    @Test func acceptsARealTape() {
        #expect(TapeConsistency.problems(json: Self.realTapeJSON, trackSizes: Self.realTrackSizes) == [])
    }

    @Test func catchesWrongSizesAndMissingTracks() {
        var sizes = Self.realTrackSizes
        sizes["track_1.wav"] = 1_000
        sizes["track_4.wav"] = nil
        #expect(TapeConsistency.problems(json: Self.realTapeJSON, trackSizes: sizes)
                == ["track_1.wav is 1000 bytes, clips imply 1164852", "track_4.wav missing"])
        #expect(TapeConsistency.problems(json: Data("{}".utf8), trackSizes: sizes) == ["tape.json has no clips array"])
    }

    @Test func catchesClipsPastSixMinutes() {
        let json = Data(#"{"clips":[{"ch":0,"id":0,"start":0,"stop":15876001}]}"#.utf8)
        let sizes = ["track_1.wav": 44 + 8 * 15_876_001, "track_2.wav": 44, "track_3.wav": 44, "track_4.wav": 44]
        #expect(TapeConsistency.problems(json: json, trackSizes: sizes) == ["clip on ch 0 ends past 6 minutes, at frame 15876001"])
    }

    @Test func catchesClipsOnTracksThatDontExist() {
        let json = Data(#"{"clips":[{"ch":4,"id":0,"start":0,"stop":10}]}"#.utf8)
        #expect(TapeConsistency.problems(json: json, trackSizes: Self.realTrackSizes).first == "clip on unknown track ch 4")
    }
}

@Suite struct WAVHeaderTests {
    /// The headers of `mixdown/side_a.wav` (12,235,308 bytes) and an empty tape track, as the probe saved them.
    static let side = Data(hex: "52494646 24b2ba00 57415645 666d7420 10000000 01000200 44ac0000 10b10200 04001000 64617461 00b2ba00")
    static let emptyTrack = Data(hex: "52494646 24000000 57415645 666d7420 10000000 01000200 44ac0000 20620500 08002000 64617461 00000000")

    @Test func readsAnAlbumSide() throws {
        let header = try WAVHeader(Self.side)
        #expect(header.format == FirmwareProfile.v1_7_3.sideFormat)
        #expect(header.problems(fileSize: 12_235_308) == [])
        #expect(header.problems(fileSize: 12_235_309) == ["RIFF size 12235300, not 12235301", "data size 12235264, not 12235265"])
    }

    @Test func readsAnEmptyTrack() throws {
        let header = try WAVHeader(Self.emptyTrack)
        #expect(header.format == FirmwareProfile.v1_7_3.trackFormat)
        #expect(header.format.frameBytes == 8)
        #expect(header.dataSize == 0)
        #expect(header.problems(fileSize: 44) == [])
        #expect(header.format.description == "PCM, 2 channels, 32 bits, 44100 Hz")
    }

    @Test func refusesWhatIsntTheOP1sLayout() {
        #expect(throws: WAVHeader.Problem.tooShort(10)) { try WAVHeader(Data(count: 10)) }
        #expect(throws: WAVHeader.Problem.notWAV) { try WAVHeader(Data(count: 44)) }
        var withList = Self.side
        withList.replaceSubrange(36..<40, with: Data("LIST".utf8))
        #expect(throws: WAVHeader.Problem.unexpectedLayout) { try WAVHeader(withList) }
    }
}

extension Data {
    init(hex: String) {
        let digits = Array(hex.filter(\.isHexDigit))
        self.init(stride(from: 0, to: digits.count, by: 2).map { UInt8(String(digits[$0...$0 + 1]), radix: 16)! })
    }
}
