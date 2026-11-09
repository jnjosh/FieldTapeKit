import Foundation
@preconcurrency import ImageCaptureCore
import Synchronization

/// Sends PTP transactions through ImageCaptureCore's raw passthrough (ADR 0001), carried over from the probe.
///
/// `ICCameraDevice` isn't `Sendable`, so it's only touched on the main actor, as the probe did.
final class ImageCaptureTransport: MTPTransport, @unchecked Sendable {
    private let camera: ICCameraDevice
    private let removed = Mutex(false)

    init(camera: ICCameraDevice) {
        self.camera = camera
    }

    func markRemoved() {
        removed.withLock { $0 = true }
    }

    private var isRemoved: Bool { removed.withLock { $0 } }

    func transact(command: Data, dataOut: Data?) async throws -> MTPTransaction {
        guard !isRemoved else { throw MTPError.disconnected }
        let camera = self.camera
        return try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                camera.requestSendPTPCommand(command, outData: dataOut) { [self] data, response, error in
                    // ImageCaptureCore can report an error alongside a real response. The response wins.
                    // With no error and no response either, the session reports an unreadable response.
                    if PTPContainer.responseCode(response) != nil || error == nil {
                        continuation.resume(returning: MTPTransaction(data: data, response: response))
                    } else if isRemoved {
                        continuation.resume(throwing: MTPError.disconnected)
                    } else {
                        continuation.resume(throwing: error!)
                    }
                }
            }
        }
    }
}
