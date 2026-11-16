import Foundation
import System

/// The OP-1's album: `mixdown/side_a.wav` and `mixdown/side_b.wav`, as read when it was listed (ADR 0002, section 5).
/// It's a snapshot: list again to see a change.
public struct Album: Sendable, Hashable {
    /// Side A or B. A new case would break an app's exhaustive `switch`, so it needs a major version.
    public enum Side: String, Sendable, Hashable, CaseIterable, Codable, CustomStringConvertible {
        case a, b

        /// `side_a.wav` or `side_b.wav`.
        var fileName: String { "side_\(rawValue).wav" }

        /// "Side A" or "Side B".
        public var description: String { "Side \(rawValue.uppercased())" }
    }

    public let a: AlbumSide
    public let b: AlbumSide

    public subscript(side: Side) -> AlbumSide {
        switch side {
        case .a: a
        case .b: b
        }
    }

    /// Both sides, A first.
    public var sides: [AlbumSide] { [a, b] }
}

/// One side of the album, as listed: its size, and the format its WAV header states.
///
/// A side that isn't sound, with its file missing, a header that can't be read or doesn't match the file's size, or
/// another format than the OP-1 records (`album.files`, `album.wav-format`), says why in `problems`. It's listed
/// anyway, and can't be copied.
public struct AlbumSide: Sendable, Hashable {
    public let side: Album.Side
    /// `mixdown/side_a.wav` or `mixdown/side_b.wav`.
    public let path: FilePath
    /// As listed, header included. Zero if the file is missing.
    public let size: Int
    /// From the WAV header, or nil if it can't be read, which `problems` says.
    public let format: AudioFormat?
    /// Why the side isn't sound, or none.
    public let problems: [String]

    /// Only the 44-byte header, or nothing at all.
    public var isEmpty: Bool { size <= WAVHeader.size }

    /// The file is there, its header reads and matches its size, and it's in the format the OP-1 records.
    public var isSound: Bool { problems.isEmpty }

    /// The audio after the header, in the header's format, or the OP-1's if that can't be read.
    public var duration: Duration {
        let format = format?.wav ?? FirmwareProfile.v1_7_3.sideFormat
        guard format.frameBytes > 0, format.sampleRate > 0 else { return .zero }
        let frames = max(size - WAVHeader.size, 0) / format.frameBytes
        return .milliseconds(Int64(frames) * 1_000 / Int64(format.sampleRate))
    }
}

/// The audio format a WAV header states.
public struct AudioFormat: Sendable, Hashable, CustomStringConvertible {
    let wav: WAVFormat

    package init(_ wav: WAVFormat) { self.wav = wav }

    /// Integer PCM, as the OP-1 records.
    public var isPCM: Bool { wav.encoding == WAVFormat.pcm }
    public var sampleRate: Int { wav.sampleRate }
    public var bitDepth: Int { wav.bitsPerSample }
    public var channels: Int { wav.channels }

    /// Such as "PCM, 2 channels, 16 bits, 44100 Hz".
    public var description: String { wav.description }
}

/// A side copied off the OP-1 into a WAV file, and what it held: an app can store it, and later ask
/// `side(_:matches:)` whether the side was recorded over since.
public struct AlbumSideCopy: Sendable, Hashable, Codable {
    /// The side it was copied from.
    public let side: Album.Side
    /// The WAV file, such as `Side A 2026-11-16.wav`. Moving the file doesn't update this.
    public let url: URL
    /// In bytes, header included.
    public let size: Int
    /// The SHA-256 of the file, in lowercase hex.
    public let sha256: String
    public let copiedAt: Date
}
