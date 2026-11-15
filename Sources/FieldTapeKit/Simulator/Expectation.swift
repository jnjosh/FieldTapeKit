/// One OP-1 behavior FieldTapeKit relies on (ADR 0003, section 1).
///
/// The same IDs are used by FieldCheck's checks, the simulator's tests and the baselines, so a check that comes
/// back different points at the code that relies on it. IDs are stable: renaming one breaks every baseline that
/// recorded it. A new expectation is added when FieldTapeKit starts relying on something new, and removing one
/// needs a note on why.
package struct Expectation: Sendable, Hashable, Identifiable {
    package let id: String
    /// What the OP-1 is expected to do, as observed on 1.7.3.
    package let summary: String
    /// What in FieldTapeKit relies on it.
    package let usedBy: String

    package static subscript(id id: String) -> Expectation? {
        all.first { $0.id == id }
    }

    /// Every expectation, in ADR 0003's order.
    package static let all: [Expectation] = [
        Expectation("device.operations",
                    "The 21 operations logged on 1.7.3: 16 standard ones and 0x9801–0x9805. No MoveObject or CopyObject.",
                    usedBy: "Replace is delete-then-send; duplicate copies through memory"),
        Expectation("device.storage",
                    "One storage, 0x00010001. GetStorageInfo answers, and its free space falls by about the size of "
                        + "what level 2 writes, and rises again after cleanup.",
                    usedBy: "Device info; free-space checks once the figure is trusted (ADR 0002, section 1)"),
        Expectation("device.identity",
                    "USB vendor 0x2367, MTP product 0x0102, the name \"OP-1\".",
                    usedBy: "FieldDevice.connections filter"),
        Expectation("session.implicit",
                    "ImageCaptureCore's session is enough; no OpenSession.",
                    usedBy: "Transport"),
        Expectation("session.data-phase",
                    "Data arrives without the 12-byte container header.",
                    usedBy: "PTP parsing"),
        Expectation("layout.folders",
                    "tapes/, mixdown/, synth/, drum/ exist, with the subfolders seen on 1.7.3.",
                    usedBy: "FilePath well-known locations, safety rule 4"),
        Expectation("layout.readmes",
                    "The text of every readme.txt matches the baseline.",
                    usedBy: "Folder rules"),
        Expectation("names.lowercase",
                    "Names on the device are stored lowercase.",
                    usedBy: "Case-insensitive paths, TapeName"),
        Expectation("names.maximum",
                    "A new tape with a 15-character name, using every kind of allowed character, is accepted over MTP "
                        + "and kept after a reconnect.",
                    usedBy: "TapeName.maximumLength"),
        Expectation("tape.files",
                    "Each tape has tape.json, track_1–4.wav, and maybe readme.txt. Nothing else.",
                    usedBy: "Tape"),
        Expectation("tape.wav-format",
                    "Tracks are 44-byte-header PCM WAV: 2 channels, 32 bits, 44.1 kHz.",
                    usedBy: "Track sizes, consistency check"),
        Expectation("album.files",
                    "mixdown/ holds exactly side_a.wav and side_b.wav, and an empty side is the 44-byte header.",
                    usedBy: "Album, AlbumSide.isEmpty"),
        Expectation("album.wav-format",
                    "Sides are PCM WAV, 2 channels, 16 bits, 44.1 kHz.",
                    usedBy: "AlbumSide.format, the restore format check"),
        Expectation("album.write-exact",
                    "A side written back reads back byte for byte.",
                    usedBy: "restoreSide"),
        Expectation("album.write-other-format",
                    "What the OP-1 does with a side written in another format, such as 32-bit. Not yet known.",
                    usedBy: "The restore format check"),
        Expectation("tape.json-keys",
                    "tape.json has exactly the known keys and versions. Unknown keys are reported.",
                    usedBy: "TapeManifest"),
        Expectation("tape.json-units",
                    "Every track is 44 + 8 × last clip end bytes; ch is 0-based.",
                    usedBy: "Consistency check"),
        Expectation("tape.types",
                    "tape_type values are 0–3.",
                    usedBy: "TapeType"),
        Expectation("tape.track-limit",
                    "A full 6-minute track of 127,008,044 bytes can be written and read back. Runs only when asked.",
                    usedBy: "tapeTooLong, upload memory use"),
        Expectation("read.partial",
                    "GetPartialObject works at any offset with chunks up to 1 MiB.",
                    usedBy: "contents(of:range:), WAV header reads"),
        Expectation("read.speed",
                    "Reads at about 20 MB/s. A big drop is reported, not failed.",
                    usedBy: "Timeouts, progress estimates"),
        Expectation("write.speed",
                    "Writes at about 7 MB/s, timed apart from the read-back. A big drop is reported, not failed. "
                        + "Split from read.speed on 2026-11-15, since only level 2 writes.",
                    usedBy: "Timeouts, progress estimates"),
        Expectation("read.cost",
                    "What a GetPartialObject's time grows with: its offset, or the number of reads before it. On 1.7.3 "
                        + "it's the offset: a read costs about what reading from the file's start to its end would (2026-11-14).",
                    usedBy: "Whole files read with one GetObject (ADR 0002, 2026-11-14)"),
        Expectation("write.folder",
                    "A tape folder can be made with SendObjectInfo alone (format 0x3001, association type 1).",
                    usedBy: "createTape, restoreTape"),
        Expectation("write.exact",
                    "Tracks and tape.json written to a tape read back byte for byte.",
                    usedBy: "Read-back verification"),
        Expectation("write.refused-name",
                    "A name a folder doesn't allow (track_5.wav) is refused with 0x2002.",
                    usedBy: "Folder rules"),
        Expectation("write.preset-converted",
                    "Audio written to drum/user/ or synth/user/ comes back as AIFC under the same name, in the same "
                        + "format, with the same samples as the start of what was sent (cut to 20 s in drum/user/ and 6 s in synth/user/). The format code stays the one it was sent with.",
                    usedBy: "Preset writes: the read-back checks the audio"),
        Expectation("rebuild.tape-json",
                    "After a track write, the OP-1 rebuilds tape.json (one clip per track).",
                    usedBy: "Restore order: tracks first, tape.json last"),
        Expectation("rebuild.stale-size",
                    "Within the session, the rebuilt tape.json still lists, and reads, at its old size.",
                    usedBy: "Fresh info before every read"),
        Expectation("delete.files-then-folder",
                    "Deleting a tape's files, then its folder, removes it.",
                    usedBy: "deleteTape, moveTape"),
        Expectation("delete.folder-with-files",
                    "What one DeleteObject on a folder with files in it does. Not yet known.",
                    usedBy: "Could simplify deleteTape"),
        Expectation("reconnect.kept",
                    "After leaving MTP mode, a written tape and its tape.json are kept, apart from pos.",
                    usedBy: "Restore"),
        Expectation("reconnect.renamed",
                    "After reconnecting, a created tape's name is lowercase and readme.txt has been added.",
                    usedBy: "TapeName, Tape"),
        Expectation("reconnect.handles",
                    "Object handles change after reconnecting.",
                    usedBy: "Handles stay private"),
    ]

    private init(_ id: String, _ summary: String, usedBy: String) {
        self.id = id
        self.summary = summary
        self.usedBy = usedBy
    }
}
