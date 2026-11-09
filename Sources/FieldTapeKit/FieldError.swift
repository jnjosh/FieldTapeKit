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

    init(_ code: Code, path: FilePath? = nil, responseCode: UInt16? = nil, changed: [FilePath] = [],
         underlying: (any Error)? = nil) {
        self.code = code
        self.path = path
        self.responseCode = responseCode
        self.changed = changed
        self.underlying = underlying
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
    }

    public var errorDescription: String? {
        switch code {
        case .disconnected: "The OP-1 is no longer connected."
        case .timedOut: "The OP-1 didn't answer in time."
        case .notAuthorized: "This app isn't allowed to use connected devices."
        case .deviceInUse: "Another app is using the OP-1."
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
        case .deviceInUse:
            "Quit the other app, such as Teenage Engineering's app or Image Capture on a Mac, then connect the OP-1 again."
        default:
            nil
        }
    }
}

extension FieldError {
    /// Turns an error from the MTP layer into a `FieldError`. `FieldError` and `CancellationError` pass through.
    static func wrapping(_ error: any Error, path: FilePath? = nil) -> any Error {
        switch error {
        case let error as FieldError:
            error
        case is CancellationError:
            error
        case let error as MTPError:
            switch error {
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
