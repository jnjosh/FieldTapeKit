import FieldTapeKit
import Foundation
import System

/// Checks that run the same way against the simulator and a real OP-1, to keep the simulator honest
/// (ADR 0002, section 8).
///
/// They use only FieldTapeKit's public API, so they check what apps see. They read the OP-1 and never change it;
/// copies go into a folder the caller gives. Steps 8 to 10 of the plan add writes. None of them depends on what's on
/// the OP-1. A check that needs something that isn't there, such as a tape, is skipped.
public enum Conformance {
    public struct Result: Sendable, Hashable, Identifiable {
        public enum Outcome: Sendable, Hashable {
            case pass
            case fail(String)
            case skipped(String)
        }

        public let name: String
        public let outcome: Outcome
        /// What a passing check found worth recording, such as a copy's SHA-256.
        public let detail: String?
        public var id: String { name }

        init(name: String, outcome: Outcome, detail: String? = nil) {
            self.name = name
            self.outcome = outcome
            self.detail = detail
        }
    }

    public struct Check: Sendable {
        public let name: String
        /// Takes the folder for copies, and returns a detail to record.
        let body: @Sendable (FieldDevice, URL) async throws -> String?

        init(_ name: String, _ body: @escaping @Sendable (FieldDevice) async throws -> Void) {
            self.name = name
            self.body = { device, _ in
                try await body(device)
                return nil
            }
        }

        /// A check that copies files into `workspace`, and returns what it copied.
        init(_ name: String, copying body: @escaping @Sendable (FieldDevice, _ workspace: URL) async throws -> String) {
            self.name = name
            self.body = body
        }

        /// Runs the check, copying anything it copies into `workspace`, a folder that exists. It never throws: a
        /// failure, an unexpected error or a skip is its outcome.
        public func run(on device: FieldDevice, workspace: URL) async -> Result {
            do {
                let detail = try await body(device, workspace)
                return Result(name: name, outcome: .pass, detail: detail)
            } catch let skip as Skip {
                return Result(name: name, outcome: .skipped(skip.reason))
            } catch let failure as Failure {
                return Result(name: name, outcome: .fail(failure.message))
            } catch {
                let description = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                return Result(name: name, outcome: .fail("Unexpected error: \(description)"))
            }
        }
    }

    /// Every check, in order. Copies of OP-1 files are left in `workspace`, a folder that exists, so they can be
    /// compared with copies made another way, such as on a Mac.
    public static func run(on device: FieldDevice, workspace: URL) async -> [Result] {
        var results: [Result] = []
        for check in checks { results.append(await check.run(on: device, workspace: workspace)) }
        return results
    }

    /// Every check: listing first, then tapes, then reading and copying.
    public static let checks = listingChecks + tapeChecks + readingChecks

    struct Failure: Error {
        let message: String
    }

    struct Skip: Error {
        let reason: String
    }

    static func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw Failure(message: message()) }
    }

    static func expectError(_ code: FieldError.Code, path: FilePath, _ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch let error as FieldError {
            try expect(error.code == code, "expected \(code) for \(path), got \(error.code)")
            try expect(error.path == path, "expected the error's path to be \(path), got \(error.path?.string ?? "none")")
            return
        }
        throw Failure(message: "expected \(code) for \(path), but nothing was thrown")
    }

    /// A name nothing on an OP-1 has.
    static let missing = "fieldtapekit-conformance-missing"

    // MARK: Listing

    static let listingChecks: [Check] = [
        Check("The root holds the four well-known folders") { device in
            let root = try await device.contentsOfDirectory(at: "")
            for path in [FilePath.op1Synth, .op1Drum, .op1Tapes, .op1Mixdown] {
                let item = root.first { $0.path == path }
                try expect(item != nil, "\(path) isn't listed at the root")
                try expect(item?.isDirectory == true && item?.format == .folder, "\(path) isn't a folder")
            }
            let slash = try await device.contentsOfDirectory(at: "/")
            try expect(slash == root, "listing / differs from listing the empty path")
        },
        Check("Every listed item's path is its folder's path and its name") { device in
            for folder in [FilePath(""), .op1Tapes, .op1Mixdown] {
                for item in try await device.contentsOfDirectory(at: folder) {
                    try expect(item.path == folder.appending(item.name), "\(item.path) isn't \(folder) and \(item.name)")
                    try expect(item.id == item.path, "\(item.path)'s id isn't its path")
                }
            }
        },
        Check("Names are lowercase") { device in
            for folder in [FilePath(""), .op1Tapes, .op1Mixdown, .op1Synth, .op1Drum] {
                for item in try await device.contentsOfDirectory(at: folder) {
                    try expect(item.name == item.name.lowercased(), "\(item.path) isn't lowercase")
                }
            }
        },
        Check("Lookups ignore case and answer with the OP-1's spelling") { device in
            let item = try await device.item(at: "MIXDOWN/Side_A.WAV")
            try expect(item?.path == "mixdown/side_a.wav", "MIXDOWN/Side_A.WAV found \(item?.path.string ?? "nothing")")
            let listed = try await device.contentsOfDirectory(at: "Mixdown").map(\.path)
            try expect(listed.contains("mixdown/side_a.wav"), "listing Mixdown didn't answer with mixdown/side_a.wav")
        },
        Check("item(at:) agrees with the listing") { device in
            for listed in try await device.contentsOfDirectory(at: .op1Mixdown) {
                let item = try await device.item(at: listed.path)
                try expect(item == listed, "item(at: \(listed.path)) differs from its listing")
            }
        },
        Check("The album sides are WAV files, and the readmes text") { device in
            for name in ["side_a.wav", "side_b.wav"] {
                let side = try await device.item(at: FilePath.op1Mixdown.appending(name))
                try expect(side?.format == .wav && side?.isDirectory == false, "mixdown/\(name) isn't a WAV file")
                try expect((side?.size ?? 0) >= 44, "mixdown/\(name) is shorter than a WAV header")
            }
            let readme = try await device.item(at: "mixdown/readme.txt")
            try expect(readme?.format == .text, "mixdown/readme.txt isn't text")
        },
        Check("A tape's tape.json is JSON and its tracks are WAV files") { device in
            guard let tape = try await device.contentsOfDirectory(at: .op1Tapes).first(where: \.isDirectory) else {
                throw Skip(reason: "There are no tapes on the OP-1.")
            }
            let contents = try await device.contentsOfDirectory(at: tape.path)
            let json = contents.first { $0.name == "tape.json" }
            try expect(json?.format == .json, "\(tape.path)/tape.json isn't JSON")
            for track in contents where track.name.hasPrefix("track_") {
                try expect(track.format == .wav, "\(track.path) isn't a WAV file")
            }
        },
        Check("Something missing is nil, and doesn't exist") { device in
            let path = FilePath.op1Tapes.appending(missing)
            try expect(try await device.item(at: path) == nil, "\(path) was found")
            try expect(try await !device.fileExists(at: path), "\(path) exists")
            try expect(try await device.item(at: path.appending("deeper")) == nil, "\(path)/deeper was found")
            try expect(try await device.fileExists(at: "mixdown/side_a.wav"), "mixdown/side_a.wav doesn't exist")
        },
        Check("Listing a missing folder is notFound") { device in
            let path = FilePath.op1Tapes.appending(missing)
            try await expectError(.notFound, path: path) { _ = try await device.contentsOfDirectory(at: path) }
        },
        Check("Listing a file is notADirectory") { device in
            let path: FilePath = "mixdown/side_a.wav"
            try await expectError(.notADirectory, path: path) { _ = try await device.contentsOfDirectory(at: path) }
            // A lookup through a file names the file it found on the way.
            try await expectError(.notADirectory, path: path) { _ = try await device.item(at: path.appending("inside")) }
        },
    ]
}
