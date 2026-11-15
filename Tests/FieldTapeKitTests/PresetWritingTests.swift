import Foundation
import System
import Testing
@testable import FieldTapeKit

/// Writing to `synth/user/` and `drum/user/`, where the OP-1 converts what it receives (`write.preset-converted`):
/// the read-back checks the audio, not the bytes.
@Suite struct PresetWritingTests {
    static let stereo = WAVFormat(encoding: WAVFormat.pcm, channels: 2, sampleRate: 44_100, bitsPerSample: 16)
    static let mono22k = WAVFormat(encoding: WAVFormat.pcm, channels: 1, sampleRate: 22_050, bitsPerSample: 16)

    static func samples(_ format: WAVFormat, frames: Int) -> Data {
        Data((0..<frames * format.frameBytes).map { UInt8(truncatingIfNeeded: $0 &* 7) })
    }

    static func wav(_ format: WAVFormat = stereo, frames: Int = 1_000) -> Data {
        let samples = samples(format, frames: frames)
        return WAVHeader.bytes(format: format, dataBytes: samples.count) + samples
    }

    /// A plain big-endian AIFF, as other apps write one.
    static func aiff(_ format: WAVFormat, samples: Data) -> Data {
        var swapped = [UInt8](samples)
        for offset in stride(from: 0, to: swapped.count, by: 2) { swapped.swapAt(offset, offset + 1) }
        var comm = Data()
        comm.appendBigEndian(UInt16(format.channels))
        comm.appendBigEndian(UInt32(samples.count / format.frameBytes))
        comm.appendBigEndian(UInt16(16))
        // 44,100 as an 80-bit extended float.
        comm.append(contentsOf: [0x40, 0x0E, 0xAC, 0x44, 0, 0, 0, 0, 0, 0])
        var body = Data("AIFFCOMM".utf8)
        body.appendBigEndian(UInt32(comm.count))
        body.append(comm)
        body.append(contentsOf: Array("SSND".utf8))
        body.appendBigEndian(UInt32(8 + swapped.count))
        body.append(Data(count: 8))
        body.append(contentsOf: swapped)
        var file = Data("FORM".utf8)
        file.appendBigEndian(UInt32(body.count))
        return file + body
    }

    static func device(_ faults: [SimulatedMTPDevice.Fault] = []) -> (FieldDevice, SimulatedMTPDevice) {
        let simulator = SimulatedMTPDevice(faults: faults, contents: SimulatedNode.layout173)
        return (FieldDevice.simulated(simulator), simulator)
    }

    // MARK: Writing

    @Test func aWAVIsStoredAsAIFCUnderItsOwnName() async throws {
        let (device, simulator) = Self.device()
        let sent = Self.wav()
        let item = try await device.write(sent, to: "Drum/User/Kick.WAV")
        #expect(item.path == "drum/user/kick.wav")
        let stored = try #require(await simulator.stored("kick.wav", in: "user"))
        #expect(item.size == stored.count)
        let audio = try PCMAudio(stored)
        #expect(audio.container == .aifc)
        #expect(audio.samples == (try PCMAudio(sent)).samples)
    }

    @Test func drumUserKeepsTwentySeconds() async throws {
        let (device, simulator) = Self.device()
        let item = try await device.write(Self.wav(frames: 21 * 44_100), to: "drum/user/long.wav")
        let stored = try #require(await simulator.stored("long.wav", in: "user"))
        #expect(try PCMAudio(stored).frames == 20 * 44_100)
        #expect(item.size == stored.count)
    }

    /// FieldCheck level 2 found the cap on the OP-1 (2026-11-15).
    @Test func synthUserKeepsSixSeconds() async throws {
        let (device, _) = Self.device()
        let item = try await device.write(Self.wav(frames: 7 * 44_100), to: "synth/user/pad.wav")
        #expect(try PCMAudio(try await device.contents(of: item.path)).frames == 6 * 44_100)
        #expect(item.format == .wav)
    }

    /// The OP-1's own presets are 22,050 Hz mono AIFC, like applefly.aif, and copying one back keeps its samples.
    @Test func anOP1PresetCanBeCopiedBack() async throws {
        let (device, _) = Self.device()
        let preset = PCMAudio(container: .aifc, format: Self.mono22k, samples: Self.samples(Self.mono22k, frames: 500))
        let item = try await device.write(preset.aifcBytes(metadata: Data(#"{"name":"applefly"}"#.utf8)),
                                          to: "drum/user/probe-copy.aif")
        #expect(try PCMAudio(try await device.contents(of: item.path)).samples == preset.samples)
    }

    @Test func aBigEndianAIFFComparesByItsSamples() async throws {
        let (device, _) = Self.device()
        let samples = Self.samples(Self.stereo, frames: 300)
        let item = try await device.write(Self.aiff(Self.stereo, samples: samples), to: "drum/user/snare.aiff")
        #expect(try PCMAudio(try await device.contents(of: item.path)).samples == samples)
    }

    // MARK: Before anything is sent

    @Test(arguments: [
        ("drum/user/kick.mp3", "a preset's name ends in .aif, .aiff, .aifc or .wav"),
        ("drum/user/.wav", "a preset's name ends in .aif, .aiff, .aifc or .wav"),
        ("drum/user/notes.txt", "a preset's name ends in .aif, .aiff, .aifc or .wav"),
        ("drum/slots/1/kick.wav", "FieldTapeKit writes only tape files, album sides and presets"),
        ("drum/kick.wav", "FieldTapeKit writes only tape files, album sides and presets"),
    ])
    func refusesAPresetNameOrFolder(path: String, reason: String) async throws {
        let (device, simulator) = Self.device()
        await #expect { try await device.write(Self.wav(), to: FilePath(path)) } throws: { error in
            let error = error as? FieldError
            return error?.code == .notAllowed && error?.errorDescription?.hasSuffix("because \(reason).") == true
        }
        #expect(await simulator.stored((path as NSString).lastPathComponent, in: "user") == nil)
    }

    @Test(arguments: [
        WAVFormat(encoding: 1, channels: 2, sampleRate: 48_000, bitsPerSample: 16),
        WAVFormat(encoding: 1, channels: 2, sampleRate: 44_100, bitsPerSample: 24),
        WAVFormat(encoding: 1, channels: 2, sampleRate: 22_050, bitsPerSample: 16),
        WAVFormat(encoding: 1, channels: 4, sampleRate: 44_100, bitsPerSample: 16),
    ])
    func refusesAudioTheOP1HasntBeenSeenToKeep(format: WAVFormat) async throws {
        let (device, _) = Self.device()
        await #expect { try await device.write(Self.wav(format), to: "drum/user/kick.wav") } throws: { error in
            (error as? FieldError)?.code == .notAllowed
                && (error as? FieldError)?.errorDescription?.contains("a preset must be") == true
        }
    }

    @Test func refusesWhatIsntAudioOrIsEmpty() async throws {
        let (device, _) = Self.device()
        var float = Self.wav()
        float[20] = 3
        for data in [Data("not audio".utf8), Self.wav(frames: 0), float] {
            await #expect { try await device.write(data, to: "drum/user/kick.wav") } throws: {
                ($0 as? FieldError)?.code == .notAllowed
            }
        }
    }

    // MARK: Read-back

    @Test func aChangedSampleIsDeletedAndReported() async throws {
        let (device, simulator) = Self.device([.corruptStored(name: "kick.wav")])
        await #expect { try await device.write(Self.wav(), to: "drum/user/kick.wav") } throws: { error in
            let error = error as? FieldError
            return error?.code == .verificationFailed && error?.changed == []
                && error?.errorDescription == "drum/user/kick.wav couldn't be verified: its stored samples differ from the ones sent."
        }
        #expect(await simulator.deleted == ["kick.wav"])
    }

    @Test func whatTheStoredAudioMustBe() throws {
        let sent = PCMAudio(container: .wav, format: Self.stereo, samples: Self.samples(Self.stereo, frames: 10))
        #expect(PCMAudio(container: .aifc, format: Self.stereo, samples: sent.samples.prefix(16)).mismatch(asStoredFrom: sent) == nil)
        #expect(PCMAudio(container: .aifc, format: Self.stereo, samples: sent.samples).mismatch(asStoredFrom: sent) == nil)
        #expect(PCMAudio(container: .aifc, format: Self.stereo, samples: Data()).mismatch(asStoredFrom: sent)
                == "it was stored with no audio")
        #expect(PCMAudio(container: .aifc, format: Self.stereo, samples: sent.samples + Data(count: 4)).mismatch(asStoredFrom: sent)
                == "it was stored with 11 frames, more than the 10 sent")
        let mono = WAVFormat(encoding: 1, channels: 1, sampleRate: 44_100, bitsPerSample: 16)
        #expect(PCMAudio(container: .aifc, format: mono, samples: sent.samples).mismatch(asStoredFrom: sent)?
                .hasPrefix("it was stored as PCM, 1 channels") == true)
    }

    // MARK: Reading audio

    @Test func readsTheSampleRateFromAIFFsExtendedFloat() throws {
        for format in [Self.stereo, Self.mono22k] {
            let audio = PCMAudio(container: .aifc, format: format, samples: Self.samples(format, frames: 4))
            #expect(try PCMAudio(audio.aifcBytes(metadata: Data("{}".utf8))) == audio)
        }
    }

    @Test func walksPastAWAVsOtherChunks() throws {
        let samples = Self.samples(Self.stereo, frames: 3)
        var body = Data("WAVE".utf8)
        // A LIST chunk with an odd size, padded, before fmt.
        body.append(contentsOf: Array("LIST".utf8)); body.appendLittleEndian(UInt32(3)); body.append(contentsOf: [1, 2, 3, 0])
        body.append(WAVHeader.bytes(format: Self.stereo, dataBytes: samples.count).suffix(from: 12))
        body.append(samples)
        var file = Data("RIFF".utf8)
        file.appendLittleEndian(UInt32(body.count))
        let audio = try PCMAudio(file + body)
        #expect(audio.container == .wav && audio.format == Self.stereo && audio.samples == samples)
    }

    @Test func refusesCompressedAIFC() throws {
        let audio = PCMAudio(container: .aifc, format: Self.stereo, samples: Self.samples(Self.stereo, frames: 2))
        var bytes = audio.aifcBytes(metadata: Data())
        let comm = try #require(bytes.firstRange(of: Data("sowt".utf8)))
        bytes.replaceSubrange(comm, with: Data("ima4".utf8))
        #expect(throws: PCMAudio.Problem.notPCM("AIFC compression “ima4”")) { try PCMAudio(bytes) }
    }
}
