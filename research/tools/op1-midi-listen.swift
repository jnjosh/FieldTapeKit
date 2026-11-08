// Read-only: lists MIDI devices and prints every message the OP-1 sends, with timestamps, for a fixed time.
// Run while FieldKit talks to the OP-1 (plug in, or click its row) to see the replies to its SysEx requests.
// Usage (from research/): swift tools/op1-midi-listen.swift [seconds]
import CoreMIDI
import Foundation

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "90") ?? 90
let start = Date()

func name(_ object: MIDIObjectRef, _ key: CFString = kMIDIPropertyName) -> String {
    var value: Unmanaged<CFString>?
    guard MIDIObjectGetStringProperty(object, key, &value) == noErr, let value else { return "?" }
    return value.takeRetainedValue() as String
}

func stamp() -> String { String(format: "[%7.2f]", Date().timeIntervalSince(start)) }

for index in 0..<MIDIGetNumberOfDevices() {
    let device = MIDIGetDevice(index)
    var offline: Int32 = 0
    MIDIObjectGetIntegerProperty(device, kMIDIPropertyOffline, &offline)
    print("Device: \(name(device)), manufacturer \(name(device, kMIDIPropertyManufacturer)), model \(name(device, kMIDIPropertyModel)), offline \(offline)")
}

var client = MIDIClientRef()
MIDIClientCreateWithBlock("op1-listen" as CFString, &client) { notification in
    print("\(stamp()) MIDI setup changed, message ID \(notification.pointee.messageID.rawValue)")
}

var port = MIDIPortRef()
let status = MIDIInputPortCreateWithBlock(client, "in" as CFString, &port) { list, source in
    let sourceName = source.map { String(cString: $0.assumingMemoryBound(to: CChar.self)) } ?? "?"
    for packet in list.unsafeSequence() {
        let bytes = withUnsafeBytes(of: packet.pointee.data) { Array($0.prefix(Int(packet.pointee.length))) }
        print("\(stamp()) from \(sourceName), \(bytes.count) bytes: \(bytes.map { String(format: "%02x", $0) }.joined(separator: " "))")
    }
}
guard status == noErr else { fatalError("MIDIInputPortCreate failed: \(status)") }

var names = [UnsafeMutablePointer<CChar>]()
for index in 0..<MIDIGetNumberOfSources() {
    let source = MIDIGetSource(index)
    let sourceName = name(source)
    let tag = strdup(sourceName)!
    names.append(tag)
    MIDIPortConnectSource(port, source, tag)
    print("Listening to source: \(sourceName)")
}

print("\(stamp()) Listening for \(Int(seconds)) s")
RunLoop.main.run(until: Date().addingTimeInterval(seconds))
print("\(stamp()) Done")
