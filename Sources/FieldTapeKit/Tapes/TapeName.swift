import System

/// A tape's name, which is its folder in `tapes/` (ADR 0002, section 4).
///
/// The OP-1 stores names lowercase (`names.lowercase`), so a name is kept lowercase, and two names that differ only
/// in case are the same name. A name for a new tape must be one the OP-1 keeps: letters, digits, `#`, `-` and
/// space, and at most 12 characters, since the OP-1 cuts a longer one to 12 once it leaves MTP mode
/// (`names.maximum`). A name already on the OP-1, or in an archive, is accepted as it is, at any length.
public struct TapeName: Sendable, Hashable, Comparable, CustomStringConvertible {
    /// The longest name FieldTapeKit gives a new tape, from the newest tested firmware's profile. A device checks
    /// its own firmware's limit again before writing.
    public static let maximumLength = FirmwareProfile.v1_7_3.maximumTapeNameLength

    /// The name as the OP-1 stores it, lowercase.
    public let string: String

    /// Creates a name for a new tape.
    ///
    /// - Parameter string: The name. It's kept lowercase.
    /// - Throws: `FieldError` with `.invalidName`, saying which characters aren't allowed, or that it's empty or too
    ///   long.
    public init(_ string: String) throws(FieldError) {
        let lowered = string.lowercased()
        if let problem = Self.problem(with: lowered, maximumLength: Self.maximumLength) {
            throw FieldError(.invalidName, path: FilePath.op1Tapes.appending(lowered), reason: problem)
        }
        self.string = lowered
    }

    /// A name as it's listed on the OP-1, or in an archive, whatever it holds.
    init(listed string: String) {
        self.string = string.lowercased()
    }

    /// The name as the OP-1 stores it.
    public var description: String { string }

    /// Orders names as their strings sort.
    public static func < (lhs: TapeName, rhs: TapeName) -> Bool {
        lhs.string < rhs.string
    }

    /// Characters a new tape's name may use, lowercase.
    static let characters = Set("abcdefghijklmnopqrstuvwxyz0123456789#- ")

    /// Why a lowercase name can't be a new tape's, or nil if it can.
    static func problem(with name: String, maximumLength: Int) -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "it's empty" }
        let unexpected = name.filter { !characters.contains($0) }
        if !unexpected.isEmpty {
            return "it uses " + Array(Set(unexpected)).sorted().map { "“\($0)”" }.joined(separator: ", ")
        }
        if name.count > maximumLength { return "it's longer than \(maximumLength) characters" }
        return nil
    }
}

