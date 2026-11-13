import Foundation

/// What a check observed, as plain JSON, so a report and a baseline can record any check's findings in the same
/// shape and compare them later (ADR 0003, section 4).
public enum CheckValue: Sendable, Hashable, Codable {
    case bool(Bool)
    case int(Int)
    case string(String)
    case list([CheckValue])
    case record([String: CheckValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Bool first: JSONDecoder won't read `true` as an Int, or 1 as a Bool, so the order only matters for speed.
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([CheckValue].self) {
            self = .list(value)
        } else if let value = try? container.decode([String: CheckValue].self) {
            self = .record(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container,
                                                   debugDescription: "Not a boolean, integer, string, list or record")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .list(let value): try container.encode(value)
        case .record(let value): try container.encode(value)
        }
    }
}

extension CheckValue: ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByStringLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: CheckValue...) { self = .list(elements) }
    public init(dictionaryLiteral elements: (String, CheckValue)...) {
        self = .record(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
