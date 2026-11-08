import Foundation
import Testing
@testable import FieldTapeKit

private let le16 = Bytes.le16, le32 = Bytes.le32
private let getDeviceInfo = PTPOperation.getDeviceInfo.rawValue

@Suite struct MTPSessionTests {
    private func session(_ transport: ScriptedTransport) -> MTPSession {
        MTPSession(transport: transport, timeout: .milliseconds(100), pingTimeout: .milliseconds(100))
    }

    @Test func returnsPayloadWithoutContainerAndResponseParams() async throws {
        let wrapped = le32(16) + le16(PTPContainerType.data) + le16(0x1009) + le32(1) + [9, 8, 7, 6]
        let transport = ScriptedTransport { _, _ in ScriptedTransport.reply(wrapped, params: [4]) }
        let reply = try await session(transport).send(.getObject, [0x42])
        #expect(Array(reply.payload) == [9, 8, 7, 6])
        #expect(reply.params == [4])
        #expect(await transport.sent == [.init(operation: 0x1009, transactionID: 1, params: [0x42])])
    }

    @Test func transactionIDsCountUp() async throws {
        let transport = ScriptedTransport { _, _ in ScriptedTransport.reply(Bytes.le32(0)) }
        let session = session(transport)
        for _ in 0..<3 { _ = try await session.storageIDs() }
        #expect(await transport.sent.map(\.transactionID) == [1, 2, 3])
    }

    @Test(arguments: [UInt16(0x2002), 0x2003, 0x2009])
    func reportsARefusalWithItsResponseCode(code: UInt16) async {
        let transport = ScriptedTransport { _, _ in ScriptedTransport.reply(code: code) }
        await #expect(throws: MTPError.refused(.getObjectInfo, responseCode: code)) {
            try await session(transport).objectInfo(7)
        }
        #expect(await transport.sent.count == 1, "a refusal isn't retried, and no OpenSession is sent")
    }

    @Test func reportsAnUnreadableResponse() async {
        let transport = ScriptedTransport { _, _ in MTPTransaction(data: Data(), response: Data([1, 2, 3])) }
        await #expect(throws: MTPError.unreadableResponse(.getStorageIDs)) { try await session(transport).storageIDs() }
    }

    @Test func passesOnATransportError() async {
        struct Unplugged: Error {}
        let transport = ScriptedTransport { _, _ in throw Unplugged() }
        await #expect(throws: Unplugged.self) { try await session(transport).storageIDs() }
    }

    @Test func overlappingCallersAreSentOneAtATime() async throws {
        let transport = ScriptedTransport { _, _ in
            try await Task.sleep(for: .milliseconds(5))
            return ScriptedTransport.reply(Bytes.le32(0))
        }
        let session = session(transport)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 { group.addTask { _ = try await session.storageIDs() } }
            try await group.waitForAll()
        }
        #expect(await transport.sent.count == 5)
        #expect(await transport.mostInFlight == 1)
    }

    @Test func aSlowRequestThatThePingAnswersIsATimeout() async throws {
        let transport = ScriptedTransport { request, _ in
            request == 1 ? try await ScriptedTransport.hang() : ScriptedTransport.reply(Bytes.le32(0))
        }
        let session = session(transport)
        await #expect(throws: MTPError.timedOut(.getStorageIDs)) { try await session.storageIDs() }
        #expect(await transport.sent.last?.operation == getDeviceInfo, "the ping is a read-only GetDeviceInfo")
        #expect(try await session.storageIDs() == [], "the device is still usable")
        #expect(await session.isDisconnected == false)
    }

    @Test func noAnswerToTheRequestOrThePingIsADisconnect() async throws {
        let transport = ScriptedTransport { _, _ in try await ScriptedTransport.hang() }
        let session = session(transport)
        await #expect(throws: MTPError.disconnected) { try await session.storageIDs() }
        #expect(await session.isDisconnected)

        await #expect(throws: MTPError.disconnected) { try await session.storageIDs() }
        #expect(await transport.sent.count == 2, "nothing more is sent once the device is gone")
    }

    @Test func aCancelledCallerSendsNothing() async {
        let transport = ScriptedTransport { _, _ in ScriptedTransport.reply(Bytes.le32(0)) }
        let session = session(transport)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await session.storageIDs()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.sent.isEmpty)
    }
}
