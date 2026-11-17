// Builds a simulated OP-1 and lists what's on it, as Testing with the Simulated OP-1 shows.
import FieldTapeKit

// snippet.build
let device = FieldDevice.simulated {
    SimulatedTape("2026-220#01", type: .vintage, seconds: [12, 0, 4.5])
    SimulatedTape("2026-276#01", seconds: [60, 60, 60, 60])
    Directory("mixdown") {
        File("side_a.wav", seconds: 69)
    }
    Directory("drum") {
        Directory("user") { File("kick.wav", seconds: 1) }
    }
}
// snippet.end

for tape in try await device.tapes() {
    print(tape.name, tape.duration)
}
print("Side A:", try await device.album().a.duration)
