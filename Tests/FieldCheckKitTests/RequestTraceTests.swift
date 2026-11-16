import Foundation
import Testing
@testable import FieldCheckKit
@testable import FieldTapeKit

@Suite struct RequestTraceTests {
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

    @Test func sawFailureWhenARequestGetsNoAnswer() async throws {
        let simulator = SimulatedMTPDevice(contents: SimulatedNode.layout173)
        let device = FieldDevice.simulated(simulator, timeout: .milliseconds(100), pingTimeout: .milliseconds(50))
        await simulator.add(faults: [.silent(fromRequest: await simulator.requestCount + 3)])
        let (_, trace) = await RequestTrace.during(device) { _ = try? await device.album() }
        #expect(trace.sawFailure)
        let failed = try #require(trace.all.firstIndex { $0.hasPrefix("✕ ") })
        #expect(trace.all[failed - 1].hasPrefix("→ "), "the request that got no answer is named just before")
    }
}
