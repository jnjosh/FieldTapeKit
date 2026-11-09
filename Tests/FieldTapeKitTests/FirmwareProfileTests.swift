import Foundation
import Testing
@testable import FieldTapeKit

@Suite struct FirmwareProfileTests {
    @Test func exactlyTestedFirmware() {
        let (profile, isTested) = FirmwareProfile.profile(for: "1.7.3")
        #expect(profile == .v1_7_3)
        #expect(isTested)
    }

    @Test(arguments: ["1.8", "1.7.4", "2.0.0", "1.7.3.1"])
    func newerFirmwareUsesTheNewestOlderProfile(firmware: String) {
        let (profile, isTested) = FirmwareProfile.profile(for: firmware)
        #expect(profile == .v1_7_3)
        #expect(!isTested)
    }

    @Test func olderFirmwareUsesTheOldestProfile() {
        let (profile, isTested) = FirmwareProfile.profile(for: "1.6.0")
        #expect(profile == FirmwareProfile.tested.first)
        #expect(!isTested)
    }

    @Test(arguments: ["", "beta", "1.x", "1..3", "-1.0"])
    func unreadableVersionsUseTheNewestProfile(firmware: String) {
        let (profile, isTested) = FirmwareProfile.profile(for: firmware)
        #expect(profile == FirmwareProfile.tested.last)
        #expect(!isTested)
    }

    @Test func versionsCompareNumberByNumber() throws {
        let v = { (string: String) throws -> FirmwareVersion in try #require(FirmwareVersion(string)) }
        #expect(try v("1.10") > v("1.9"))
        #expect(try v("1.7") == v("1.7.0"))
        #expect(try v("1.7").hashValue == v("1.7.0").hashValue)
        #expect(try v("1.7.3") < v("1.7.10"))
        #expect(try v("1.7.3").description == "1.7.3")
    }
}
