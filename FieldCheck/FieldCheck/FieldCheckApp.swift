// FieldCheck: checks a connected OP-1 against what FieldTapeKit expects (ADR 0003), in two tabs.
// Validate shows connection events and device info, runs level 1, and saves each report and its log to Documents.
// This launch's latest clean run of each level can be saved together as the firmware's baseline, to copy into the
// repository's firmware/ folder. Level 2 writes only FieldCheck's own scratch content, after a person confirms its plan. A clean level 2
// leaves level 3 waiting, saved in Documents, for after the OP-1 leaves MTP mode and comes back. Level 3 checks the
// scratch tape and deletes it. FieldCheck offers to delete content left by a run that didn't finish, and to put back an
// album side left holding its tone, from level 2's copy, logging every MTP request.
// It also runs FieldTapeKit's conformance suite, the checks the simulator passes too, and logs the results.
// Explore (ExploreView.swift) browses the OP-1 through FieldTapeKit's public API, as an app would. It only reads.

import FieldCheckKit
import FieldTapeConformance
import FieldTapeKit
import Synchronization
import SwiftUI
import System
import UIKit

@main
struct FieldCheckApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Trace lines from the MTP session, collected in order and logged once the work is done.
final class TraceLines: Sendable {
    private let lines = Mutex<[String]>([])
    func append(_ line: String) { lines.withLock { $0.append(line) } }
    var all: [String] { lines.withLock { $0 } }
}

@MainActor
@Observable
final class ConnectionLog {
    struct Entry: Identifiable {
        let id = UUID()
        let line: String
    }

    private(set) var entries: [Entry] = []
    private(set) var devices: [FieldDevice] = []
    /// The latest report for each connection.
    private(set) var reports: [FieldDevice.ID: CheckReport] = [:]
    /// This launch's latest report of each level, kept across reconnects, since level 3 always runs on a new
    /// connection. A baseline is made from these.
    private(set) var latestByLevel: [Int: CheckReport] = [:]
    /// The latest conformance results for each connection.
    private(set) var conformance: [FieldDevice.ID: [Conformance.Result]] = [:]
    private(set) var running: FieldDevice.ID?
    /// Level 3, waiting for the OP-1 to leave MTP mode and come back after a clean level 2. Saved in Documents.
    private(set) var pendingLevelThree: LevelThree.Pending?
    /// FieldCheck's own content found on each connection, from a run that didn't finish.
    private(set) var leftovers: [FieldDevice.ID: [FilePath]] = [:]
    /// A copy level 2 kept of an album side that isn't back yet, found in Documents without reading the OP-1.
    private(set) var sideCopy: SideRestore.Copy?
    /// The connection whose album side is being read to put it back, so only that shows as reading.
    private(set) var readingSide: FieldDevice.ID?
    /// Each connection's trace of its MTP requests, from the moment it connected.
    private var traces: [FieldDevice.ID: RequestTrace] = [:]
    private let pendingURL = URL.documentsDirectory.appending(path: "level3-pending.json")
    private let started = Date()
    private let fileURL: URL
    private let host: CheckReport.Host

    init() {
        let stamp = Date.now.formatted(.iso8601.year().month().day().timeZone(separator: .omitted)
            .time(includingFractionalSeconds: false).timeSeparator(.omitted))
        fileURL = URL.documentsDirectory.appending(path: "fieldcheck-\(stamp).txt")
        let device = UIDevice.current
        let app = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        host = CheckReport.Host(app: app, model: device.model, system: "\(device.systemName) \(device.systemVersion)")
        record("FieldCheck \(app) on \(device.model), \(device.systemName) \(device.systemVersion)")
        if let data = try? Data(contentsOf: pendingURL) {
            do {
                pendingLevelThree = try LevelThree.Pending(json: data)
                record("Level 3 is waiting, after level 2 on \(pendingLevelThree!.serialNumber)")
            } catch {
                record("Couldn't read \(pendingURL.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    /// Saves or clears the waiting level 3.
    private func setPendingLevelThree(_ pending: LevelThree.Pending?) {
        pendingLevelThree = pending
        do {
            if let pending {
                try pending.jsonData().write(to: pendingURL, options: .atomic)
            } else if FileManager.default.fileExists(atPath: pendingURL.path) {
                try FileManager.default.removeItem(at: pendingURL)
            }
        } catch {
            record("Couldn't save \(pendingURL.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Whether level 3 is waiting for this OP-1.
    func isLevelThreePending(for device: FieldDevice) -> Bool {
        pendingLevelThree?.serialNumber == device.info.serialNumber
    }

    /// Whether this is the connection level 2 ran on, so the OP-1 hasn't left MTP mode since.
    func isLevelTwoConnection(_ device: FieldDevice) -> Bool {
        pendingLevelThree?.connection == device.id
    }

    /// Looks for FieldCheck's own content on the OP-1: its tapes and presets. It only reads, and it doesn't read the
    /// album: album writing is off (`album.write-again`), so a level 2 copy of a side is found in Documents, and the
    /// side is read only when a person asks to put it back.
    private func findLeftovers(on device: FieldDevice) async {
        leftovers[device.id] = await LevelTwo.plan(for: device).leftovers
        logIfStopped(device)
        sideCopy = pendingLevelThree?.album == nil ? SideRestore.copies(in: .documentsDirectory).first : nil
    }

    /// Reads the side `copy` is of, for a person to confirm putting it back, and returns what it holds now, or nil if
    /// it's back already or couldn't be read.
    func readSide(for copy: SideRestore.Copy, on device: FieldDevice) async -> SideRestore.Current? {
        guard running == nil else { return nil }
        running = device.id
        readingSide = device.id
        defer {
            running = nil
            readingSide = nil
        }
        record("Reading \(copy.side), to put it back from \(copy.folder)/\(copy.url.lastPathComponent)")
        do {
            let current = try await SideRestore.current(copy, on: device)
            logIfStopped(device)
            if current == .matches {
                SideRestore.markPutBack(copy.url)
                sideCopy = nil
                record("\(copy.side) already holds level 2's copy, so it's back")
                return nil
            }
            return current
        } catch {
            logIfStopped(device)
            record("Couldn't read \(copy.side): \(error.localizedDescription)")
            return nil
        }
    }

    /// Puts an album side back from level 2's copy, after a person confirms, and logs every MTP request it sends.
    /// Over FieldCheck's tone it's replaced as it is. Over anything else, that's copied next to level 2's copy first.
    func putSideBack(on device: FieldDevice, from copy: SideRestore.Copy, over current: SideRestore.Current) async {
        guard running == nil else { return }
        running = device.id
        defer { running = nil }
        record("Putting \(copy.side) back from \(copy.folder)/\(copy.url.lastPathComponent)")
        let replaced: URL? = if case .other = current {
            copy.url.deletingLastPathComponent().appending(path: "side_\(copy.side.rawValue) replaced \(Self.stamp()).wav")
        } else {
            nil
        }
        let lines = TraceLines()
        let outcome = await SideRestore.putBack(copy, on: device, copyingReplacedTo: replaced) { lines.append($0) }
        for line in lines.all { record("  " + line) }
        logIfStopped(device)
        record((outcome.succeeded ? "Put back: " : "Not put back: ") + outcome.summary)
        await findLeftovers(on: device)
    }

    /// Level 1 only reads, so it needs no confirmation.
    func runLevelOne(on device: FieldDevice) async {
        guard running == nil else { return }
        running = device.id
        defer { running = nil }
        record("Level 1: running")
        let run = await LevelOne.run(on: device, host: host)
        logIfStopped(device)
        let report = compared(run)
        reports[device.id] = report
        latestByLevel[report.level] = report
        for result in report.results where result.outcome != .pass {
            record("Level 1: \(result.expectation) \(result.outcome.rawValue): \(result.summary)")
        }
        record("Level 1: \(report.countsDescription)")
        do {
            let saved = try report.save(in: .documentsDirectory)
            record("Saved \(saved.json.lastPathComponent) and \(saved.markdown.lastPathComponent)"
                   + (saved.draftADR.map { ", and a draft ADR for its changes and failures, \($0.lastPathComponent)" } ?? ""))
        } catch {
            record("Couldn't save the report: \(error.localizedDescription)")
        }
    }

    /// Level 2 writes, so it starts from a plan that a person confirms (ADR 0003, section 3). This only reads.
    ///
    /// It counts as running, so the buttons wait for it and a second tap doesn't queue another plan behind it.
    func planLevelTwo(on device: FieldDevice) async -> LevelTwo.Plan? {
        guard running == nil else { return nil }
        running = device.id
        planning = device.id
        defer {
            running = nil
            planning = nil
        }
        record("Level 2: looking at the OP-1 to plan it")
        let plan = await LevelTwo.plan(for: device)
        logIfStopped(device)
        if let refusal = plan.refusal { record("Level 2: can't run: \(refusal)") }
        return plan
    }

    /// The connection level 2 is being planned on, so its button can say so.
    private(set) var planning: FieldDevice.ID?

    /// Runs a confirmed level 2 plan, with the long check if asked for. Copies it keeps, of the replaced track, an
    /// empty album side and the drum preset, go in a new `level2-<time>` folder in Documents.
    func runLevelTwo(on device: FieldDevice, plan: LevelTwo.Plan, longCheck: Bool) async {
        guard running == nil else { return }
        running = device.id
        defer { running = nil }
        let workspace = URL.documentsDirectory.appending(path: "level2-\(Self.stamp())")
        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        } catch {
            record("Level 2: couldn't make \(workspace.lastPathComponent): \(error.localizedDescription)")
            return
        }
        record("Level 2: running\(longCheck ? " with the long check" : ""), copies go in \(workspace.lastPathComponent)")
        let run = await LevelTwo.run(on: device, plan: plan, longCheck: longCheck, workspace: workspace, host: host)
        logIfStopped(device)
        let report = compared(run)
        reports[device.id] = report
        latestByLevel[report.level] = report
        if let pending = await LevelThree.pending(after: report, on: device, workspace: workspace) {
            setPendingLevelThree(pending)
            record("Level 3 is waiting: leave MTP mode on the OP-1, then enter it again. You can play the scratch tape "
                + "on the OP-1 in between.")
            if let album = pending.album {
                record("\(album.side) holds FieldCheck's tone until level 3 puts it back from \(album.folder)/\(album.file).")
            }
        } else {
            let failed = report.results.filter { $0.outcome == .fail }.map(\.expectation)
            record("Level 3 isn't waiting: it runs only after a level 2 with no failures"
                   + (failed.isEmpty ? "." : ", and \(failed.joined(separator: ", ")) failed. Delete FieldCheck's content, then run level 2 again."))
        }
        await findLeftovers(on: device)
        for result in report.results {
            record("Level 2: \(result.expectation) \(result.outcome.rawValue): \(result.summary)")
        }
        record("Level 2: \(report.countsDescription)")
        do {
            let saved = try report.save(in: .documentsDirectory)
            record("Saved \(saved.json.lastPathComponent) and \(saved.markdown.lastPathComponent)"
                   + (saved.draftADR.map { ", and a draft ADR for its changes and failures, \($0.lastPathComponent)" } ?? ""))
        } catch {
            record("Couldn't save the report: \(error.localizedDescription)")
        }
    }

    /// Deletes FieldCheck's own content, after a person confirms: the scratch tape and any preset left behind.
    func deleteLeftovers(on device: FieldDevice) async {
        guard running == nil else { return }
        running = device.id
        defer { running = nil }
        record("Deleting FieldCheck's content")
        let result = await LevelTwo.deleteLeftovers(on: device)
        logIfStopped(device)
        record("\(result.expectation) \(result.outcome.rawValue): \(result.summary)")
        if isLevelThreePending(for: device) {
            if let album = pendingLevelThree?.album {
                record("Level 3 is still waiting, to check \(album.side) and put it back from \(album.folder)/\(album.file)")
            } else {
                setPendingLevelThree(nil)
                record("Level 3 isn't waiting any more, since FieldCheck's tapes were deleted")
            }
        }
        await findLeftovers(on: device)
    }

    /// Runs the waiting level 3, after a person confirms, since it deletes FieldCheck's tapes. Once it has run, level
    /// 3 is no longer waiting, and a tape it leaves behind is offered for cleanup instead. If it can't run on this
    /// connection, it keeps waiting, unless the scratch tape is gone.
    func runLevelThree(on device: FieldDevice) async {
        guard running == nil, let pending = pendingLevelThree else { return }
        running = device.id
        defer { running = nil }
        if let refusal = await LevelThree.refusal(on: device, pending: pending) {
            record("Level 3: can't run: \(refusal)")
            if refusal.endsLevelThree {
                setPendingLevelThree(nil)
                record("Level 3 isn't waiting any more")
            }
            await findLeftovers(on: device)
            return
        }
        record("Level 3: running, after level 2 at \(pending.levelTwoStarted.formatted(.iso8601))")
        let run = await LevelThree.run(on: device, pending: pending, files: .documentsDirectory, host: host)
        logIfStopped(device)
        let report = compared(run)
        reports[device.id] = report
        latestByLevel[report.level] = report
        for result in report.results {
            record("Level 3: \(result.expectation) \(result.outcome.rawValue): \(result.summary)")
        }
        record("Level 3: \(report.countsDescription)")
        do {
            let saved = try report.save(in: .documentsDirectory)
            record("Saved \(saved.json.lastPathComponent) and \(saved.markdown.lastPathComponent)"
                   + (saved.draftADR.map { ", and a draft ADR for its changes and failures, \($0.lastPathComponent)" } ?? ""))
        } catch {
            record("Couldn't save the report: \(error.localizedDescription)")
        }
        setPendingLevelThree(nil)
        await findLeftovers(on: device)
    }

    private static func stamp() -> String {
        Date.now.formatted(.iso8601.year().month().day().timeZone(separator: .omitted)
            .time(includingFractionalSeconds: false).timeSeparator(.omitted))
    }

    /// The conformance suite only reads the OP-1, so it needs no confirmation either. It copies a tape track and an
    /// album side into a new folder in Documents, kept so they can be compared with copies made on a Mac. The log
    /// is its record, with each copy's SHA-256.
    ///
    /// With `writing`, it runs the writing checks instead, which the person confirms first: each makes the scratch
    /// tape `tapes/conformance` in a free slot, checks it and deletes it. The person's tapes are only read. The
    /// archives the checks make go in a temporary folder, not Documents.
    func runConformance(on device: FieldDevice, writing: Bool = false) async {
        guard running == nil else { return }
        running = device.id
        defer { running = nil }
        let stamp = Date.now.formatted(.iso8601.year().month().day().timeZone(separator: .omitted)
            .time(includingFractionalSeconds: false).timeSeparator(.omitted))
        // The writing checks copy nothing, so they don't leave an empty folder in Documents.
        let workspace = (writing ? URL.temporaryDirectory : URL.documentsDirectory).appending(path: "conformance-\(stamp)")
        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        } catch {
            record("Conformance: couldn't make \(workspace.lastPathComponent): \(error.localizedDescription)")
            return
        }
        let kind = writing ? "writing checks, making and deleting tapes/\(Conformance.scratchTape)" : "copies go in \(workspace.lastPathComponent)"
        record("Conformance: running, \(kind). \(memory())")
        // One check at a time, so the memory each one takes shows in the log.
        var results: [Conformance.Result] = []
        for check in writing ? Conformance.writingChecks : Conformance.checks {
            let result = await check.run(on: device, workspace: workspace)
            logIfStopped(device)
            results.append(result)
            switch result.outcome {
            case .pass: record("Conformance: pass: \(result.name)\(result.detail.map { ". \($0)" } ?? "")")
            case .fail(let message): record("Conformance: FAIL: \(result.name): \(message)")
            case .skipped(let reason): record("Conformance: skipped: \(result.name): \(reason)")
            }
            record("Conformance: \(memory())")
        }
        conformance[device.id] = results
        let failed = results.filter { if case .fail = $0.outcome { true } else { false } }.count
        record("Conformance: \(results.count - failed) of \(results.count) without a failure")
    }

    /// FieldCheck's memory now, and its highest since launch, to see what each check costs.
    private func memory() -> String {
        guard let use = MemoryUse.now() else { return "Memory: unknown" }
        let megabytes = { (bytes: Int) in (Double(bytes) / 1_000_000).formatted(.number.precision(.fractionLength(1))) }
        return "Memory: \(megabytes(use.footprint)) MB, peak \(megabytes(use.peak)) MB"
    }

    /// The runs a baseline would be made from: this launch's latest of each level, if it passed and is from the same
    /// firmware as level 1's. Level 1 is needed.
    var baselineReports: [CheckReport] {
        guard let levelOne = latestByLevel[1], levelOne.count(.fail) == 0 else { return [] }
        return latestByLevel.values
            .filter { $0.count(.fail) == 0 && $0.device.firmware == levelOne.device.firmware }
            .sorted { $0.level < $1.level }
    }

    /// Saves the baseline as `baseline-<firmware>.json` in Documents, under a new name if one is there already.
    func saveBaseline() {
        let reports = baselineReports
        do {
            let baseline = try Baseline(reports: reports)
            let url = try baseline.save(in: .documentsDirectory)
            let levels = baseline.levels.map { "\($0.source.level)" }.joined(separator: ", ")
            savedBaseline = SavedBaseline(file: url.lastPathComponent, from: reports.map(\.started), problem: nil)
            record("Saved \(url.lastPathComponent), with levels \(levels). Copy it into the repository as "
                + "firmware/\(baseline.firmware)/baseline.json.")
        } catch {
            savedBaseline = SavedBaseline(file: nil, from: reports.map(\.started), problem: error.localizedDescription)
            record("Couldn't save the baseline: \(error.localizedDescription)")
        }
    }

    /// The last time Save as baseline was tapped: the file it wrote or why it couldn't, and the runs it was made from.
    struct SavedBaseline: Equatable {
        let file: String?
        let from: [Date]
        let problem: String?
    }

    private(set) var savedBaseline: SavedBaseline?

    /// What was saved from the runs a baseline would be made from now, or nil if they've changed since.
    var baselineSavedFromCurrentRuns: SavedBaseline? {
        guard let savedBaseline, savedBaseline.from == baselineReports.map(\.started) else { return nil }
        return savedBaseline
    }

    func watch() async {
        #if targetEnvironment(simulator)
        // The simulator has no USB devices. `-SimulatedOP1 YES` gives it FieldTapeKit's simulated OP-1, to try the
        // app's screens without hardware.
        if UserDefaults.standard.bool(forKey: "SimulatedOP1") {
            let device = FieldDevice.simulated {
                SimulatedTape("2026-220#02", type: .vintage, seconds: [3])
                Directory("mixdown") { File("side_a.wav", seconds: 10) }
            }
            devices.append(device)
            record("Connected: a simulated OP-1, firmware \(device.info.firmware)")
        }
        #endif
        record("Watching for an OP-1 in MTP mode")
        do {
            for try await event in FieldDevice.connections {
                switch event {
                case .connected(let device):
                    devices.append(device)
                    traces[device.id] = await RequestTrace.start(on: device) { [weak self] line in
                        Task { @MainActor in self?.record(line) }
                    }
                    let info = device.info
                    record("Connected: \(info.model), firmware \(info.firmware)\(info.isFirmwareTested ? "" : " (untested)"), "
                        + "serial \(info.serialNumber)")
                    record("Storage: \(info.storage.capacity) bytes, \(info.storage.freeSpace) free")
                    if isLevelThreePending(for: device), !isLevelTwoConnection(device) {
                        record("Level 3 is waiting, and can run now")
                    }
                    await findLeftovers(on: device)
                case .disconnected(let id):
                    logIfStopped(id)
                    traces[id] = nil
                    devices.removeAll { $0.id == id }
                    reports[id] = nil
                    conformance[id] = nil
                    leftovers[id] = nil
                    record("Disconnected")
                }
            }
            record("Stopped watching")
        } catch {
            record("Stopped: \(error.localizedDescription) \((error as? LocalizedError)?.recoverySuggestion ?? "")")
        }
    }

    /// The run compared with the built-in baseline for its firmware, or the closest one (ADR 0003, section 4), and
    /// what it was compared with logged.
    private func compared(_ run: CheckReport) -> CheckReport {
        guard let (baseline, isExact) = Baseline.for(firmware: run.device.firmware) else {
            record("Level \(run.level): there's no built-in baseline, so nothing was compared")
            return run
        }
        let report = run.compared(with: baseline, isExact: isExact)
        record("Level \(run.level): compared with \(report.comparisonDescription)")
        for result in report.results where result.outcome == .changed {
            for difference in result.differences {
                record("Level \(run.level): \(result.expectation) changed at \(difference.path.isEmpty ? "the whole value" : difference.path) "
                       + "(\(difference.suggested.rawValue), to confirm)")
            }
        }
        return report
    }

    /// Logs the connection's last MTP requests if one got no answer since they were last logged, so the log says
    /// where the OP-1 stopped, whatever sent the request.
    private func logIfStopped(_ device: FieldDevice) { logIfStopped(device.id) }

    private func logIfStopped(_ id: FieldDevice.ID) {
        guard let lines = traces[id]?.takeFailure() else { return }
        record("The last \(lines.count) MTP requests, up to the one that got no answer:")
        for line in lines { record("  " + line) }
    }

    func record(_ message: String) {
        let line = String(format: "[%7.2f] ", Date().timeIntervalSince(started)) + message
        entries.append(Entry(line: line))
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }
}

/// Both tabs share the connections, which are watched for as long as the app runs.
struct RootView: View {
    @State private var log = ConnectionLog()

    var body: some View {
        TabView {
            Tab("Validate", systemImage: "checkmark.seal") { ValidateView(log: log) }
            Tab("Explore", systemImage: "folder") { ExploreView(devices: log.devices, log: log) }
        }
        .task { await log.watch() }
    }
}

struct ValidateView: View {
    let log: ConnectionLog
    /// A level 2 plan waiting for the person to confirm, and the device it's for.
    @State private var plan: (device: FieldDevice, plan: LevelTwo.Plan)?
    @State private var cleanup: FieldDevice?
    /// The side the person is asked to confirm putting back, the copy it comes from, and what the side holds now.
    @State private var putBack: (device: FieldDevice, copy: SideRestore.Copy, current: SideRestore.Current)?
    /// The device a level 3 is waiting for the person to confirm on.
    @State private var levelThree: FieldDevice?
    /// What the writing conformance checks do, for the person to confirm.
    static let writingConformancePlan: String = {
        let scratch = "tapes/\(Conformance.scratchTape)"
        let steps: [String] = [
            "Makes an empty tape, \(scratch), checks it, and deletes it.",
            "Duplicates your smallest tape to \(scratch), checks the copy, and deletes it. Your tape is only read.",
            "Copies that tape into a temporary archive, restores it as \(scratch), checks it against the archive, and deletes both.",
            "Duplicates that tape again and moves the copy off into a temporary archive, then deletes the archive.",
            "Duplicates it once more and deletes the copy, keeping your tape as its match.",
            "Makes an empty \(scratch), restores that tape's archive over it, archiving it first, then restores the empty tape back with a confirmation, and deletes it.",
            "Needs one free tape slot, and leaves nothing behind.",
        ]
        return steps.map { "• " + $0 }.joined(separator: "\n")
    }()

    static func duration(_ duration: Duration) -> String {
        duration.formatted(.units(allowed: [.minutes, .seconds], width: .narrow))
    }

    /// The device the writing conformance checks are waiting for the person to confirm on.
    @State private var writingConformance: FieldDevice?

    var body: some View {
        NavigationStack {
            List {
                Section("OP-1") {
                    if log.devices.isEmpty {
                        Text("Put the OP-1 in MTP mode and connect it with USB.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(log.devices) { device in
                        DeviceRow(info: device.info)
                        Button(log.running == device.id ? "Running level 1…" : "Run level 1 (reads only)") {
                            Task { await log.runLevelOne(on: device) }
                        }
                        .disabled(log.running != nil)
                        Button("Run conformance suite (reads only, copies to Documents)") {
                            Task { await log.runConformance(on: device) }
                        }
                        .disabled(log.running != nil)
                        Button("Run writing conformance (scratch tape)…") { writingConformance = device }
                            .disabled(log.running != nil)
                        Button(log.planning == device.id ? "Planning level 2…" : "Run level 2 (scratch writes)…") {
                            Task {
                                if let planned = await log.planLevelTwo(on: device) { plan = (device, planned) }
                            }
                        }
                        .disabled(log.running != nil)
                        if log.isLevelThreePending(for: device) {
                            if log.isLevelTwoConnection(device) {
                                Text("Level 3 is waiting. Leave MTP mode on the OP-1, then enter it again. You can "
                                     + "play the scratch tape on the OP-1 in between.")
                                    .foregroundStyle(.secondary)
                            } else {
                                Button(log.running == device.id ? "Running level 3…" : "Run level 3 (after the reconnect)…") {
                                    levelThree = device
                                }
                                .disabled(log.running != nil)
                            }
                        } else if let found = log.leftovers[device.id], !found.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("FieldCheck's content from a run that didn't finish is on the OP-1:")
                                Text(found.map(\.string).joined(separator: ", ")).font(.caption.monospaced())
                            }
                            Button("Delete FieldCheck's content…", role: .destructive) { cleanup = device }
                                .disabled(log.running != nil)
                        }
                        if let copy = log.sideCopy {
                            Text("Level 2's copy of \(copy.side) is in \(copy.folder). FieldCheck reads \(copy.side) only if you put it back.")
                                .foregroundStyle(.secondary)
                            Button(log.readingSide == device.id ? "Reading \(copy.side)…" : "Put \(copy.side) back from level 2's copy…") {
                                Task {
                                    if let current = await log.readSide(for: copy, on: device) { putBack = (device, copy, current) }
                                }
                            }
                            .disabled(log.running != nil)
                        }
                    }
                }
                ForEach(log.devices) { device in
                    if let report = log.reports[device.id] {
                        Section {
                            ForEach(report.results, id: \.expectation) { ResultRow(result: $0) }
                        } header: {
                            Text("Level \(report.level): \(report.countsDescription)")
                        }
                    }
                }
                if !log.latestByLevel.isEmpty {
                    BaselineSection(log: log)
                }
                ForEach(log.devices) { device in
                    if let results = log.conformance[device.id] {
                        Section("Conformance") {
                            ForEach(results) { ConformanceRow(result: $0) }
                        }
                    }
                }
                Section("Log") {
                    ForEach(log.entries) { entry in
                        Text(entry.line)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Validate")
            .confirmationDialog("Level 2", isPresented: Binding(get: { plan != nil }, set: { if !$0 { plan = nil } }),
                                titleVisibility: .visible, presenting: plan) { pending in
                if pending.plan.refusal == nil {
                    Button("Write to the OP-1") {
                        Task { await log.runLevelTwo(on: pending.device, plan: pending.plan, longCheck: false) }
                    }
                    Button("Write, with the long check") {
                        Task { await log.runLevelTwo(on: pending.device, plan: pending.plan, longCheck: true) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { pending in
                if let refusal = pending.plan.refusal {
                    Text(refusal)
                } else {
                    Text(pending.plan.steps.map { "• \($0)" }.joined(separator: "\n"))
                }
            }
            .confirmationDialog("Put the side back?", isPresented: Binding(get: { putBack != nil }, set: { if !$0 { putBack = nil } }),
                                titleVisibility: .visible, presenting: putBack) { pending in
                Button("Put the copy back", role: .destructive) {
                    Task { await log.putSideBack(on: pending.device, from: pending.copy, over: pending.current) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { pending in
                let copy = "\(pending.copy.folder)/\(pending.copy.url.lastPathComponent), \(pending.copy.size.formatted()) bytes, "
                    + "SHA-256 \(pending.copy.sha256.prefix(8))…\(pending.copy.sha256.suffix(10))"
                let side = "mixdown/side_\(pending.copy.side.rawValue).wav"
                if case .other(let now) = pending.current {
                    Text("Copies what \(side) holds now, \(Self.duration(now.duration)) and \(now.size.formatted()) bytes, next to "
                         + "level 2's copy and verifies it, then replaces it with \(copy). If the side is shorter than the "
                         + "copy, nothing is written. It logs every MTP request it sends.")
                } else {
                    Text("Replaces FieldCheck's 2-second tone on \(side) with \(copy). It writes only if the side still "
                         + "holds the tone. It logs every MTP request it sends.")
                }
            }
            .confirmationDialog("Level 3", isPresented: Binding(get: { levelThree != nil }, set: { if !$0 { levelThree = nil } }),
                                titleVisibility: .visible, presenting: levelThree) { device in
                Button(log.pendingLevelThree?.album == nil ? "Check, then delete FieldCheck's tapes"
                       : "Check, put the side back, and delete FieldCheck's tapes", role: .destructive) {
                    Task { await log.runLevelThree(on: device) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text(LevelThree.steps(for: log.pendingLevelThree).map { "• \($0)" }.joined(separator: "\n"))
            }
            .confirmationDialog("Writing conformance", isPresented: Binding(get: { writingConformance != nil },
                                                                              set: { if !$0 { writingConformance = nil } }),
                                titleVisibility: .visible, presenting: writingConformance) { device in
                Button("Write to the OP-1") { Task { await log.runConformance(on: device, writing: true) } }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text(Self.writingConformancePlan)
            }
            .confirmationDialog("Delete FieldCheck's content?", isPresented: Binding(get: { cleanup != nil },
                                                                                      set: { if !$0 { cleanup = nil } }),
                                titleVisibility: .visible, presenting: cleanup) { device in
                Button("Delete", role: .destructive) { Task { await log.deleteLeftovers(on: device) } }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Deletes \(LevelTwo.ownContent.map(\.string).joined(separator: ", ")) if they're there: "
                     + "only what level 2 makes. Each tape's files, then its folder.")
            }
        }
    }
}

/// This launch's latest run of each level, and saving them as the baseline.
struct BaselineSection: View {
    let log: ConnectionLog

    var body: some View {
        let included = Set(log.baselineReports.map(\.level))
        Section {
            ForEach(1...3, id: \.self) { level in
                if let report = log.latestByLevel[level] {
                    LabeledContent("Level \(level)", value: report.countsDescription + (included.contains(level) ? "" : ", left out"))
                } else {
                    LabeledContent("Level \(level)", value: "not run yet")
                }
            }
            if let saved = log.baselineSavedFromCurrentRuns, let file = saved.file {
                // Saved already: a second tap would only write the same runs again under another name.
                Label("Saved as \(file) in Documents", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            } else {
                Button("Save as baseline for \(log.baselineReports.first?.device.firmware ?? "this firmware")") { log.saveBaseline() }
                    .disabled(included.isEmpty)
                if let problem = log.baselineSavedFromCurrentRuns?.problem {
                    Text("Couldn't save: \(problem)").foregroundStyle(.red)
                }
            }
        } header: {
            Text("Baseline")
        } footer: {
            Text("Made from this launch's latest run of each level. Level 1 is needed, and a level with failures is left "
                 + "out. For a firmware's baseline, run levels 1, 2 and 3.")
        }
    }
}

struct DeviceRow: View {
    let info: FieldDeviceInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(info.model).font(.headline)
            LabeledContent("Firmware", value: info.isFirmwareTested ? info.firmware : "\(info.firmware), untested")
            LabeledContent("Serial number", value: info.serialNumber)
            LabeledContent("Free space", value: info.storage.freeSpace.formatted(.byteCount(style: .file)))
            LabeledContent("Capacity", value: info.storage.capacity.formatted(.byteCount(style: .file)))
        }
    }
}

struct ResultRow: View {
    let result: CheckResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(result.expectation).font(.body.monospaced())
                Spacer()
                Text(result.outcome.rawValue)
                    .font(.caption.bold())
                    .foregroundStyle(color)
            }
            Text(result.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            ForEach(result.differences, id: \.self) { difference in
                Text("Changed: \(difference.path.isEmpty ? "the whole value" : difference.path), \(difference.suggested.rawValue)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let note = result.baselineNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var color: Color {
        switch result.outcome {
        case .pass: .green
        case .changed: .orange
        case .fail: .red
        case .notRun: .secondary
        }
    }
}

struct ConformanceRow: View {
    let result: Conformance.Result

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(result.name)
                Spacer()
                Text(label).font(.caption.bold()).foregroundStyle(color)
            }
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private var label: String {
        switch result.outcome {
        case .pass: "pass"
        case .fail: "fail"
        case .skipped: "skipped"
        }
    }

    private var detail: String? {
        switch result.outcome {
        case .pass: result.detail
        case .fail(let message), .skipped(let message): message
        }
    }

    private var color: Color {
        switch result.outcome {
        case .pass: .green
        case .fail: .red
        case .skipped: .secondary
        }
    }
}

#Preview {
    List { DeviceRow(info: FieldDevice.simulated().info) }
}
