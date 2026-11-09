import Foundation

/// A connected OP-1 Field, in MTP mode.
///
/// Get one from `FieldDevice.connections`, or `FieldDevice.simulated()` for tests and previews. A device is
/// an actor because the OP-1 handles one request at a time. After a disconnect, every call throws
/// `FieldError.Code.disconnected`, and a reconnect produces a new `FieldDevice`, because the OP-1's object
/// handles don't survive it.
public actor FieldDevice: Identifiable {
    /// Identifies one connection. A reconnect gets a new ID.
    public struct ID: Hashable, Sendable {
        let rawValue = UUID()
    }

    public enum ConnectionEvent: Sendable {
        case connected(FieldDevice)
        case disconnected(FieldDevice.ID)
    }

    public nonisolated let id = ID()
    /// What the OP-1 reported when it connected.
    public nonisolated let info: FieldDeviceInfo
    nonisolated let session: MTPSession
    nonisolated let profile: FirmwareProfile
    private var wasRemoved = false

    init(session: MTPSession, info: FieldDeviceInfo, profile: FirmwareProfile) {
        self.session = session
        self.info = info
        self.profile = profile
    }

    /// False once the OP-1 has been unplugged, has left MTP mode, or has stopped answering.
    public var isConnected: Bool {
        get async {
            guard !wasRemoved else { return false }
            return await !session.isDisconnected
        }
    }

    /// Called when ImageCaptureCore reports the device gone.
    func markRemoved() {
        wasRemoved = true
    }

    /// Reads the OP-1's device and storage info over a new session, and makes the device from them.
    static func connect(over transport: any MTPTransport, timeout: Duration = .seconds(30),
                        pingTimeout: Duration = .seconds(5)) async throws -> FieldDevice {
        let session = MTPSession(transport: transport, timeout: timeout, pingTimeout: pingTimeout)
        do {
            let deviceInfo = try await session.deviceInfo()
            // The OP-1 has one storage (`device.storage`). Free space is read from the first.
            guard let storageID = try await session.storageIDs().first else {
                throw FieldError(.deviceRefused)
            }
            let storage = try await session.storageInfo(storageID)
            let (profile, isTested) = FirmwareProfile.profile(for: deviceInfo.deviceVersion)
            let info = FieldDeviceInfo(model: deviceInfo.model, firmware: deviceInfo.deviceVersion,
                                       isFirmwareTested: isTested, serialNumber: deviceInfo.serialNumber,
                                       storage: FieldStorage(capacity: Int(clamping: storage.maxCapacity),
                                                             freeSpace: Int(clamping: storage.freeSpaceInBytes)))
            return FieldDevice(session: session, info: info, profile: profile)
        } catch {
            throw FieldError.wrapping(error)
        }
    }
}

// MARK: - Info

public struct FieldDeviceInfo: Sendable, Hashable {
    /// "OP-1" for an OP-1 Field.
    public let model: String
    /// The firmware version, such as "1.7.3".
    public let firmware: String
    /// Whether this release of FieldTapeKit has a FieldCheck baseline for exactly this firmware. On an untested
    /// firmware everything still works, using the profile of the nearest tested one, so an app can warn the person
    /// (ADR 0002, section 11).
    public let isFirmwareTested: Bool
    public let serialNumber: String
    /// Storage as reported when the OP-1 connected.
    public let storage: FieldStorage
}

public struct FieldStorage: Sendable, Hashable {
    /// In bytes.
    public let capacity: Int
    /// In bytes, as the OP-1 reports it. Whether that figure is accurate hasn't been tested yet, so FieldTapeKit
    /// doesn't refuse writes on it (ADR 0002, section 1).
    public let freeSpace: Int
}

// MARK: - Simulated

extension FieldDevice {
    /// An empty OP-1 that exists only in memory, for tests and SwiftUI previews. It behaves like OP-1
    /// firmware 1.7.3 at the MTP level (ADR 0002, section 8).
    public static func simulated() -> FieldDevice {
        simulated(SimulatedMTPDevice())
    }

    static func simulated(_ simulator: SimulatedMTPDevice, timeout: Duration = .seconds(30),
                          pingTimeout: Duration = .seconds(5)) -> FieldDevice {
        let (profile, isTested) = FirmwareProfile.profile(for: simulator.firmware)
        let info = FieldDeviceInfo(model: "OP-1", firmware: simulator.firmware, isFirmwareTested: isTested,
                                   serialNumber: simulator.serialNumber,
                                   storage: FieldStorage(capacity: Int(clamping: simulator.capacity),
                                                         freeSpace: Int(clamping: simulator.capacity)))
        return FieldDevice(session: MTPSession(transport: simulator, timeout: timeout, pingTimeout: pingTimeout),
                           info: info, profile: profile)
    }
}
