// FieldCheck: checks a connected OP-1 against what FieldTapeKit expects (ADR 0003).
// It shows connection events and device info, runs level 1, and saves each report and its log to Documents.

import FieldCheckKit
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
                    }
                }
                ForEach(log.devices) { device in
                    if let report = log.reports[device.id] {
                        Section("Level 1: \(report.count(.pass)) pass, \(report.count(.fail)) fail, "
                            + "\(report.count(.notRun)) not run") {
                            ForEach(report.results, id: \.expectation) { ResultRow(result: $0) }
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

#Preview {
    List { DeviceRow(info: FieldDevice.simulated().info) }
}
