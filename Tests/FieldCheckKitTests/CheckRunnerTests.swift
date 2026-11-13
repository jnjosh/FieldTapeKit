@testable import FieldTapeKit
import Foundation
import Testing
@testable import FieldCheckKit

@Suite struct CheckRunnerTests {
    struct Unreadable: Error {}

    @Test func runsEveryCheckInOrder() async {
        let results = await CheckRunner.run([
            Check("device.operations") { .pass("21 operations", observed: [0x1001, 0x1002]) },
            Check("device.storage") { .fail("No storage") },
            Check("names.lowercase") { .notRun("Nothing to look at") },
        ])
        #expect(results == [
            CheckResult(expectation: "device.operations", outcome: .pass, summary: "21 operations",
                        observed: [0x1001, 0x1002]),
            CheckResult(expectation: "device.storage", outcome: .fail, summary: "No storage"),
            CheckResult(expectation: "names.lowercase", outcome: .notRun, summary: "Nothing to look at"),
        ])
    }

    @Test func aCheckThatThrowsFailsAndTheRunGoesOn() async {
        let results = await CheckRunner.run([
            Check("device.storage") { throw FieldError.wrapping(Unreadable()) },
            Check("device.operations") { throw Unreadable() },
            Check("names.lowercase") { .pass("All lowercase") },
        ])
        #expect(results.map(\.outcome) == [.fail, .fail, .pass])
        #expect(results[0].summary == "Couldn't check: The OP-1 sent a reply that couldn't be read.")
        #expect(results[1].summary.hasPrefix("Couldn't check: "))
    }

    @Test func aDisconnectFailsThatCheckAndSkipsTheRest() async {
        let results = await CheckRunner.run([
            Check("device.operations") { .pass("Fine") },
            Check("device.storage") { throw FieldError(.disconnected) },
            Check("names.lowercase") { Issue.record("ran after a disconnect"); return .pass("") },
        ])
        #expect(results.map(\.outcome) == [.pass, .fail, .notRun])
        #expect(results[1].summary == "The OP-1 disconnected during this check.")
        #expect(results[2].summary == "The OP-1 disconnected.")
    }

    @Test func cancellingSkipsTheRest() async {
        let task = Task {
            await CheckRunner.run([
                Check("device.operations") { .pass("Fine") },
                Check("device.storage") {
                    withUnsafeCurrentTask { $0?.cancel() }
                    throw CancellationError()
                },
                Check("names.lowercase") { Issue.record("ran after cancelling"); return .pass("") },
            ])
        }
        let results = await task.value
        #expect(results.map(\.outcome) == [.pass, .notRun, .notRun])
        #expect(results.dropFirst().allSatisfy { $0.summary == "The run was cancelled." })
    }

    @Test func aCancelledRunStillReportsEveryCheck() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await CheckRunner.run([
                Check("device.operations") { Issue.record("ran after cancelling"); return .pass("") },
                Check("device.storage") { Issue.record("ran after cancelling"); return .pass("") },
            ])
        }
        let results = await task.value
        #expect(results.map(\.expectation) == ["device.operations", "device.storage"])
        #expect(results.allSatisfy { $0.outcome == .notRun })
    }
}
