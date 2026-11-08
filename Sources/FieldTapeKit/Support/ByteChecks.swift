import Foundation

extension Data {
    /// How many byte positions differ from `other`, counting any difference in length, and where the first one is.
    /// Used to report a read-back that didn't match.
    func differences(from other: Data) -> (count: Int, firstOffset: Int?) {
        var count = 0
        var firstOffset: Int?
        for (offset, (mine, theirs)) in zip(self, other).enumerated() where mine != theirs {
            count += 1
            if firstOffset == nil { firstOffset = offset }
        }
        if self.count != other.count { firstOffset = firstOffset ?? Swift.min(self.count, other.count) }
        return (count + abs(self.count - other.count), firstOffset)
    }
}

enum WAV {
    /// A tape track or album side with no audio is just the 44-byte RIFF header.
    static let headerSize = 44

    static func isHeaderOnly(_ data: Data) -> Bool {
        data.count == headerSize && data.starts(with: Array("RIFF".utf8))
    }
}
