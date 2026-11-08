// Read-only: lists devices macOS ImageCaptureCore finds, with USB IDs, for a fixed time. Used to check whether the
// OP-1 is visible to ImageCaptureCore after entering MTP mode by SysEx versus by its own buttons.
// Usage: op1-icc-list [seconds]
import Foundation
import ImageCaptureCore

final class Watcher: NSObject, ICDeviceBrowserDelegate {
    let start = Date()
    func stamp() -> String { String(format: "[%6.2f]", Date().timeIntervalSince(start)) }
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        print("\(stamp()) found \(device.name ?? "?"), USB \(String(format: "%04X:%04X", device.usbVendorID, device.usbProductID)), transport \(device.transportType ?? "?"), capabilities \(device.capabilities)")
    }
    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        print("\(stamp()) removed \(device.name ?? "?")")
    }
}

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "30") ?? 30
let watcher = Watcher()
let browser = ICDeviceBrowser()
browser.delegate = watcher
browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
browser.start()
print("\(watcher.stamp()) browsing for \(Int(seconds)) s")
RunLoop.main.run(until: Date().addingTimeInterval(seconds))
print("\(watcher.stamp()) done")
