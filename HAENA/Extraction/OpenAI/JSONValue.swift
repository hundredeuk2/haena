import Foundation

/// A minimal encodable JSON tree.
///
/// Exists so the extraction JSON Schema can be *built* in Swift — with a shared sub-schema helper
/// instead of four copy-pasted evidence blocks — while still encoding as ordinary JSON inside the
/// request body. `[String: Any]` would have worked but is neither `Encodable` nor `Sendable`.
indirect enum JSONValue: Encodable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case integer(Int)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        case .array(let values):
            try container.encode(values)
        case .object(let values):
            try container.encode(values)
        }
    }
}
