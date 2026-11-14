import Foundation
@testable import FieldTapeKit

/// A simulated OP-1 laid out as the probe listed one on 1.7.3 (`probe-results/large-tape-ipad-2026-11-08b/`),
/// with the readme texts from `probe-results/folder-rules-ipad-2026-11-05/`. It has two tapes, as the probe read
/// them on 2026-11-08 (`probe-results/tape-json-ipad-2026-11-08/`): 2026-220#02 with two recorded tracks, and the
/// blank 2026-312#01. Side A has 5 MB of audio, enough for `read.cost`, and side B is empty.
enum OP1Fixture {
    static let recordedTapeJSON = #"{"clips":[{"ch":0,"id":0,"padding":[112,113,-1,-1],"start":0,"stop":145601},{"ch":1,"id":1,"padding":[114,115,-1,-1],"start":0,"stop":150849}],"loop":true,"loop_in":0,"loop_out":264600,"mixer_params":[1.0,1.0,1.0,1.0,0.0,0.0,0.0,0.0],"pos":0,"tape_type":1,"tempobpmdecimal":1200,"tempometronomelevel":0.0,"tempometronometype":0,"temposyncout":1,"temposynctype":0,"track":1,"version":1}"#
    static let blankTapeJSON = #"{"clips":[],"loop":false,"loop_in":0,"loop_out":0,"mixer_params":[1.0,1.0,1.0,1.0,0.0,0.0,0.0,0.0],"pos":0,"tape_type":3,"tempobpmdecimal":1200,"tempometronomelevel":0.0,"tempometronometype":0,"temposyncout":1,"temposynctype":0,"track":0,"version":1}"#
    static let sideABytes = 5_000_044

    /// A canonical 44-byte header and `dataBytes` of patterned audio, so reads at different offsets differ.
    static func wav(_ format: WAVFormat, dataBytes: Int) -> Data {
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLittleEndian(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(format.encoding)
        data.appendLittleEndian(UInt16(format.channels))
        data.appendLittleEndian(UInt32(format.sampleRate))
        data.appendLittleEndian(UInt32(format.sampleRate * format.frameBytes))
        data.appendLittleEndian(UInt16(format.frameBytes))
        data.appendLittleEndian(UInt16(format.bitsPerSample))
        data.append(contentsOf: Array("data".utf8))
        data.appendLittleEndian(UInt32(dataBytes))
        // A 251-byte ramp, repeated, so reads at different offsets differ.
        let ramp = Data((0..<251).map { UInt8($0) })
        var audio = Data(capacity: dataBytes)
        while audio.count < dataBytes { audio.append(ramp.prefix(dataBytes - audio.count)) }
        data.append(audio)
        return data
    }

    static let tapeReadme = "this folder accepts 44100 Hz .wav files.\nallowed names: track_1.wav track_2.wav track_3.wav track_4.wav\n"
    static let mixdownReadme = "this folder accepts 44100 Hz .wav files.\nallowed names: side_a.wav side_b.wav\n"
    static let presetReadme = "this folder accepts mono/stereo .aif/.aiff/.aifc/.wav files.\nthe OP-1 sample rate is 44100 Hz.\n"
        + "other sample rates change the maximum sample time.\n"

    /// Leaves out any folder in `skipping`, and lets a test change the contents before the checks run.
    static func device(operations: [UInt16] = SimulatedMTPDevice.operations173, skipping: Set<String> = [],
                       faults: [SimulatedMTPDevice.Fault] = [],
                       adding extra: @Sendable (SimulatedMTPDevice, _ folders: [String: UInt32]) async -> Void = { _, _ in })
        async -> SimulatedMTPDevice {
        let simulator = SimulatedMTPDevice(operations: operations, faults: faults)
        var folders: [String: UInt32] = [:]
        func folder(_ path: String) async {
            guard !skipping.contains(path) else { return }
            let parts = path.split(separator: "/")
            let parent = parts.count > 1 ? folders[parts.dropLast().joined(separator: "/")] : SimulatedMTPDevice.root
            guard let parent else { return }
            folders[path] = await simulator.addFolder(String(parts.last!), in: parent)
        }
        func file(_ name: String, in path: String, _ data: Data, format: UInt16 = PTPObjectFormat.undefined) async {
            guard let parent = folders[path] else { return }
            await simulator.addFile(name, data: data, format: format, in: parent)
        }

        for kind in ["synth", "drum"] {
            await folder(kind)
            await folder("\(kind)/user")
            await folder("\(kind)/slots")
            for slot in 1...8 { await folder("\(kind)/slots/\(slot)") }
            await file("readme.txt", in: "\(kind)/user", Data(presetReadme.utf8))
            await file("you may create folders here", in: kind, Data())
            await file("vibrates.aif", in: "\(kind)/slots/8", Data(count: 64), format: 0x3007)
        }
        let track = FirmwareProfile.v1_7_3.trackFormat
        await folder("tapes")
        let tapes = [("2026-220#02", recordedTapeJSON, [1_164_852, 1_206_836, 44, 44]),
                     ("2026-312#01", blankTapeJSON, [44, 44, 44, 44])]
        for (tape, json, sizes) in tapes {
            await folder("tapes/\(tape)")
            await file("tape.json", in: "tapes/\(tape)", Data(json.utf8), format: PTPObjectFormat.text)
            await file("readme.txt", in: "tapes/\(tape)", Data(tapeReadme.utf8))
            for (index, size) in sizes.enumerated() {
                await file("track_\(index + 1).wav", in: "tapes/\(tape)", wav(track, dataBytes: size - 44),
                           format: PTPObjectFormat.wav)
            }
        }
        let side = FirmwareProfile.v1_7_3.sideFormat
        await folder("mixdown")
        await file("side_a.wav", in: "mixdown", wav(side, dataBytes: sideABytes - 44), format: PTPObjectFormat.wav)
        await file("side_b.wav", in: "mixdown", wav(side, dataBytes: 0), format: PTPObjectFormat.wav)
        await file("readme.txt", in: "mixdown", Data(mixdownReadme.utf8))
        await extra(simulator, folders)
        return simulator
    }
}
