import Foundation
import Synchronization
import Testing
@testable import FieldCheckKit
@testable import FieldTapeKit

@Suite struct RequestTraceTests {
    final class Lines: Sendable {
        let lines = Mutex<[String]>([])
        func append(_ line: String) { lines.withLock { $0.append(line) } }
        var all: [String] { lines.withLock { $0 } }
    }

    @Test func keepsOnlyTheLastRequests() async throws {
        let device = FieldDevice.simulated()
        let (count, trace) = await RequestTrace.during(device, limit: 4) {
            (try? await device.contentsOfDirectory(at: "mixdown").count) ?? -1
        }
        #expect(count == 3)
        #expect(trace.all.count == 4 && !trace.sawFailure)
        #expect(trace.all.last?.hasPrefix("← getObjectInfo 0x2001") == true)
        // Tracing stops afterwards.
        _ = try await device.album()
        #expect(trace.all.count == 4)
    }

    @Test func aConnectionsTraceLastsAndTellsEachFailureOnce() async throws {
        let simulator = SimulatedMTPDevice(contents: SimulatedNode.layout173)
        let device = FieldDevice.simulated(simulator, timeout: .milliseconds(100), slowAfter: .milliseconds(50))
        let trace = await RequestTrace.start(on: device, limit: 10)
        _ = try await device.album()
        #expect(trace.all.count == 10 && trace.takeFailure() == nil)
        await simulator.add(faults: [.silent(fromRequest: await simulator.requestCount + 1)])
        _ = try? await device.album()
        let lines = try #require(trace.takeFailure())
        #expect(lines.contains { $0.hasPrefix("✕ getObjectHandles: no answer") })
        #expect(trace.takeFailure() == nil)
    }

    @Test func aLateAnswerIsTraced() async throws {
        let simulator = SimulatedMTPDevice(contents: SimulatedNode.layout173)
        let device = FieldDevice.simulated(simulator, timeout: .milliseconds(100), slowAfter: .milliseconds(500))
        let told = Lines()
        let trace = await RequestTrace.start(on: device) { told.append($0) }
        await simulator.add(faults: [.slowAnswer(request: await simulator.requestCount + 1, after: .milliseconds(300))])
        await #expect(throws: FieldError.self) { _ = try await device.album() }
        try await Task.sleep(for: .milliseconds(400))
        #expect(trace.all.contains { $0.hasPrefix("✕ getObjectHandles: no answer after 0.1 seconds") })
        #expect(trace.all.contains { $0.hasPrefix("← late: getObjectHandles answered after ") && $0.hasSuffix(", and was dropped") })
        #expect(told.all.count == 1 && told.all[0].hasPrefix("← late: getObjectHandles answered after "), "told at once")
    }

    @Test func sawFailureWhenARequestGetsNoAnswer() async throws {
        let simulator = SimulatedMTPDevice(contents: SimulatedNode.layout173)
        let device = FieldDevice.simulated(simulator, timeout: .milliseconds(100), slowAfter: .milliseconds(50))
        await simulator.add(faults: [.silent(fromRequest: await simulator.requestCount + 3)])
        let (_, trace) = await RequestTrace.during(device) { _ = try? await device.album() }
        #expect(trace.sawFailure)
        let failed = try #require(trace.all.firstIndex { $0.hasPrefix("✕ ") })
        #expect(trace.all[failed - 1].hasPrefix("⋯ "), "noted as slow first")
        #expect(trace.all[failed - 2].hasPrefix("→ "), "the request that got no answer is named before that")
    }
}
