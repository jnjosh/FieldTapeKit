import System

extension FieldDevice {
    /// What's directly inside the folder at `path`, in the order the OP-1 lists it. An empty path is the root.
    ///
    /// Names are matched ignoring case, because the OP-1 stores them lowercase (`names.lowercase`), and every
    /// item comes back as the OP-1 spells it. Sizes are fresh: each call asks the OP-1 again.
    ///
    /// - Throws: `FieldError` with `.notFound`, `.notADirectory`, `.ambiguousPath`, `.disconnected`, `.timedOut`
    ///   or `.deviceRefused`, or `CancellationError`.
    public func contentsOfDirectory(at path: FilePath) async throws -> [FieldItem] {
        do {
            guard let folder = try await locate(path) else { throw FieldError(.notFound, path: path) }
            guard folder.isDirectory else { throw FieldError(.notADirectory, path: path) }
            return try await children(of: folder).map { FieldItem(path: folder.path.appending($0.info.filename), info: $0.info) }
        } catch {
            throw FieldError.wrapping(error, path: path)
        }
    }

    /// The item at `path`, or nil if there's nothing there. An empty path is the root, which has no item.
    ///
    /// - Throws: `FieldError` with `.notADirectory` if a folder on the way is a file, `.ambiguousPath`,
    ///   `.disconnected`, `.timedOut` or `.deviceRefused`, or `CancellationError`.
    public func item(at path: FilePath) async throws -> FieldItem? {
        do {
            guard let found = try await locate(path), let info = found.info else { return nil }
            return FieldItem(path: found.path, info: info)
        } catch {
            throw FieldError.wrapping(error, path: path)
        }
    }

    /// Whether anything is at `path`.
    ///
    /// - Throws: As `item(at:)`.
    public func fileExists(at path: FilePath) async throws -> Bool {
        try await item(at: path) != nil
    }

    // MARK: Finding paths

    /// An object found by path. Handles are private: they change after a reconnect.
    struct Located {
        /// `PTPContainer.rootParent` for the root.
        let handle: UInt32
        /// As the OP-1 spells it.
        let path: FilePath
        /// Nil for the root.
        let info: PTPObjectInfo?

        var isDirectory: Bool { info?.isFolder ?? true }
    }

    /// Walks `path` from the root, one folder listing at a time, with fresh object info for each. Nil if any
    /// part of it is missing.
    func locate(_ path: FilePath) async throws -> Located? {
        var current = Located(handle: PTPContainer.rootParent, path: FilePath(), info: nil)
        for component in try Self.components(of: path) {
            guard current.isDirectory else { throw FieldError(.notADirectory, path: current.path) }
            let children = try await children(of: current)
            guard let child = try Self.match(component, in: children, path: current.path.appending(component)) else {
                return nil
            }
            current = Located(handle: child.handle, path: current.path.appending(child.info.filename), info: child.info)
        }
        return current
    }

    private func children(of folder: Located) async throws -> [(handle: UInt32, info: PTPObjectInfo)] {
        var children: [(handle: UInt32, info: PTPObjectInfo)] = []
        for handle in try await session.objectHandles(parent: folder.handle) {
            children.append((handle, try await session.objectInfo(handle)))
        }
        return children
    }

    /// The path's names, relative to the device root. A leading `/` is allowed and ignored, and `..` isn't.
    static func components(of path: FilePath) throws -> [String] {
        let relative = path.lexicallyNormalized().removingRoot()
        let names = relative.components.map(\.string)
        guard !names.contains("..") else { throw FieldError(.notFound, path: path) }
        return names
    }

    /// An exact match wins. Otherwise a single match ignoring case is used, and several are refused, so nothing
    /// acts on an item the caller didn't mean.
    static func match(_ name: String, in children: [(handle: UInt32, info: PTPObjectInfo)],
                      path: FilePath) throws -> (handle: UInt32, info: PTPObjectInfo)? {
        if let exact = children.first(where: { $0.info.filename == name }) { return exact }
        let lowered = name.lowercased()
        let matches = children.filter { $0.info.filename.lowercased() == lowered }
        guard matches.count <= 1 else { throw FieldError(.ambiguousPath, path: path) }
        return matches.first
    }
}
