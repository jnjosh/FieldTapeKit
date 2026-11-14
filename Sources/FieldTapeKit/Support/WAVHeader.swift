import Foundation

/// The audio format a WAV header states.
package struct WAVFormat: Sendable, Hashable, CustomStringConvertible {
    /// The format tag for integer PCM.
    package static let pcm: UInt16 = 1

    package let encoding: UInt16
    package let channels: Int
    package let sampleRate: Int
    package let bitsPerSample: Int

    package init(encoding: UInt16, channels: Int, sampleRate: Int, bitsPerSample: Int) {
        self.encoding = encoding
        self.channels = channels
        self.sampleRate = sampleRate
        self.bitsPerSample = bitsPerSample
    }

    /// Bytes per frame: one sample for every channel.
    package var frameBytes: Int { channels * bitsPerSample / 8 }

    package var description: String {
        let kind = encoding == Self.pcm ? "PCM" : String(format: "format 0x%04X", encoding)
        return "\(kind), \(channels) channels, \(bitsPerSample) bits, \(sampleRate) Hz"
    }
}

/// The 44-byte header the OP-1 writes at the start of every tape track and album side: a RIFF chunk holding
/// one `fmt ` chunk of 16 bytes and then the `data` chunk (`tape.wav-format`, `album.wav-format`).
///
/// Only that layout is read. A header with other chunks before `data` throws, since the OP-1 has never written one.
package struct WAVHeader: Sendable, Hashable {
    package static let size = 44

    package let format: WAVFormat
    /// The RIFF chunk's size field, which should be the file size minus 8.
    package let riffSize: Int
    /// The `data` chunk's size field, which should be the file size minus 44.
    package let dataSize: Int

    package enum Problem: Error, Equatable, CustomStringConvertible {
        case tooShort(Int)
        case notWAV
        case unexpectedLayout

        package var description: String {
            switch self {
            case .tooShort(let count): "only \(count) bytes, not a 44-byte header"
            case .notWAV: "not a RIFF WAVE file"
            case .unexpectedLayout: "not a 16-byte fmt chunk followed by the data chunk"
            }
        }
    }

    package init(_ data: Data) throws(Problem) {
        let bytes = Array(data.prefix(Self.size))
        guard bytes.count == Self.size else { throw Problem.tooShort(bytes.count) }
        func tag(_ offset: Int) -> String { String(decoding: bytes[offset..<offset + 4], as: UTF8.self) }
        func u16(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        func u32(_ offset: Int) -> Int { u16(offset) | u16(offset + 2) << 16 }

        guard tag(0) == "RIFF", tag(8) == "WAVE" else { throw Problem.notWAV }
        guard tag(12) == "fmt ", u32(16) == 16, tag(36) == "data" else { throw Problem.unexpectedLayout }
        format = WAVFormat(encoding: UInt16(u16(20)), channels: u16(22), sampleRate: u32(24), bitsPerSample: u16(34))
        riffSize = u32(4)
        dataSize = u32(40)
    }

    /// The header the OP-1 writes for `dataBytes` of audio in `format`.
    package static func bytes(format: WAVFormat, dataBytes: Int) -> Data {
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
        return data
    }

    /// What's inconsistent about this header for a file of `fileSize` bytes, or nothing.
    package func problems(fileSize: Int) -> [String] {
        var problems: [String] = []
        if riffSize != fileSize - 8 { problems.append("RIFF size \(riffSize), not \(fileSize - 8)") }
        if dataSize != fileSize - Self.size { problems.append("data size \(dataSize), not \(fileSize - Self.size)") }
        if format.frameBytes > 0, dataSize % format.frameBytes != 0 {
            problems.append("data size \(dataSize) isn't whole \(format.frameBytes)-byte frames")
        }
        return problems
    }
}
