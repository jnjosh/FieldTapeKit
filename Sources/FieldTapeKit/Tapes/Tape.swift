import Foundation
import System

/// A tape on the OP-1: its folder in `tapes/`, its four tracks and its `tape.json`, as read when it was listed
/// (ADR 0002, section 4). It's a snapshot: list again to see a change.
///
/// Every folder in `tapes/` is listed as a tape, so a slot is never hidden. One that isn't sound, with `tape.json`
/// missing or unreadable, a track missing, or track sizes that don't match its clips, says why in `problems`.
public struct Tape: Sendable, Identifiable, Hashable {
    public let name: TapeName
    /// `tapes/<name>`.
    public let path: FilePath
    /// The tracks there are, in order: all four on a sound tape, blank ones included.
    public let tracks: [TapeTrack]
    /// Nil if `tape.json` is missing or can't be read, which `problems` says.
    public let manifest: TapeManifest?
    /// Why the tape isn't sound, or none: missing or unexpected files, an unreadable `tape.json`, or tracks that
    /// don't match its clips (`tape.files`, `tape.json-units`).
    public let problems: [String]

    public var id: TapeName { name }

    /// The tape machine it uses, or nil without a readable `tape.json`.
    public var type: TapeType? { manifest?.type }

    /// To the end of the last clip, or of the longest track without a readable `tape.json`. At most 6 minutes.
    public var duration: Duration {
        let frames = manifest?.endFrame ?? tracks.map(\.frames).max() ?? 0
        return Tape.duration(frames: frames)
    }

    /// Every track blank and no clips.
    public var isEmpty: Bool {
        tracks.allSatisfy(\.isBlank) && (manifest?.clips.isEmpty ?? true)
    }

    /// The numbers, 1 to 4, of the tracks with audio.
    public var recordedTracks: [Int] {
        tracks.filter { !$0.isBlank }.map(\.number)
    }

    /// Nothing missing, nothing unexpected, and the tracks match the clips.
    public var isSound: Bool { problems.isEmpty }

    static func duration(frames: Int) -> Duration {
        .milliseconds(Int64(frames) * 1_000 / Int64(FirmwareProfile.v1_7_3.trackFormat.sampleRate))
    }
}

/// One of a tape's four tracks: `track_1.wav` to `track_4.wav`, 32-bit stereo at 44.1 kHz (`tape.wav-format`).
public struct TapeTrack: Sendable, Hashable {
    /// 1 to 4.
    public let number: Int
    public let path: FilePath
    /// As listed, header included.
    public let size: Int

    /// Only the 44-byte header.
    public var isBlank: Bool { size <= WAVHeader.size }

    /// Frames of audio, from frame 0 to the end of the last clip, gaps included.
    public var frames: Int { max(size - WAVHeader.size, 0) / FirmwareProfile.v1_7_3.trackFormat.frameBytes }

    public var duration: Duration { Tape.duration(frames: frames) }
}

/// How many of the OP-1's tape slots are used.
public struct TapeSlots: Sendable, Hashable {
    /// Folders in `tapes/`, sound or not.
    public let used: Int
    /// 8 on 1.7.3.
    public let limit: Int

    public var available: Int { max(limit - used, 0) }
}
