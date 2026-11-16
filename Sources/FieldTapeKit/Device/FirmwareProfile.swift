/// What's known about one OP-1 firmware, from its FieldCheck baseline (ADR 0002, section 11).
///
/// It's the single place for behavior that can differ between firmwares. Later steps add their constants here,
/// so supporting a second firmware means adding a profile, not a refactor.
package struct FirmwareProfile: Sendable, Equatable {
    package let version: FirmwareVersion
    /// The folders that exist on every OP-1 with this firmware, relative to the root and lowercase
    /// (`layout.folders`). Tapes, and folders people make in `synth/` and `drum/`, aren't listed.
    package let folders: [String]
    /// The names the `readme.txt` in each kind of folder allows (`layout.readmes`). `tapes/*` stands for every
    /// tape folder.
    package let allowedNames: [String: [String]]
    /// Files the OP-1 puts in its folders itself, which FieldTapeKit never deletes on their own. They go with a tape
    /// folder when it's deleted.
    package let ownFiles: [String]
    /// What each tape folder holds (`tape.files`).
    package let tapeFiles: FolderFiles
    /// What `mixdown/` holds (`album.files`).
    package let albumFiles: FolderFiles
    /// What `tape.json` looks like (`tape.json-keys`, `tape.types`).
    package let tapeJSON: TapeJSONShape
    /// Tape tracks (`tape.wav-format`).
    package let trackFormat: WAVFormat
    /// Album sides (`album.wav-format`).
    package let sideFormat: WAVFormat
    /// The longest a tape can be, in frames: 6 minutes at 44.1 kHz.
    package let maximumTapeFrames: Int
    /// The longest album side FieldTapeKit sends, in frames. The OP-1's own limit isn't known
    /// (`album.side-limit`), so it's the tape's 6 minutes until FieldCheck finds it.
    package let maximumSideFrames: Int
    /// Whether FieldTapeKit writes album sides on this firmware. Not on 1.7.3: a side written over MTP, once the OP-1
    /// has left MTP mode, hangs the OP-1 when it's written again, until it's restarted (`album.write-again`). Until
    /// that's understood, album writing is off, and only reading and copying the album work.
    package let albumWrites: Bool
    /// How many tapes the OP-1 holds.
    package let maximumTapes: Int
    /// The longest tape name the OP-1 keeps. A longer one is accepted over MTP, then cut to this length once the
    /// OP-1 leaves MTP mode (`names.maximum`).
    package let maximumTapeNameLength: Int
    /// The folders that take presets and convert what they receive (`write.preset-converted`).
    package let presetFolders: [String]
    /// The extensions a preset's name may have, from the folders' `readme.txt`.
    package let presetExtensions: Set<String>
    /// The audio FieldTapeKit sends as a preset: what the OP-1 has been seen to keep sample for sample.
    package let presetFormats: [WAVFormat]

    package static let v1_7_3 = FirmwareProfile(
        version: FirmwareVersion("1.7.3")!,
        // From the probe's listings (PROBE-NOTES.md, 2026-11-08).
        folders: ["drum", "drum/slots"] + (1...8).map { "drum/slots/\($0)" } + ["drum/user", "mixdown",
                  "synth", "synth/slots"] + (1...8).map { "synth/slots/\($0)" } + ["synth/user", "tapes"],
        allowedNames: [
            "mixdown": ["side_a.wav", "side_b.wav"],
            "tapes/*": ["track_1.wav", "track_2.wav", "track_3.wav", "track_4.wav"],
        ],
        ownFiles: ["readme.txt", "you may create folders here"],
        tapeFiles: FolderFiles(required: ["tape.json", "track_1.wav", "track_2.wav", "track_3.wav", "track_4.wav"],
                               optional: ["readme.txt"]),
        albumFiles: FolderFiles(required: ["side_a.wav", "side_b.wav"], optional: ["readme.txt"]),
        // From every tape.json the probe read (PROBE-NOTES.md, `tape.json` format, 2026-11-08).
        tapeJSON: TapeJSONShape(
            keys: ["clips", "loop", "loop_in", "loop_out", "mixer_params", "pos", "tape_type", "tempobpmdecimal",
                   "tempometronomelevel", "tempometronometype", "temposyncout", "temposynctype", "track", "version"],
            clipKeys: ["ch", "id", "padding", "start", "stop"],
            versions: [1],
            tapeTypes: 0...3),
        trackFormat: WAVFormat(encoding: WAVFormat.pcm, channels: 2, sampleRate: 44_100, bitsPerSample: 32),
        sideFormat: WAVFormat(encoding: WAVFormat.pcm, channels: 2, sampleRate: 44_100, bitsPerSample: 16),
        maximumTapeFrames: 6 * 60 * 44_100,
        maximumSideFrames: 6 * 60 * 44_100,
        // Four side writes hung the OP-1 on 2026-11-16, each over a side written over MTP before a reconnect
        // (PROBE-NOTES.md). Album writing is a future improvement, decided by the owner.
        albumWrites: false,
        maximumTapes: 8,
        // FieldCheck's 15-character scratch tape came back cut to 12 after a reconnect (PROBE-NOTES.md, 2026-11-15).
        maximumTapeNameLength: 12,
        presetFolders: ["synth/user", "drum/user"],
        presetExtensions: ["aif", "aiff", "aifc", "wav"],
        // 44.1 kHz stereo from the probe's WAV write, 22,050 Hz mono from the OP-1's own preset applefly.aif
        // (PROBE-NOTES.md, 2026-11-03 and 2026-11-05). 44.1 kHz mono is what the readme states.
        presetFormats: [
            WAVFormat(encoding: WAVFormat.pcm, channels: 1, sampleRate: 44_100, bitsPerSample: 16),
            WAVFormat(encoding: WAVFormat.pcm, channels: 2, sampleRate: 44_100, bitsPerSample: 16),
            WAVFormat(encoding: WAVFormat.pcm, channels: 1, sampleRate: 22_050, bitsPerSample: 16),
        ])

    /// Every firmware this release has a baseline for, oldest first.
    static let tested: [FirmwareProfile] = [.v1_7_3]

    /// The profile for a firmware, and whether it's tested. An untested firmware uses the newest tested one
    /// older than it, or the oldest if it's older than all of them. A version that can't be read uses the newest,
    /// since a firmware FieldTapeKit hasn't seen is most likely a newer one.
    static func profile(for firmware: String) -> (profile: FirmwareProfile, isTested: Bool) {
        guard let version = FirmwareVersion(firmware) else { return (tested.last!, false) }
        if let exact = tested.first(where: { $0.version == version }) { return (exact, true) }
        return (tested.last(where: { $0.version < version }) ?? tested.first!, false)
    }
}

/// A firmware version such as "1.7.3", compared number by number, so 1.10 is newer than 1.9.
package struct FirmwareVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    let components: [Int]

    package init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        components = parts.map { $0! }
    }

    package var description: String { components.map(String.init).joined(separator: ".") }

    package static func == (lhs: Self, rhs: Self) -> Bool { lhs.padded(to: rhs) == rhs.padded(to: lhs) }

    package func hash(into hasher: inout Hasher) {
        var trimmed = components
        while trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }

    package static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.padded(to: rhs).lexicographicallyPrecedes(rhs.padded(to: lhs))
    }

    /// 1.7 and 1.7.0 are the same version.
    private func padded(to other: Self) -> [Int] {
        components + Array(repeating: 0, count: max(0, other.components.count - components.count))
    }
}

/// The files a kind of folder holds: every required one, and maybe the optional ones. Nothing else.
package struct FolderFiles: Sendable, Equatable {
    package let required: [String]
    package let optional: [String]
}

/// The keys and values `tape.json` has on one firmware.
package struct TapeJSONShape: Sendable, Equatable {
    package let keys: Set<String>
    /// The keys of each entry in `clips`.
    package let clipKeys: Set<String>
    package let versions: Set<Int>
    package let tapeTypes: ClosedRange<Int>
}
