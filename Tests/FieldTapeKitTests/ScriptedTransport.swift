import Foundation
@testable import FieldTapeKit

/// A transport that answers each request with whatever the test's handler returns, and records what was sent.
actor ScriptedTransport: MTPTransport {
    struct Sent: Equatable {
        let operation: UInt16
        let transactionID: UInt32
        let params: [UInt32]
    }

    typealias Handler = @Sendable (_ request: Int, _ operation: UInt16) async throws -> MTPTransaction

    private let handler: Handler
    private(set) var sent: [Sent] = []
    private(set) var inFlight = 0
    private(set) var mostInFlight = 0

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    func transact(command: Data, dataOut: Data?) async throws -> MTPTransaction {
        var reader = PTPReader(command)
        let length = try reader.u32()
        _ = try reader.u16()
        let operation = try reader.u16()
        let transactionID = try reader.u32()
        let params = try (0..<((Int(length) - PTPContainer.headerSize) / 4)).map { _ in try reader.u32() }
        sent.append(Sent(operation: operation, transactionID: transactionID, params: params))

        inFlight += 1
        mostInFlight = max(mostInFlight, inFlight)
        defer { inFlight -= 1 }
        return try await handler(sent.count, operation)
    }

    static func reply(_ data: [UInt8] = [], code: UInt16 = PTPResponseCode.ok, params: [UInt32] = []) -> MTPTransaction {
        MTPTransaction(data: Data(data), response: Data(Bytes.response(code: code, params: params)))
    }

    /// Long enough that a test's timeout always fires first.
    static func hang() async throws -> MTPTransaction {
        try await Task.sleep(for: .seconds(3600))
        return reply()
    }
}

extension Bytes {
    static func response(code: UInt16, transactionID: UInt32 = 1, params: [UInt32] = []) -> [UInt8] {
        le32(UInt32(12 + 4 * params.count)) + le16(PTPContainerType.response) + le16(code) + le32(transactionID)
            + params.flatMap(le32)
    }
}
