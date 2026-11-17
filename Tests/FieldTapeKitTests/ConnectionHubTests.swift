import Foundation
import Testing
@testable import FieldTapeKit

@MainActor
@Suite struct ConnectionHubTests {
    private typealias Iterator = AsyncThrowingStream<FieldDevice.ConnectionEvent, any Error>.Iterator

    /// Registration hops to the main actor, so this waits until the hub has the new listener.
    private func listen(_ hub: ConnectionHub) async throws -> Iterator {
        let before = hub.listenerCount
        let iterator = ConnectionHub.stream { hub }.makeAsyncIterator()
        try await settle { hub.listenerCount > before }
        return iterator
    }

    private func connectedID(_ event: FieldDevice.ConnectionEvent?) -> FieldDevice.ID? {
        if case .connected(let device) = event { device.id } else { nil }
    }

    private func disconnectedID(_ event: FieldDevice.ConnectionEvent?) -> FieldDevice.ID? {
        if case .disconnected(let id) = event { id } else { nil }
    }

    /// Waits for the main actor to catch up with listeners that went away.
    private func settle(until condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func aNewListenerHearsAboutDevicesAlreadyConnectedFirst() async throws {
        let hub = ConnectionHub()
        let early = FieldDevice.simulated(), late = FieldDevice.simulated()
        hub.connected(early)

        var events = try await listen(hub)
        hub.connected(late)
        #expect(connectedID(try await events.next(isolation: MainActor.shared)) == early.id)
        #expect(connectedID(try await events.next(isolation: MainActor.shared)) == late.id)
    }

    @Test func everyListenerHearsEveryEvent() async throws {
        let hub = ConnectionHub()
        var first = try await listen(hub), second = try await listen(hub)
        let device = FieldDevice.simulated()
        hub.connected(device)
        hub.disconnected(device.id)

        #expect(connectedID(try await first.next(isolation: MainActor.shared)) == device.id)
        #expect(disconnectedID(try await first.next(isolation: MainActor.shared)) == device.id)
        #expect(connectedID(try await second.next(isolation: MainActor.shared)) == device.id)
        #expect(disconnectedID(try await second.next(isolation: MainActor.shared)) == device.id)
        #expect(hub.devices.isEmpty, "a disconnected device isn't announced to later listeners")
    }

    @Test func anOP1ThatCouldNotBeOpenedIsReportedAndWatchingGoesOn() async throws {
        let hub = ConnectionHub()
        var changes: [Bool] = []
        hub.onWatchingChanged = { changes.append($0) }
        var events = try await listen(hub)
        let underlying = NSError(domain: "com.apple.ImageCaptureCore", code: -9922)
        hub.couldNotOpen(FieldError(.deviceRefused, underlying: underlying))
        let device = FieldDevice.simulated()
        hub.connected(device)

        guard case .couldNotOpen(let error) = try await events.next(isolation: MainActor.shared) else {
            Issue.record("expected couldNotOpen")
            return
        }
        #expect(error.code == .deviceRefused)
        #expect((error.underlying as? NSError)?.code == -9922)
        #expect(connectedID(try await events.next(isolation: MainActor.shared)) == device.id,
                "another OP-1 still connects")
        #expect(changes == [true], "watching doesn't stop")

        var later = try await listen(hub)
        #expect(connectedID(try await later.next(isolation: MainActor.shared)) == device.id,
                "a later listener hears only about connected devices")
    }

    @Test func watchingStartsWithTheFirstListenerAndStopsAfterTheLast() async throws {
        let hub = ConnectionHub()
        var changes: [Bool] = []
        hub.onWatchingChanged = { changes.append($0) }

        let one = Task { for try await _ in ConnectionHub.stream({ hub }) {} }
        let two = Task { for try await _ in ConnectionHub.stream({ hub }) {} }
        try await settle { hub.isWatching }
        #expect(changes == [true])

        one.cancel()
        try await Task.sleep(for: .milliseconds(20))
        #expect(changes == [true], "still watching while one listener is left")

        two.cancel()
        try await settle { !hub.isWatching }
        #expect(changes == [true, false])
    }

    @Test func aFailureEndsEveryStreamNowAndLater() async throws {
        let hub = ConnectionHub()
        var current = try await listen(hub)
        hub.fail(FieldError(.notAuthorized))

        await #expect { _ = try await current.next(isolation: MainActor.shared) } throws: { ($0 as? FieldError)?.code == .notAuthorized }
        var later = ConnectionHub.stream { hub }.makeAsyncIterator()
        await #expect { _ = try await later.next(isolation: MainActor.shared) } throws: { ($0 as? FieldError)?.code == .notAuthorized }
        #expect(!hub.isWatching)
    }

    @Test func aListenerThatLeavesBeforeItsRegisteredIsNeverAdded() {
        let hub = ConnectionHub()
        let (_, continuation) = AsyncThrowingStream<FieldDevice.ConnectionEvent, any Error>.makeStream()
        let token = UUID()
        hub.removeListener(token)
        hub.addListener(token, continuation)
        #expect(!hub.isWatching)
    }
}
