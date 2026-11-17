import Foundation
import System

/// A file or folder on the OP-1 that a person can confirm deleting.
///
/// Get one from ``FieldDevice/prepareToRemove(at:)``, show it to the person, then pass it to
/// ``FieldDevice/removeItem(_:)``. It works once, only on the connection that made it, and only while the item and
/// everything in it are as they were when it was made (ADR 0002, section 6).
public struct FileDeletion: Sendable, Hashable, Identifiable {
    /// Identifies this confirmation, which works once.
    public let id: UUID
    /// As read fresh when this was made.
    public let item: FieldItem
    /// For a folder, everything in it at every depth, as listed when this was made. Empty for a file.
    public let contents: [FieldItem]
    let deviceID: FieldDevice.ID

    /// The bytes that would be lost.
    public var size: Int { item.size + contents.reduce(0) { $0 + $1.size } }
    /// An empty folder, so nothing would be lost and the prompt can be skipped.
    public var losesNothing: Bool { item.isDirectory && contents.isEmpty }
}

extension FieldDevice {
    /// Copies a file off the OP-1, verifies the copy, and only then deletes the file from the OP-1.
    ///
    /// The copy is made as ``copyItem(at:to:progress:)`` makes one: never over a local file, and read
    /// back and matched by SHA-256. Then the file is read from the OP-1 again and matched to the copy, so a read that
    /// went wrong can't leave a bad copy (ADR 0002, safety rules 1 and 2). If anything fails before the delete,
    /// nothing on the OP-1 changes, and the copy is kept. A folder needs ``prepareToRemove(at:)`` and a person's
    /// confirmation.
    ///
    /// - Parameters:
    ///   - path: The file on the OP-1, relative to the device root, matched ignoring case.
    ///   - backup: The local file to copy it to. Its folder must exist.
    /// - Returns: The copy's URL, which is `backup` unless that was taken.
    /// - Throws: `FieldError` with `.notAllowed` for something that belongs to the OP-1, `.isADirectory`,
    ///   `.verificationFailed` if the file changed after it was copied, the codes of `copyItem`, or
    ///   `CancellationError`.
    @discardableResult
    public func removeItem(at path: FilePath, keepingCopyAt backup: URL) async throws -> URL {
        do {
            try refuseIfOwnedByTheOP1(path)
            guard let before = try await locate(path), let info = before.info else { throw FieldError(.notFound, path: path) }
            guard !info.isFolder else { throw FieldError(.isADirectory, path: before.path) }
            let copy = try await verifiedCopy(of: before.path, to: backup)
            // The copy is of the file as it was. If the OP-1 lists it differently now, the copy doesn't cover it.
            guard let after = try await locate(before.path), after.handle == before.handle,
                  after.info?.compressedSize == info.compressedSize else {
                throw FieldError(.verificationFailed, path: before.path)
            }
            try await matchAgain(after.handle, at: before.path, to: copy.sha256)
            try Task.checkCancellation()
            try await session.deleteObject(after.handle)
            return copy.url
        } catch {
            throw FieldError.wrapping(error, path: path)
        }
    }

    /// Reads an item, and everything in it if it's a folder, so a person can confirm losing exactly that.
    ///
    /// - Parameter path: The file or folder on the OP-1, relative to the device root, matched ignoring case.
    /// - Returns: The confirmation to show the person, then to pass to ``removeItem(_:)``.
    /// - Throws: `FieldError` with `.notFound`, `.notAllowed` for something that belongs to the OP-1, or the codes
    ///   of `item(at:)`, or `CancellationError`.
    public func prepareToRemove(at path: FilePath) async throws -> FileDeletion {
        do {
            try refuseIfOwnedByTheOP1(path)
            guard let found = try await locate(path), let info = found.info else { throw FieldError(.notFound, path: path) }
            let contents = try await everything(in: found).map(\.item)
            return FileDeletion(id: UUID(), item: FieldItem(path: found.path, info: info), contents: contents, deviceID: id)
        } catch {
            throw FieldError.wrapping(error, path: path)
        }
    }

    /// Deletes what a person confirmed: a file, or a folder's contents, deepest first, and then the folder.
    ///
    /// It checks first that the confirmation is unused, from this connection, and still matches the OP-1 exactly.
    /// It's used up as soon as the first delete is sent. If a delete fails partway, the error's
    /// ``FieldError/changed`` lists what was already deleted, and nothing more is tried (ADR 0002, safety rule 6).
    ///
    /// - Parameter deletion: From ``prepareToRemove(at:)``, shown to the person who confirmed it.
    /// - Throws: `FieldError` with `.changedSinceConfirmation`, `.confirmationAlreadyUsed`, `.disconnected`,
    ///   `.timedOut` or `.deviceRefused`, or `CancellationError`.
    public func removeItem(_ deletion: FileDeletion) async throws {
        let path = deletion.item.path
        guard !usedConfirmations.contains(deletion.id) else { throw FieldError(.confirmationAlreadyUsed, path: path) }
        guard deletion.deviceID == id else { throw FieldError(.changedSinceConfirmation, path: path) }
        let targets: [(handle: UInt32, item: FieldItem)]
        do {
            guard let found = try await locate(path), let info = found.info,
                  FieldItem(path: found.path, info: info) == deletion.item else {
                throw FieldError(.changedSinceConfirmation, path: path)
            }
            let contents = try await everything(in: found)
            guard contents.map(\.item) == deletion.contents else { throw FieldError(.changedSinceConfirmation, path: path) }
            targets = Self.deletionOrder((found.handle, deletion.item), contents: contents)
            try Task.checkCancellation()
        } catch {
            throw FieldError.wrapping(error, path: path)
        }

        usedConfirmations.insert(deletion.id)
        try await deleteInOrder(targets)
    }

    // MARK: Helpers

    /// Sends a DeleteObject for each target in order, and stops at the first that fails. Its error's `changed` lists
    /// what was already deleted, and nothing more is tried (ADR 0002, safety rule 6).
    func deleteInOrder(_ targets: [(handle: UInt32, item: FieldItem)]) async throws {
        var deleted: [FilePath] = []
        for target in targets {
            do {
                try await session.deleteObject(target.handle)
            } catch {
                guard let error = FieldError.wrapping(error, path: target.item.path) as? FieldError else { throw error }
                throw error.adding(changed: deleted)
            }
            deleted.append(target.item.path)
        }
    }

    /// A folder's contents, deepest first, then the folder, so every folder is empty when its turn comes
    /// (`delete.files-then-folder`).
    static func deletionOrder(_ folder: (handle: UInt32, item: FieldItem),
                              contents: [(handle: UInt32, item: FieldItem)]) -> [(handle: UInt32, item: FieldItem)] {
        contents.sorted { $0.item.path.components.count > $1.item.path.components.count } + [folder]
    }

    /// Everything inside `folder` at every depth, in listing order, with fresh info. Empty for a file.
    func everything(in folder: Located) async throws -> [(handle: UInt32, item: FieldItem)] {
        guard folder.isDirectory else { return [] }
        var found: [(handle: UInt32, item: FieldItem)] = []
        for child in try await children(of: folder) {
            let located = Located(handle: child.handle, path: folder.path.appending(child.info.filename), info: child.info)
            found.append((child.handle, FieldItem(path: located.path, info: child.info)))
            found += try await everything(in: located)
        }
        return found
    }

    /// The root, the folders every OP-1 has, and the files the OP-1 puts in them belong to it, so they're refused
    /// before anything happens (ADR 0002, safety rule 4). A tape folder, with its readme.txt, can still be deleted.
    private func refuseIfOwnedByTheOP1(_ path: FilePath) throws {
        let names = try Self.components(of: path).map { $0.lowercased() }
        let owned = names.isEmpty
            || profile.folders.contains(names.joined(separator: "/"))
            || profile.ownFiles.contains(names.last!)
        if owned { throw FieldError(.notAllowed, path: path) }
    }
}
