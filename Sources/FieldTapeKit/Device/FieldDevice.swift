import Foundation

/// A connected OP-1 Field, in MTP mode.
///
/// Get one from ``connections``, or ``simulated(_:)`` for tests and previews. A device is an actor because the OP-1
/// handles one request at a time. After a disconnect, every call throws ``FieldError/Code/disconnected``, and a
/// reconnect produces a new `FieldDevice`, because the OP-1's object handles don't survive it.
public actor FieldDevice: Identifiable {
    /// Identifies one connection. A reconnect gets a new ID.
    public struct ID: Hashable, Sendable {
        let rawValue = UUID()
    }

    /// A change in which OP-1s are connected, from ``connections``.
    public enum ConnectionEvent: Sendable {
        /// An OP-1 connected in MTP mode and is ready to use.
        case connected(FieldDevice)
        /// The OP-1 with this ID was unplugged or left MTP mode. Calls on it throw `disconnected`.
        case disconnected(FieldDevice.ID)
        /// An OP-1 was found, but ImageCaptureCore couldn't open a session with it, or its device info couldn't be
        /// read, such as when another app holds it. Watching goes on, and it can be connected again.
        case couldNotOpen(FieldError)
    }

    /// Identifies this connection.
    public nonisolated let id = ID()
    /// What the OP-1 reported when it connected.
    public nonisolated let info: FieldDeviceInfo
    package nonisolated let session: MTPSession
    package nonisolated let profile: FirmwareProfile
    /// What ImageCaptureCore reported about the USB device, or nil if it wasn't asked (`device.identity`).
    package nonisolated let usb: USBIdentity?
    /// The OP-1's one storage, which new objects go into (`device.storage`).
    package nonisolated let storageID: UInt32
    private var wasRemoved = false
    /// Confirmations already used. Each works once (ADR 0002, safety rule 1).
    var usedConfirmations: Set<UUID> = []
    /// Lets album sides be written although the firmware profile has album writing off, for FieldCheck to put back a
    /// side it overwrote, and for tests of the code that writes them. Package-only: apps can't turn it on.
    var albumWritesOverridden = false

    /// Whether album sides can be written on this connection.
    package var albumWritesAllowed: Bool { profile.albumWrites || albumWritesOverridden }

    /// Turns the override of `FirmwareProfile.albumWrites` on or off for this connection.
    package func overrideAlbumWrites(_ on: Bool) {
        albumWritesOverridden = on
    }

    init(session: MTPSession, info: FieldDeviceInfo, profile: FirmwareProfile, usb: USBIdentity?,
         storageID: UInt32 = SimulatedMTPDevice.storageID) {
        self.session = session
        self.info = info
        self.profile = profile
        self.usb = usb
        self.storageID = storageID
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
    static func connect(over transport: any MTPTransport, usb: USBIdentity? = nil, timeout: Duration = .seconds(90),
                        slowAfter: Duration = .seconds(30)) async throws -> FieldDevice {
        let session = MTPSession(transport: transport, timeout: timeout, slowAfter: slowAfter)
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
            return FieldDevice(session: session, info: info, profile: profile, usb: usb, storageID: storageID)
        } catch {
            throw FieldError.wrapping(error)
        }
    }
}

// MARK: - Info

/// The USB identity of a device as ImageCaptureCore reports it.
package struct USBIdentity: Sendable, Hashable {
    package let vendorID: Int
    package let productID: Int
    package let name: String?

    package init(vendorID: Int, productID: Int, name: String?) {
        self.vendorID = vendorID
        self.productID = productID
        self.name = name
    }

    /// An OP-1 Field in MTP mode, as seen on 1.7.3. The simulator reports it too.
    package static let op1 = USBIdentity(vendorID: 0x2367, productID: 0x0102, name: "OP-1")
}

/// What an OP-1 reported about itself when it connected.
public struct FieldDeviceInfo: Sendable, Hashable {
    /// "OP-1" for an OP-1 Field.
    public let model: String
    /// The firmware version, such as "1.7.3".
    public let firmware: String
    /// Whether this release of FieldTapeKit has a FieldCheck baseline for exactly this firmware. On an untested
    /// firmware everything still works, using the profile of the nearest tested one, so an app can warn the person
    /// (ADR 0002, section 11).
    public let isFirmwareTested: Bool
    /// The OP-1's serial number, such as "L1PXE14W".
    public let serialNumber: String
    /// Storage as reported when the OP-1 connected.
    public let storage: FieldStorage
}

/// The OP-1's storage, as GetStorageInfo reported it.
public struct FieldStorage: Sendable, Hashable {
    /// In bytes.
    public let capacity: Int
    /// In bytes, as the OP-1 reports it. Whether that figure is accurate hasn't been tested yet, so FieldTapeKit
    /// doesn't refuse writes on it (ADR 0002, section 1).
    public let freeSpace: Int
}

// MARK: - Simulated

extension FieldDevice {

    static func simulated(_ simulator: SimulatedMTPDevice, timeout: Duration = .seconds(90),
                          slowAfter: Duration = .seconds(30)) -> FieldDevice {
        let (profile, isTested) = FirmwareProfile.profile(for: simulator.firmware)
        let info = FieldDeviceInfo(model: "OP-1", firmware: simulator.firmware, isFirmwareTested: isTested,
                                   serialNumber: simulator.serialNumber,
                                   storage: FieldStorage(capacity: Int(clamping: simulator.capacity),
                                                         freeSpace: Int(clamping: simulator.initialFreeSpace)))
        return FieldDevice(session: MTPSession(transport: simulator, timeout: timeout, slowAfter: slowAfter),
                           info: info, profile: profile, usb: .op1)
    }
}
