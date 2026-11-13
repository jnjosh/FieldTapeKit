import FieldTapeKit
import Foundation

/// One file or folder on the OP-1, as GetObjectInfo described it during the walk.
struct CatalogEntry: Sendable, Hashable {
    let handle: UInt32
    /// Relative to the root, as the OP-1 spells it, with no leading or trailing slash.
    let path: String
    let name: String
    let isFolder: Bool
    let format: UInt16
    let size: Int
}

/// Everything on the OP-1, walked folder by folder once and shared by the checks that need it. The probe
/// walked the same way, because a recursive GetObjectHandles is optional for MTP devices.
actor Catalog {
    private let session: MTPSession
    private var walked: [CatalogEntry]?

    init(_ session: MTPSession) {
        self.session = session
    }

    func entries() async throws -> [CatalogEntry] {
        if let walked { return walked }
        var entries: [CatalogEntry] = []
        var folders: [(handle: UInt32, path: String)] = [(PTPContainer.rootParent, "")]
        while !folders.isEmpty {
            let folder = folders.removeFirst()
            for handle in try await session.objectHandles(parent: folder.handle) {
                let info = try await session.objectInfo(handle)
                let path = folder.path.isEmpty ? info.filename : "\(folder.path)/\(info.filename)"
                entries.append(CatalogEntry(handle: handle, path: path, name: info.filename, isFolder: info.isFolder,
                                            format: info.format, size: Int(info.compressedSize)))
                if info.isFolder { folders.append((handle, path)) }
            }
        }
        walked = entries
        return entries
    }

    /// A file's contents. Only for small files, such as `readme.txt`.
    func contents(of entry: CatalogEntry) async throws -> Data {
        try await session.object(entry.handle)
    }
}
