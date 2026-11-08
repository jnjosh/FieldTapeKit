// Sends one Teenage Engineering SysEx request to the OP-1 over CoreMIDI and prints the replies.
// Usage:
//   op1-sysex greet          asks the OP-1 to identify itself (harmless; FieldKit sends this on every connect)
//   op1-sysex mtp [2|3]      the mode command FieldKit sends to enter MTP mode, payload [0x01, value], default 2
// Format, from the OP-1's replies and FieldKit (2026-11-08):
//   F0 00 20 76 <device 02> 40 <flags> <request id low 7 bits> <command> <7-bit packed payload> F7
//   flags: 0x40 = request, 0x20 = request ID present, low 5 bits = request ID high bits.
//   Replies clear 0x40 and start the payload with a status byte (0 = OK), then packed data.
// Never send command 0x03: FieldKit names it dfu, the firmware updater.
import CoreMIDI
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let start = Date()
func stamp() -> String { String(format: "[%6.2f]", Date().timeIntervalSince(start)) }

func pack(_ bytes: [UInt8]) -> [UInt8] {
    var out = [UInt8]()
    for groupStart in stride(from: 0, to: bytes.count, by: 7) {
        let group = bytes[groupStart..<min(groupStart + 7, bytes.count)]
        var flags: UInt8 = 0
        for (index, byte) in group.enumerated() where byte & 0x80 != 0 { flags |= 1 << index }
        out.append(flags)
        out.append(contentsOf: group.map { $0 & 0x7F })
    }
    return out
}

func unpack(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
    var out = [UInt8]()
    var index = bytes.startIndex
    while index < bytes.endIndex {
        let flags = bytes[index]
        let group = bytes[(index + 1)..<min(index + 8, bytes.endIndex)]
        for (bit, byte) in group.enumerated() { out.append(byte | (flags >> bit & 1 == 1 ? 0x80 : 0)) }
        index += 8
    }
    return out
}

let command: UInt8
let payload: [UInt8]
switch arguments.first {
case "greet":
    command = 0x01
    payload = []
case "mtp":
    let value = UInt8(arguments.dropFirst().first ?? "2") ?? 2
    guard value == 2 || value == 3 else { fatalError("mtp value must be 2 or 3") }
    command = 0x04
    payload = [0x01, value]
default:
    fatalError("usage: op1-sysex greet | mtp [2|3]")
}

let requestID = UInt16.random(in: 1..<0x1000)
var message: [UInt8] = [0xF0, 0x00, 0x20, 0x76, 0x02, 0x40, 0x60 | UInt8(requestID >> 7), UInt8(requestID & 0x7F), command]
message += pack(payload)
message.append(0xF7)

func midiName(_ object: MIDIObjectRef) -> String {
    var value: Unmanaged<CFString>?
    guard MIDIObjectGetStringProperty(object, kMIDIPropertyName, &value) == noErr, let value else { return "?" }
    return value.takeRetainedValue() as String
}

var client = MIDIClientRef()
MIDIClientCreateWithBlock("op1-sysex" as CFString, &client, nil)
var input = MIDIPortRef()
MIDIInputPortCreateWithBlock(client, "in" as CFString, &input) { list, _ in
    for packet in list.unsafeSequence() {
        let bytes = withUnsafeBytes(of: packet.pointee.data) { Array($0.prefix(Int(packet.pointee.length))) }
        print("\(stamp()) ← \(bytes.map { String(format: "%02x", $0) }.joined(separator: " "))")
        guard bytes.count >= 11, Array(bytes[0..<6]) == [0xF0, 0x00, 0x20, 0x76, 0x02, 0x40], bytes.last == 0xF7 else { continue }
        let id = UInt16(bytes[6] & 0x1F) << 7 | UInt16(bytes[7])
        let status = bytes[9]
        let data = unpack(bytes[10..<(bytes.count - 1)])
        let text = String(decoding: data, as: UTF8.self)
        print("\(stamp())   reply to request \(id)\(id == requestID ? " (ours)" : ""), command \(String(format: "0x%02x", bytes[8])), status \(status)\(data.isEmpty ? "" : ": \(text)")")
    }
}
var output = MIDIPortRef()
MIDIOutputPortCreate(client, "out" as CFString, &output)

var destination: MIDIEndpointRef?
for index in 0..<MIDIGetNumberOfSources() where midiName(MIDIGetSource(index)) == "OP-1" {
    MIDIPortConnectSource(input, MIDIGetSource(index), nil)
}
for index in 0..<MIDIGetNumberOfDestinations() where midiName(MIDIGetDestination(index)) == "OP-1" {
    destination = MIDIGetDestination(index)
}
guard let destination else { fatalError("No OP-1 MIDI destination. Is it plugged in and out of MTP mode?") }

print("\(stamp()) → \(message.map { String(format: "%02x", $0) }.joined(separator: " ")) (request \(requestID))")
var packetList = MIDIPacketList()
let packet = MIDIPacketListInit(&packetList)
_ = MIDIPacketListAdd(&packetList, MemoryLayout<MIDIPacketList>.size, packet, 0, message.count, message)
let status = MIDISend(output, destination, &packetList)
print("\(stamp()) MIDISend status \(status)")
RunLoop.main.run(until: Date().addingTimeInterval(6))
