// Watches for an OP-1 in MTP mode and reports each connection event, as Getting Started shows.
// With no OP-1 plugged in, `swift run WatchingForAnOP1` waits until one is.
import FieldTapeKit
import Foundation

// snippet.watch
func watch() async {
    do {
        for try await event in FieldDevice.connections {
            switch event {
            case .connected(let device):
                print("Connected: firmware \(device.info.firmware)")
            case .disconnected(let id):
                print("Disconnected: \(id)")
            case .couldNotOpen(let error):
                print("Found an OP-1 but couldn't open it: \(error.localizedDescription)")
            }
        }
    } catch {
        print(error.localizedDescription)   // The person didn't allow access to connected devices.
    }
}
// snippet.end

// snippet.copyEverything
func copyEveryTape(to folder: URL) async throws {
    for try await event in FieldDevice.connections {
        guard case .connected(let device) = event else { continue }
        for tape in try await device.tapes() where tape.isSound && !tape.isEmpty {
            let archive = try await device.copyTape(tape, to: folder)
            print("Copied \(tape.name) to \(archive.url.lastPathComponent)")
        }
    }
}
// snippet.end

// snippet.firmware
func warnIfUntested(_ device: FieldDevice) {
    if !device.info.isFirmwareTested {
        print("FieldTapeKit hasn't been tested on firmware \(device.info.firmware) yet. Keep a copy of anything you restore.")
    }
}
// snippet.end

await watch()
