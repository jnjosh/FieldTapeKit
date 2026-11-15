// FieldCheck: checks a connected OP-1 against what FieldTapeKit expects (ADR 0003), in two tabs.
// Validate shows connection events and device info, runs level 1, and saves each report and its log to Documents.
// A level 1 run with no failures can be saved as its firmware's baseline, to copy into the repository's firmware/
// folder. Level 2 writes only FieldCheck's own scratch content, after a person confirms its plan, and FieldCheck can
// delete what it leaves.
// It also runs FieldTapeKit's conformance suite, the checks the simulator passes too, and logs the results.
// Explore (ExploreView.swift) browses the OP-1 through FieldTapeKit's public API, as an app would. It only reads.

import FieldCheckKit
import FieldTapeConformance
import FieldTapeKit
import SwiftUI
import UIKit

@main
struct FieldCheckApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
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
    /// The latest conformance results for each connection.
    private(set) var conformance: [FieldDevice.ID: [Conformance.Result]] = [:]
    private(set) var running: FieldDevice.ID?
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
    }

    /// Level 1 only reads, so it needs no confirmation.
    func runLevelOne(on device: FieldDevice) async {
        guard running == nil else { return }
        running = device.id
        defer { running = nil }
        record("Level 1: running")
        let report = await LevelOne.run(on: device, host: host)
        reports[device.id] = report
        for result in report.results where result.outcome != .pass {
            record("Level 1: \(result.expectation) \(result.outcome.rawValue): \(result.summary)")
        }
        record("Level 1: \(report.count(.pass)) pass, \(report.count(.fail)) fail, \(report.count(.notRun)) not run")
        do {
            let saved = try report.save(in: .documentsDirectory)
            record("Saved \(saved.json.lastPathComponent) and \(saved.markdown.lastPathComponent)")
        } catch {
            record("Couldn't save the report: \(error.localizedDescription)")
        }
    }

    /// Level 2 writes, so it starts from a plan that a person confirms (ADR 0003, section 3). This only reads.
    func planLevelTwo(on device: FieldDevice) async -> LevelTwo.Plan {
        let plan = await LevelTwo.plan(for: device)
        if let refusal = plan.refusal { record("Level 2: can't run: \(refusal)") }
        return plan
    }

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
        let report = await LevelTwo.run(on: device, plan: plan, longCheck: longCheck, workspace: workspace, host: host)
        reports[device.id] = report
        for result in report.results {
            record("Level 2: \(result.expectation) \(result.outcome.rawValue): \(result.summary)")
        }
        record("Level 2: \(report.count(.pass)) pass, \(report.count(.fail)) fail, \(report.count(.notRun)) not run")
        do {
            let saved = try report.save(in: .documentsDirectory)
            record("Saved \(saved.json.lastPathComponent) and \(saved.markdown.lastPathComponent)")
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
        record("\(result.expectation) \(result.outcome.rawValue): \(result.summary)")
    }

    private static func stamp() -> String {
        Date.now.formatted(.iso8601.year().month().day().timeZone(separator: .omitted)
            .time(includingFractionalSeconds: false).timeSeparator(.omitted))
    }

    /// The conformance suite only reads the OP-1, so it needs no confirmation either. It copies a tape track and an
    /// album side into a new folder in Documents, kept so they can be compared with copies made on a Mac. The log
    /// is its record, with each copy's SHA-256.
    func runConformance(on device: FieldDevice) async {
        guard running == nil else { return }
        running = device.id
        defer { running = nil }
        let stamp = Date.now.formatted(.iso8601.year().month().day().timeZone(separator: .omitted)
            .time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let workspace = URL.documentsDirectory.appending(path: "conformance-\(stamp)")
        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        } catch {
            record("Conformance: couldn't make \(workspace.lastPathComponent): \(error.localizedDescription)")
            return
        }
        record("Conformance: running, copies go in \(workspace.lastPathComponent)")
        let results = await Conformance.run(on: device, workspace: workspace)
        conformance[device.id] = results
        for result in results {
            switch result.outcome {
            case .pass: record("Conformance: pass: \(result.name)\(result.detail.map { ". \($0)" } ?? "")")
            case .fail(let message): record("Conformance: FAIL: \(result.name): \(message)")
            case .skipped(let reason): record("Conformance: skipped: \(result.name): \(reason)")
            }
        }
        let failed = results.filter { if case .fail = $0.outcome { true } else { false } }.count
        record("Conformance: \(results.count - failed) of \(results.count) without a failure")
    }

    /// Saves the report as `baseline-<firmware>.json` in Documents, under a new name if one is there already.
    func saveBaseline(_ report: CheckReport) {
        do {
            let url = try Baseline(report: report).save(in: .documentsDirectory)
            record("Saved \(url.lastPathComponent). Copy it into the repository as firmware/\(report.device.firmware)/baseline.json.")
        } catch {
            record("Couldn't save the baseline: \(error.localizedDescription)")
        }
    }

    func watch() async {
        #if targetEnvironment(simulator)
        // The simulator has no USB devices. `-SimulatedOP1 YES` gives it FieldTapeKit's simulated OP-1, to try the
        // app's screens without hardware.
        if UserDefaults.standard.bool(forKey: "SimulatedOP1") {
            let device = FieldDevice.simulated {
                Directory("tapes") {
                    Directory("2026-220#02") {
                        File("tape.json", data: Data(#"{"clips":[],"version":1}"#.utf8))
                        File("track_1.wav", seconds: 3)
                        for track in 2...4 { File("track_\(track).wav", seconds: 0) }
                    }
                }
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
                    let info = device.info
                    record("Connected: \(info.model), firmware \(info.firmware)\(info.isFirmwareTested ? "" : " (untested)"), "
                        + "serial \(info.serialNumber)")
                    record("Storage: \(info.storage.capacity) bytes, \(info.storage.freeSpace) free")
                case .disconnected(let id):
                    devices.removeAll { $0.id == id }
                    reports[id] = nil
                    conformance[id] = nil
                    record("Disconnected")
                }
            }
            record("Stopped watching")
        } catch {
            record("Stopped: \(error.localizedDescription) \((error as? LocalizedError)?.recoverySuggestion ?? "")")
        }
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
                        Button("Run level 2 (scratch writes)…") {
                            Task { plan = (device, await log.planLevelTwo(on: device)) }
                        }
                        .disabled(log.running != nil)
                        Button("Delete FieldCheck's content…", role: .destructive) { cleanup = device }
                            .disabled(log.running != nil)
                    }
                }
                ForEach(log.devices) { device in
                    if let report = log.reports[device.id] {
                        Section {
                            ForEach(report.results, id: \.expectation) { ResultRow(result: $0) }
                            if report.level == 1 {
                                Button("Save as baseline for \(report.device.firmware)") { log.saveBaseline(report) }
                                    .disabled(report.count(.fail) > 0)
                            }
                        } header: {
                            Text("Level \(report.level): \(report.count(.pass)) pass, \(report.count(.fail)) fail, "
                                + "\(report.count(.notRun)) not run")
                        } footer: {
                            if report.level == 1, report.count(.fail) > 0 {
                                Text("A run with failures can't be a baseline.")
                            } else if report.level == 2 {
                                Text("Baselines cover level 1 for now.")
                            }
                        }
                    }
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
            .confirmationDialog("Delete FieldCheck's content?", isPresented: Binding(get: { cleanup != nil },
                                                                                      set: { if !$0 { cleanup = nil } }),
                                titleVisibility: .visible, presenting: cleanup) { device in
                Button("Delete", role: .destructive) { Task { await log.deleteLeftovers(on: device) } }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Deletes \(LevelTwo.ownContent.map(\.string).joined(separator: ", ")) if they're there: "
                     + "only what level 2 makes. Each file, then the tape's folder.")
            }
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
        }
    }

    private var color: Color {
        switch result.outcome {
        case .pass: .green
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
