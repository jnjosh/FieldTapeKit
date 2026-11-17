import System

extension FilePath {
    /// The OP-1's tapes, one folder each.
    public static let op1Tapes: FilePath = "tapes"
    /// The album: `side_a.wav` and `side_b.wav`.
    public static let op1Mixdown: FilePath = "mixdown"
    /// Synth presets.
    public static let op1Synth: FilePath = "synth"
    /// Drum presets.
    public static let op1Drum: FilePath = "drum"
}

/// A file or folder on the OP-1, as a listing found it.
public struct FieldItem: Sendable, Hashable, Identifiable {
    /// Relative to the device root, as the OP-1 spells it. Use it for later calls rather than retyping it.
    public let path: FilePath
    /// The last part of ``path``, as the OP-1 spells it, which is lowercase on firmware 1.7.3.
    public let name: String
    /// Whether it's a folder.
    public let isDirectory: Bool
    /// In bytes, fresh from the OP-1 when this item was listed. Zero for a folder.
    public let size: Int
    /// What kind of file the OP-1 says it is.
    public let format: FieldFormat

    /// The item's ``path``.
    public var id: FilePath { path }

    init(path: FilePath, info: PTPObjectInfo) {
        self.path = path
        name = info.filename
        isDirectory = info.isFolder
        size = info.isFolder ? 0 : Int(info.compressedSize)
        format = FieldFormat(code: info.format, name: info.filename, isFolder: info.isFolder)
    }
}

/// What kind of file an item is, from the format code the OP-1 reports for it rather than its name.
///
/// - Note: A preset in `synth/user/` or `drum/user/` may not be what this says: a WAV sent there is stored as AIFC,
///   keeping its `.wav` name and its WAV format code (`write.preset-converted`).
public enum FieldFormat: Sendable, Hashable {
    /// A folder.
    case folder
    /// A WAV file, MTP format 0x3008: tape tracks and album sides.
    case wav
    /// An AIFF or AIFC file, MTP format 0x3007.
    case aiff
    /// A `.json` file, such as `tape.json`, which the OP-1 reports as text.
    case json
    /// A text file, such as `readme.txt`.
    case text
    /// Any other MTP object format code.
    case other(UInt16)

    init(code: UInt16, name: String, isFolder: Bool) {
        let name = name.lowercased()
        switch code {
        case _ where isFolder: self = .folder
        case 0x3008: self = .wav
        case 0x3007: self = .aiff
        // The OP-1 reports tape.json as Text.
        case PTPObjectFormat.text: self = name.hasSuffix(".json") ? .json : .text
        // And readme.txt as Undefined.
        case PTPObjectFormat.undefined where name.hasSuffix(".txt"): self = .text
        default: self = .other(code)
        }
    }
}
