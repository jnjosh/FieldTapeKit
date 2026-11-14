import Foundation
import System
import Testing
@testable import FieldTapeKit

@Suite struct ListingTests {
    static let device = FieldDevice.simulated {
        Directory("tapes") {
            Directory("2026-220#02") {
                File("tape.json", data: Data("{}".utf8))
                File("track_1.wav", seconds: 1)
            }
        }
        Directory("mixdown") { File("side_a.wav", seconds: 2) }
    }

    // MARK: Listing

    @Test func listsTheRootInTheDevicesOrder() async throws {
        let root = try await Self.device.contentsOfDirectory(at: "")
        #expect(root.map(\.path) == [.op1Synth, .op1Drum, .op1Tapes, .op1Mixdown])
        #expect(root.allSatisfy { $0.isDirectory && $0.format == .folder && $0.size == 0 })
        #expect(try await Self.device.contentsOfDirectory(at: "/").map(\.name) == root.map(\.name))
    }

    @Test func listsAFolderWithFreshSizesAndFormats() async throws {
        let mixdown = try await Self.device.contentsOfDirectory(at: .op1Mixdown)
        #expect(mixdown.map(\.name) == ["side_a.wav", "side_b.wav", "readme.txt"])
        #expect(mixdown.map(\.format) == [.wav, .wav, .text])
        // 2 seconds of 16-bit stereo at 44.1 kHz, and an empty side.
        let twoSeconds = 44 + 2 * 44_100 * 4
        #expect(Array(mixdown.map(\.size).prefix(2)) == [twoSeconds, 44])
        #expect(mixdown[0].path == "mixdown/side_a.wav")
        #expect(mixdown[0].id == mixdown[0].path)
    }

    @Test func aTapeTrackIs32Bit() async throws {
        let track = try #require(try await Self.device.item(at: "tapes/2026-220#02/track_1.wav"))
        let oneSecond = 44 + 44_100 * 8
        #expect(track.size == oneSecond)
        #expect(try await Self.device.item(at: "tapes/2026-220#02/tape.json")?.format == .json)
    }

    // MARK: Case

    @Test func matchesIgnoringCaseAndAnswersWithTheDevicesSpelling() async throws {
        let item = try #require(try await Self.device.item(at: "TAPES/2026-220#02/Track_1.WAV"))
        #expect(item.path == "tapes/2026-220#02/track_1.wav")
        #expect(item.name == "track_1.wav")
        #expect(try await Self.device.contentsOfDirectory(at: "Mixdown").count == 3)
    }

    @Test func anExactMatchWinsOverOnesThatDifferInCase() async throws {
        let simulator = SimulatedMTPDevice()
        let tapes = await simulator.addFolder("tapes")
        await simulator.addFolder("probe 1-#a", in: tapes)
        await simulator.addFolder("PROBE 1-#A", in: tapes)
        let device = FieldDevice.simulated(simulator)
        #expect(try await device.item(at: "tapes/PROBE 1-#A")?.name == "PROBE 1-#A")
        #expect(try await device.item(at: "tapes/probe 1-#a")?.name == "probe 1-#a")

        // Neither matches exactly, so either could be meant.
        await #expect { try await device.item(at: "tapes/Probe 1-#A") } throws: { error in
            let error = error as? FieldError
            return error?.code == .ambiguousPath && error?.path == "tapes/Probe 1-#A"
        }
    }

    // MARK: Missing and not folders

    @Test func missingItemsAreNil() async throws {
        #expect(try await Self.device.item(at: "tapes/nope") == nil)
        #expect(try await Self.device.item(at: "nope/deeper/still") == nil)
        #expect(try await !Self.device.fileExists(at: "mixdown/side_c.wav"))
        #expect(try await Self.device.fileExists(at: "mixdown/side_b.wav"))
        #expect(try await Self.device.item(at: "") == nil)
    }

    @Test func listingAMissingFolderIsNotFound() async {
        await #expect { try await Self.device.contentsOfDirectory(at: "tapes/nope") } throws: { error in
            let error = error as? FieldError
            return error?.code == .notFound && error?.path == "tapes/nope"
                && error?.errorDescription == "There's nothing on the OP-1 at tapes/nope."
        }
        await #expect { try await Self.device.contentsOfDirectory(at: "../tapes") } throws: {
            ($0 as? FieldError)?.code == .notFound
        }
    }

    @Test func aFileIsNotADirectory() async {
        await #expect { try await Self.device.contentsOfDirectory(at: "mixdown/side_a.wav") } throws: { error in
            let error = error as? FieldError
            return error?.code == .notADirectory
                && error?.errorDescription == "On the OP-1, mixdown/side_a.wav is a file, not a folder."
        }
        await #expect { try await Self.device.item(at: "mixdown/side_a.wav/inside") } throws: {
            ($0 as? FieldError)?.code == .notADirectory
        }
    }

    @Test func aDisconnectIsReported() async {
        let device = FieldDevice.simulated(SimulatedMTPDevice(faults: [.silent(fromRequest: 1)]),
                                           timeout: .milliseconds(100), pingTimeout: .milliseconds(100))
        await #expect { try await device.contentsOfDirectory(at: .op1Tapes) } throws: { error in
            let error = error as? FieldError
            return error?.code == .disconnected && error?.path == .op1Tapes
        }
    }

    // MARK: Formats

    static let formats: [(UInt16, String, Bool, FieldFormat)] = [
        (0x3001, "tapes", true, .folder),
        (0x3008, "side_a.wav", false, .wav),
        (0x3007, "applefly.aif", false, .aiff),
        (0x3004, "tape.json", false, .json),
        (0x3004, "notes", false, .text),
        (0x3000, "readme.txt", false, .text),
        (0x3000, "you may create folders here", false, .other(0x3000)),
        (0x3008, "Converted.WAV", false, .wav),
        (0x300C, "x.mp3", false, .other(0x300C)),
    ]

    @Test(arguments: formats)
    func formatsComeFromTheMTPCode(code: UInt16, name: String, isFolder: Bool, format: FieldFormat) {
        #expect(FieldFormat(code: code, name: name, isFolder: isFolder) == format)
    }
}

@Suite struct SimulatedContentsTests {
    @Test func startsAsA173OP1WithNoTapes() async throws {
        let device = FieldDevice.simulated()
        #expect(try await device.contentsOfDirectory(at: .op1Tapes).isEmpty)
        #expect(try await device.contentsOfDirectory(at: "synth/slots").map(\.name) == (1...8).map(String.init))
        #expect(try await device.item(at: "drum/user/readme.txt")?.size == SimulatedNode.presetReadme.utf8.count)
        #expect(try await device.item(at: "mixdown/side_b.wav")?.size == 44)
        #expect(device.info.storage.freeSpace < device.info.storage.capacity)
    }

    @Test func lowercasesNamesAndReplacesFiles() async throws {
        let device = FieldDevice.simulated {
            Directory("MixDown") { File("SIDE_A.WAV", seconds: 1) }
            Directory("Tapes") { Directory("ABC- 012#-#") }
        }
        let mixdown = try await device.contentsOfDirectory(at: .op1Mixdown)
        #expect(mixdown.map(\.name) == ["side_a.wav", "side_b.wav", "readme.txt"])
        let oneSecond = 44 + 44_100 * 4
        #expect(mixdown[0].size == oneSecond)
        #expect(try await device.contentsOfDirectory(at: .op1Tapes).map(\.name) == ["abc- 012#-#"])
        #expect(try await device.contentsOfDirectory(at: "").count == 4)
    }

    @Test func buildsWithLoopsAndConditions() async throws {
        let withExtra = true
        let device = FieldDevice.simulated {
            Directory("tapes") {
                for number in 1...3 { Directory("tape \(number)") }
                if withExtra { Directory("extra") } else { Directory("none") }
            }
        }
        #expect(try await device.contentsOfDirectory(at: .op1Tapes).map(\.name) == ["tape 1", "tape 2", "tape 3", "extra"])
    }

    @Test func aFileAtTheRootIsAllowed() async throws {
        let device = FieldDevice.simulated { File("notes.txt", data: Data("hi".utf8)) }
        #expect(try await device.item(at: "notes.txt")?.format == .text)
    }
}
