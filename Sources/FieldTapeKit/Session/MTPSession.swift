import Foundation
import Synchronization

enum MTPError: Error, Equatable {
    /// The device answered with a response code other than OK.
    case refused(PTPOperation, responseCode: UInt16)
    /// What came back wasn't a response container.
    case unreadableResponse(PTPOperation)
    /// No answer in time, but the device answered a ping afterwards, so it's still there.
    case timedOut(PTPOperation)
    /// No answer, and no answer to a ping either. Every later request throws this too.
    case disconnected
}

struct MTPReply: Sendable {
    let payload: Data
    let params: [UInt32]
}

/// Sends one PTP transaction at a time to a device, with a timeout on each.
///
/// There's no OpenSession: ImageCaptureCore's session is enough (`session.implicit`), and OpenSession isn't in
/// ADR 0002's rule 7. A Session Not Open response is reported like any other refusal.
actor MTPSession {
    private let transport: any MTPTransport
    private let timeout: Duration
    private let pingTimeout: Duration
    /// ImageCaptureCore replaces transaction IDs with its own (probe logs, 2026-11-08), so these only label
    /// the commands. Replies aren't matched against them.
    private var nextTransactionID: UInt32 = 1
    private var isBusy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var isDisconnected = false

    init(transport: any MTPTransport, timeout: Duration = .seconds(30), pingTimeout: Duration = .seconds(5)) {
        self.transport = transport
        self.timeout = timeout
        self.pingTimeout = pingTimeout
    }

    /// Sends one operation and returns its data phase and response parameters.
    ///
    /// Requests are sent strictly one after another, even when callers overlap. Cancellation is checked before
    /// sending. A request already sent isn't abandoned on cancellation, only on a timeout.
    func send(_ operation: PTPOperation, _ params: [UInt32] = [], dataOut: Data? = nil) async throws -> MTPReply {
        await acquire()
        defer { release() }
        guard !isDisconnected else { throw MTPError.disconnected }
        try Task.checkCancellation()

        let command = PTPContainer.command(operation, transactionID: takeTransactionID(), params: params)
        let transaction: MTPTransaction
        do {
            transaction = try await Self.withTimeout(timeout) { [transport] in
                try await transport.transact(command: command, dataOut: dataOut)
            }
        } catch is RequestTimeout {
            if await deviceAnswersPing() { throw MTPError.timedOut(operation) }
            isDisconnected = true
            throw MTPError.disconnected
        }

        guard let code = PTPContainer.responseCode(transaction.response) else {
            throw MTPError.unreadableResponse(operation)
        }
        guard code == PTPResponseCode.ok else { throw MTPError.refused(operation, responseCode: code) }
        return MTPReply(payload: PTPContainer.payload(transaction.data, for: operation),
                        params: PTPContainer.responseParams(transaction.response))
    }

    // MARK: Operations

    func deviceInfo() async throws -> PTPDeviceInfo {
        try PTPDeviceInfo(try await send(.getDeviceInfo).payload)
    }

    func storageIDs() async throws -> [UInt32] {
        try PTPReader.u32Array(from: try await send(.getStorageIDs).payload)
    }

    func storageInfo(_ storageID: UInt32) async throws -> PTPStorageInfo {
        try PTPStorageInfo(try await send(.getStorageInfo, [storageID]).payload)
    }

    /// The handles directly inside `parent`, or at the root when it's `PTPContainer.rootParent`.
    func objectHandles(storage: UInt32 = PTPContainer.allStorages, parent: UInt32) async throws -> [UInt32] {
        try PTPReader.u32Array(from: try await send(.getObjectHandles, [storage, 0, parent]).payload)
    }

    func objectInfo(_ handle: UInt32) async throws -> PTPObjectInfo {
        try PTPObjectInfo(try await send(.getObjectInfo, [handle]).payload)
    }

    func object(_ handle: UInt32) async throws -> Data {
        try await send(.getObject, [handle]).payload
    }

    /// Up to `maxLength` bytes from `offset`. Fewer come back at the end of the file.
    func partialObject(_ handle: UInt32, offset: UInt32, maxLength: UInt32) async throws -> Data {
        try await send(.getPartialObject, [handle, offset, maxLength]).payload
    }

    // MARK: One request at a time

    private func acquire() async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            isBusy = false
        } else {
            waiting.removeFirst().resume()
        }
    }

    private func takeTransactionID() -> UInt32 {
        defer { nextTransactionID = nextTransactionID == 0xFFFF_FFFE ? 1 : nextTransactionID + 1 }
        return nextTransactionID
    }

    // MARK: Timeouts

    /// A read-only GetDeviceInfo, to tell a slow request from a device that's gone.
    private func deviceAnswersPing() async -> Bool {
        let command = PTPContainer.command(.getDeviceInfo, transactionID: takeTransactionID(), params: [])
        let reply = try? await Self.withTimeout(pingTimeout) { [transport] in
            try await transport.transact(command: command, dataOut: nil)
        }
        return reply.flatMap { PTPContainer.responseCode($0.response) } != nil
    }

    private struct RequestTimeout: Error {}

    /// Runs `body`, or throws `RequestTimeout` after `limit`. A request ImageCaptureCore has taken can't be
    /// cancelled, so on a timeout it's left to finish on its own, and its result is dropped.
    private static func withTimeout<T: Sendable>(
        _ limit: Duration, _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let resumer = Resumer(continuation)
            let timer = Task {
                try await Task.sleep(for: limit)
                resumer.resume(with: .failure(RequestTimeout()))
            }
            Task {
                do {
                    let value = try await body()
                    timer.cancel()
                    resumer.resume(with: .success(value))
                } catch {
                    timer.cancel()
                    resumer.resume(with: .failure(error))
                }
            }
        }
    }
}

/// Resumes a continuation once, from whichever side finishes first.
private final class Resumer<T: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<T, any Error>?>

    init(_ continuation: CheckedContinuation<T, any Error>) {
        self.continuation = Mutex(continuation)
    }

    func resume(with result: Result<T, any Error>) {
        continuation.withLock { pending in
            pending?.resume(with: result)
            pending = nil
        }
    }
}
