import Foundation
import Testing
@testable import FieldTapeKit

@Suite struct FieldDeviceTests {
    @Test func connectingReadsTheDeviceAndStorageInfo() async throws {
        let simulator = SimulatedMTPDevice(serialNumber: "TEST1234", capacity: 5_000)
        await simulator.addFile("side_a.wav", data: Data(count: 1_200))
        let device = try await FieldDevice.connect(over: simulator)
        #expect(device.info.model == "OP-1")
        #expect(device.info.firmware == "1.7.3")
        #expect(device.info.isFirmwareTested)
        #expect(device.info.serialNumber == "TEST1234")
        #expect(device.info.storage == FieldStorage(capacity: 5_000, freeSpace: 3_800))
        #expect(await device.isConnected)
    }

    @Test func untestedFirmwareStillConnects() async throws {
        let device = try await FieldDevice.connect(over: SimulatedMTPDevice(firmware: "1.8.0"))
        #expect(device.info.firmware == "1.8.0")
        #expect(!device.info.isFirmwareTested)
        #expect(device.profile == .v1_7_3)
    }

    @Test func aSimulatedDeviceReportsWhatItsPTPRepliesSay() async throws {
        let simulator = SimulatedMTPDevice(serialNumber: "SAME")
        let overPTP = try await FieldDevice.connect(over: simulator)
        #expect(FieldDevice.simulated(simulator).info == overPTP.info)
        #expect(FieldDevice.simulated().info.isFirmwareTested)
    }

    @Test func aDeviceThatDoesntAnswerIsReportedDisconnected() async {
        let simulator = SimulatedMTPDevice(faults: [.silent(fromRequest: 1)])
        await #expect {
            try await FieldDevice.connect(over: simulator, timeout: .milliseconds(100), pingTimeout: .milliseconds(100))
        } throws: { ($0 as? FieldError)?.code == .disconnected }
    }

    @Test func removalAndSilenceBothDisconnect() async throws {
        let removed = FieldDevice.simulated()
        await removed.markRemoved()
        #expect(await !removed.isConnected)

        let silent = FieldDevice.simulated(SimulatedMTPDevice(faults: [.silent(fromRequest: 1)]),
                                            timeout: .milliseconds(100), pingTimeout: .milliseconds(100))
        _ = try? await silent.session.storageIDs()
        #expect(await !silent.isConnected)
    }

    @Test func everyConnectionHasItsOwnID() {
        #expect(FieldDevice.simulated().id != FieldDevice.simulated().id)
    }
}
