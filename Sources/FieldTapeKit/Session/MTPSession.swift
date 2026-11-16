import Foundation
import Synchronization

package enum MTPError: Error, Equatable {
    /// The device answered with a response code other than OK.
    case refused(PTPOperation, responseCode: UInt16)
    /// What came back wasn't a response container.
    case unreadableResponse(PTPOperation)
    /// No answer in time, but the device answered a ping afterwards, so it's still there.
    case timedOut(PTPOperation)
    /// No answer, and no answer to a ping either. Every later request throws this too.
    case disconnected
}

package struct MTPReply: Sendable {
    package let payload: Data
    package let params: [UInt32]
    /// Whether the data phase came with its 12-byte container header, which `payload` leaves out
    /// (`session.data-phase`).
    package let hadContainerHeader: Bool
}

/// Sends one PTP transaction at a time to a device, with a timeout on each.
///
/// There's no OpenSession: ImageCaptureCore's session is enough (`session.implicit`), and OpenSession isn't in
/// ADR 0002's rule 7. A Session Not Open response is reported like any other refusal.
package actor MTPSession {
    private let transport: any MTPTransport
    private let timeout: Duration
    private let pingTimeout: Duration
    /// ImageCaptureCore replaces transaction IDs with its own (probe logs, 2026-11-08), so these only label
    /// the commands. Replies aren't matched against them.
    private var nextTransactionID: UInt32 = 1
    private var isBusy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var isDisconnected = false
    /// Told about every request and how it ended, when set, to find which one a device stops answering.
    private var trace: (@Sendable (String) -> Void)?

    init(transport: any MTPTransport, timeout: Duration = .seconds(30), pingTimeout: Duration = .seconds(5)) {
        self.transport = transport
        self.timeout = timeout
        self.pingTimeout = pingTimeout
    }

    /// Starts or stops telling `trace` about each request: what was sent, then the response code, the bytes that
    /// came back and how long it took, or that it got no answer. It's for diagnosing, so it's package-only.
    package func setTrace(_ trace: (@Sendable (String) -> Void)?) {
        self.trace = trace
    }

    /// Sends one operation and returns its data phase and response parameters.
    ///
    /// Requests are sent strictly one after another, even when callers overlap. Cancellation is checked before
    /// sending. A request already sent isn't abandoned on cancellation, only on a timeout.
    package func send(_ operation: PTPOperation, _ params: [UInt32] = [], dataOut: Data? = nil) async throws -> MTPReply {
        await acquire()
        defer { release() }
        guard !isDisconnected else { throw MTPError.disconnected }
        try Task.checkCancellation()

        let command = PTPContainer.command(operation, transactionID: takeTransactionID(), params: params)
        let clock = ContinuousClock()
        let start = clock.now
        trace?("→ \(operation)" + params.map { String(format: " 0x%X", $0) }.joined()
               + (dataOut.map { ", \($0.count) bytes out" } ?? ""))
        let transaction: MTPTransaction
        do {
            let trace = trace
            transaction = try await Self.withTimeout(timeout, late: { succeeded in
                let elapsed = clock.now - start
                trace?("← late: \(operation) " + (succeeded ? "answered" : "failed") + " after "
                       + "\(elapsed.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow))), and was dropped")
            }) { [transport] in
                try await transport.transact(command: command, dataOut: dataOut)
            }
        } catch is RequestTimeout {
            trace?("✕ \(operation): no answer after \(timeout)")
            if await deviceAnswersPing() {
                trace?("  a GetDeviceInfo ping was answered")
                throw MTPError.timedOut(operation)
            }
            trace?("  a GetDeviceInfo ping got no answer in \(pingTimeout) either")
            isDisconnected = true
            throw MTPError.disconnected
        } catch {
            trace?("✕ \(operation): \(error)")
            throw error
        }

        guard let code = PTPContainer.responseCode(transaction.response) else {
            trace?("✕ \(operation): unreadable response")
            throw MTPError.unreadableResponse(operation)
        }
        let elapsed = clock.now - start
        trace?("← \(operation) " + String(format: "0x%04X", code) + ", \(transaction.data.count) bytes in, "
               + "\(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000) ms")
        guard code == PTPResponseCode.ok else { throw MTPError.refused(operation, responseCode: code) }
        return MTPReply(payload: PTPContainer.payload(transaction.data, for: operation),
                        params: PTPContainer.responseParams(transaction.response),
                        hadContainerHeader: PTPContainer.hasContainerHeader(transaction.data, for: operation))
    }

    // MARK: Operations

    package func deviceInfo() async throws -> PTPDeviceInfo {
        try PTPDeviceInfo(try await send(.getDeviceInfo).payload)
    }

    package func storageIDs() async throws -> [UInt32] {
        try PTPReader.u32Array(from: try await send(.getStorageIDs).payload)
    }

    package func storageInfo(_ storageID: UInt32) async throws -> PTPStorageInfo {
        try PTPStorageInfo(try await send(.getStorageInfo, [storageID]).payload)
    }

    /// The handles directly inside `parent`, or at the root when it's `PTPContainer.rootParent`.
    package func objectHandles(storage: UInt32 = PTPContainer.allStorages, parent: UInt32) async throws -> [UInt32] {
        try PTPReader.u32Array(from: try await send(.getObjectHandles, [storage, 0, parent]).payload)
    }

    package func objectInfo(_ handle: UInt32) async throws -> PTPObjectInfo {
        try PTPObjectInfo(try await send(.getObjectInfo, [handle]).payload)
    }

    package func object(_ handle: UInt32) async throws -> Data {
        try await send(.getObject, [handle]).payload
    }

    /// Announces a new object, with no data yet. The OP-1 makes it, and a folder is complete with this alone
    /// (`write.folder`).
    ///
    /// - Returns: The new object's handle.
    package func sendObjectInfo(storage: UInt32, parent: UInt32, dataset: Data) async throws -> UInt32 {
        let reply = try await send(.sendObjectInfo, [storage, parent], dataOut: dataset)
        guard reply.params.count >= 3 else { throw MTPError.unreadableResponse(.sendObjectInfo) }
        return reply.params[2]
    }

    /// Sends the data for the object announced just before.
    package func sendObject(_ data: Data) async throws {
        _ = try await send(.sendObject, [], dataOut: data)
    }

    /// Deletes one object. A folder is deleted only once it's empty (`delete.files-then-folder`).
    package func deleteObject(_ handle: UInt32) async throws {
        _ = try await send(.deleteObject, [handle, 0])
    }

    /// Up to `maxLength` bytes from `offset`. Fewer come back at the end of the file.
    package func partialObject(_ handle: UInt32, offset: UInt32, maxLength: UInt32) async throws -> Data {
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
    ///
    /// `late` is told if the request finishes after it timed out, with whether it succeeded, so a trace can tell a
    /// slow answer from a lost one.
    private static func withTimeout<T: Sendable>(
        _ limit: Duration, late: (@Sendable (Bool) -> Void)? = nil, _ body: @escaping @Sendable () async throws -> T
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
                    if !resumer.resume(with: .success(value)) { late?(true) }
                } catch {
                    timer.cancel()
                    if !resumer.resume(with: .failure(error)) { late?(false) }
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

    /// Whether this call resumed it, rather than an earlier one.
    @discardableResult
    func resume(with result: Result<T, any Error>) -> Bool {
        continuation.withLock { pending in
            guard let continuation = pending else { return false }
            continuation.resume(with: result)
            pending = nil
            return true
        }
    }
}
