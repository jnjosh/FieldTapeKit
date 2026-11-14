import Testing
@testable import FieldTapeKit

@Suite struct ExpectationTests {
    /// ADR 0003's list, with `read.cost` added on 2026-11-14. IDs are stable, so a rename or removal here must be deliberate.
    static let adr0003 = [
        "device.operations", "device.storage", "device.identity", "session.implicit", "session.data-phase",
        "layout.folders", "layout.readmes", "names.lowercase", "names.maximum", "tape.files", "tape.wav-format",
        "album.files", "album.wav-format", "album.write-exact", "album.write-other-format", "tape.json-keys",
        "tape.json-units", "tape.types", "tape.track-limit", "read.partial", "read.speed", "read.cost", "write.folder",
        "write.exact", "write.refused-name", "write.preset-converted", "rebuild.tape-json", "rebuild.stale-size",
        "delete.files-then-folder", "delete.folder-with-files", "reconnect.kept", "reconnect.renamed",
        "reconnect.handles",
    ]

    @Test func matchesADR0003() {
        #expect(Expectation.all.map(\.id) == Self.adr0003)
    }

    @Test func everyEntrySaysWhatItIsAndWhatUsesIt() {
        for expectation in Expectation.all {
            #expect(!expectation.summary.isEmpty, "\(expectation.id)")
            #expect(!expectation.usedBy.isEmpty, "\(expectation.id)")
        }
    }

    @Test func idsAreUniqueAndShapedAlike() {
        let ids = Expectation.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for id in ids {
            #expect(id.wholeMatch(of: /[a-z]+\.[a-z0-9-]+/) != nil, "\(id)")
        }
    }

    @Test func lookup() {
        #expect(Expectation[id: "names.lowercase"]?.usedBy == "Case-insensitive paths, TapeName")
        #expect(Expectation[id: "names.uppercase"] == nil)
    }
}
