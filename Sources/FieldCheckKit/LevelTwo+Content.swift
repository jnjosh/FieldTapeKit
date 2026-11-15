import FieldTapeKit
import Foundation

extension LevelTwo {
    /// What level 2 writes: generated tones and a generated `tape.json`, never anyone's own audio or `padding`
    /// (ADR 0003, section 2). The same every run, so a baseline can record their SHA-256s.
    enum Content {
        static let profile = FirmwareProfile.v1_7_3
        /// 2 seconds at 44.1 kHz.
        static let trackFrames = 88_200
        static let trackBytes = WAVHeader.size + trackFrames * profile.trackFormat.frameBytes

        /// `track_1.wav` to `track_4.wav`, in the tape track format: a different note on each.
        static let tracks: [(String, Data)] = [220.0, 277.18, 329.63, 440.0].enumerated().map { index, frequency in
            ("track_\(index + 1).wav", track(frequency))
        }

        /// What replaces `track_1.wav`, the same length, so the generated `tape.json` still fits it.
        static let replacement = track(554.37)

        /// 25 seconds of 16-bit stereo, longer than either folder keeps: 20 seconds in `drum/user/`, 6 in `synth/user/`.
        static let preset: Data = {
            let format = WAVFormat(encoding: WAVFormat.pcm, channels: 2, sampleRate: 44_100, bitsPerSample: 16)
            let frames = 25 * format.sampleRate
            var samples = Data(capacity: frames * format.frameBytes)
            for frame in 0..<frames {
                let value = Int16(sin(2 * .pi * 440 * Double(frame) / 44_100) * 0.25 * Double(Int16.max))
                samples.appendLittleEndianSample(value)
                samples.appendLittleEndianSample(value)
            }
            return WAVHeader.bytes(format: format, dataBytes: samples.count) + samples
        }()

        /// 2 seconds of a tone in the album side format, written only to a side that's empty (`album.write-exact`).
        static let side: Data = {
            let format = profile.sideFormat
            var samples = Data(capacity: trackFrames * format.frameBytes)
            for frame in 0..<trackFrames {
                let value = Int16(sin(2 * .pi * 392 * Double(frame) / 44_100) * 0.25 * Double(Int16.max))
                samples.appendLittleEndianSample(value)
                samples.appendLittleEndianSample(value)
            }
            return WAVHeader.bytes(format: format, dataBytes: samples.count) + samples
        }()

        /// A full 6-minute track, the longest the OP-1 allows, for the long check (`tape.track-limit`): 127,008,044
        /// bytes. Made when asked for, not kept, since it's large. The tone is 441 Hz, so one period is exactly 100
        /// frames, repeated.
        static func longTrack(frames: Int = profile.maximumTapeFrames) -> Data {
            let period = 100
            var block = Data(capacity: period * profile.trackFormat.frameBytes)
            for frame in 0..<period {
                let value = Int32(sin(2 * .pi * Double(frame) / Double(period)) * 0.25 * Double(Int32.max))
                block.appendLittleEndianSample(value)
                block.appendLittleEndianSample(value)
            }
            let bytes = frames * profile.trackFormat.frameBytes
            var samples = Data(capacity: bytes)
            while samples.count + block.count <= bytes { samples.append(block) }
            samples.append(block.prefix(bytes - samples.count))
            return WAVHeader.bytes(format: profile.trackFormat, dataBytes: samples.count) + samples
        }

        /// The `tape.json` the OP-1 gives a new tape, as on the blank tape the probe read (2026-11-08). The tracks
        /// written after it make the OP-1 rebuild it longer, which is the case the probe saw read back truncated.
        static let blankTapeJSON = Data(#"""
            {"clips":[],"loop":false,"loop_in":0,"loop_out":0,"mixer_params":[1.0,1.0,1.0,1.0,0.0,0.0,0.0,0.0],\#
            "pos":0,"tape_type":3,"tempobpmdecimal":1200,"tempometronomelevel":0.0,"tempometronometype":0,\#
            "temposyncout":1,"temposynctype":0,"track":0,"version":1}
            """#.utf8)

        /// Several clips, a loop, a custom tempo and a type other than a new tape's, with `padding` all -1 as on a
        /// tape the OP-1 rebuilt. Written as the OP-1 writes its own, with the same keys in the same order, and
        /// consistent with the tracks (`tape.json-units`).
        static let tapeJSON = Data(#"""
            {"clips":[{"ch":0,"id":0,"padding":[-1,-1,-1,-1],"start":0,"stop":44100},\#
            {"ch":0,"id":1,"padding":[-1,-1,-1,-1],"start":44100,"stop":88200},\#
            {"ch":1,"id":2,"padding":[-1,-1,-1,-1],"start":0,"stop":88200},\#
            {"ch":2,"id":3,"padding":[-1,-1,-1,-1],"start":22050,"stop":88200},\#
            {"ch":3,"id":4,"padding":[-1,-1,-1,-1],"start":0,"stop":88200}],\#
            "loop":true,"loop_in":0,"loop_out":88200,"mixer_params":[1.0,1.0,1.0,1.0,0.0,0.0,0.0,0.0],"pos":0,\#
            "tape_type":2,"tempobpmdecimal":900,"tempometronomelevel":0.0,"tempometronometype":0,"temposyncout":1,\#
            "temposynctype":0,"track":0,"version":1}
            """#.utf8)

        /// A tone at a quarter of full scale, in both channels.
        static func track(_ frequency: Double) -> Data {
            var samples = Data(capacity: trackFrames * profile.trackFormat.frameBytes)
            for frame in 0..<trackFrames {
                let value = Int32(sin(2 * .pi * frequency * Double(frame) / 44_100) * 0.25 * Double(Int32.max))
                samples.appendLittleEndianSample(value)
                samples.appendLittleEndianSample(value)
            }
            return WAVHeader.bytes(format: profile.trackFormat, dataBytes: samples.count) + samples
        }
    }
}

private extension Data {
    mutating func appendLittleEndianSample<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
