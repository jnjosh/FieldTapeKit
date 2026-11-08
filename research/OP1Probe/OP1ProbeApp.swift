// Probe for ADR 0001: can raw MTP operations sent through ImageCaptureCore's PTP
// passthrough list and download the OP-1 Field's audio files?

import CryptoKit
@preconcurrency import ImageCaptureCore
import SwiftUI

// MARK: - PTP/MTP wire format

enum PTPOp: UInt16 {
    case getDeviceInfo = 0x1001
    case openSession = 0x1002
    case getStorageIDs = 0x1004
    case getObjectHandles = 0x1007
    case getObjectInfo = 0x1008
    case getObject = 0x1009
    case deleteObject = 0x100B
    case sendObjectInfo = 0x100C
    case sendObject = 0x100D
    case getPartialObject = 0x101B
}

enum PTPResponse {
    static let ok: UInt16 = 0x2001
    static let sessionNotOpen: UInt16 = 0x2003
    static let sessionAlreadyOpen: UInt16 = 0x201E
}

enum PTPContainer {
    static let command: UInt16 = 1
    static let data: UInt16 = 2
    static let response: UInt16 = 3
}

enum PTPError: Error, CustomStringConvertible {
    case truncated(offset: Int)
    case noResponse(PTPOp)
    case failed(PTPOp, UInt16)
    case missingObject(String)

    var description: String {
        switch self {
        case .truncated(let offset): "dataset truncated at byte \(offset)"
        case .noResponse(let op): "\(op) returned no PTP response"
        case .failed(let op, let code): "\(op) failed with response \(code.hex)"
        case .missingObject(let name): "couldn't find \(name)"
        }
    }
}

enum PTP {
    static let allStorages: UInt32 = 0xFFFF_FFFF
    static let rootParent: UInt32 = 0xFFFF_FFFF
    static let associationFormat: UInt16 = 0x3001
    static let containerHeaderSize = 12
    static let emptyWAVSize: UInt32 = 44
    static let wavFormat: UInt16 = 0x3008
    static let trackFilenames: Set<String> = ["track_1.wav", "track_2.wav", "track_3.wav", "track_4.wav"]
    static let tapeWriteFilename = "track_1.wav"
    static let partialProbeChunk: UInt32 = 16 * 1024
    static let mixdownTestPath = "mixdown/side_b.wav"
    /// SHA-256 of the copy of side_b.wav backed up on the Mac on 2026-11-08. The mixdown test only deletes
    /// side_b.wav if the OP-1's file still matches it, so a restore from that backup is always possible.
    static let mixdownBackupSHA256 = "9204518b5ef84a37dcf171ed29082a1261933c625d355ea925b7ab5f361a97aa"
    static let chunkSizes: [UInt32] = [64 * 1024, 256 * 1024, 512 * 1024, 1024 * 1024]
    static let tapeJSONFilename = "tape.json"
    static let textFormat: UInt16 = 0x3004
    static let genericFolder: UInt16 = 0x0001
    /// Characters the OP-1 seems to allow in tape names, per the user (2026-11-08). Not confirmed.
    static let tapeNameCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789#- ")

    /// Characters in `name` outside the set the OP-1 is thought to allow.
    static func unexpectedTapeNameCharacters(_ name: String) -> [Character] {
        var seen = Set<Character>()
        return name.filter { !tapeNameCharacters.contains($0) && seen.insert($0).inserted }.map { $0 }
    }

    static func clipCount(_ json: Data) -> Int? {
        ((try? JSONSerialization.jsonObject(with: json) as? [String: Any])?["clips"] as? [Any])?.count
    }
    /// Tape tracks are stereo 32-bit PCM.
    static let tapeFrameBytes: UInt64 = 8
    /// The OP-1 holds at most 8 tapes, each up to 6 minutes long (per the user, 2026-11-08).
    static let maxTapes = 8
    static let maxTapeFrames: UInt64 = 6 * 60 * 44_100

    /// Checks a tape.json against its track sizes: each clip's `ch` names a track, and each track is a 44-byte header plus
    /// 8 bytes per frame up to the end of its last clip. Returns the problems found, or none.
    static func tapeProblems(json: Data, trackSizes: [String: UInt64]) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let clips = root["clips"] as? [[String: Any]] else { return ["tape.json has no clips array"] }
        var lastFrame = [Int: UInt64]()
        var problems = [String]()
        for clip in clips {
            guard let ch = clip["ch"] as? Int, let start = clip["start"] as? Int, let stop = clip["stop"] as? Int else {
                problems.append("clip missing ch, start or stop: \(clip)")
                continue
            }
            if !(0..<4).contains(ch) { problems.append("clip on unknown track ch \(ch)") }
            if stop < start || start < 0 { problems.append("clip on ch \(ch) runs \(start) to \(stop)") }
            if UInt64(max(stop, 0)) > maxTapeFrames { problems.append("clip on ch \(ch) ends past 6 minutes, at frame \(stop)") }
            lastFrame[ch] = max(lastFrame[ch] ?? 0, UInt64(max(stop, 0)))
        }
        for ch in 0..<4 {
            let name = "track_\(ch + 1).wav"
            guard let size = trackSizes[name] else {
                problems.append("\(name) missing")
                continue
            }
            let expected = UInt64(emptyWAVSize) + tapeFrameBytes * (lastFrame[ch] ?? 0)
            if size != expected { problems.append("\(name) is \(size) bytes, clips imply \(expected)") }
        }
        return problems
    }

    static func command(_ op: PTPOp, transactionID: UInt32, params: [UInt32]) -> Data {
        var data = Data()
        data.appendLE(UInt32(containerHeaderSize + params.count * 4))
        data.appendLE(PTPContainer.command)
        data.appendLE(op.rawValue)
        data.appendLE(transactionID)
        params.forEach { data.appendLE($0) }
        return data
    }

    /// Whether ImageCaptureCore hands back the data phase with its container header
    /// isn't documented, so strip the header only when one is really there.
    static func payload(_ data: Data, op: PTPOp) -> Data {
        let data = Data(data)
        var reader = PTPReader(data)
        guard let length = try? reader.u32(), let type = try? reader.u16(), let code = try? reader.u16(),
              length == data.count, type == PTPContainer.data, code == op.rawValue
        else { return data }
        return data.dropFirst(containerHeaderSize)
    }

    static func responseCode(_ data: Data) -> UInt16? {
        var reader = PTPReader(data)
        guard (try? reader.u32()) != nil, (try? reader.u16()) == PTPContainer.response else { return nil }
        return try? reader.u16()
    }

    static func responseParams(_ data: Data) -> [UInt32] {
        var reader = PTPReader(data)
        var params: [UInt32] = []
        guard (try? reader.u32()) != nil, (try? reader.u32()) != nil, (try? reader.u32()) != nil else { return [] }
        while let param = try? reader.u32() { params.append(param) }
        return params
    }

    /// An empty tape track is just a 44-byte RIFF header.
    static func isBlankTrack(_ data: Data) -> Bool {
        data.count == Int(emptyWAVSize) && data.starts(with: Array("RIFF".utf8))
    }

    /// How many byte positions differ, counting any length difference, and where the first one is.
    static func differences(_ first: Data, _ second: Data) -> (count: Int, firstOffset: Int?) {
        let a = Array(first), b = Array(second)
        let shared = min(a.count, b.count)
        var count = 0
        var firstOffset: Int?
        for index in 0..<shared where a[index] != b[index] {
            count += 1
            if firstOffset == nil { firstOffset = index }
        }
        if a.count != b.count { firstOffset = firstOffset ?? shared }
        return (count + abs(a.count - b.count), firstOffset)
    }

    static func objectInfoDataset(storageID: UInt32, format: UInt16, size: UInt32, parent: UInt32, filename: String, associationType: UInt16 = 0) -> Data {
        var data = Data()
        data.appendLE(storageID)
        data.appendLE(format)
        data.appendLE(UInt16(0)) // ProtectionStatus
        data.appendLE(size)
        data.appendLE(UInt16(0)) // ThumbFormat
        for _ in 0..<6 { data.appendLE(UInt32(0)) } // Thumb and image dimensions
        data.appendLE(parent)
        data.appendLE(associationType)
        data.appendLE(UInt32(0)) // AssociationDesc
        data.appendLE(UInt32(0)) // SequenceNumber
        data.appendPTPString(filename)
        for _ in 0..<3 { data.appendPTPString("") } // CaptureDate, ModificationDate, Keywords
        return data
    }
}

struct PTPReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) {
        bytes = Array(data)
    }

    mutating func u8() throws -> UInt8 {
        guard offset < bytes.count else { throw PTPError.truncated(offset: offset) }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u16() throws -> UInt16 {
        let low = try u8(), high = try u8()
        return UInt16(low) | UInt16(high) << 8
    }

    mutating func u32() throws -> UInt32 {
        let low = try u16(), high = try u16()
        return UInt32(low) | UInt32(high) << 16
    }

    /// One-byte character count (including the terminator), then UTF-16LE.
    mutating func string() throws -> String {
        let count = Int(try u8())
        guard count > 0 else { return "" }
        var units: [UInt16] = []
        for _ in 0..<count { units.append(try u16()) }
        return String(decoding: units.dropLast(), as: UTF16.self)
    }

    mutating func u16Array() throws -> [UInt16] {
        try (0..<(try u32())).map { _ in try u16() }
    }

    mutating func u32Array() throws -> [UInt32] {
        try (0..<(try u32())).map { _ in try u32() }
    }
}

struct PTPDeviceInfo {
    let standardVersion: UInt16
    let vendorExtensionID: UInt32
    let vendorExtensionDescription: String
    let operations: [UInt16]
    let manufacturer: String
    let model: String
    let deviceVersion: String
    let serialNumber: String

    init(_ data: Data) throws {
        var reader = PTPReader(data)
        standardVersion = try reader.u16()
        vendorExtensionID = try reader.u32()
        _ = try reader.u16() // VendorExtensionVersion
        vendorExtensionDescription = try reader.string()
        _ = try reader.u16() // FunctionalMode
        operations = try reader.u16Array()
        _ = try reader.u16Array() // EventsSupported
        _ = try reader.u16Array() // DevicePropertiesSupported
        _ = try reader.u16Array() // CaptureFormats
        _ = try reader.u16Array() // ImageFormats
        manufacturer = try reader.string()
        model = try reader.string()
        deviceVersion = try reader.string()
        serialNumber = try reader.string()
    }
}

struct PTPObjectInfo {
    let storageID: UInt32
    let format: UInt16
    let compressedSize: UInt32
    let parent: UInt32
    let associationType: UInt16
    let filename: String

    var isFolder: Bool { format == PTP.associationFormat || associationType != 0 }

    init(_ data: Data) throws {
        var reader = PTPReader(data)
        storageID = try reader.u32()
        format = try reader.u16()
        _ = try reader.u16() // ProtectionStatus
        compressedSize = try reader.u32()
        _ = try reader.u16() // ThumbFormat
        for _ in 0..<6 { _ = try reader.u32() } // Thumb and image dimensions
        parent = try reader.u32()
        associationType = try reader.u16()
        _ = try reader.u32() // AssociationDesc
        _ = try reader.u32() // SequenceNumber
        filename = try reader.string()
    }
}

extension Data {
    fileprivate mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    fileprivate mutating func appendPTPString(_ string: String) {
        guard !string.isEmpty else { return append(0) }
        let units = Array(string.utf16) + [0]
        append(UInt8(units.count))
        units.forEach { appendLE($0) }
    }

    var sha256: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }

    func hexDump(limit: Int = 64) -> String {
        let shown = prefix(limit).map { String(format: "%02x", $0) }.joined(separator: " ")
        return count > limit ? "\(shown) … (\(count) bytes)" : shown
    }
}

extension UInt16 {
    var hex: String { String(format: "0x%04X", self) }
}

extension UInt32 {
    var hex: String { String(format: "0x%08X", self) }
}

// MARK: - Probe

struct ProbeObject: Identifiable {
    let handle: UInt32
    let path: String
    let info: PTPObjectInfo

    var id: UInt32 { handle }
    var isAudio: Bool { ["aif", "aiff", "wav"].contains((path as NSString).pathExtension.lowercased()) }
    var isTapeOrAlbum: Bool {
        guard !info.isFolder, let top = path.split(separator: "/").first?.lowercased() else { return false }
        return top == "tapes" || top == "mixdown"
    }

    /// Copies the smallest real tape track, or the largest with `largest`, over track_1 of a tape with no audio. Tape folders store
    /// .wav files under fixed names, and an all-blank tape has no recording at risk.
    static func tapeWritePlan(in objects: [ProbeObject], largest: Bool = false) -> (source: ProbeObject, folder: ProbeObject, blank: ProbeObject)? {
        let tracks = objects.filter { $0.path.hasPrefix("tapes/") && PTP.trackFilenames.contains($0.info.filename) }
        let real = tracks.filter { $0.info.compressedSize > PTP.emptyWAVSize }
        let bySize: (ProbeObject, ProbeObject) -> Bool = { $0.info.compressedSize < $1.info.compressedSize }
        let blankTapes = objects
            .filter { $0.info.isFolder && $0.path.hasPrefix("tapes/") }
            .sorted { $0.path < $1.path }
        for folder in blankTapes {
            let own = tracks.filter { $0.info.parent == folder.handle }
            guard own.count == PTP.trackFilenames.count, own.allSatisfy({ $0.info.compressedSize == PTP.emptyWAVSize }),
                  let blank = own.first(where: { $0.info.filename == PTP.tapeWriteFilename }),
                  let source = largest ? real.max(by: bySize) : real.min(by: bySize)
            else { continue }
            return (source, folder, blank)
        }
        return nil
    }

    /// Tapes with all four tracks and a tape.json, by path.
    private static func completeTapes(in objects: [ProbeObject]) -> [(tape: ProbeObject, tracks: [ProbeObject])] {
        objects.filter { $0.info.isFolder && $0.path.hasPrefix("tapes/") }.sorted { $0.path < $1.path }.compactMap { tape in
            let files = objects.filter { $0.info.parent == tape.handle && !$0.info.isFolder }
            let tracks = files.filter { PTP.trackFilenames.contains($0.info.filename) }
            guard tracks.count == PTP.trackFilenames.count, files.contains(where: { $0.info.filename == PTP.tapeJSONFilename }) else { return nil }
            return (tape, tracks)
        }
    }

    /// The real tape with the least audio, or the most with `largest`.
    static func copySource(in objects: [ProbeObject], largest: Bool = false) -> ProbeObject? {
        let real = completeTapes(in: objects).filter { !$0.tracks.allSatisfy { $0.info.compressedSize == PTP.emptyWAVSize } }
        let audio: ([ProbeObject]) -> UInt64 = { $0.reduce(0) { $0 + UInt64($1.info.compressedSize) } }
        let ordered = real.sorted { audio($0.tracks) < audio($1.tracks) }
        return (largest ? ordered.last : ordered.first)?.tape
    }

    /// Copies a whole tape, its four tracks and tape.json, onto a tape whose tracks are all blank. The source is the tape with the
    /// least audio, or the most with `largest`. Both must have a tape.json.
    static func wholeTapePlan(in objects: [ProbeObject], largest: Bool = false) -> (source: ProbeObject, target: ProbeObject)? {
        guard let target = completeTapes(in: objects).first(where: { $0.tracks.allSatisfy { $0.info.compressedSize == PTP.emptyWAVSize } })?.tape,
              let source = copySource(in: objects, largest: largest) else { return nil }
        return (source, target)
    }
}

@MainActor
@Observable
final class Probe: NSObject {
    private(set) var status = "Starting"
    private(set) var lines: [String] = []
    private(set) var objects: [ProbeObject] = []
    private(set) var isBusy = false
    private(set) var hasCamera = false
    private(set) var restorePath = UserDefaults.standard.string(forKey: Probe.restorePathKey)
    let logURL: URL

    private(set) var restoreTapePath = UserDefaults.standard.string(forKey: Probe.restoreTapePathKey)

    private static let restorePathKey = "restorePath"
    private static let restoreTapePathKey = "restoreTapePath"
    private(set) var createdTapePath = UserDefaults.standard.string(forKey: Probe.createdTapePathKey)
    private static let createdTapePathKey = "createdTapePath"
    private static let newTapeNameKey = "newTapeName"
    @ObservationIgnored private let browser = ICDeviceBrowser()
    @ObservationIgnored private var camera: ICCameraDevice?
    @ObservationIgnored private var hasRun = false
    @ObservationIgnored private var isBrowsing = false
    @ObservationIgnored private var transactionID: UInt32 = 0
    @ObservationIgnored private let started = Date()
    @ObservationIgnored private let documents = URL.documentsDirectory

    override init() {
        let stamp = Date.now.formatted(.iso8601.year().month().day().timeZone(separator: .omitted).time(includingFractionalSeconds: false).timeSeparator(.omitted))
        logURL = URL.documentsDirectory.appending(path: "probe-\(stamp).txt")
        super.init()
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(
            rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        )!
    }

    func start() async {
        let device = UIDevice.current
        log("\(device.model), \(device.systemName) \(device.systemVersion)")

        // The iOS 27.2 simulator's ICDeviceBrowser doesn't implement authorization and crashes.
        #if targetEnvironment(simulator)
        status = "Simulator has no USB devices"
        log(status)
        return
        #endif

        // A missing authorization callback shouldn't block browsing.
        browser.requestContentsAuthorization { [self] contents in
            Task { @MainActor in
                log("Contents authorization: \(contents.rawValue)")
                browser.requestControlAuthorization { [self] control in
                    Task { @MainActor in
                        log("Control authorization: \(control.rawValue)")
                        startBrowsing()
                    }
                }
            }
        }

        try? await Task.sleep(for: .seconds(15))
        if !isBrowsing {
            log("No authorization callback after 15s, browsing anyway")
            startBrowsing()
        }
    }

    private func startBrowsing() {
        guard !isBrowsing else { return }
        isBrowsing = true
        browser.start()
        status = "Waiting for OP-1 (set it to MTP mode)"
        log("Browsing for cameras")
    }

    func runProbe() async {
        guard camera != nil, !isBusy else { return }
        hasRun = true
        isBusy = true
        defer { isBusy = false }
        objects = []
        status = "Probing"

        do {
            try await logDeviceInfo()
            let storages = try PTPReader.u32Array(from: await send(.getStorageIDs).payload)
            log("Storages: \(storages.map(\.hex))")

            await logAllStoragesRootCount()
            for storage in storages {
                try await walk(storage: storage)
            }
            logCatalogSummary()
            await logFolderRules()
            await logTapeFiles()

            // Empty tape tracks are header-only WAVs, which prove nothing about downloading audio.
            let files = objects.filter { !$0.info.isFolder && $0.info.compressedSize > PTP.emptyWAVSize }
            let audio = files.filter(\.isAudio)
            let candidate = (audio.isEmpty ? files : audio).min { $0.info.compressedSize < $1.info.compressedSize }
            guard let candidate else {
                status = "FAIL: no downloadable files listed"
                log(status)
                return
            }
            let intact = try await download(candidate)
            let listed = !objects.filter(\.isTapeOrAlbum).isEmpty
            status = listed && intact ? "PASS" : "FAIL: tapes/albums listed \(listed), download intact \(intact)"
            log("Verdict: \(status)")
        } catch {
            status = "FAIL: \(error)"
            log(status)
        }
    }

    func downloadTapped(_ object: ProbeObject) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await download(object)
        } catch {
            log("Download failed: \(error)")
        }
    }

    var canWriteTest: Bool { ProbeObject.tapeWritePlan(in: objects) != nil && restorePath == nil && restoreTapePath == nil && !isBusy }
    var canRestore: Bool { restorePath != nil && hasCamera && !objects.isEmpty && !isBusy }


    private var blankBackupURL: URL { documents.appending(path: "blank-track-backup.wav") }

    /// Round trip: replace a blank track with a copy of a real one, read it back, and compare every byte.
    /// MTP can't overwrite, so the blank is verified and saved first, then deleted.
    /// `large` copies the biggest tape track instead.
    func runTapeWriteTest(large: Bool = false) async {
        guard let (source, folder, blank) = ProbeObject.tapeWritePlan(in: objects, largest: large), restorePath == nil, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let filename = blank.info.filename
        status = "Writing \(blank.path)"

        do {
            log("Tape write test: \(source.path) → \(blank.path)")
            let readBegin = Date()
            let original = try await send(.getObject, [source.handle]).payload
            log("Read \(original.count) bytes in \(rate(original.count, since: readBegin)), SHA-256 \(original.sha256)")
            guard original.count == Int(source.info.compressedSize) else {
                status = "WRITE STOPPED: source read was the wrong size"
                log(status)
                return
            }

            let blankBytes = try await send(.getObject, [blank.handle]).payload
            guard PTP.isBlankTrack(blankBytes) else {
                status = "WRITE STOPPED: \(blank.path) isn't a blank track"
                log(status)
                return
            }
            try blankBytes.write(to: blankBackupURL)
            guard try Data(contentsOf: blankBackupURL) == blankBytes else {
                status = "WRITE STOPPED: blank track backup didn't verify"
                log(status)
                return
            }
            log("Backed up blank track, \(blankBytes.count) bytes: \(blankBytes.hexDump())")

            setRestorePath(blank.path)
            _ = try await send(.deleteObject, [blank.handle, 0])
            objects.removeAll { $0.handle == blank.handle }

            do {
                try await sendFile(original, format: source.info.format, filename: filename, folder: folder)
                guard let copy = try await find(filename, in: folder, path: blank.path) else {
                    status = "WRITE FAIL: copy not listed after SendObject"
                    log(status)
                    return
                }
                objects.append(copy)
                let readBack = try await send(.getObject, [copy.handle]).payload
                log("Read back \(readBack.count) bytes, SHA-256 \(readBack.sha256)")
                let intact = readBack == original
                if !intact {
                    let difference = PTP.differences(original, readBack)
                    log("Sizes \(original.count) and \(readBack.count), \(difference.count) bytes differ, first at offset \(difference.firstOffset ?? 0)")
                    try original.write(to: documents.appending(path: "\(source.handle.hex)-\(source.info.filename)"))
                    try readBack.write(to: documents.appending(path: "\(copy.handle.hex)-\(copy.info.filename)"))
                    log("Saved both files to Documents for comparison")
                }
                status = intact ? "WRITE PASS: copy matches original exactly" : "WRITE FAIL: copy differs from original"
                log("Verdict: \(status)")
            } catch {
                log("WRITE FAIL: \(error). Putting the blank track back.")
                try await restoreBlankTrack()
                status = "WRITE FAIL: \(error). Blank track restored."
                log(status)
            }
        } catch {
            status = "WRITE FAIL: \(error)"
            log(status)
        }
    }

    /// Puts the blank track back after the test, so the tape ends as it began.
    func restoreTapped() async {
        guard canRestore else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await restoreBlankTrack()
        } catch {
            status = "Restore failed: \(error)"
            log(status)
        }
    }

    private func restoreBlankTrack() async throws {
        guard let restorePath else { return }
        let folderPath = (restorePath as NSString).deletingLastPathComponent
        let filename = (restorePath as NSString).lastPathComponent
        guard let folder = objects.first(where: { $0.info.isFolder && $0.path == folderPath }) else {
            throw PTPError.missingObject(folderPath)
        }
        let blankBytes = try Data(contentsOf: blankBackupURL)
        guard PTP.isBlankTrack(blankBytes) else { throw PTPError.missingObject("blank track backup") }

        log("Restoring blank track at \(restorePath)")
        if let written = try await find(filename, in: folder, path: restorePath) {
            _ = try await send(.deleteObject, [written.handle, 0])
            objects.removeAll { $0.handle == written.handle }
        }
        try await sendFile(blankBytes, format: PTP.wavFormat, filename: filename, folder: folder)
        guard let restored = try await find(filename, in: folder, path: restorePath) else {
            throw PTPError.missingObject(restorePath)
        }
        objects.append(restored)
        guard try await send(.getObject, [restored.handle]).payload == blankBytes else {
            throw PTPError.missingObject("matching \(restorePath)")
        }
        setRestorePath(nil)
        status = "Restored blank track \(restorePath)"
        log(status)
    }

    var canWholeTapeTest: Bool { ProbeObject.wholeTapePlan(in: objects) != nil && restorePath == nil && restoreTapePath == nil && !isBusy }
    var canRestoreTape: Bool { restoreTapePath != nil && hasCamera && !objects.isEmpty && !isBusy }
    private var tapeBackupFolder: URL { documents.appending(path: "tape-backup") }
    /// The tape.json the copy wrote, kept so later probe runs can tell whether the OP-1 kept it or rewrote it.
    private var copiedTapeJSONURL: URL { documents.appending(path: "tape-copy-written.json") }

    /// Copies a whole tape onto a blank one: every track with audio, then tape.json, each read back and compared.
    /// The blank tape's files are verified blank and backed up first, and Restore blank tape puts them back.
    /// Tracks go first because the OP-1 rewrites tape.json when a track changes, so writing tape.json last gives it the best chance to stay.
    /// `large` copies the tape with the most audio.
    func runWholeTapeTest(large: Bool = false) async {
        guard let (source, target) = ProbeObject.wholeTapePlan(in: objects, largest: large), canWholeTapeTest else { return }
        isBusy = true
        defer { isBusy = false }
        status = "Copying \(source.path) to \(target.path)"
        func stop(_ reason: String) {
            status = "TAPE COPY STOPPED: \(reason)"
            log(status)
        }

        do {
            log("Whole tape test: \(source.path) → \(target.path)")
            let sourceFiles = files(in: source)
            guard let sourceJSONObject = sourceFiles.first(where: { $0.info.filename == PTP.tapeJSONFilename }) else {
                return stop("\(source.path) has no tape.json")
            }
            let sourceJSON = try await send(.getObject, [sourceJSONObject.handle], quiet: true).payload
            let problems = PTP.tapeProblems(json: sourceJSON, trackSizes: trackSizes(sourceFiles))
            guard problems.isEmpty else { return stop("\(source.path) doesn't match its tape.json: \(problems)") }
            log("Source tape.json, \(sourceJSON.count) bytes, matches its tracks")

            // Back up the blank tape and prove it's blank: header-only tracks and no clips.
            try? FileManager.default.removeItem(at: tapeBackupFolder)
            try FileManager.default.createDirectory(at: tapeBackupFolder, withIntermediateDirectories: true)
            let targetFiles = files(in: target)
            for name in PTP.trackFilenames.sorted() + [PTP.tapeJSONFilename] {
                guard let file = targetFiles.first(where: { $0.info.filename == name }) else { return stop("\(target.path) has no \(name)") }
                let bytes = try await send(.getObject, [file.handle], quiet: true).payload
                if name == PTP.tapeJSONFilename {
                    let blankSizes = Dictionary(uniqueKeysWithValues: PTP.trackFilenames.map { ($0, UInt64(PTP.emptyWAVSize)) })
                    guard PTP.tapeProblems(json: bytes, trackSizes: blankSizes).isEmpty, PTP.clipCount(bytes) == 0 else {
                        return stop("\(target.path)/tape.json has clips: \(String(decoding: bytes, as: UTF8.self))")
                    }
                } else if !PTP.isBlankTrack(bytes) {
                    return stop("\(target.path)/\(name) isn't blank")
                }
                let url = tapeBackupFolder.appending(path: name)
                try bytes.write(to: url)
                guard try Data(contentsOf: url) == bytes else { return stop("backup of \(name) didn't verify") }
            }
            log("Backed up \(target.path): four blank tracks and an empty tape.json")
            setRestoreTapePath(target.path)

            do {
                for name in PTP.trackFilenames.sorted() {
                    guard let track = sourceFiles.first(where: { $0.info.filename == name }) else { continue }
                    guard track.info.compressedSize > PTP.emptyWAVSize else {
                        log("\(name) is blank on both tapes, skipped")
                        continue
                    }
                    let readBegin = Date()
                    let bytes = try await send(.getObject, [track.handle]).payload
                    log("Read \(track.path), \(bytes.count) bytes in \(rate(bytes.count, since: readBegin))")
                    guard bytes.count == Int(track.info.compressedSize) else { throw PTPError.missingObject("full read of \(track.path)") }
                    try await replace(name, in: target, with: bytes, format: track.info.format)
                }

                if let generated = files(in: target).first(where: { $0.info.filename == PTP.tapeJSONFilename }) {
                    // The OP-1 rewrites this file when a track changes, but the 2026-11-08 run read back only the old 251 bytes.
                    // Asking for the object info again shows whether the device reports the new size mid-session.
                    let fresh = try PTPObjectInfo(await send(.getObjectInfo, [generated.handle], quiet: true).payload)
                    let bytes = try await send(.getObject, [generated.handle], quiet: true).payload
                    log("\(target.path)/tape.json after the tracks, before writing it: listed \(generated.info.compressedSize) bytes at the start, \(fresh.compressedSize) now, read \(bytes.count): \(String(decoding: bytes, as: UTF8.self))")
                    if let partial = try? await send(.getPartialObject, [generated.handle, 0, 64 * 1024], quiet: true) {
                        log("GetPartialObject of it returned \(partial.payload.count) bytes, params \(partial.responseParams.map(\.hex))")
                    }
                }
                try await replace(PTP.tapeJSONFilename, in: target, with: sourceJSON, format: sourceJSONObject.info.format)
                try sourceJSON.write(to: copiedTapeJSONURL)

                status = "TAPE COPY PASS: \(target.path) matches \(source.path)"
                log(status)
                log("Next: leave MTP mode, open \(target.path) on the OP-1 and check its clips, loop and tempo match \(source.path). Then reconnect: the probe logs whether the OP-1 kept the copied tape.json.")
            } catch {
                log("TAPE COPY FAIL: \(error). Putting the blank tape back.")
                try await restoreTape()
                status = "TAPE COPY FAIL: \(error). Blank tape restored."
                log(status)
            }
        } catch {
            status = "TAPE COPY FAIL: \(error)"
            log(status)
        }
    }

    /// The name the create-tape test gives its folder. It's editable so each run can try a different name.
    var newTapeName = UserDefaults.standard.string(forKey: Probe.newTapeNameKey) ?? "PROBE 1-#A" {
        didSet { UserDefaults.standard.set(newTapeName, forKey: Probe.newTapeNameKey) }
    }
    private var tapesRoot: ProbeObject? { objects.first { $0.info.isFolder && $0.path == "tapes" } }
    private var tapeCount: Int { objects.filter { $0.info.isFolder && $0.info.parent == tapesRoot?.handle }.count }
    var canCreateTapeTest: Bool {
        tapesRoot != nil && tapeCount < PTP.maxTapes && ProbeObject.copySource(in: objects) != nil && !newTapeName.isEmpty
            && createdTapePath == nil && restorePath == nil && !isBusy
    }

    /// Restoring a tape that's gone from the OP-1 means making its folder. This creates `tapes/<newTapeName>` with SendObjectInfo
    /// alone, as MTP does for folders, logs what the OP-1 lists in it, then copies the smallest real tape into it: all four tracks,
    /// then tape.json. It changes no existing tape. Delete test tape removes it afterwards.
    func runCreateTapeTest() async {
        guard canCreateTapeTest, let root = tapesRoot, let source = ProbeObject.copySource(in: objects) else { return }
        isBusy = true
        defer { isBusy = false }
        let name = newTapeName
        let path = "tapes/\(name)"
        func stop(_ reason: String) {
            status = "CREATE TAPE STOPPED: \(reason)"
            log(status)
        }

        do {
            log("Create tape test: new folder \"\(name)\" (\(name.count) characters), filled from \(source.path). Tapes now: \(tapeCount) of \(PTP.maxTapes)")
            let unexpected = PTP.unexpectedTapeNameCharacters(name)
            if !unexpected.isEmpty { log("Name has characters outside A-Z, 0-9, #, - and space: \(unexpected.map { "\"\($0)\"" }.joined(separator: " "))") }
            // The OP-1 lowercases tape names, so a name differing only in case would clash.
            if let clash = try await listFolder(root).first(where: { $0.info.filename.lowercased() == name.lowercased() }) {
                return stop("\(clash.path) already exists")
            }
            let existing = objects.filter { $0.info.isFolder && $0.info.parent == root.handle }
            log("Existing tape folders report association types \(Set(existing.map(\.info.associationType)).sorted().map(\.hex))")

            // Read everything first, so a failed read leaves nothing behind.
            let sourceFiles = files(in: source)
            guard let sourceJSONObject = sourceFiles.first(where: { $0.info.filename == PTP.tapeJSONFilename }) else { return stop("\(source.path) has no tape.json") }
            let sourceJSON = try await send(.getObject, [sourceJSONObject.handle], quiet: true).payload
            let problems = PTP.tapeProblems(json: sourceJSON, trackSizes: trackSizes(sourceFiles))
            guard problems.isEmpty else { return stop("\(source.path) doesn't match its tape.json: \(problems)") }
            var tracks = [(name: String, bytes: Data, format: UInt16)]()
            for trackName in PTP.trackFilenames.sorted() {
                guard let track = sourceFiles.first(where: { $0.info.filename == trackName }) else { return stop("\(source.path) has no \(trackName)") }
                let bytes = try await send(.getObject, [track.handle], quiet: true).payload
                guard bytes.count == Int(track.info.compressedSize) else { return stop("short read of \(track.path)") }
                tracks.append((trackName, bytes, track.info.format))
            }
            log("Read \(source.path): \(tracks.map { "\($0.name) \($0.bytes.count)" }.joined(separator: ", ")), tape.json \(sourceJSON.count)")

            let dataset = PTP.objectInfoDataset(storageID: root.info.storageID, format: PTP.associationFormat, size: 0,
                                                parent: root.handle, filename: name, associationType: PTP.genericFolder)
            log("Folder ObjectInfo dataset: \(dataset.hexDump(limit: 128))")
            let reply = try await send(.sendObjectInfo, [root.info.storageID, root.handle], outData: dataset)
            log("SendObjectInfo response params: \(reply.responseParams.map(\.hex))")
            setCreatedTapePath(path)

            guard let folder = try await find(name, in: root, path: path) else {
                // The OP-1 may have stored it under another name, so list everything in tapes/.
                let handles = try PTPReader.u32Array(from: await send(.getObjectHandles, [root.info.storageID, 0, root.handle]).payload)
                for handle in handles {
                    let info = try PTPObjectInfo(await send(.getObjectInfo, [handle], quiet: true).payload)
                    log("tapes/ has \(handle.hex) \"\(info.filename)\" format \(info.format.hex)")
                }
                return stop("no folder named \"\(name)\" listed after SendObjectInfo")
            }
            objects.append(folder)
            log("Created \(path): handle \(folder.handle.hex), format \(folder.info.format.hex), association type \(folder.info.associationType.hex)")

            let contents = try await listFolder(folder)
            log(contents.isEmpty ? "The OP-1 put nothing in the new folder" : "The OP-1 put these in the new folder: \(contents.map { "\($0.info.filename) \($0.info.compressedSize)" })")
            objects.append(contentsOf: contents)

            for track in tracks {
                try await replace(track.name, in: folder, with: track.bytes, format: track.format)
            }
            try await replace(PTP.tapeJSONFilename, in: folder, with: sourceJSON, format: sourceJSONObject.info.format)

            let after = try await listFolder(folder)
            log("\(path) now holds: \(after.map { "\($0.info.filename) \($0.info.compressedSize)" })")
            status = "CREATE TAPE PASS: \(path) made and filled from \(source.path)"
            log(status)
            log("Next: leave MTP mode and look for the tape on the OP-1: its name as shown, and whether it plays like \(source.path). Then reconnect and tap Delete test tape.")
        } catch {
            status = "CREATE TAPE FAIL: \(error)"
            log(status)
            if createdTapePath != nil { log("The folder may exist. Reconnect, then tap Delete test tape, or delete the tape on the OP-1.") }
        }
    }

    /// The tape the create-tape test made, or, if that record is gone, a tape named like the name field. Names are compared
    /// ignoring case, because the OP-1 lowercases a tape's folder name once it leaves MTP mode.
    var testTape: ProbeObject? {
        let name = createdTapePath.map { String($0.dropFirst("tapes/".count)) } ?? newTapeName
        return tape(named: name)
    }
    var canDeleteCreatedTape: Bool { testTape != nil && hasCamera && !isBusy }

    private func tape(named name: String) -> ProbeObject? {
        guard let root = tapesRoot, !name.isEmpty else { return nil }
        return objects.first { $0.info.isFolder && $0.info.parent == root.handle && $0.info.filename.lowercased() == name.lowercased() }
    }

    /// Deletes the test tape: its files, then the folder, then checks tapes/ no longer lists it. The UI asks first.
    func deleteCreatedTapeTapped() async {
        guard canDeleteCreatedTape, let listed = testTape, let root = tapesRoot else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            // List tapes/ again rather than trusting the catalog, so the handle is current.
            let tapes = try await listFolder(root)
            guard let folder = tapes.first(where: { $0.info.isFolder && $0.info.filename.lowercased() == listed.info.filename.lowercased() }) else {
                log("No tape named \"\(listed.info.filename)\" in tapes/, which lists \(tapes.map { "\"\($0.info.filename)\"" })")
                status = "DELETE STOPPED: test tape not listed"
                return
            }
            log("Deleting \(folder.path), handle \(folder.handle.hex)")
            for file in try await listFolder(folder) {
                _ = try await send(.deleteObject, [file.handle, 0])
                objects.removeAll { $0.handle == file.handle }
                log("Deleted \(file.path)")
            }
            _ = try await send(.deleteObject, [folder.handle, 0])
            log("DeleteObject on the folder returned OK")
            objects.removeAll { $0.handle == folder.handle }
            let after = try await listFolder(root)
            guard !after.contains(where: { $0.info.filename.lowercased() == folder.info.filename.lowercased() }) else {
                status = "DELETE FAIL: \(folder.path) is still listed. Delete the tape on the OP-1."
                log(status)
                return
            }
            setCreatedTapePath(nil)
            status = "Deleted test tape \(folder.path). Tapes now: \(after.filter(\.info.isFolder).count) of \(PTP.maxTapes)"
            log(status)
        } catch {
            status = "DELETE FAIL: \(error). Delete the tape on the OP-1 if it's still there."
            log(status)
        }
    }

    private func listFolder(_ folder: ProbeObject) async throws -> [ProbeObject] {
        let handles = try PTPReader.u32Array(from: await send(.getObjectHandles, [folder.info.storageID, 0, folder.handle], quiet: true).payload)
        var contents = [ProbeObject]()
        for handle in handles {
            let info = try PTPObjectInfo(await send(.getObjectInfo, [handle], quiet: true).payload)
            contents.append(ProbeObject(handle: handle, path: "\(folder.path)/\(info.filename)", info: info))
        }
        return contents
    }

    private func setCreatedTapePath(_ path: String?) {
        createdTapePath = path
        UserDefaults.standard.set(path, forKey: Probe.createdTapePathKey)
    }

    func restoreTapeTapped() async {
        guard canRestoreTape else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await restoreTape()
        } catch {
            status = "Tape restore failed: \(error)"
            log(status)
        }
    }

    /// Writes back the blank tape's backed-up tracks and tape.json.
    private func restoreTape() async throws {
        guard let path = restoreTapePath else { return }
        guard let folder = objects.first(where: { $0.info.isFolder && $0.path == path }) else { throw PTPError.missingObject(path) }
        log("Restoring \(path) from backup")
        for name in PTP.trackFilenames.sorted() + [PTP.tapeJSONFilename] {
            let bytes = try Data(contentsOf: tapeBackupFolder.appending(path: name))
            try await replace(name, in: folder, with: bytes, format: name == PTP.tapeJSONFilename ? PTP.textFormat : PTP.wavFormat)
        }
        setRestoreTapePath(nil)
        try? FileManager.default.removeItem(at: copiedTapeJSONURL)
        status = "Restored blank tape \(path)"
        log(status)
    }

    /// Deletes `filename` from `folder` if it's there, writes `bytes` in its place, and reads it back. Throws if the read-back differs.
    private func replace(_ filename: String, in folder: ProbeObject, with bytes: Data, format: UInt16) async throws {
        let path = "\(folder.path)/\(filename)"
        if let old = try await find(filename, in: folder, path: path) {
            _ = try await send(.deleteObject, [old.handle, 0])
            objects.removeAll { $0.handle == old.handle }
        }
        try await sendFile(bytes, format: format, filename: filename, folder: folder)
        guard let copy = try await find(filename, in: folder, path: path) else { throw PTPError.missingObject(path) }
        objects.append(copy)
        let readBack = try await send(.getObject, [copy.handle], quiet: true).payload
        guard readBack == bytes else {
            let difference = PTP.differences(bytes, readBack)
            log("\(path): sizes \(bytes.count) and \(readBack.count), \(difference.count) bytes differ, first at offset \(difference.firstOffset ?? 0)")
            throw PTPError.missingObject("matching \(path)")
        }
        log("\(path): \(bytes.count) bytes written and read back intact, SHA-256 \(bytes.sha256)")
    }

    private func files(in folder: ProbeObject) -> [ProbeObject] {
        objects.filter { $0.info.parent == folder.handle && !$0.info.isFolder }
    }

    private func trackSizes(_ files: [ProbeObject]) -> [String: UInt64] {
        Dictionary(files.filter { PTP.trackFilenames.contains($0.info.filename) }.map { ($0.info.filename, UInt64($0.info.compressedSize)) },
                   uniquingKeysWith: { first, _ in first })
    }

    private func setRestoreTapePath(_ path: String?) {
        restoreTapePath = path
        UserDefaults.standard.set(path, forKey: Probe.restoreTapePathKey)
    }

    var canPartialReadTest: Bool { partialReadSource != nil && !isBusy }
    private var partialReadSource: ProbeObject? {
        objects.filter { $0.isAudio && $0.info.compressedSize >= 4 * PTP.partialProbeChunk }
            .min { $0.info.compressedSize < $1.info.compressedSize }
    }

    /// Read-only. The large test hung on its second GetPartialObject, so this tries one request at a time,
    /// ordered to separate "any offset but 0 fails" from "a second request fails", and checks every chunk
    /// against a whole-file read. It stops at the first failure and checks the device still answers.
    func runPartialReadTest() async {
        guard let source = partialReadSource, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let chunk = PTP.partialProbeChunk
        let steps: [(label: String, offset: UInt32)] = [
            ("first request, nonzero offset", chunk),
            ("offset 0", 0),
            ("offset 0 again", 0),
            ("next chunk after offset 0", chunk),
            ("skip ahead", chunk * 3),
        ]
        status = "Partial read test on \(source.path)"
        do {
            log("Partial read test: \(source.path), \(source.info.compressedSize) bytes, \(chunk)-byte chunks")
            let whole = try await send(.getObject, [source.handle], quiet: true).payload
            log("Whole read \(whole.count) bytes")
            for (index, step) in steps.enumerated() {
                let begin = Date()
                do {
                    let reply = try await send(.getPartialObject, [source.handle, step.offset, chunk])
                    let expected = whole.subdata(in: Int(step.offset)..<Int(step.offset + chunk))
                    let matches = reply.payload == expected
                    log("Step \(index + 1), \(step.label): \(reply.payload.count) bytes in \(String(format: "%.2f", Date().timeIntervalSince(begin)))s, params \(reply.responseParams.map(\.hex)), matches: \(matches)")
                    guard matches else {
                        status = "PARTIAL FAIL at step \(index + 1): wrong bytes"
                        log(status)
                        return
                    }
                } catch {
                    log("Step \(index + 1), \(step.label): failed after \(String(format: "%.2f", Date().timeIntervalSince(begin)))s: \(error)")
                    status = "PARTIAL FAIL at step \(index + 1), \(step.label)"
                    log(status)
                    await logStillAnswering()
                    return
                }
            }
            status = "PARTIAL PASS: all \(steps.count) requests matched"
            log(status)
        } catch {
            status = "PARTIAL FAIL: \(error)"
            log(status)
        }
    }

    var canMixdownTest: Bool { mixdownSource != nil && restorePath == nil && restoreTapePath == nil && !isBusy }
    private var mixdownSource: ProbeObject? { objects.first { $0.path == PTP.mixdownTestPath && !$0.info.isFolder } }

    /// Writes side_b.wav back to mixdown/, the user's own copy-off-and-write-back case. MTP can't overwrite,
    /// so this deletes the real file first. It refuses unless the OP-1's file matches the Mac backup.
    func runMixdownWriteTest() async {
        guard let source = mixdownSource, restorePath == nil, !isBusy,
              let folder = objects.first(where: { $0.info.isFolder && $0.handle == source.info.parent })
        else { return }
        isBusy = true
        defer { isBusy = false }
        let filename = source.info.filename
        status = "Writing \(source.path)"

        do {
            log("Mixdown write test: \(source.path) back to itself")
            let readBegin = Date()
            let original = try await send(.getObject, [source.handle]).payload
            log("Read \(original.count) bytes in \(rate(original.count, since: readBegin)), SHA-256 \(original.sha256)")
            guard original.count == Int(source.info.compressedSize), original.sha256 == PTP.mixdownBackupSHA256 else {
                status = "WRITE STOPPED: \(filename) doesn't match the Mac backup, so nothing was deleted"
                log(status)
                return
            }

            let backupURL = documents.appending(path: "side_b-backup.wav")
            try original.write(to: backupURL)
            guard try Data(contentsOf: backupURL) == original else {
                status = "WRITE STOPPED: iPad backup didn't verify, so nothing was deleted"
                log(status)
                return
            }
            log("Backed up to \(backupURL.lastPathComponent) on the iPad; it matches the Mac backup")

            _ = try await send(.deleteObject, [source.handle, 0])
            objects.removeAll { $0.handle == source.handle }
            log("Deleted \(source.path)")

            do {
                try await sendFile(original, format: source.info.format, filename: filename, folder: folder)
            } catch {
                log("First send failed: \(error). Retrying once.")
                if let partial = try? await find(filename, in: folder, path: source.path) {
                    _ = try? await send(.deleteObject, [partial.handle, 0])
                }
                try await Task.sleep(for: .seconds(2))
                try await sendFile(original, format: source.info.format, filename: filename, folder: folder)
            }

            guard let copy = try await find(filename, in: folder, path: source.path) else {
                status = "WRITE FAIL: \(filename) not listed after SendObject. Restore it from the Mac backup."
                log(status)
                return
            }
            objects.append(copy)
            let readBack = try await send(.getObject, [copy.handle]).payload
            log("Read back \(readBack.count) bytes, SHA-256 \(readBack.sha256)")
            if readBack == original {
                status = "WRITE PASS: \(filename) written back exactly"
            } else {
                let difference = PTP.differences(original, readBack)
                log("Sizes \(original.count) and \(readBack.count), \(difference.count) bytes differ, first at offset \(difference.firstOffset ?? 0)")
                try readBack.write(to: documents.appending(path: "\(copy.handle.hex)-\(filename)"))
                status = "WRITE FAIL: \(filename) differs from the backup. Restore it from the Mac backup."
            }
            log("Verdict: \(status)")
        } catch {
            status = "WRITE FAIL: \(error). If \(filename) is missing, restore it from the Mac backup."
            log(status)
        }
    }

    var canChunkSizeTest: Bool { chunkSizeSource != nil && !isBusy }
    private var chunkSizeSource: ProbeObject? {
        objects.filter { $0.isAudio && $0.info.compressedSize >= 2 * PTP.chunkSizes.last! }
            .max { $0.info.compressedSize < $1.info.compressedSize }
    }

    /// Read-only. A 1 MiB GetPartialObject hung on its second request, right after a 22 MB whole read of the
    /// same file, while 16 KiB chunks work. This steps the chunk size up with no whole read first, then repeats
    /// 1 MiB after a whole read, to show whether size or the earlier whole read is the trigger.
    func runChunkSizeTest() async {
        guard let source = chunkSizeSource, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        status = "Chunk size test on \(source.path)"
        log("Chunk size test: \(source.path), \(source.info.compressedSize) bytes")

        var chunks: [(offset: UInt32, data: Data)] = []
        func readPair(_ size: UInt32, _ phase: String) async -> Bool {
            for offset in [0, size] {
                let begin = Date()
                do {
                    let reply = try await send(.getPartialObject, [source.handle, offset, size])
                    let seconds = Date().timeIntervalSince(begin)
                    log("\(phase), \(size / 1024) KiB at offset \(offset): \(reply.payload.count) bytes in \(String(format: "%.2f", seconds))s, params \(reply.responseParams.map(\.hex))")
                    guard reply.payload.count == Int(size) else {
                        status = "CHUNK FAIL: \(size / 1024) KiB at offset \(offset) returned \(reply.payload.count) bytes"
                        log(status)
                        return false
                    }
                    chunks.append((offset, reply.payload))
                } catch {
                    log("\(phase), \(size / 1024) KiB at offset \(offset): failed after \(String(format: "%.2f", Date().timeIntervalSince(begin)))s: \(error)")
                    status = "CHUNK FAIL: \(size / 1024) KiB at offset \(offset), \(phase)"
                    log(status)
                    await logStillAnswering()
                    return false
                }
            }
            return true
        }

        for size in PTP.chunkSizes {
            guard await readPair(size, "No whole read yet") else { return }
        }

        do {
            let whole = try await send(.getObject, [source.handle], quiet: true).payload
            log("Whole read \(whole.count) bytes")
            guard await readPair(PTP.chunkSizes.last!, "After whole read") else { return }
            let bad = chunks.filter { whole.subdata(in: Int($0.offset)..<Int($0.offset) + $0.data.count) != $0.data }
            status = bad.isEmpty
                ? "CHUNK PASS: \(chunks.count) chunks up to \(PTP.chunkSizes.last! / 1024) KiB matched"
                : "CHUNK FAIL: \(bad.count) of \(chunks.count) chunks had wrong bytes"
            log(status)
        } catch {
            status = "CHUNK FAIL: \(error)"
            log(status)
        }
    }

    private func logStillAnswering() async {
        do {
            _ = try await send(.getStorageIDs)
            log("Device still answers commands")
        } catch {
            log("Device no longer answers: \(error). Unplug the OP-1 or leave MTP mode, then come back.")
        }
    }

    private func rate(_ bytes: Int, since begin: Date) -> String {
        let seconds = Date().timeIntervalSince(begin)
        return String(format: "%.2fs, %.1f MB/s", seconds, Double(bytes) / 1_000_000 / seconds)
    }

    private func setRestorePath(_ path: String?) {
        restorePath = path
        UserDefaults.standard.set(path, forKey: Probe.restorePathKey)
    }

    private func sendFile(_ bytes: Data, format: UInt16, filename: String, folder: ProbeObject) async throws {
        let dataset = PTP.objectInfoDataset(
            storageID: folder.info.storageID,
            format: format,
            size: UInt32(bytes.count),
            parent: folder.handle,
            filename: filename
        )
        log("ObjectInfo dataset: \(dataset.hexDump(limit: 128))")
        let reply = try await send(.sendObjectInfo, [folder.info.storageID, folder.handle], outData: dataset)
        log("SendObjectInfo response params: \(reply.responseParams.map(\.hex))")

        let begin = Date()
        _ = try await send(.sendObject, outData: bytes)
        let seconds = Date().timeIntervalSince(begin)
        let megabytes = Double(bytes.count) / 1_000_000
        log("SendObject took \(String(format: "%.2f", seconds))s, \(String(format: "%.1f", megabytes / seconds)) MB/s")
    }

    /// Lists the folder on the device, which proves the device really has the file.
    private func find(_ filename: String, in folder: ProbeObject, path: String) async throws -> ProbeObject? {
        let handles = try PTPReader.u32Array(
            from: await send(.getObjectHandles, [folder.info.storageID, 0, folder.handle]).payload
        )
        for handle in handles {
            let info = try PTPObjectInfo(await send(.getObjectInfo, [handle], quiet: true).payload)
            if info.filename == filename { return ProbeObject(handle: handle, path: path, info: info) }
        }
        return nil
    }

    /// The OP-1 keeps a readme in each folder, which may state what can be written there.
    private func logFolderRules() async {
        for readme in objects where !readme.info.isFolder && readme.info.filename == "readme.txt" {
            do {
                let text = try await send(.getObject, [readme.handle], quiet: true).payload
                log("\(readme.path): \(String(decoding: text, as: UTF8.self))")
            } catch {
                log("Couldn't read \(readme.path): \(error)")
            }
        }
    }

    /// Read-only: logs each tape's tape.json next to its track sizes, and saves a copy, to work out the format for whole-tape backup.
    private func logTapeFiles() async {
        let folder = documents.appending(path: "tape-json")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tapes = objects.filter { $0.info.isFolder && $0.path.hasPrefix("tapes/") }.sorted { $0.path < $1.path }
        log("Tapes: \(tapes.count) of \(PTP.maxTapes)")
        for tape in tapes {
            let own = objects.filter { $0.info.parent == tape.handle && !$0.info.isFolder }
            let tracks = PTP.trackFilenames.sorted().map { name in
                own.first { $0.info.filename == name }.map { "\(name) \($0.info.compressedSize)" } ?? "\(name) missing"
            }
            log("\(tape.path) tracks: \(tracks.joined(separator: ", "))")
            let others = own.filter { !PTP.trackFilenames.contains($0.info.filename) && $0.info.filename != "readme.txt" && $0.info.filename != "tape.json" }
            if !others.isEmpty { log("\(tape.path) other files: \(others.map { "\($0.info.filename) \($0.info.compressedSize)" })") }
            guard let json = own.first(where: { $0.info.filename == "tape.json" }) else {
                log("\(tape.path) has no tape.json")
                continue
            }
            do {
                let data = try await send(.getObject, [json.handle], quiet: true).payload
                log("\(json.path) (\(data.count) of \(json.info.compressedSize) bytes): \(String(decoding: data, as: UTF8.self))")
                let name = (tape.info.filename as NSString).lastPathComponent
                try data.write(to: folder.appending(path: "\(name).json"))
                let problems = PTP.tapeProblems(json: data, trackSizes: trackSizes(own))
                log(problems.isEmpty ? "\(tape.path): tracks match tape.json" : "\(tape.path) doesn't match its tape.json: \(problems)")
                if tape.path == restoreTapePath, let written = try? Data(contentsOf: copiedTapeJSONURL) {
                    log(data == written ? "\(tape.path): the OP-1 kept the copied tape.json" : "\(tape.path): the OP-1 changed the copied tape.json (\(written.count) bytes written, \(data.count) now)")
                }
            } catch {
                log("Couldn't read \(json.path): \(error)")
            }
        }
    }

    private func logDeviceInfo() async throws {
        let reply = try await send(.getDeviceInfo)
        log("DeviceInfo raw: \(reply.payload.hexDump(limit: 128))")
        let info = try PTPDeviceInfo(reply.payload)
        log("Device: \(info.manufacturer) \(info.model) \(info.deviceVersion), serial \(info.serialNumber)")
        log("Standard \(info.standardVersion), vendor extension \(info.vendorExtensionID.hex): \(info.vendorExtensionDescription)")
        log("Operations: \(info.operations.map(\.hex).joined(separator: " "))")
        let wanted: [(String, UInt16)] = [
            ("DeleteObject", 0x100B), ("SendObjectInfo", 0x100C), ("SendObject", 0x100D),
            ("GetPartialObject", 0x101B), ("GetObjectPropList", 0x9805),
        ]
        for (name, code) in wanted {
            log("  \(name): \(info.operations.contains(code) ? "yes" : "no")")
        }
    }

    /// The exact GetObjectHandles call the ADR names. Informational, so a failure here doesn't stop the walk.
    private func logAllStoragesRootCount() async {
        do {
            let reply = try await send(.getObjectHandles, [PTP.allStorages, 0, PTP.rootParent])
            log("All storages, root: \(try PTPReader.u32Array(from: reply.payload).count) handles")
        } catch {
            log("All storages, root failed: \(error)")
        }
    }

    private func walk(storage: UInt32) async throws {
        var folders: [(parent: UInt32, path: String)] = [(PTP.rootParent, "")]
        var seen = Set<UInt32>()

        while let folder = folders.popLast() {
            let reply = try await send(.getObjectHandles, [storage, 0, folder.parent], quiet: true)
            for handle in try PTPReader.u32Array(from: reply.payload) where seen.insert(handle).inserted {
                do {
                    let info = try PTPObjectInfo(try await send(.getObjectInfo, [handle], quiet: true).payload)
                    let path = folder.path + info.filename
                    let object = ProbeObject(handle: handle, path: path, info: info)
                    objects.append(object)
                    log("\(handle.hex) \(info.format.hex) \(info.compressedSize) \(path)\(info.isFolder ? "/" : "")")
                    if info.isFolder { folders.append((handle, path + "/")) }
                } catch {
                    log("GetObjectInfo \(handle.hex) failed: \(error)")
                }
            }
        }
    }

    private func logCatalogSummary() {
        let files = objects.filter { !$0.info.isFolder }
        let bytes = files.reduce(UInt64(0)) { $0 + UInt64($1.info.compressedSize) }
        log("Catalog: \(files.count) files, \(objects.count - files.count) folders, \(bytes) bytes")
        log("Audio files: \(files.filter(\.isAudio).count), tape/album files: \(files.filter(\.isTapeOrAlbum).count)")
    }

    private func download(_ object: ProbeObject) async throws -> Bool {
        let expected = Int(object.info.compressedSize)
        log("Downloading \(object.path), \(expected) bytes expected")
        status = "Downloading \(object.path)"
        let begin = Date()
        let payload = try await send(.getObject, [object.handle]).payload
        let seconds = Date().timeIntervalSince(begin)

        let name = "\(object.handle.hex)-\(object.info.filename.replacingOccurrences(of: "/", with: "_"))"
        try payload.write(to: documents.appending(path: name))

        let intact = payload.count == expected
        log("Received \(payload.count) bytes in \(String(format: "%.2f", seconds))s, starts \(payload.hexDump(limit: 16))")
        log("SHA-256 \(payload.sha256)")
        log("Saved \(name). Size matches: \(intact)")
        status = intact ? "Downloaded \(object.info.filename)" : "Size mismatch on \(object.info.filename)"
        return intact
    }

    // MARK: PTP exchange

    private struct Reply {
        let payload: Data
        let responseParams: [UInt32]
    }

    private func send(_ op: PTPOp, _ params: [UInt32] = [], outData: Data? = nil, quiet: Bool = false) async throws -> Reply {
        var (code, payload, response) = try await exchange(op, params, outData: outData, quiet: quiet)

        // ImageCaptureCore normally owns the session. Only open one if the device says none exists.
        if code == PTPResponse.sessionNotOpen {
            log("\(op) reported SessionNotOpen, sending OpenSession")
            let (openCode, _, _) = try await exchange(.openSession, [1], outData: nil, quiet: false)
            guard openCode == PTPResponse.ok || openCode == PTPResponse.sessionAlreadyOpen else {
                throw PTPError.failed(.openSession, openCode)
            }
            (code, payload, response) = try await exchange(op, params, outData: outData, quiet: quiet)
        }

        guard code == PTPResponse.ok else { throw PTPError.failed(op, code) }
        return Reply(payload: PTP.payload(payload, op: op), responseParams: PTP.responseParams(response))
    }

    private func exchange(_ op: PTPOp, _ params: [UInt32], outData: Data?, quiet: Bool) async throws -> (UInt16, Data, Data) {
        guard let camera else { throw PTPError.noResponse(op) }
        transactionID += 1
        let command = PTP.command(op, transactionID: transactionID, params: params)
        if !quiet { log("→ \(op) \(params.map(\.hex)) tx \(transactionID)") }

        let (data, response): (Data, Data) = try await withCheckedThrowingContinuation { continuation in
            camera.requestSendPTPCommand(command, outData: outData) { data, response, error in
                if let error, PTP.responseCode(response) == nil {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data, response))
                }
            }
        }

        guard let code = PTP.responseCode(response) else {
            log("\(op) unparseable response: \(response.hexDump())")
            throw PTPError.noResponse(op)
        }
        if !quiet || code != PTPResponse.ok {
            log("← \(code.hex), \(data.count) data bytes, response \(response.hexDump())")
        }
        return (code, data, response)
    }

    // MARK: Device lifecycle

    private func cameraAdded(_ device: ICDevice) {
        log("Found \(device.name ?? "unnamed"), type \(device.type.rawValue), transport \(device.transportType ?? "unknown"), USB \(String(format: "%04X:%04X", device.usbVendorID, device.usbProductID))")
        guard let found = device as? ICCameraDevice, camera == nil else { return }
        camera = found
        hasCamera = true
        found.delegate = self
        log("Capabilities: \(found.capabilities)")
        status = "Opening session"
        found.requestOpenSession()
    }

    private func cameraRemoved(_ device: ICDevice) {
        log("Removed \(device.name ?? "unnamed")")
        guard device === camera else { return }
        camera = nil
        hasCamera = false
        hasRun = false
        transactionID = 0
        status = "Waiting for OP-1 (set it to MTP mode)"
    }

    private func sessionOpened(_ error: Error?) {
        if let error {
            status = "Session failed: \(error.localizedDescription)"
            log("\(status) \(error as NSError)")
            return
        }
        status = "Session open, waiting for catalog"
        log("Session open")

        // The catalog may never finish if the device has no images, so don't depend on it.
        Task {
            try? await Task.sleep(for: .seconds(20))
            guard !hasRun else { return }
            log("No catalog after 20s, probing anyway")
            await runProbe()
        }
    }

    private func catalogReady(_ device: ICCameraDevice) {
        log("Catalog ready: \(device.mediaFiles?.count ?? 0) media files, \(device.contents?.count ?? 0) top-level items")
        guard !hasRun else { return }
        Task { await runProbe() }
    }

    fileprivate func log(_ message: String) {
        let line = String(format: "[%7.2f] ", Date().timeIntervalSince(started)) + message
        lines.append(line)
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL)
        }
    }
}

extension PTPReader {
    static func u32Array(from data: Data) throws -> [UInt32] {
        var reader = PTPReader(data)
        return try reader.u32Array()
    }
}

extension Probe: ICDeviceBrowserDelegate {
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        Task { @MainActor in cameraAdded(device) }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        Task { @MainActor in cameraRemoved(device) }
    }
}

extension Probe: ICCameraDeviceDelegate {
    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        Task { @MainActor in sessionOpened(error) }
    }

    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        Task { @MainActor in log("Session closed, error: \(String(describing: error))") }
    }

    nonisolated func didRemove(_ device: ICDevice) {}

    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        Task { @MainActor in catalogReady(device) }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
        Task { @MainActor in log("PTP event: \(eventData.hexDump())") }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}

// MARK: - UI

@main
struct OP1ProbeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    private enum Tab { case log, files }

    @State private var probe = Probe()
    @State private var tab = Tab.log
    @State private var confirmMixdown = false
    @State private var confirmDeleteTape = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    if probe.isBusy { ProgressView() }
                    Text(probe.status).font(.headline)
                    Spacer()
                }
                .padding()

                Picker("View", selection: $tab) {
                    Text("Log").tag(Tab.log)
                    Text("Files (\(probe.objects.count))").tag(Tab.files)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    Button("Tape write test") { Task { await probe.runTapeWriteTest() } }
                        .disabled(!probe.canWriteTest)
                    Button("Large tape test") { Task { await probe.runTapeWriteTest(large: true) } }
                        .disabled(!probe.canWriteTest)
                    Button("Partial read test") { Task { await probe.runPartialReadTest() } }
                        .disabled(!probe.canPartialReadTest)
                    Button("Chunk size test") { Task { await probe.runChunkSizeTest() } }
                        .disabled(!probe.canChunkSizeTest)
                    Button("Mixdown write test", role: .destructive) { confirmMixdown = true }
                        .disabled(!probe.canMixdownTest)
                    Button("Whole tape copy") { Task { await probe.runWholeTapeTest() } }
                        .disabled(!probe.canWholeTapeTest)
                    Button("Large tape copy") { Task { await probe.runWholeTapeTest(large: true) } }
                        .disabled(!probe.canWholeTapeTest)
                    TextField("Tape name", text: Binding(get: { probe.newTapeName }, set: { probe.newTapeName = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .frame(width: 160)
                    Button("Create tape test") { Task { await probe.runCreateTapeTest() } }
                        .disabled(!probe.canCreateTapeTest)
                    if let tape = probe.testTape {
                        Button("Delete \(tape.info.filename)", role: .destructive) { confirmDeleteTape = true }
                            .disabled(!probe.canDeleteCreatedTape)
                    }
                    if probe.restoreTapePath != nil {
                        Button("Restore blank tape", role: .destructive) { Task { await probe.restoreTapeTapped() } }
                            .disabled(!probe.canRestoreTape)
                    }
                    if probe.restorePath != nil {
                        Button("Restore blank track", role: .destructive) { Task { await probe.restoreTapped() } }
                            .disabled(!probe.canRestore)
                    }
                }
                .buttonStyle(.bordered)
                .padding([.horizontal, .top])
                }

                switch tab {
                case .log: logView
                case .files: filesView
                }
            }
            .confirmationDialog("Write side_b.wav back?", isPresented: $confirmMixdown, titleVisibility: .visible) {
                Button("Delete and write back", role: .destructive) { Task { await probe.runMixdownWriteTest() } }
            } message: {
                Text("This deletes side_b.wav from the OP-1, then writes the same file back. It stops first if the OP-1's file doesn't match the Mac backup. If the write fails, restore side B from the Mac backup.")
            }
            .confirmationDialog("Delete \(probe.testTape?.path ?? "the test tape")?", isPresented: $confirmDeleteTape, titleVisibility: .visible) {
                Button("Delete tape", role: .destructive) { Task { await probe.deleteCreatedTapeTapped() } }
            } message: {
                Text("This deletes the tape and all its tracks from the OP-1, and can't be undone. Only do this for the tape the Create tape test made.")
            }
            .navigationTitle("OP-1 Probe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Run") { Task { await probe.runProbe() } }
                        .disabled(!probe.hasCamera || probe.isBusy)
                }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: probe.logURL)
                }
            }
        }
        .task {
            UIApplication.shared.isIdleTimerDisabled = true
            await probe.start()
        }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(probe.lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                            .id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .onChange(of: probe.lines.count) { _, count in
                proxy.scrollTo(count - 1, anchor: .bottom)
            }
        }
    }

    private var filesView: some View {
        List(probe.objects) { object in
            Button {
                Task { await probe.downloadTapped(object) }
            } label: {
                HStack {
                    Image(systemName: object.info.isFolder ? "folder" : object.isAudio ? "waveform" : "doc")
                    Text(object.path)
                    Spacer()
                    if !object.info.isFolder {
                        Text(Int64(object.info.compressedSize), format: .byteCount(style: .file))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(object.info.isFolder || probe.isBusy)
        }
        .overlay {
            if probe.objects.isEmpty {
                ContentUnavailableView("No objects yet", systemImage: "externaldrive.badge.questionmark")
            }
        }
    }
}
