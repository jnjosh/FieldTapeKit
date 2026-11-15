import Foundation

extension FieldDevice {
    /// An OP-1 that exists only in memory, for tests and SwiftUI previews. It behaves like firmware 1.7.3 at the MTP
    /// level (ADR 0002, section 8).
    ///
    /// It starts as a 1.7.3 OP-1 with no tapes: every folder, the `readme.txt` files, and both album sides empty.
    /// What the builder adds goes into that layout, and replaces a file of the same name:
    ///
    /// ```swift
    /// let device = FieldDevice.simulated {
    ///     Directory("mixdown") { File("side_a.wav", seconds: 69) }
    /// }
    /// ```
    ///
    /// Names are stored lowercase, as the OP-1 stores them.
    public static func simulated(@SimulatedContentsBuilder _ contents: () -> SimulatedContents = { SimulatedContents() })
        -> FieldDevice {
        let layout = SimulatedNode.merge(contents().nodes, into: SimulatedNode.layout173, path: [])
        return simulated(SimulatedMTPDevice(contents: layout))
    }
}

/// What `FieldDevice.simulated { }` builds: folders and files to add to a simulated OP-1.
public struct SimulatedContents: Sendable {
    let nodes: [PendingNode]

    public init() {
        nodes = []
    }

    init(_ nodes: [PendingNode]) {
        self.nodes = nodes
    }
}

/// A folder on a simulated OP-1. One that's already there, such as `mixdown`, gets the contents added to it.
public struct Directory: Sendable {
    let name: String
    let contents: SimulatedContents

    public init(_ name: String, @SimulatedContentsBuilder _ contents: () -> SimulatedContents = { SimulatedContents() }) {
        self.name = name
        self.contents = contents()
    }
}

/// A file on a simulated OP-1.
public struct File: Sendable {
    let name: String
    let content: PendingNode.Content

    /// A file with these bytes.
    public init(_ name: String, data: Data) {
        self.name = name
        content = .data(data)
    }

    /// A WAV file of silence, in the format the OP-1 uses where it's put: 32-bit for a tape track, and 16-bit,
    /// as album sides are, anywhere else.
    public init(_ name: String, seconds: Double) {
        self.name = name
        content = .silence(seconds: seconds)
    }
}

/// A sound tape on a simulated OP-1, in `tapes/`: four tracks of silence, and a `tape.json` as the OP-1 writes one,
/// with a clip from the start to the end of each recorded track. It's not called `Tape`, which is the tape layer's
/// type for a tape that's been listed.
///
/// ```swift
/// let device = FieldDevice.simulated {
///     SimulatedTape("2026-220#02", type: .vintage, seconds: [3, 0, 1.5])
/// }
/// ```
public struct SimulatedTape: Sendable {
    let node: PendingNode

    /// `seconds` gives each track's length in order, up to four; a track left out, or 0, is blank.
    public init(_ name: String, type: TapeType = .studio, seconds: [Double] = []) {
        let format = FirmwareProfile.v1_7_3.trackFormat
        let frames = (0..<4).map { index in index < seconds.count ? Int((seconds[index] * Double(format.sampleRate)).rounded()) : 0 }
        var files: [PendingNode] = frames.enumerated().map { index, count in
            .file("track_\(index + 1).wav", .data(WAVHeader.bytes(format: format, dataBytes: count * format.frameBytes)
                + Data(count: count * format.frameBytes)))
        }
        files.append(.file("tape.json", .data(Self.tapeJSON(type: type, frames: frames))))
        node = .folder("tapes", [.folder(name, files)])
    }

    /// With the keys in the order the OP-1 writes them, and `padding` all -1, as on a tape the OP-1 rebuilt.
    static func tapeJSON(type: TapeType, frames: [Int]) -> Data {
        var id = 0
        var clips: [String] = []
        for (index, count) in frames.enumerated() where count > 0 {
            clips.append(#"{"ch":\#(index),"id":\#(id),"padding":[-1,-1,-1,-1],"start":0,"stop":\#(count)}"#)
            id += 1
        }
        return Data(("{\"clips\":[" + clips.joined(separator: ",") + "],"
            + #""loop":false,"loop_in":0,"loop_out":0,"mixer_params":[1.0,1.0,1.0,1.0,0.0,0.0,0.0,0.0],"pos":0,"#
            + #""tape_type":\#(type.rawValue),"tempobpmdecimal":1200,"tempometronomelevel":0.0,"tempometronometype":0,"#
            + #""temposyncout":1,"temposynctype":0,"track":0,"version":1}"#).utf8)
    }
}

@resultBuilder
public enum SimulatedContentsBuilder {
    public static func buildExpression(_ directory: Directory) -> SimulatedContents {
        SimulatedContents([.folder(directory.name, directory.contents.nodes)])
    }

    public static func buildExpression(_ file: File) -> SimulatedContents {
        SimulatedContents([.file(file.name, file.content)])
    }

    public static func buildExpression(_ tape: SimulatedTape) -> SimulatedContents {
        SimulatedContents([tape.node])
    }

    public static func buildBlock(_ parts: SimulatedContents...) -> SimulatedContents {
        SimulatedContents(parts.flatMap(\.nodes))
    }

    public static func buildArray(_ parts: [SimulatedContents]) -> SimulatedContents {
        SimulatedContents(parts.flatMap(\.nodes))
    }

    public static func buildOptional(_ part: SimulatedContents?) -> SimulatedContents {
        part ?? SimulatedContents()
    }

    public static func buildEither(first part: SimulatedContents) -> SimulatedContents { part }
    public static func buildEither(second part: SimulatedContents) -> SimulatedContents { part }
}

/// A folder or file as the builder describes it, before its audio is made.
enum PendingNode: Sendable {
    enum Content: Sendable {
        case data(Data)
        case silence(seconds: Double)
    }

    case folder(String, [PendingNode])
    case file(String, Content)
}

/// A folder or file laid out on a simulated OP-1.
enum SimulatedNode: Sendable, Equatable {
    case folder(String, [SimulatedNode])
    case file(String, Data, format: UInt16)

    var name: String {
        switch self {
        case .folder(let name, _), .file(let name, _, _): name
        }
    }

    /// `additions` laid into `nodes`, lowercased. A folder merges with one of the same name, and a file replaces
    /// whatever has its name.
    static func merge(_ additions: [PendingNode], into nodes: [SimulatedNode], path: [String]) -> [SimulatedNode] {
        var nodes = nodes
        for addition in additions {
            let made: SimulatedNode
            switch addition {
            case .folder(let name, let children):
                let name = name.lowercased()
                let existing: [SimulatedNode]
                if let index = nodes.firstIndex(where: { $0.name == name }), case .folder(_, let children) = nodes[index] {
                    existing = children
                } else {
                    existing = []
                }
                made = .folder(name, merge(children, into: existing, path: path + [name]))
            case .file(let name, let content):
                let name = name.lowercased()
                made = .file(name, data(for: content, in: path), format: format(of: name))
            }
            if let index = nodes.firstIndex(where: { $0.name == made.name }) {
                nodes[index] = made
            } else {
                nodes.append(made)
            }
        }
        return nodes
    }

    private static func data(for content: PendingNode.Content, in path: [String]) -> Data {
        switch content {
        case .data(let data):
            return data
        case .silence(let seconds):
            let profile = FirmwareProfile.v1_7_3
            let format = path.count == 2 && path[0] == "tapes" ? profile.trackFormat : profile.sideFormat
            let bytes = Int((seconds * Double(format.sampleRate)).rounded()) * format.frameBytes
            return WAVHeader.bytes(format: format, dataBytes: bytes) + Data(count: bytes)
        }
    }

    /// The format codes the OP-1 reports, by name.
    static func format(of name: String) -> UInt16 {
        switch (name as NSString).pathExtension {
        case "wav": PTPObjectFormat.wav
        case "aif", "aiff", "aifc": 0x3007
        case "json": PTPObjectFormat.text
        default: PTPObjectFormat.undefined
        }
    }

    // MARK: 1.7.3

    static let tapeReadme = "this folder accepts 44100 Hz .wav files.\nallowed names: track_1.wav track_2.wav track_3.wav track_4.wav\n"
    static let mixdownReadme = "this folder accepts 44100 Hz .wav files.\nallowed names: side_a.wav side_b.wav\n"
    static let presetReadme = "this folder accepts mono/stereo .aif/.aiff/.aifc/.wav files.\nthe OP-1 sample rate is 44100 Hz.\n"
        + "other sample rates change the maximum sample time.\n\nto keep your sounds in different folders,\n"
        + "create new folders in 'synth' or 'drum'.\n"

    /// An OP-1 on 1.7.3 with no tapes, as the probe and FieldCheck listed one: the folders, the `readme.txt` files
    /// with the texts in `firmware/1.7.3/baseline.json`, and both album sides as empty 44-byte headers.
    static let layout173: [SimulatedNode] = {
        func presets(_ kind: String) -> SimulatedNode {
            .folder(kind, [
                .folder("user", [.file("readme.txt", Data(presetReadme.utf8), format: PTPObjectFormat.undefined)]),
                .folder("slots", (1...8).map { .folder("\($0)", []) }),
                .file("you may create folders here", Data(), format: PTPObjectFormat.undefined),
            ])
        }
        let emptySide = WAVHeader.bytes(format: FirmwareProfile.v1_7_3.sideFormat, dataBytes: 0)
        return [
            presets("synth"),
            presets("drum"),
            .folder("tapes", []),
            .folder("mixdown", [
                .file("side_a.wav", emptySide, format: PTPObjectFormat.wav),
                .file("side_b.wav", emptySide, format: PTPObjectFormat.wav),
                .file("readme.txt", Data(mixdownReadme.utf8), format: PTPObjectFormat.undefined),
            ]),
        ]
    }()
}
