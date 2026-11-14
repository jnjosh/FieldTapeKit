// Explore: a plain browser of a connected OP-1, built only on FieldTapeKit's public API, the way an app would use it.
// It lists folders, shows each item's details, and copies a file to this device. It never changes the OP-1: ADR 0003
// keeps FieldCheck's writes to its own scratch content, and the owner decided on read-only (2026-11-14).

import FieldTapeKit
import SwiftUI
import System

struct ExploreView: View {
    let devices: [FieldDevice]
    /// Where copies are noted, as the rest of FieldCheck's runs are. Nil in previews.
    let log: ConnectionLog?
    @State private var selected: FieldDevice.ID?

    private var device: FieldDevice? {
        devices.first { $0.id == selected } ?? devices.first
    }

    var body: some View {
        NavigationStack {
            Group {
                if let device {
                    FolderView(device: device, path: FilePath(), log: log)
                } else {
                    ContentUnavailableView("No OP-1", systemImage: "cable.connector",
                                           description: Text("Put the OP-1 in MTP mode and connect it with USB."))
                }
            }
            .toolbar {
                if devices.count > 1 {
                    Picker("OP-1", selection: $selected) {
                        ForEach(devices) { Text($0.info.serialNumber).tag(Optional($0.id)) }
                    }
                }
            }
        }
        // A reconnect is a new device with new handles, so browsing starts again from the root.
        .id(device?.id)
    }
}

struct FolderView: View {
    let device: FieldDevice
    let path: FilePath
    let log: ConnectionLog?
    @State private var items: [FieldItem]?
    @State private var failure: String?

    var body: some View {
        List {
            if let failure {
                Text(failure).foregroundStyle(.red)
            } else if let items {
                if items.isEmpty { Text("Empty").foregroundStyle(.secondary) }
                ForEach(items) { item in
                    NavigationLink {
                        if item.isDirectory {
                            FolderView(device: device, path: item.path, log: log)
                        } else {
                            ItemView(device: device, item: item, log: log)
                        }
                    } label: {
                        ItemRow(item: item)
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(path.lastComponent?.string ?? "OP-1")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            items = try await device.contentsOfDirectory(at: path)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}

struct ItemRow: View {
    let item: FieldItem

    var body: some View {
        HStack {
            Image(systemName: item.isDirectory ? "folder" : "doc")
                .foregroundStyle(item.isDirectory ? .blue : .secondary)
            Text(item.name)
            Spacer()
            if !item.isDirectory {
                Text(item.size.formatted(.byteCount(style: .file))).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

struct ItemView: View {
    let device: FieldDevice
    let item: FieldItem
    let log: ConnectionLog?
    @State private var copying = false
    @State private var copy: URL?
    @State private var failure: String?

    var body: some View {
        List {
            Section {
                LabeledContent("Path", value: item.path.string)
                LabeledContent("Size", value: "\(item.size.formatted()) bytes")
                LabeledContent("Format", value: item.format.label)
            }
            Section {
                Button(copying ? "Copying…" : "Copy to this device") {
                    Task { await copyOff() }
                }
                .disabled(copying)
                if let copy {
                    LabeledContent("Copied to", value: "Documents/explore/\(copy.lastPathComponent)")
                    ShareLink(item: copy)
                }
                if let failure {
                    Text(failure).foregroundStyle(.red)
                }
            } footer: {
                Text("Reads the file with one GetObject, saves it under a new name if one's taken, and checks the copy by SHA-256.")
            }
        }
        .navigationTitle(item.name)
    }

    private func copyOff() async {
        copying = true
        defer { copying = false }
        do {
            let folder = URL.documentsDirectory.appending(path: "explore")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = try await device.copyItem(at: item.path, to: folder.appending(path: item.name))
            copy = url
            failure = nil
            log?.record("Explore: copied \(item.path) to explore/\(url.lastPathComponent), \(item.size) bytes")
        } catch {
            failure = error.localizedDescription
            log?.record("Explore: couldn't copy \(item.path): \(error.localizedDescription)")
        }
    }
}

extension FieldFormat {
    var label: String {
        switch self {
        case .folder: "Folder"
        case .wav: "WAV"
        case .aiff: "AIFF"
        case .json: "JSON"
        case .text: "Text"
        case .other(let code): String(format: "Other (0x%04X)", code)
        }
    }
}

#Preview {
    ExploreView(devices: [FieldDevice.simulated {
        Directory("tapes") {
            Directory("2026-220#02") {
                File("tape.json", data: Data(#"{"clips":[]}"#.utf8))
                File("track_1.wav", seconds: 3)
            }
        }
        Directory("mixdown") { File("side_a.wav", seconds: 10) }
    }], log: nil)
}
