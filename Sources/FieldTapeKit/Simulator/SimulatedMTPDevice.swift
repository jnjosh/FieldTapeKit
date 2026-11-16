import Foundation

/// An OP-1 simulated at the MTP level. It decodes real command containers and answers with real datasets,
/// so the PTP encoding and parsing run in tests (ADR 0002, section 8).
///
/// This step serves the read operations only. Writes are answered with Operation Not Supported until the
/// file layer needs them.
actor SimulatedMTPDevice: MTPTransport {
    /// Something to go wrong on purpose. Requests are counted from 1, pings included.
    enum Fault: Sendable {
        /// The request never gets an answer.
        case noAnswer(request: Int)
        /// From this request on, nothing gets an answer, as if the cable were pulled mid-session.
        case silent(fromRequest: Int)
        /// The request is refused with this response code.
        case refuse(request: Int, responseCode: UInt16)
        /// The request's data phase comes back cut short, after this many bytes.
        case shortData(request: Int, keeping: Int)
        /// Deleting the object with this name is refused with this response code.
        case refuseDeleting(name: String, responseCode: UInt16)
        /// The file with this name is stored with its last byte changed, so it reads back wrong. For a preset
        /// that's a sample, after the conversion.
        case corruptStored(name: String)
        /// Every SendObject is refused with this response code, after its SendObjectInfo succeeded.
        case refuseSendObject(responseCode: UInt16)
        /// Right after the file with this name has been read with GetObject this many times, it's replaced with this
        /// data, as if the OP-1 rewrote it, and it lists at its new size. It happens once.
        case changeAfterReading(name: String, to: Data, reads: Int = 1)
        /// GetObject for the file with this name comes back a byte short, once.
        case shortRead(name: String)
        /// After a reconnect, both album sides are the OP-1's own again, whatever was written to them over MTP. It's
        /// one answer to `album.write-kept`, which isn't known yet. Without it, a written side lasts.
        case albumKeepsItsOwn
    }

    struct Object: Sendable {
        var parent: UInt32
        var name: String
        var format: UInt16
        var associationType: UInt16 = 0
        var data = Data()
        /// The size the OP-1 lists and serves, when it's not the data's: a file rebuilt within the session keeps its
        /// old size until a reconnect (`rebuild.stale-size`).
        var staleSize: Int?

        /// What GetObject and GetPartialObject serve.
        var served: Data { staleSize.map { Data(data.prefix($0)) } ?? data }
    }

    static let storageID: UInt32 = 0x0001_0001
    /// Root-level objects carry parent 0 in their ObjectInfo, as the PTP spec says.
    static let root: UInt32 = 0

    /// The operations OP-1 firmware 1.7.3 lists in its DeviceInfo (probe logs, 2026-11-08).
    static let operations173: [UInt16] = [
        0x1002, 0x1003, 0x1001, 0x1004, 0x1005, 0x1009, 0x1014, 0x1015, 0x1016, 0x100B, 0x100D,
        0x1006, 0x1007, 0x1008, 0x100C, 0x101B, 0x9801, 0x9802, 0x9803, 0x9804, 0x9805,
    ]

    let firmware: String
    let serialNumber: String
    /// What GetDeviceInfo lists.
    let operations: [UInt16]
    /// The default is the capacity a real OP-1 Field reported on 1.7.3 (FieldCheck, 2026-11-09). Free space is
    /// this minus the stored bytes.
    let capacity: UInt64
    private var objects: [UInt32: Object] = [:]
    private var nextHandle: UInt32 = 1
    private var faults: [Fault]
    private(set) var requestCount = 0
    /// The names of deleted objects, in the order they went.
    private(set) var deleted: [String] = []
    /// The name of every object made with SendObjectInfo, in order.
    private(set) var sentNames: [String] = []
    /// The file SendObjectInfo announced, waiting for its SendObject.
    private var pending: UInt32?
    /// The album as the OP-1 itself holds it, by side name. A side deleted over MTP is back from it after a
    /// reconnect, as the owner saw on 1.7.3 (PROBE-NOTES.md, 2026-11-16).
    private var album: [String: Data] = [:]

    /// Free space when it was made, before any later `addFile`.
    let initialFreeSpace: UInt64

    /// `contents` is laid out under the root, in order.
    init(firmware: String = "1.7.3", serialNumber: String = "SIMULATED", capacity: UInt64 = 6_429_185_024,
         operations: [UInt16] = operations173, faults: [Fault] = [], contents: [SimulatedNode] = []) {
        self.firmware = firmware
        self.serialNumber = serialNumber
        self.operations = operations
        self.capacity = capacity
        self.faults = faults
        var objects: [UInt32: Object] = [:]
        var nextHandle: UInt32 = 1
        func lay(_ nodes: [SimulatedNode], in parent: UInt32) {
            for node in nodes {
                let handle = nextHandle
                nextHandle += 1
                switch node {
                case .folder(let name, let children):
                    objects[handle] = Object(parent: parent, name: name, format: PTPObjectFormat.association,
                                             associationType: PTPAssociationType.genericFolder)
                    lay(children, in: handle)
                case .file(let name, let data, let format):
                    objects[handle] = Object(parent: parent, name: name, format: format, data: data)
                }
            }
        }
        lay(contents, in: Self.root)
        self.objects = objects
        self.nextHandle = nextHandle
        for side in Self.sideNames {
            if let object = objects.values.first(where: { $0.name == side && objects[$0.parent]?.name == "mixdown" }) {
                album[side] = object.data
            }
        }
        let used = objects.values.reduce(UInt64(0)) { $0 + UInt64($1.data.count) }
        initialFreeSpace = capacity - min(used, capacity)
    }

    // MARK: Contents

    @discardableResult
    func addFolder(_ name: String, in parent: UInt32 = root) -> UInt32 {
        add(Object(parent: parent, name: name, format: PTPObjectFormat.association,
                   associationType: PTPAssociationType.genericFolder))
    }

    @discardableResult
    func addFile(_ name: String, data: Data, format: UInt16 = PTPObjectFormat.wav, in parent: UInt32 = root) -> UInt32 {
        add(Object(parent: parent, name: name, format: format, data: data))
    }

    /// Replaces a file's contents as the OP-1 does when it rebuilds `tape.json` after a track write: within the
    /// session it still lists, and reads, at its size before the rebuild (`rebuild.stale-size`).
    func rebuild(_ handle: UInt32, with data: Data) {
        guard var object = objects[handle] else { return }
        object.staleSize = object.staleSize ?? object.data.count
        object.data = data
        objects[handle] = object
    }

    /// What the simulator holds for the object with this name in the folder with that name, ignoring what it serves.
    func stored(_ name: String, in folder: String) -> Data? {
        objects.values.first { object in
            object.name == name && objects[object.parent]?.name == folder
        }?.data
    }

    /// Replaces a file's contents with ones of another size, as if it were rewritten before this session.
    func replace(_ handle: UInt32, with data: Data) {
        objects[handle]?.data = data
        objects[handle]?.staleSize = nil
    }

    /// Replaces the contents of the file with this name in the folder with that name, as if the OP-1 changed it
    /// outside MTP mode, such as by recording over a track.
    func overwrite(_ name: String, in folder: String, with data: Data) {
        guard let handle = objects.first(where: { $0.value.name == name && objects[$0.value.parent]?.name == folder })?.key
        else { return }
        replace(handle, with: data)
        if folder == "mixdown", Self.sideNames.contains(name) { album[name] = data }
    }

    func add(faults more: [Fault]) {
        faults += more
    }

    /// What the OP-1 does between leaving MTP mode and entering it again, as seen on 1.7.3: names are stored
    /// lowercase, a tape's name is cut to 12 characters, a tape made over MTP gets a `readme.txt`, every object gets a
    /// new handle, and files list at their real size again (`reconnect.renamed`, `names.maximum`,
    /// `reconnect.handles`, `rebuild.stale-size`; PROBE-NOTES.md, 2026-11-08 and 2026-11-15). What happens when two
    /// cut names collide isn't known, so the simulator leaves both. An album side deleted over MTP is back, as the
    /// OP-1 last had it (PROBE-NOTES.md, 2026-11-16). A side written over MTP lasts, unless `albumKeepsItsOwn` says
    /// otherwise (`album.write-kept`). The hang when such a side is written again (`album.write-again`) isn't
    /// modeled, since what causes it isn't known. Make a new `FieldDevice` on it afterwards, as a
    /// real reconnect does.
    func leaveAndReenterMTPMode() {
        var handles: [UInt32: UInt32] = [Self.root: Self.root]
        for handle in objects.keys.sorted() {
            handles[handle] = nextHandle
            nextHandle += 1
        }
        var renumbered: [UInt32: Object] = [:]
        for (handle, var object) in objects {
            object.parent = handles[object.parent] ?? object.parent
            object.name = object.name.lowercased()
            object.staleSize = nil
            renumbered[handles[handle]!] = object
        }
        objects = renumbered
        pending = nil
        if let mixdown = objects.first(where: { $0.value.parent == Self.root && $0.value.name == "mixdown" })?.key {
            let keepsItsOwn = faults.contains { if case .albumKeepsItsOwn = $0 { true } else { false } }
            for side in Self.sideNames {
                let handle = objects.first { $0.value.parent == mixdown && $0.value.name == side }?.key
                switch (handle, album[side]) {
                case (nil, let own?):
                    addFile(side, data: own, in: mixdown)
                case (let handle?, let own?) where keepsItsOwn:
                    replace(handle, with: own)
                case (let handle?, _):
                    album[side] = objects[handle]!.data
                case (nil, nil):
                    break
                }
            }
        }
        if let tapes = tapesFolder {
            let folders = objects.filter { $0.value.parent == tapes && $0.value.format == PTPObjectFormat.association }.keys
            let limit = FirmwareProfile.v1_7_3.maximumTapeNameLength
            for folder in folders {
                let name = objects[folder]!.name
                objects[folder]!.name = String(name.prefix(limit))
            }
            for folder in folders.sorted()
            where !objects.values.contains(where: { $0.parent == folder && $0.name == "readme.txt" }) {
                addFile("readme.txt", data: Data(SimulatedNode.tapeReadme.utf8), format: PTPObjectFormat.undefined, in: folder)
            }
        }
    }

    private func add(_ object: Object) -> UInt32 {
        defer { nextHandle += 1 }
        objects[nextHandle] = object
        return nextHandle
    }

    // MARK: MTPTransport

    func transact(command: Data, dataOut: Data?) async throws -> MTPTransaction {
        requestCount += 1
        let request = requestCount
        var reader = PTPReader(command)
        let length = try reader.u32()
        guard try reader.u16() == PTPContainerType.command else {
            return MTPTransaction(data: Data(), response: Self.response(Response.invalidParameter))
        }
        let code = try reader.u16()
        let transactionID = try reader.u32()
        let params = try (0..<max(0, (Int(length) - PTPContainer.headerSize) / 4)).map { _ in try reader.u32() }

        for fault in faults {
            switch fault {
            case .noAnswer(let number) where number == request:
                try await Self.neverAnswer()
            case .silent(let from) where request >= from:
                try await Self.neverAnswer()
            case .refuse(let number, let responseCode) where number == request:
                return MTPTransaction(data: Data(), response: Self.response(responseCode, transactionID: transactionID))
            case .shortData(let number, let keeping) where number == request:
                let (data, responseCode, responseParams) = answer(code, params, dataOut)
                return MTPTransaction(data: Data(data.prefix(keeping)),
                                      response: Self.response(responseCode, transactionID: transactionID, params: responseParams))
            default:
                continue
            }
        }

        let (data, responseCode, responseParams) = answer(code, params, dataOut)
        return MTPTransaction(data: data, response: Self.response(responseCode, transactionID: transactionID, params: responseParams))
    }

    /// Waits far longer than any timeout, so the session gives up first. The session drops the request
    /// without cancelling it, as it does with a real one.
    private static func neverAnswer() async throws {
        try await Task.sleep(for: .seconds(86_400))
    }

    // MARK: Answers

    private enum Response {
        static let ok = PTPResponseCode.ok
        static let operationNotSupported: UInt16 = 0x2005
        static let invalidStorageID: UInt16 = 0x2008
        static let invalidObjectHandle: UInt16 = 0x2009
        static let invalidParentObject: UInt16 = 0x201A
        static let invalidParameter: UInt16 = 0x201D
        static let noValidObjectInfo: UInt16 = 0x2015
    }

    private func answer(_ code: UInt16, _ params: [UInt32], _ dataOut: Data?) -> (Data, UInt16, [UInt32]) {
        let none = Data()
        switch PTPOperation(rawValue: code) {
        case .getDeviceInfo:
            return (deviceInfo(), Response.ok, [])

        case .getStorageIDs:
            var data = Data()
            data.appendLittleEndian(UInt32(1))
            data.appendLittleEndian(Self.storageID)
            return (data, Response.ok, [])

        case .getStorageInfo:
            guard params.first == Self.storageID else { return (none, Response.invalidStorageID, []) }
            return (storageInfo(), Response.ok, [])

        case .getObjectHandles:
            guard params.count == 3 else { return (none, Response.invalidParameter, []) }
            let (storage, format, parent) = (params[0], params[1], params[2])
            guard storage == PTPContainer.allStorages || storage == Self.storageID else {
                return (none, Response.invalidStorageID, [])
            }
            let matches: (Object) -> Bool
            switch parent {
            case PTPContainer.rootParent: matches = { $0.parent == Self.root }
            case 0: matches = { _ in true }
            default:
                guard let folder = objects[parent] else { return (none, Response.invalidObjectHandle, []) }
                guard folder.format == PTPObjectFormat.association else { return (none, Response.invalidParentObject, []) }
                matches = { $0.parent == parent }
            }
            let handles = objects.filter { matches($0.value) && (format == 0 || $0.value.format == format) }.keys.sorted()
            var data = Data()
            data.appendLittleEndian(UInt32(handles.count))
            handles.forEach { data.appendLittleEndian($0) }
            return (data, Response.ok, [])

        case .getObjectInfo:
            guard let handle = params.first, let object = objects[handle] else { return (none, Response.invalidObjectHandle, []) }
            let dataset = PTPObjectInfo.dataset(storageID: Self.storageID, format: object.format, size: UInt32(object.served.count),
                                                parent: object.parent, filename: object.name,
                                                associationType: object.associationType)
            return (dataset, Response.ok, [])

        case .getObject:
            guard let handle = params.first, let object = objects[handle] else { return (none, Response.invalidObjectHandle, []) }
            if let index = faults.firstIndex(where: { if case .changeAfterReading(let name, _, _) = $0 { name == object.name } else { false } }),
               case .changeAfterReading(let name, let data, let reads) = faults.remove(at: index) {
                if reads > 1 {
                    faults.append(.changeAfterReading(name: name, to: data, reads: reads - 1))
                } else {
                    replace(handle, with: data)
                }
            }
            if let index = faults.firstIndex(where: { if case .shortRead(let name) = $0 { name == object.name } else { false } }) {
                faults.remove(at: index)
                return (Data(object.served.dropLast()), Response.ok, [])
            }
            return (object.served, Response.ok, [])

        case .getPartialObject:
            guard params.count == 3 else { return (none, Response.invalidParameter, []) }
            guard let object = objects[params[0]] else { return (none, Response.invalidObjectHandle, []) }
            let served = object.served
            let start = min(Int(params[1]), served.count)
            let end = min(start + Int(params[2]), served.count)
            let slice = Data(served[served.startIndex + start ..< served.startIndex + end])
            return (slice, Response.ok, [UInt32(slice.count)])

        case .deleteObject:
            guard let handle = params.first, let object = objects[handle] else { return (none, Response.invalidObjectHandle, []) }
            for case .refuseDeleting(let name, let responseCode) in faults where name == object.name {
                return (none, responseCode, [])
            }
            // On 1.7.3, DeleteObject on a folder deletes what's in it too (`delete.folder-with-files`, 2026-11-15).
            // FieldTapeKit still empties a folder first.
            var gone = [handle]
            var index = 0
            while index < gone.count {
                gone += objects.filter { $0.value.parent == gone[index] }.keys.sorted()
                index += 1
            }
            for handle in gone.reversed() {
                deleted.append(objects[handle]!.name)
                objects[handle] = nil
            }
            return (none, Response.ok, [])

        case .sendObjectInfo:
            return sendObjectInfo(params, dataOut)

        case .sendObject:
            return sendObject(dataOut)

        case nil:
            return (none, Response.operationNotSupported, [])
        }
    }

    // MARK: Writing, as 1.7.3 does

    /// Folders that hold tapes, by handle: the folder named `tapes` at the root.
    static let sideNames = ["side_a.wav", "side_b.wav"]

    private var tapesFolder: UInt32? {
        objects.first { $0.value.parent == Self.root && $0.value.name.lowercased() == "tapes" }?.key
    }

    /// The names a folder accepts, as its readme says, or nil for any name (`write.refused-name`).
    private func allowedNames(in parent: UInt32) -> Set<String>? {
        guard let folder = objects[parent] else { return [] }
        if folder.parent == tapesFolder { return ["track_1.wav", "track_2.wav", "track_3.wav", "track_4.wav", "tape.json"] }
        if folder.parent == Self.root, folder.name.lowercased() == "mixdown" { return ["side_a.wav", "side_b.wav"] }
        return nil
    }

    private func sendObjectInfo(_ params: [UInt32], _ dataOut: Data?) -> (Data, UInt16, [UInt32]) {
        let none = Data()
        guard params.count == 2, let dataOut, let info = try? PTPObjectInfo(dataOut) else {
            return (none, Response.invalidParameter, [])
        }
        guard params[0] == Self.storageID else { return (none, Response.invalidStorageID, []) }
        let parent = params[1]
        guard let folder = objects[parent], folder.format == PTPObjectFormat.association else {
            return (none, Response.invalidParentObject, [])
        }
        if info.isFolder {
            // A new tape needs one of the 8 slots. How the OP-1 refuses a ninth isn't known; General Error is a guess.
            guard parent == tapesFolder, objects.values.count(where: { $0.parent == parent && $0.format == PTPObjectFormat.association }) < 8
            else { return (none, PTPResponseCode.generalError, []) }
        } else {
            if let allowed = allowedNames(in: parent), !allowed.contains(info.filename.lowercased()) {
                return (none, PTPResponseCode.generalError, [])
            }
            let used = objects.values.reduce(UInt64(0)) { $0 + UInt64($1.data.count) }
            if UInt64(info.compressedSize) > capacity - min(used, capacity) { return (none, PTPResponseCode.storeFull, []) }
        }
        // Within the session the OP-1 keeps the name as sent.
        let handle = add(Object(parent: parent, name: info.filename, format: info.format,
                                associationType: info.isFolder ? PTPAssociationType.genericFolder : 0))
        pending = info.isFolder ? nil : handle
        sentNames.append(info.filename)
        return (none, Response.ok, [Self.storageID, parent, handle])
    }

    private func sendObject(_ dataOut: Data?) -> (Data, UInt16, [UInt32]) {
        guard let handle = pending, var object = objects[handle] else { return (Data(), Response.noValidObjectInfo, []) }
        pending = nil
        for case .refuseSendObject(let responseCode) in faults { return (Data(), responseCode, []) }
        var data = convertPreset(dataOut ?? Data(), named: object.name, in: object.parent)
        for case .corruptStored(let name) in faults where name == object.name && !data.isEmpty {
            data[data.index(before: data.endIndex)] ^= 0xFF
        }
        object.data = data
        objects[handle] = object
        let keepsItsOwn = faults.contains { if case .albumKeepsItsOwn = $0 { true } else { false } }
        if !keepsItsOwn, objects[object.parent]?.name == "mixdown", Self.sideNames.contains(object.name) { album[object.name] = data }
        rebuildTapeJSON(afterWriting: object)
        return (Data(), Response.ok, [])
    }

    /// What `synth/user/` and `drum/user/` store for audio they receive: AIFC with `sowt`, the same samples, cut to
    /// 20 seconds in `drum/user/` and 6 in `synth/user/` (`write.preset-converted`, FieldCheck level 2, 2026-11-15),
    /// with an `op-1` metadata chunk naming the preset after the file. It keeps the format code it was sent with, as
    /// the OP-1 does. Anything that isn't audio is kept as it is, since what the OP-1 does then isn't known.
    private func convertPreset(_ data: Data, named name: String, in parent: UInt32) -> Data {
        guard let folder = objects[parent], folder.name.lowercased() == "user",
              let kind = objects[folder.parent], kind.parent == Self.root,
              ["synth", "drum"].contains(kind.name.lowercased()),
              let audio = try? PCMAudio(data) else { return data }
        let seconds = kind.name.lowercased() == "drum" ? 20 : 6
        let samples = audio.samples.prefix(seconds * audio.format.sampleRate * audio.format.frameBytes)
        let preset = (name as NSString).deletingPathExtension
        let metadata = (try? JSONSerialization.data(withJSONObject: ["\(kind.name.lowercased())_version": 2, "name": preset],
                                                    options: [.sortedKeys])) ?? Data()
        return PCMAudio(container: .aifc, format: audio.format, samples: Data(samples)).aifcBytes(metadata: metadata)
    }

    /// After a track is written, the OP-1 rebuilds its tape's `tape.json`: one clip per track with audio, from frame 0
    /// to the end of the file, `padding` all -1, and the loop off (`rebuild.tape-json`). Within the session it still
    /// lists at its old size (`rebuild.stale-size`).
    private func rebuildTapeJSON(afterWriting track: Object) {
        guard objects[track.parent]?.parent == tapesFolder, track.name.lowercased().hasPrefix("track_"),
              let json = objects.first(where: { $0.value.parent == track.parent && $0.value.name.lowercased() == "tape.json" })
        else { return }
        var root = (try? JSONSerialization.jsonObject(with: json.value.data) as? [String: Any]) ?? [:]
        let tracks = objects.values.filter { $0.parent == track.parent && $0.name.lowercased().hasPrefix("track_") }
        var clips: [[String: Any]] = []
        for number in 1...4 {
            guard let file = tracks.first(where: { $0.name.lowercased() == "track_\(number).wav" }) else { continue }
            let frames = max(0, file.data.count - WAVHeader.size) / 8
            guard frames > 0 else { continue }
            clips.append(["ch": number - 1, "id": clips.count, "padding": [-1, -1, -1, -1], "start": 0, "stop": frames])
        }
        root["clips"] = clips
        root["loop"] = false
        guard let rebuilt = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) else { return }
        rebuild(json.key, with: rebuilt)
    }

    private func deviceInfo() -> Data {
        var data = Data()
        data.appendLittleEndian(UInt16(100))         // StandardVersion
        data.appendLittleEndian(UInt32(6))           // VendorExtensionID: Microsoft, for MTP
        data.appendLittleEndian(UInt16(100))         // VendorExtensionVersion
        data.appendPTPString("microsoft.com: 1.0;")
        data.appendLittleEndian(UInt16(0))           // FunctionalMode
        data.appendU16Array(operations)
        for _ in 0..<4 { data.appendU16Array([]) }   // Events, device properties, capture and image formats
        data.appendPTPString("teenage engineering")
        data.appendPTPString("OP-1")
        data.appendPTPString(firmware)
        data.appendPTPString(serialNumber)
        return data
    }

    private func storageInfo() -> Data {
        let used = objects.values.reduce(UInt64(0)) { $0 + UInt64($1.data.count) }
        var data = Data()
        data.appendLittleEndian(UInt16(0x0003))      // StorageType: fixed RAM
        data.appendLittleEndian(UInt16(0x0002))      // FilesystemType: generic hierarchical
        data.appendLittleEndian(UInt16(0x0000))      // AccessCapability: read-write
        data.appendLittleEndian(capacity)
        data.appendLittleEndian(capacity - min(used, capacity))
        data.appendLittleEndian(UInt32(0xFFFF_FFFF)) // FreeSpaceInObjects: not used
        data.appendPTPString("")
        data.appendPTPString("")
        return data
    }

    private static func response(_ code: UInt16, transactionID: UInt32 = 0, params: [UInt32] = []) -> Data {
        var data = Data()
        data.appendLittleEndian(UInt32(PTPContainer.headerSize + 4 * params.count))
        data.appendLittleEndian(PTPContainerType.response)
        data.appendLittleEndian(code)
        data.appendLittleEndian(transactionID)
        params.forEach { data.appendLittleEndian($0) }
        return data
    }
}

extension Data {
    fileprivate mutating func appendU16Array(_ values: [UInt16]) {
        appendLittleEndian(UInt32(values.count))
        values.forEach { appendLittleEndian($0) }
    }
}
