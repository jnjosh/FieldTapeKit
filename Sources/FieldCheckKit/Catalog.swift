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

    private var cache: [UInt32: Data] = [:]

    /// A file's contents, read once. Only for small files, such as `readme.txt` and `tape.json`.
    func contents(of entry: CatalogEntry) async throws -> Data {
        if let data = cache[entry.handle] { return data }
        let data = try await session.object(entry.handle)
        cache[entry.handle] = data
        return data
    }

    /// Up to `length` bytes from `offset`, with GetPartialObject.
    func read(_ entry: CatalogEntry, offset: Int, length: Int) async throws -> Data {
        try await session.partialObject(entry.handle, offset: UInt32(offset), maxLength: UInt32(length))
    }
}

extension [CatalogEntry] {
    /// What's directly inside the folder at `path`, matched ignoring case.
    func children(of path: String) -> [CatalogEntry] {
        let prefix = path.lowercased() + "/"
        return filter { entry in
            let lower = entry.path.lowercased()
            return lower.hasPrefix(prefix) && !lower.dropFirst(prefix.count).contains("/")
        }
    }

    /// Every tape: each folder directly inside `tapes/`, with what's in it.
    func tapes() -> [(folder: CatalogEntry, contents: [CatalogEntry])] {
        children(of: "tapes").filter(\.isFolder).sorted { $0.path < $1.path }.map { ($0, children(of: $0.path)) }
    }
}
