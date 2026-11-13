import Foundation
@preconcurrency import ImageCaptureCore
import os

extension FieldDevice {
    /// Connect and disconnect events for every OP-1 in MTP mode.
    ///
    /// Each iteration starts with a `.connected` event for every OP-1 already attached. Watching starts when
    /// something iterates and stops when the last iterating task is cancelled. Several listeners share one
    /// `ICDeviceBrowser`. The first use asks for ImageCaptureCore authorization on iOS.
    ///
    /// - Throws: `FieldError` with `.notAuthorized` if the person denies access. The iOS simulator has no
    ///   USB devices, so there it never yields anything.
    public static var connections: some AsyncSequence<ConnectionEvent, any Error> {
        ConnectionHub.stream { DeviceMonitor.shared.hub }
    }
}

/// Finds OP-1s with ImageCaptureCore and turns them into `FieldDevice`s. Carried over from the probe's
/// device lifecycle, which worked on iPad and iPhone with firmware 1.7.3.
@MainActor
final class DeviceMonitor: NSObject {
    static let shared = DeviceMonitor()

    let hub = ConnectionHub()
    private let log = Logger(subsystem: "com.jnjosh.FieldTapeKit", category: "connections")
    private lazy var browser: ICDeviceBrowser = {
        let browser = ICDeviceBrowser()
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(
            rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        )!
        return browser
    }()
    private var isAuthorizing = false
    private var isAuthorized = false

    /// OP-1s whose session or catalog isn't ready yet.
    private var opening: Set<ObjectIdentifier> = []
    private var connected: [ObjectIdentifier: (transport: ImageCaptureTransport, device: FieldDevice)] = [:]

    /// The probe always saw the catalog about 0.4 s after the session opened, and never needed this.
    private static let catalogFallback: Duration = .seconds(10)
    /// The probe's fallback for an authorization callback that never arrives.
    private static let authorizationFallback: Duration = .seconds(15)

    override private init() {
        super.init()
        hub.onWatchingChanged = { [unowned self] watching in watching ? start() : stop() }
    }

    // MARK: Watching

    private func start() {
        #if targetEnvironment(simulator)
        // The iOS 27.2 simulator's ICDeviceBrowser has no authorization method and crashes (PROBE-NOTES.md).
        log.info("The simulator has no USB devices")
        #elseif os(iOS)
        guard isAuthorized else { return authorize() }
        browser.start()
        #else
        browser.start()
        #endif
    }

    private func stop() {
        guard browser.isBrowsing else { return }
        browser.stop()
    }

    #if os(iOS) && !targetEnvironment(simulator)
    private func authorize() {
        guard !isAuthorizing else { return }
        isAuthorizing = true
        browser.requestContentsAuthorization { contents in
            Task { @MainActor in
                self.log.info("Contents authorization: \(contents.rawValue, privacy: .public)")
                self.browser.requestControlAuthorization { control in
                    Task { @MainActor in self.authorized(control) }
                }
            }
        }
        Task {
            try? await Task.sleep(for: Self.authorizationFallback)
            guard isAuthorizing else { return }
            log.info("No authorization callback, browsing anyway")
            authorized(nil)
        }
    }

    private func authorized(_ control: ICAuthorizationStatus?) {
        guard isAuthorizing else { return }
        isAuthorizing = false
        if let control {
            log.info("Control authorization: \(control.rawValue, privacy: .public)")
        }
        if control == .denied || control == .restricted {
            hub.fail(FieldError(.notAuthorized))
            return
        }
        isAuthorized = true
        if hub.isWatching { browser.start() }
    }
    #endif

    // MARK: Device lifecycle

    /// USB vendor 0x2367 and MTP product 0x0102, or the name (`device.identity`).
    private static func isOP1(_ device: ICDevice) -> Bool {
        let op1 = USBIdentity.op1
        return (Int(device.usbVendorID) == op1.vendorID && Int(device.usbProductID) == op1.productID) || device.name == op1.name
    }

    fileprivate func added(_ device: ICDevice) {
        guard Self.isOP1(device), let camera = device as? ICCameraDevice else { return }
        let key = ObjectIdentifier(camera)
        guard !opening.contains(key), connected[key] == nil else { return }
        log.info("Found \(camera.name ?? "OP-1", privacy: .public), opening a session")
        opening.insert(key)
        camera.delegate = self
        camera.requestOpenSession()
    }

    fileprivate func sessionOpened(_ camera: ICCameraDevice, error: (any Error)?) {
        let key = ObjectIdentifier(camera)
        guard opening.contains(key) else { return }
        if let error {
            log.error("Session failed: \(String(describing: error), privacy: .public)")
            opening.remove(key)
            return
        }
        Task {
            try? await Task.sleep(for: Self.catalogFallback)
            guard opening.contains(key) else { return }
            log.info("No catalog, connecting anyway")
            await connect(camera)
        }
    }

    /// The probe always waited for this before sending PTP.
    fileprivate func catalogReady(_ camera: ICCameraDevice) {
        Task { await connect(camera) }
    }

    private func connect(_ camera: ICCameraDevice) async {
        let key = ObjectIdentifier(camera)
        guard opening.remove(key) != nil else { return }
        let transport = ImageCaptureTransport(camera: camera)
        let usb = USBIdentity(vendorID: Int(camera.usbVendorID), productID: Int(camera.usbProductID), name: camera.name)
        do {
            let device = try await FieldDevice.connect(over: transport, usb: usb)
            log.info("Connected: firmware \(device.info.firmware, privacy: .public)")
            connected[key] = (transport, device)
            hub.connected(device)
        } catch {
            log.error("Couldn't read the OP-1's info: \(String(describing: error), privacy: .public)")
        }
    }

    fileprivate func removed(_ device: ICDevice) {
        let key = ObjectIdentifier(device)
        opening.remove(key)
        guard let (transport, fieldDevice) = connected.removeValue(forKey: key) else { return }
        log.info("Disconnected")
        transport.markRemoved()
        Task { await fieldDevice.markRemoved() }
        hub.disconnected(fieldDevice.id)
    }
}

// ImageCaptureCore calls these on the main thread, but nothing guarantees it, so each hops to the main actor.

extension DeviceMonitor: ICDeviceBrowserDelegate {
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        Task { @MainActor in added(device) }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        Task { @MainActor in removed(device) }
    }
}

extension DeviceMonitor: ICCameraDeviceDelegate {
    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        guard let camera = device as? ICCameraDevice else { return }
        Task { @MainActor in sessionOpened(camera, error: error) }
    }

    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        Task { @MainActor in catalogReady(device) }
    }

    nonisolated func didRemove(_ device: ICDevice) {
        Task { @MainActor in removed(device) }
    }

    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: (any Error)?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: (any Error)?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}
