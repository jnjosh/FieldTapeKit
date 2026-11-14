// FieldCheck: checks a connected OP-1 against what FieldTapeKit expects (ADR 0003).
// It shows connection events and device info, runs level 1, and saves each report and its log to Documents.
// A run with no failures can be saved as its firmware's baseline, to copy into the repository's firmware/ folder.
// It also runs FieldTapeKit's conformance suite, the checks the simulator passes too, and logs the results.

import FieldCheckKit
import FieldTapeConformance
import FieldTapeKit
import SwiftUI
import UIKit

@main
struct FieldCheckApp: App {
    var body: some Scene {
        WindowGroup {
            ConnectionsView()
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

    private func record(_ message: String) {
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

struct ConnectionsView: View {
    @State private var log = ConnectionLog()

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
                    }
                }
                ForEach(log.devices) { device in
                    if let report = log.reports[device.id] {
                        Section {
                            ForEach(report.results, id: \.expectation) { ResultRow(result: $0) }
                            Button("Save as baseline for \(report.device.firmware)") { log.saveBaseline(report) }
                                .disabled(report.count(.fail) > 0)
                        } header: {
                            Text("Level 1: \(report.count(.pass)) pass, \(report.count(.fail)) fail, "
                                + "\(report.count(.notRun)) not run")
                        } footer: {
                            if report.count(.fail) > 0 {
                                Text("A run with failures can't be a baseline.")
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
            .navigationTitle("FieldCheck")
        }
        .task { await log.watch() }
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
