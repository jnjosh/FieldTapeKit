import FieldTapeKit
import Foundation

/// FieldCheck's level 1: reads only, and changes nothing on the OP-1 (ADR 0003, section 2).
///
/// It covers the device, the session, the layout and names, and then tapes, the album and reads
/// (`LevelOne+Content.swift`, `LevelOne+Reads.swift`). Each check fetches what it needs, then a plain function
/// judges it, so the judging can be tested without a device.
public enum LevelOne {
    /// Runs every level 1 check on `device`, in order, and returns the report. It never throws: a check that
    /// can't finish is a failure in the report.
    public static func run(on device: FieldDevice, host: CheckReport.Host) async -> CheckReport {
        let started = Date.now
        let results = await CheckRunner.run(checks(for: device))
        return CheckReport(level: 1, started: started, finished: .now, device: CheckReport.Device(device.info),
                           host: host, results: results)
    }

    static func checks(for device: FieldDevice) -> [Check] {
        let session = device.session
        let profile = device.profile
        let catalog = Catalog(session)
        return [
            Check("device.identity") { identity(device.usb) },
            Check("device.operations") { operations(try await session.deviceInfo()) },
            Check("device.storage") {
                var storages: [Storage] = []
                for id in try await session.storageIDs() {
                    storages.append(Storage(id: id, info: try await session.storageInfo(id)))
                }
                return storage(storages)
            },
            Check("session.implicit") {
                do {
                    let handles = try await session.objectHandles(parent: PTPContainer.rootParent)
                    return implicitSession(refusedWith: nil, rootObjects: handles.count)
                } catch MTPError.refused(_, let responseCode) {
                    return implicitSession(refusedWith: responseCode, rootObjects: 0)
                }
            },
            Check("session.data-phase") {
                var replies: [(PTPOperation, MTPReply)] = []
                for operation in [PTPOperation.getDeviceInfo, .getStorageIDs] {
                    replies.append((operation, try await session.send(operation)))
                }
                return dataPhase(replies.map { ("\($0.0)", $0.1.hadContainerHeader, $0.1.payload.count) })
            },
            Check("layout.folders") { folders(try await catalog.entries(), profile: profile) },
            Check("layout.readmes") {
                var texts: [String: String] = [:]
                for entry in try await catalog.entries() where !entry.isFolder && entry.name.lowercased() == "readme.txt" {
                    texts[entry.path] = String(decoding: try await catalog.contents(of: entry), as: UTF8.self)
                }
                return readmes(texts, profile: profile)
            },
            Check("names.lowercase") { lowercase(try await catalog.entries()) },
        ] + contentChecks(catalog: catalog, profile: profile)
    }

    // MARK: device.identity

    static func identity(_ usb: USBIdentity?) -> Finding {
        guard let usb else { return .notRun("ImageCaptureCore didn't report a USB device, so there's nothing to check.") }
        let expected = USBIdentity.op1
        let observed: CheckValue = ["vendorID": .string(hex(usb.vendorID)), "productID": .string(hex(usb.productID)),
                                    "name": usb.name.map(CheckValue.string) ?? "(none)"]
        var differences: [String] = []
        if usb.vendorID != expected.vendorID { differences.append("vendor \(hex(usb.vendorID))") }
        if usb.productID != expected.productID { differences.append("product \(hex(usb.productID))") }
        if usb.name != expected.name { differences.append("name \(usb.name.map { "\"\($0)\"" } ?? "missing")") }
        guard differences.isEmpty else {
            return .fail("Connected, but not as 1.7.3 did: \(differences.joined(separator: ", ")).", observed: observed)
        }
        return .pass("USB vendor 0x2367, product 0x0102, named \"OP-1\".", observed: observed)
    }

    // MARK: device.operations

    static func operations(_ info: PTPDeviceInfo) -> Finding {
        let listed = Set(info.operations)
        let observed: CheckValue = ["operations": .list(info.operations.map { .string(hex($0)) }),
                                    "vendorExtensionID": .int(Int(info.vendorExtensionID))]
        let missing = PTPOperation.allCases.filter { !listed.contains($0.rawValue) }
        guard missing.isEmpty else {
            let names = missing.map { "\($0) (\(hex($0.rawValue)))" }.joined(separator: ", ")
            return .fail("FieldTapeKit sends operations the OP-1 doesn't list: \(names).", observed: observed)
        }
        return .pass("\(info.operations.count) operations listed, including all \(PTPOperation.allCases.count) "
                     + "that FieldTapeKit sends.", observed: observed)
    }

    // MARK: device.storage

    struct Storage: Sendable {
        let id: UInt32
        let info: PTPStorageInfo
    }

    static func storage(_ storages: [Storage]) -> Finding {
        let observed: CheckValue = ["storages": .list(storages.map { storage in
            ["id": .string(hex(storage.id, digits: 8)), "capacity": .int(Int(clamping: storage.info.maxCapacity)),
             "freeSpace": .int(Int(clamping: storage.info.freeSpaceInBytes)),
             "storageType": .string(hex(storage.info.storageType)),
             "filesystemType": .string(hex(storage.info.filesystemType)),
             "accessCapability": .string(hex(storage.info.accessCapability))]
        })]
        // Free space changes with what's on the OP-1, and even while it's out of MTP mode.
        let varies = ["storages[].freeSpace"]
        guard storages.count == 1, let only = storages.first else {
            let ids = storages.map { hex($0.id, digits: 8) }.joined(separator: ", ")
            return .fail(storages.isEmpty ? "The OP-1 lists no storage."
                         : "\(storages.count) storages (\(ids)), but FieldTapeKit uses only the first.",
                         observed: observed, varies: varies)
        }
        let free = Int(clamping: only.info.freeSpaceInBytes).formatted(.byteCount(style: .file))
        let capacity = Int(clamping: only.info.maxCapacity).formatted(.byteCount(style: .file))
        return .pass("One storage, \(hex(only.id, digits: 8)), with \(free) free of \(capacity). Whether free space is accurate "
                     + "is checked at level 2.", observed: observed, varies: varies)
    }

    // MARK: session.implicit

    static func implicitSession(refusedWith responseCode: UInt16?, rootObjects: Int) -> Finding {
        guard let responseCode else {
            return .pass("GetObjectHandles answered with no OpenSession sent, listing \(rootObjects) objects at the root.",
                         observed: ["openSessionSent": false, "getObjectHandles": .string(hex(PTPResponseCode.ok))])
        }
        let meaning = responseCode == 0x2003 ? "Session Not Open" : "a refusal"
        return .fail("GetObjectHandles, with no OpenSession sent, got \(meaning) (\(hex(responseCode))).",
                     observed: ["openSessionSent": false, "getObjectHandles": .string(hex(responseCode))])
    }

    // MARK: session.data-phase

    static func dataPhase(_ replies: [(operation: String, hadHeader: Bool, bytes: Int)]) -> Finding {
        let observed = CheckValue.record(Dictionary(uniqueKeysWithValues: replies.map {
            ($0.operation, ["containerHeader": .bool($0.hadHeader), "payloadBytes": .int($0.bytes)])
        }))
        let headed = replies.filter(\.hadHeader).map(\.operation)
        guard headed.isEmpty else {
            return .fail("Data arrived with its container header for \(headed.joined(separator: " and ")). FieldTapeKit "
                         + "strips it, but 1.7.3 never sent one, so ImageCaptureCore or the firmware changed.",
                         observed: observed)
        }
        return .pass("Data arrived without its container header for \(replies.map(\.operation).joined(separator: " and ")).",
                     observed: observed)
    }

    // MARK: layout.folders

    static func folders(_ entries: [CatalogEntry], profile: FirmwareProfile) -> Finding {
        let folders = entries.filter(\.isFolder).map(\.path)
        let present = Set(folders.map { $0.lowercased() })
        let expected = Set(profile.folders)
        let missing = profile.folders.filter { !present.contains($0) }
        let tapes = folders.filter { $0.lowercased().hasPrefix("tapes/") && !$0.dropFirst(6).contains("/") }
        let others = folders.filter { !expected.contains($0.lowercased()) && !$0.lowercased().hasPrefix("tapes/") }.sorted()
        let found = folders.filter { expected.contains($0.lowercased()) }.sorted()
        // Tapes and folders people make differ from one OP-1 to the next, and over time, so they're only in the
        // summary. What's observed is what the firmware decides, for the baseline.
        let observed: CheckValue = ["expected": .list(found.map(CheckValue.string))]
        guard missing.isEmpty else {
            return .fail("Missing: \(missing.joined(separator: ", ")).", observed: observed)
        }
        let extra = others.isEmpty ? "" : " Also there: \(others.joined(separator: ", "))."
        return .pass("All \(profile.folders.count) expected folders are there, and \(tapes.count) tape folders.\(extra)",
                     observed: observed)
    }

    // MARK: layout.readmes

    /// The names a `readme.txt` allows, from its "allowed names:" line, or nil if it has none.
    static func allowedNames(in text: String) -> [String]? {
        for line in text.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard line.lowercased().hasPrefix("allowed names:") else { continue }
            return line.dropFirst("allowed names:".count).split(whereSeparator: \.isWhitespace).map(String.init)
        }
        return nil
    }

    /// `tapes/<tape>/readme.txt` becomes `tapes/*/readme.txt`, since every tape's should say the same.
    static func readmeKind(_ path: String) -> String {
        let parts = path.split(separator: "/")
        if parts.count == 3, parts[0].lowercased() == "tapes" { return "tapes/*/\(parts[2])" }
        return path
    }

    static func readmes(_ texts: [String: String], profile: FirmwareProfile) -> Finding {
        let byKind = Dictionary(grouping: texts, by: { readmeKind($0.key).lowercased() })
        let observed = CheckValue.record(byKind.mapValues { files in
            let distinct = Set(files.map(\.value)).sorted()
            return distinct.count == 1 ? .string(distinct[0]) : .list(distinct.map(CheckValue.string))
        })
        var problems: [String] = []
        var checked: [String] = []
        for (folder, names) in profile.allowedNames.sorted(by: { $0.key < $1.key }) {
            let kind = "\(folder)/readme.txt"
            guard let files = byKind[kind] else {
                // A person may have no tapes, but mixdown/ is always there.
                if !folder.contains("*") { problems.append("\(kind) is missing") }
                continue
            }
            for (path, text) in files.sorted(by: { $0.key < $1.key }) {
                let allowed = allowedNames(in: text)
                if allowed != names {
                    problems.append("\(path) allows \(allowed?.joined(separator: " ") ?? "no names"), "
                                    + "not \(names.joined(separator: " "))")
                }
            }
            checked.append(folder.contains("*") ? "\(files.count) tapes" : folder)
        }
        guard problems.isEmpty else {
            return .fail("Folder rules differ from FieldTapeKit's: \(problems.joined(separator: "; ")).", observed: observed)
        }
        let ruled = Set(profile.allowedNames.keys.map { "\($0)/readme.txt" })
        let unruled = byKind.filter { kind, files in
            !ruled.contains(kind) && files.contains { allowedNames(in: $0.value) != nil }
        }.keys.sorted()
        let note = unruled.isEmpty ? "" : " Also naming allowed names, with no rule in FieldTapeKit: \(unruled.joined(separator: ", "))."
        return .pass("Read \(texts.count) readme.txt files. The allowed names match FieldTapeKit's rules for "
                     + "\(checked.isEmpty ? "nothing" : checked.joined(separator: " and ")).\(note)", observed: observed)
    }

    // MARK: names.lowercase

    static func lowercase(_ entries: [CatalogEntry]) -> Finding {
        let mixed = entries.filter { $0.name != $0.name.lowercased() }.map(\.path).sorted()
        // The number of names depends on what's on this OP-1, so it's only in the summary.
        let observed: CheckValue = ["notLowercase": .list(mixed.map(CheckValue.string))]
        guard mixed.isEmpty else {
            return .fail("\(mixed.count) of \(entries.count) names aren't lowercase: \(mixed.joined(separator: ", ")).",
                         observed: observed)
        }
        return .pass("All \(entries.count) names are lowercase.", observed: observed)
    }

    // MARK: Formatting

    /// Such as 0x2367, or 0x00010001 with 8 digits.
    static func hex(_ value: some BinaryInteger, digits: Int = 4) -> String {
        let text = String(value, radix: 16, uppercase: true)
        return "0x" + String(repeating: "0", count: max(0, digits - text.count)) + text
    }
}
