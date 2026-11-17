import Foundation

/// The tape machine a tape uses, its `tape_type` (`tape.types`).
///
/// It's not an enum, because a later firmware may add a type. Vintage (1) and Disk Mini (3) are confirmed on the
/// OP-1; Studio (0) and Porta (2) follow the order the OP-1 lists them in (PROBE-NOTES.md, 2026-11-08).
public struct TapeType: Sendable, Hashable, RawRepresentable, CustomStringConvertible {
    /// The value of `tape_type` in `tape.json`.
    public let rawValue: Int

    /// Creates a type from its `tape_type` value, including one this firmware profile doesn't know.
    ///
    /// - Parameter rawValue: The value of `tape_type`.
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Studio, `tape_type` 0: the default for a new tape.
    public static let studio = TapeType(rawValue: 0)
    /// Vintage, `tape_type` 1.
    public static let vintage = TapeType(rawValue: 1)
    /// Porta, `tape_type` 2.
    public static let porta = TapeType(rawValue: 2)
    /// Disk Mini, `tape_type` 3.
    public static let diskMini = TapeType(rawValue: 3)

    /// As the OP-1 names it, or "Type N" for one this firmware profile doesn't know.
    public var description: String {
        switch rawValue {
        case 0: "Studio"
        case 1: "Vintage"
        case 2: "Porta"
        case 3: "Disk Mini"
        default: "Type \(rawValue)"
        }
    }
}

/// A tape's `tape.json`, with nothing dropped (ADR 0002, section 4).
///
/// The typed properties are the fields the probe decoded. ``data`` is the file exactly as it was read, and it's what
/// FieldTapeKit writes back, so `padding` and any key it doesn't understand go back untouched. Editing a manifest is
/// out of scope.
public struct TapeManifest: Sendable, Hashable {
    /// A region of audio on one track.
    public struct Clip: Sendable, Hashable {
        /// The OP-1's clip number. An identifier, not an index: numbers can be skipped.
        public let id: Int
        /// 1 to 4. `tape.json` stores it 0-based, as `ch`.
        public let track: Int
        /// Frames at 44.1 kHz, from the start of the track.
        public let start: Int
        /// Frames at 44.1 kHz, from the start of the track, where the clip ends. `tape.json` stores it as `stop`.
        public let end: Int
    }

    /// The loop, in frames.
    public struct Loop: Sendable, Hashable {
        /// Whether looping is on, `loop` in `tape.json`.
        public let isOn: Bool
        /// Where the loop starts, `loop_in`.
        public let start: Int
        /// Where the loop ends, `loop_out`.
        public let end: Int
    }

    /// The file as it was read, byte for byte.
    public let data: Data
    /// Every clip, on every track, in the order `tape.json` lists them.
    public let clips: [Clip]
    /// The loop points.
    public let loop: Loop
    /// Beats per minute. `tape.json` stores ten times this, as `tempobpmdecimal`.
    public let tempo: Double
    /// `mixer_params`, as stored: eight numbers, probably the four tracks' levels and then their pans. That's
    /// unconfirmed, so they're given as they are.
    public let mixerParameters: [Double]
    /// The tape machine, `tape_type`.
    public let type: TapeType

    /// Why `tape.json` couldn't be read as a manifest.
    public struct Problem: Error, Sendable, Hashable, CustomStringConvertible {
        /// What's wrong, such as which key is missing.
        public let description: String
    }

    /// Reads a `tape.json`.
    ///
    /// - Parameter data: The file's bytes, which are kept exactly as they are.
    /// - Throws: `Problem` if it isn't a JSON object with the keys the typed properties come from.
    public init(_ data: Data) throws(Problem) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Problem(description: "tape.json isn't a JSON object")
        }
        func int(_ key: String, in object: [String: Any] = root) throws(Problem) -> Int {
            guard let number = object[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let value = Int(exactly: number.doubleValue) else {
                throw Problem(description: "tape.json's \(key) isn't a whole number")
            }
            return value
        }
        guard let clips = root["clips"] as? [[String: Any]] else { throw Problem(description: "tape.json has no clips list") }
        var parsed: [Clip] = []
        for clip in clips {
            parsed.append(Clip(id: try int("id", in: clip), track: try int("ch", in: clip) + 1,
                               start: try int("start", in: clip), end: try int("stop", in: clip)))
        }
        // A JSON number would bridge to Bool too, so the type is checked.
        guard let loop = root["loop"] as? NSNumber, CFGetTypeID(loop) == CFBooleanGetTypeID() else {
            throw Problem(description: "tape.json's loop isn't true or false")
        }
        guard let mixer = root["mixer_params"] as? [NSNumber] else {
            throw Problem(description: "tape.json's mixer_params isn't a list of numbers")
        }
        self.data = data
        self.clips = parsed
        self.loop = Loop(isOn: loop.boolValue, start: try int("loop_in"), end: try int("loop_out"))
        tempo = Double(try int("tempobpmdecimal")) / 10
        mixerParameters = mixer.map(\.doubleValue)
        type = TapeType(rawValue: try int("tape_type"))
    }

    /// The last frame any clip reaches, or 0 with no clips.
    public var endFrame: Int {
        clips.map(\.end).max() ?? 0
    }
}

extension TapeManifest {
    /// The `tape.json` of a new, empty tape of `type`: the blank Disk Mini tape the probe read (2026-312#01), with
    /// the keys in the order the OP-1 writes them, and only `tape_type` changed.
    static func blankData(type: TapeType) -> Data {
        Data((#"{"clips":[],"loop":false,"loop_in":0,"loop_out":0,"mixer_params":[1.0,1.0,1.0,1.0,0.0,0.0,0.0,0.0],"#
            + #""pos":0,"tape_type":\#(type.rawValue),"tempobpmdecimal":1200,"tempometronomelevel":0.0,"#
            + #""tempometronometype":0,"temposyncout":1,"temposynctype":0,"track":0,"version":1}"#).utf8)
    }
}
