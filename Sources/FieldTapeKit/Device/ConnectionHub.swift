import Foundation

/// Keeps the connected devices and the listeners to `FieldDevice.connections`, apart from ImageCaptureCore,
/// so that its rules can be tested: a new listener first hears about every device already connected, every
/// listener hears every event, and watching stops when the last listener goes away.
@MainActor
final class ConnectionHub {
    typealias Continuation = AsyncThrowingStream<FieldDevice.ConnectionEvent, any Error>.Continuation

    /// Called when the first listener arrives and when the last one leaves.
    var onWatchingChanged: (Bool) -> Void = { _ in }

    private var listeners: [UUID: Continuation] = [:]
    /// Listeners that went away before they were added, which can happen because both hop to the main actor.
    private var gone: Set<UUID> = []
    private(set) var devices: [FieldDevice] = []
    private var failure: FieldError?

    var isWatching: Bool { !listeners.isEmpty }
    var listenerCount: Int { listeners.count }

    /// A new listener's stream. It can be made from any context, so it registers on the main actor.
    nonisolated static func stream(
        _ hub: @escaping @MainActor @Sendable () -> ConnectionHub
    ) -> AsyncThrowingStream<FieldDevice.ConnectionEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<FieldDevice.ConnectionEvent, any Error>.makeStream()
        let token = UUID()
        continuation.onTermination = { _ in Task { @MainActor in hub().removeListener(token) } }
        Task { @MainActor in hub().addListener(token, continuation) }
        return stream
    }

    func addListener(_ token: UUID, _ continuation: Continuation) {
        guard gone.remove(token) == nil else { return }
        if let failure {
            continuation.finish(throwing: failure)
            return
        }
        for device in devices { continuation.yield(.connected(device)) }
        listeners[token] = continuation
        if listeners.count == 1 { onWatchingChanged(true) }
    }

    func removeListener(_ token: UUID) {
        guard listeners.removeValue(forKey: token) != nil else {
            gone.insert(token)
            return
        }
        if listeners.isEmpty { onWatchingChanged(false) }
    }

    func connected(_ device: FieldDevice) {
        devices.append(device)
        for listener in listeners.values { listener.yield(.connected(device)) }
    }

    func disconnected(_ id: FieldDevice.ID) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        devices.remove(at: index)
        for listener in listeners.values { listener.yield(.disconnected(id)) }
    }

    /// Ends every listener's stream with this error, and every later one's straight away, such as when the app
    /// isn't authorized.
    func fail(_ error: FieldError) {
        failure = error
        let ending = listeners
        listeners = [:]
        for listener in ending.values { listener.finish(throwing: error) }
        if !ending.isEmpty { onWatchingChanged(false) }
    }
}
