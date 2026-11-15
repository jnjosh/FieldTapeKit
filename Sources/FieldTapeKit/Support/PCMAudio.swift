import Foundation

/// Integer PCM audio read from a WAV, AIFF or AIFC file, for checking what a preset folder stored.
///
/// The OP-1 converts what it receives in `synth/user/` and `drum/user/` to AIFC (`sowt`, little-endian), keeping
/// the name it was sent, so the file's bytes are compared as audio, not as a file (`write.preset-converted`).
/// The chunks are walked rather than read at fixed offsets, since WAVs from other apps carry extra chunks.
package struct PCMAudio: Sendable, Equatable {
    package enum Container: Sendable, Equatable {
        case wav, aiff, aifc
    }

    package enum Problem: Error, Equatable, CustomStringConvertible {
        case notAudio
        case missingChunk(String)
        case malformed(String)
        case notPCM(String)

        package var description: String {
            switch self {
            case .notAudio: "not a WAV, AIFF or AIFC file"
            case .missingChunk(let chunk): "it has no \(chunk) chunk"
            case .malformed(let what): "its \(what) is malformed"
            case .notPCM(let encoding): "its audio is \(encoding), not integer PCM"
            }
        }
    }

    package let container: Container
    package let format: WAVFormat
    /// The samples, interleaved and little-endian whatever the file uses, so files in different containers compare.
    package let samples: Data

    package var frames: Int { format.frameBytes > 0 ? samples.count / format.frameBytes : 0 }

    package init(container: Container, format: WAVFormat, samples: Data) {
        self.container = container
        self.format = format
        self.samples = samples
    }

    package init(_ data: Data) throws(Problem) {
        let bytes = [UInt8](data)
        guard bytes.count >= 12 else { throw .notAudio }
        let kind = Self.tag(bytes, 8)
        switch (Self.tag(bytes, 0), kind) {
        case ("RIFF", "WAVE"): self = try Self.wav(bytes)
        case ("FORM", "AIFF"): self = try Self.aiff(bytes, container: .aiff)
        case ("FORM", "AIFC"): self = try Self.aiff(bytes, container: .aifc)
        default: throw .notAudio
        }
    }

    /// Whether `self`, as stored, is the start of `sent`: the same format, not empty, no longer, and every stored
    /// sample the same. Returns why not, or nil.
    package func mismatch(asStoredFrom sent: PCMAudio) -> String? {
        if format != sent.format { return "it was stored as \(format), not \(sent.format)" }
        if frames == 0 { return "it was stored with no audio" }
        if frames > sent.frames { return "it was stored with \(frames) frames, more than the \(sent.frames) sent" }
        if samples != sent.samples.prefix(samples.count) { return "its stored samples differ from the ones sent" }
        return nil
    }

    // MARK: WAV

    private static func wav(_ bytes: [UInt8]) throws(Problem) -> PCMAudio {
        let chunks = try chunks(bytes, from: 12, bigEndian: false)
        guard let fmt = chunks["fmt "] else { throw .missingChunk("fmt") }
        guard let data = chunks["data"] else { throw .missingChunk("data") }
        guard fmt.count >= 16 else { throw .malformed("fmt chunk") }
        let encoding = UInt16(littleEndian(bytes, fmt.lowerBound, 2))
        guard encoding == WAVFormat.pcm else { throw .notPCM(String(format: "WAV format 0x%04X", encoding)) }
        let format = WAVFormat(encoding: encoding, channels: littleEndian(bytes, fmt.lowerBound + 2, 2),
                               sampleRate: littleEndian(bytes, fmt.lowerBound + 4, 4),
                               bitsPerSample: littleEndian(bytes, fmt.lowerBound + 14, 2))
        guard format.frameBytes > 0, format.bitsPerSample % 8 == 0, data.count % format.frameBytes == 0 else {
            throw .malformed("data chunk")
        }
        return PCMAudio(container: .wav, format: format, samples: Data(bytes[data]))
    }

    // MARK: AIFF and AIFC

    private static func aiff(_ bytes: [UInt8], container: Container) throws(Problem) -> PCMAudio {
        let chunks = try chunks(bytes, from: 12, bigEndian: true)
        guard let comm = chunks["COMM"] else { throw .missingChunk("COMM") }
        guard let ssnd = chunks["SSND"] else { throw .missingChunk("SSND") }
        guard comm.count >= (container == .aifc ? 22 : 18), ssnd.count >= 8 else { throw .malformed("COMM or SSND chunk") }
        let channels = bigEndian(bytes, comm.lowerBound, 2)
        let frames = bigEndian(bytes, comm.lowerBound + 2, 4)
        let bits = bigEndian(bytes, comm.lowerBound + 6, 2)
        guard let rate = extended(Array(bytes[comm.lowerBound + 8..<comm.lowerBound + 18])) else {
            throw .malformed("sample rate")
        }
        var littleEndianSamples = false
        if container == .aifc {
            switch tag(bytes, comm.lowerBound + 18) {
            case "NONE", "twos": break
            case "sowt": littleEndianSamples = true
            case let other: throw .notPCM("AIFC compression “\(other)”")
            }
        }
        let format = WAVFormat(encoding: WAVFormat.pcm, channels: channels, sampleRate: rate, bitsPerSample: bits)
        guard format.frameBytes > 0, bits % 8 == 0 else { throw .malformed("COMM chunk") }
        let start = ssnd.lowerBound + 8 + bigEndian(bytes, ssnd.lowerBound, 4)
        let end = start + frames * format.frameBytes
        guard end <= ssnd.upperBound else { throw .malformed("SSND chunk") }
        var samples = Array(bytes[start..<end])
        if !littleEndianSamples {
            let width = bits / 8
            for offset in stride(from: 0, to: samples.count, by: width) { samples[offset..<offset + width].reverse() }
        }
        return PCMAudio(container: container, format: format, samples: Data(samples))
    }

    /// The AIFC file the OP-1 stores a preset as: `FVER`, `COMM` with `sowt`, an `APPL` chunk holding `op-1` and
    /// `metadata`, and `SSND`. Only the simulator writes these, so the metadata is whatever it's given.
    package func aifcBytes(metadata: Data) -> Data {
        var body = Data("AIFC".utf8)
        func chunk(_ id: String, _ contents: Data) {
            body.append(contentsOf: Array(id.utf8))
            body.appendBigEndian(UInt32(contents.count))
            body.append(contents)
            if contents.count % 2 == 1 { body.append(0) }
        }
        var fver = Data()
        fver.appendBigEndian(UInt32(0xA280_5140))
        chunk("FVER", fver)
        var comm = Data()
        comm.appendBigEndian(UInt16(format.channels))
        comm.appendBigEndian(UInt32(frames))
        comm.appendBigEndian(UInt16(format.bitsPerSample))
        comm.append(contentsOf: Self.extended(format.sampleRate))
        comm.append(contentsOf: Array("sowt".utf8))
        let name = Array("Signed integer (little-endian) linear PCM".utf8)
        comm.append(UInt8(name.count))
        comm.append(contentsOf: name)
        if (name.count + 1) % 2 == 1 { comm.append(0) }
        chunk("COMM", comm)
        chunk("APPL", Data("op-1".utf8) + metadata)
        var ssnd = Data(count: 8)
        ssnd.append(samples)
        chunk("SSND", ssnd)
        var file = Data("FORM".utf8)
        file.appendBigEndian(UInt32(body.count))
        return file + body
    }

    // MARK: Reading chunks

    /// Each chunk's contents by ID, the first of each.
    private static func chunks(_ bytes: [UInt8], from start: Int, bigEndian big: Bool) throws(Problem) -> [String: Range<Int>] {
        var chunks: [String: Range<Int>] = [:]
        var offset = start
        while offset + 8 <= bytes.count {
            let size = big ? bigEndian(bytes, offset + 4, 4) : littleEndian(bytes, offset + 4, 4)
            let contents = offset + 8
            guard contents + size <= bytes.count else { throw .malformed("\(tag(bytes, offset)) chunk size") }
            let id = tag(bytes, offset)
            if chunks[id] == nil { chunks[id] = contents..<contents + size }
            offset = contents + size + size % 2
        }
        return chunks
    }

    private static func tag(_ bytes: [UInt8], _ offset: Int) -> String {
        String(decoding: bytes[offset..<min(offset + 4, bytes.count)], as: UTF8.self)
    }

    private static func littleEndian(_ bytes: [UInt8], _ offset: Int, _ count: Int) -> Int {
        (0..<count).reduce(0) { $0 | Int(bytes[offset + $1]) << (8 * $1) }
    }

    private static func bigEndian(_ bytes: [UInt8], _ offset: Int, _ count: Int) -> Int {
        (0..<count).reduce(0) { $0 << 8 | Int(bytes[offset + $1]) }
    }

    /// A whole-number sample rate from AIFF's 80-bit extended float, or nil if it isn't one.
    private static func extended(_ bytes: [UInt8]) -> Int? {
        let exponent = (Int(bytes[0] & 0x7F) << 8 | Int(bytes[1])) - 16_383
        let mantissa = bytes[2..<10].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard bytes[0] & 0x80 == 0, (0...62).contains(exponent) else { return nil }
        let shift = UInt64(63 - exponent)
        guard mantissa & ((1 << shift) - 1) == 0 else { return nil }
        return Int(mantissa >> shift)
    }

    private static func extended(_ rate: Int) -> [UInt8] {
        let value = UInt64(rate)
        let zeros = value.leadingZeroBitCount
        let exponent = 16_383 + 63 - zeros
        let mantissa = value << UInt64(zeros)
        return [UInt8(exponent >> 8), UInt8(exponent & 0xFF)] + (0..<8).map { UInt8(truncatingIfNeeded: mantissa >> (56 - 8 * $0)) }
    }
}
