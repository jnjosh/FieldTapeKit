import FieldTapeKit
import Synchronization

/// The last MTP requests sent while some work ran, kept so that when the OP-1 stops answering, the log can say which
/// request it was (PROBE-NOTES.md, 2026-11-16). Only the last `limit` are kept, so a long run costs little.
public final class RequestTrace: Sendable {
    private let lines = Mutex<[String]>([])
    private let failed = Mutex(false)
    public let limit: Int
    /// Told at once about a request that's slow, still waited for, or that answered after it had timed out. Neither
    /// is a failure of its own, so `takeFailure()` wouldn't show them.
    let onLate: (@Sendable (String) -> Void)?

    public init(limit: Int = 50, onLate: (@Sendable (String) -> Void)? = nil) {
        self.limit = limit
        self.onLate = onLate
    }

    func append(_ line: String) {
        lines.withLock { lines in
            lines.append(line)
            if lines.count > limit { lines.removeFirst(lines.count - limit) }
        }
        if line.hasPrefix("✕") { failed.withLock { $0 = true } }
        if line.hasPrefix("← late") || line.hasPrefix("⋯") { onLate?(line) }
    }

    /// The requests kept, oldest first.
    public var all: [String] { lines.withLock { $0 } }

    /// Whether a request got no answer, or failed in the transport, while it ran.
    public var sawFailure: Bool { failed.withLock { $0 } }

    /// Traces every MTP request on `device` from now on, for as long as the connection lasts. FieldCheck starts one as
    /// soon as an OP-1 connects, so its own checks are traced too, not only the levels.
    public static func start(on device: FieldDevice, limit: Int = 50,
                             onLate: (@Sendable (String) -> Void)? = nil) async -> RequestTrace {
        let trace = RequestTrace(limit: limit, onLate: onLate)
        await device.session.setTrace { trace.append($0) }
        return trace
    }

    /// The requests kept, if one got no answer since the last call, and nil otherwise. Each failure is told once.
    public func takeFailure() -> [String]? {
        let failed = failed.withLock { failed in
            defer { failed = false }
            return failed
        }
        return failed ? all : nil
    }

    /// Runs `body` with every MTP request on `device` traced, and returns its result with the trace. It replaces any
    /// trace already set, and stops tracing after, so it's for tests and one-off runs, not a connection's trace.
    public static func during<T: Sendable>(_ device: FieldDevice, limit: Int = 50,
                                           isolation: isolated (any Actor)? = #isolation,
                                           _ body: () async -> T) async -> (T, RequestTrace) {
        let trace = RequestTrace(limit: limit)
        await device.session.setTrace { trace.append($0) }
        let result = await body()
        await device.session.setTrace(nil)
        return (result, trace)
    }
}
