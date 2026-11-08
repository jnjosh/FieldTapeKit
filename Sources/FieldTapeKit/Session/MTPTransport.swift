import Foundation

/// One PTP transaction as ImageCaptureCore's `requestSendPTPCommand` shapes it: a command container and an
/// optional data phase go out, and the device's data phase and response container come back.
///
/// The live transport is ImageCaptureCore (step 3). The simulated OP-1 is the other implementation.
protocol MTPTransport: Sendable {
    func transact(command: Data, dataOut: Data?) async throws -> MTPTransaction
}

struct MTPTransaction: Sendable {
    var data: Data
    var response: Data
}
