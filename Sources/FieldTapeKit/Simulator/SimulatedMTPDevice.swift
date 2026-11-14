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

    /// Replaces a file's contents with ones of another size, as if it were rewritten before this session.
    func replace(_ handle: UInt32, with data: Data) {
        objects[handle]?.data = data
        objects[handle]?.staleSize = nil
    }

    func add(faults more: [Fault]) {
        faults += more
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
                let (data, responseCode, responseParams) = answer(code, params)
                return MTPTransaction(data: Data(data.prefix(keeping)),
                                      response: Self.response(responseCode, transactionID: transactionID, params: responseParams))
            default:
                continue
            }
        }

        let (data, responseCode, responseParams) = answer(code, params)
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
    }

    private func answer(_ code: UInt16, _ params: [UInt32]) -> (Data, UInt16, [UInt32]) {
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
            // Whether the OP-1 deletes a folder with files in it is unknown (`delete.folder-with-files`), so the
            // simulator refuses, and FieldTapeKit always empties a folder first.
            if object.format == PTPObjectFormat.association, objects.values.contains(where: { $0.parent == handle }) {
                return (none, PTPResponseCode.generalError, [])
            }
            objects[handle] = nil
            deleted.append(object.name)
            return (none, Response.ok, [])

        case .sendObjectInfo, .sendObject, nil:
            return (none, Response.operationNotSupported, [])
        }
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
