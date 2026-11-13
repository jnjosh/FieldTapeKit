import Foundation

/// Checks a tape's `tape.json` against its track sizes, carried over from the probe (`tape.json-units`).
///
/// Each clip's `ch` names a track, 0-based, and each track is a 44-byte header plus one frame per sample up to
/// the end of its last clip, gaps included. The tape layer reuses this in step 13 of the plan.
package enum TapeConsistency {
    /// The problems found, or none. `trackSizes` is keyed by file name, such as `track_1.wav`.
    package static func problems(json: Data, trackSizes: [String: Int], profile: FirmwareProfile = .v1_7_3) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let clips = root["clips"] as? [[String: Any]] else { return ["tape.json has no clips array"] }
        let frameBytes = profile.trackFormat.frameBytes
        let tracks = profile.tapeFiles.required.filter { $0.hasPrefix("track_") }.count
        var lastFrame: [Int: Int] = [:]
        var problems: [String] = []
        for clip in clips {
            guard let ch = clip["ch"] as? Int, let start = clip["start"] as? Int, let stop = clip["stop"] as? Int else {
                problems.append("clip missing ch, start or stop: \(clip)")
                continue
            }
            if !(0..<tracks).contains(ch) { problems.append("clip on unknown track ch \(ch)") }
            if stop < start || start < 0 { problems.append("clip on ch \(ch) runs \(start) to \(stop)") }
            if stop > profile.maximumTapeFrames {
                problems.append("clip on ch \(ch) ends past 6 minutes, at frame \(stop)")
            }
            lastFrame[ch] = max(lastFrame[ch] ?? 0, max(stop, 0))
        }
        for ch in 0..<tracks {
            let name = "track_\(ch + 1).wav"
            guard let size = trackSizes[name] else {
                problems.append("\(name) missing")
                continue
            }
            let expected = WAVHeader.size + frameBytes * (lastFrame[ch] ?? 0)
            if size != expected { problems.append("\(name) is \(size) bytes, clips imply \(expected)") }
        }
        return problems
    }
}
