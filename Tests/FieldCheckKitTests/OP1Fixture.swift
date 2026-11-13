import Foundation
@testable import FieldTapeKit

/// A simulated OP-1 laid out as the probe listed one on 1.7.3 (`probe-results/large-tape-ipad-2026-11-08b/`),
/// with two tapes and the readme texts from `probe-results/folder-rules-ipad-2026-11-05/`.
enum OP1Fixture {
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
        await folder("tapes")
        for tape in ["2026-220#01", "2026-286#01"] {
            await folder("tapes/\(tape)")
            await file("tape.json", in: "tapes/\(tape)", Data("{}".utf8), format: PTPObjectFormat.text)
            await file("readme.txt", in: "tapes/\(tape)", Data(tapeReadme.utf8))
            for track in 1...4 { await file("track_\(track).wav", in: "tapes/\(tape)", Data(count: 44), format: PTPObjectFormat.wav) }
        }
        await folder("mixdown")
        await file("side_a.wav", in: "mixdown", Data(count: 44), format: PTPObjectFormat.wav)
        await file("side_b.wav", in: "mixdown", Data(count: 44), format: PTPObjectFormat.wav)
        await file("readme.txt", in: "mixdown", Data(mixdownReadme.utf8))
        await extra(simulator, folders)
        return simulator
    }
}
