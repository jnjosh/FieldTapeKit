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

    package static let v1_7_3 = FirmwareProfile(
        version: FirmwareVersion("1.7.3")!,
        // From the probe's listings (PROBE-NOTES.md, 2026-11-08).
        folders: ["drum", "drum/slots"] + (1...8).map { "drum/slots/\($0)" } + ["drum/user", "mixdown",
                  "synth", "synth/slots"] + (1...8).map { "synth/slots/\($0)" } + ["synth/user", "tapes"],
        allowedNames: [
            "mixdown": ["side_a.wav", "side_b.wav"],
            "tapes/*": ["track_1.wav", "track_2.wav", "track_3.wav", "track_4.wav"],
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
