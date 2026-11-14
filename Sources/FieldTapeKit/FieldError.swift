import Foundation
import System

/// The one error type FieldTapeKit throws, besides `CancellationError` (ADR 0002, section 7).
///
/// Each method's documentation lists the codes it can throw. `changed` is empty whenever the OP-1 wasn't touched,
/// so "nothing happened" can be told apart from "half-done".
public struct FieldError: Error, Sendable, LocalizedError {
    public let code: Code
    /// The device path the error is about, if any.
    public let path: FilePath?
    /// The PTP response code, when the OP-1 refused a request.
    public let responseCode: UInt16?
    /// What was already written or deleted on the OP-1 before the error, if anything.
    public let changed: [FilePath]
    /// `Error` refines `Sendable` in Swift 6, so this keeps `FieldError` `Sendable`.
    public let underlying: (any Error)?
    /// Why, for codes whose description needs it, such as the folder rule behind `notAllowed`.
    let reason: String?

    init(_ code: Code, path: FilePath? = nil, responseCode: UInt16? = nil, changed: [FilePath] = [],
         underlying: (any Error)? = nil, reason: String? = nil) {
        self.code = code
        self.path = path
        self.responseCode = responseCode
        self.changed = changed
        self.underlying = underlying
        self.reason = reason
    }

    /// Extensible, so a later version can add codes without breaking an app's `switch` (ADR 0002, section 11).
    public struct Code: Sendable, Hashable, CustomStringConvertible {
        public let description: String

        private init(_ description: String) {
            self.description = description
        }

        /// The OP-1 was unplugged, left MTP mode, or stopped answering.
        public static let disconnected = Code("disconnected")
        /// The OP-1 didn't answer in time, but answered a ping afterwards, so it's still connected.
        public static let timedOut = Code("timedOut")
        /// The app isn't allowed to use ImageCaptureCore's devices.
        public static let notAuthorized = Code("notAuthorized")
        /// Another app holds the OP-1.
        public static let deviceInUse = Code("deviceInUse")
        /// The OP-1 refused a request, or sent a reply that couldn't be read. `responseCode` says which, if known.
        public static let deviceRefused = Code("deviceRefused")
        /// Nothing is at `path`.
        public static let notFound = Code("notFound")
        /// `path`, or a folder on the way to it, is a file.
        public static let notADirectory = Code("notADirectory")
        /// `path` matches more than one item when case is ignored, and none exactly. The OP-1 lowercases a new
        /// name only after it leaves MTP mode, so a folder can briefly hold two names that differ only in case.
        public static let ambiguousPath = Code("ambiguousPath")
        /// `path` is a folder, where a file was needed.
        public static let isADirectory = Code("isADirectory")
        /// The file at `path` is bigger than a read into memory allows.
        public static let tooLarge = Code("tooLarge")
        /// A copy didn't match what came from the OP-1 when it was read back, so it isn't a verified copy. Nothing
        /// unverified is left behind.
        public static let verificationFailed = Code("verificationFailed")
        /// A file on this device, not the OP-1, couldn't be written or read: a full disk, a missing folder, or no
        /// permission. `underlying` is the system's error, and `path` is the OP-1 file being copied.
        public static let localFileFailed = Code("localFileFailed")
        /// FieldTapeKit doesn't do that at `path`, such as deleting a folder or file that belongs to the OP-1.
        public static let notAllowed = Code("notAllowed")
        /// A confirmation no longer matches what's on the OP-1, or was made on another connection. Nothing changed.
        public static let changedSinceConfirmation = Code("changedSinceConfirmation")
        /// A confirmation was already used. Each works once. Nothing changed.
        public static let confirmationAlreadyUsed = Code("confirmationAlreadyUsed")
        /// Something is already at `path`.
        public static let alreadyExists = Code("alreadyExists")
        /// A new tape's name isn't allowed: a character the OP-1 doesn't use, or longer than 15 characters.
        public static let invalidName = Code("invalidName")
        /// All 8 tapes are in use.
        public static let tapeLimitReached = Code("tapeLimitReached")
        /// A track is longer than the 6 minutes a tape holds.
        public static let tapeTooLong = Code("tapeTooLong")
        /// The OP-1 is full (Store Full, 0x200C).
        public static let insufficientSpace = Code("insufficientSpace")
    }

    /// The same error, also saying what had already been changed on the OP-1.
    func adding(changed more: [FilePath]) -> FieldError {
        FieldError(code, path: path, responseCode: responseCode, changed: changed + more, underlying: underlying,
                   reason: reason)
    }

    public var errorDescription: String? {
        switch code {
        case .disconnected: "The OP-1 is no longer connected."
        case .timedOut: "The OP-1 didn't answer in time."
        case .notAuthorized: "This app isn't allowed to use connected devices."
        case .deviceInUse: "Another app is using the OP-1."
        case .notFound:
            "There's nothing on the OP-1 at \(pathDescription)."
        case .notADirectory:
            "On the OP-1, \(pathDescription) is a file, not a folder."
        case .ambiguousPath:
            "More than one item on the OP-1 matches \(pathDescription) when case is ignored."
        case .notAllowed:
            "FieldTapeKit doesn't change \(pathDescription), because \(reason ?? "it belongs to the OP-1")."
        case .alreadyExists:
            "Something is already at \(pathDescription) on the OP-1."
        case .invalidName:
            "\(pathDescriptionCapitalized) isn't a name the OP-1 can use: \(reason ?? "it isn't allowed")."
        case .tapeLimitReached:
            "The OP-1 already has 8 tapes."
        case .tapeTooLong:
            "\(pathDescriptionCapitalized) is longer than the 6 minutes a tape holds."
        case .insufficientSpace:
            "The OP-1 is full."
        case .changedSinceConfirmation:
            "\(pathDescriptionCapitalized) changed on the OP-1 since it was confirmed, so nothing was deleted."
        case .confirmationAlreadyUsed:
            "That confirmation for \(pathDescription) was already used, so nothing was deleted."
        case .isADirectory:
            "On the OP-1, \(pathDescription) is a folder, not a file."
        case .tooLarge:
            "On the OP-1, \(pathDescription) is too large to read into memory."
        case .verificationFailed:
            "The copy of \(pathDescription) didn't match the OP-1's when it was read back."
        case .localFileFailed:
            if let underlying = underlying as? LocalizedError, let reason = underlying.errorDescription {
                "Couldn't save the copy of \(pathDescription) on this device. \(reason)"
            } else {
                "Couldn't save the copy of \(pathDescription) on this device."
            }
        case .deviceRefused:
            if let responseCode {
                "The OP-1 refused the request (response \(String(format: "0x%04X", responseCode)))."
            } else {
                "The OP-1 sent a reply that couldn't be read."
            }
        default: "Something went wrong with the OP-1 (\(code))."
        }
    }

    public var recoverySuggestion: String? {
        switch code {
        case .disconnected:
            "Put the OP-1 in MTP mode and connect it again. If it says MTP is connected but nothing appears, restart the OP-1."
        case .timedOut:
            "It's still connected, so try again."
        case .notAuthorized:
            "Allow this app to use connected devices, then connect the OP-1 again."
        case .ambiguousPath:
            "Use the path exactly as a listing spells it."
        case .changedSinceConfirmation, .confirmationAlreadyUsed:
            "Ask again, with what's on the OP-1 now."
        case .tapeLimitReached:
            "Move a tape off the OP-1 first."
        case .insufficientSpace:
            "Make space on the OP-1, such as by moving a tape off it."
        case .invalidName:
            "Use only letters, numbers, #, - and spaces, and at most 15 characters."
        case .tooLarge:
            "Copy it to a file with copyItem(at:to:), or read it with a larger maximum size."
        case .verificationFailed:
            "Copy it again. If it fails again, disconnect the OP-1 and connect it again first."
        case .localFileFailed:
            "Check there's space, and that the folder you're copying to exists."
        case .deviceInUse:
            "Quit the other app, such as Teenage Engineering's app or Image Capture on a Mac, then connect the OP-1 again."
        default:
            nil
        }
    }
}

extension FieldError {
    private var pathDescription: String {
        guard let path, !path.isEmpty else { return "that path" }
        return path.string
    }

    /// A path stays as the OP-1 spells it, so only the fallback is capitalized.
    private var pathDescriptionCapitalized: String {
        guard let path, !path.isEmpty else { return "That path" }
        return path.string
    }
}

extension FieldError {
    /// Turns an error from the MTP layer into a `FieldError`. `FieldError` and `CancellationError` pass through.
    package static func wrapping(_ error: any Error, path: FilePath? = nil) -> any Error {
        switch error {
        case let error as FieldError:
            error
        case is CancellationError:
            error
        case let error as MTPError:
            switch error {
            case .refused(_, let responseCode) where responseCode == PTPResponseCode.storeFull:
                FieldError(.insufficientSpace, path: path, responseCode: responseCode, underlying: error)
            case .refused(_, let responseCode):
                FieldError(.deviceRefused, path: path, responseCode: responseCode, underlying: error)
            case .unreadableResponse:
                FieldError(.deviceRefused, path: path, underlying: error)
            case .timedOut:
                FieldError(.timedOut, path: path, underlying: error)
            case .disconnected:
                FieldError(.disconnected, path: path, underlying: error)
            }
        default:
            // A dataset that couldn't be parsed, or an error from ImageCaptureCore.
            FieldError(.deviceRefused, path: path, underlying: error)
        }
    }
}
