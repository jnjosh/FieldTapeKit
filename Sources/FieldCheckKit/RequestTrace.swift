import FieldTapeKit
import Synchronization

/// The last MTP requests sent while some work ran, kept so that when the OP-1 stops answering, the log can say which
/// request it was (PROBE-NOTES.md, 2026-11-16). Only the last `limit` are kept, so a long run costs little.
public final class RequestTrace: Sendable {
    private let lines = Mutex<[String]>([])
    private let failed = Mutex(false)
    public let limit: Int

    public init(limit: Int = 50) {
        self.limit = limit
    }

    func append(_ line: String) {
        lines.withLock { lines in
            lines.append(line)
            if lines.count > limit { lines.removeFirst(lines.count - limit) }
        }
        if line.hasPrefix("✕") { failed.withLock { $0 = true } }
    }

    /// The requests kept, oldest first.
    public var all: [String] { lines.withLock { $0 } }

    /// Whether a request got no answer, or failed in the transport, while it ran.
    public var sawFailure: Bool { failed.withLock { $0 } }

    /// Runs `body` with every MTP request on `device` traced, and returns its result with the trace.
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
