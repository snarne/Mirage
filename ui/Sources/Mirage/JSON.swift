import Foundation

/// Minimal dynamic JSON value. The control protocol is small and shaped by the engine,
/// so a handful of accessors beats generating Codable types for every message.
enum JSON: Sendable, ExpressibleByDictionaryLiteral {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }

    init(data: Data) throws {
        self = JSON(any: try JSONSerialization.jsonObject(with: data))
    }

    init(any: Any) {
        switch any {
        case is NSNull: self = .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) }
            else if CFNumberIsFloatType(n) { self = .double(n.doubleValue) }
            else { self = .int(n.intValue) }
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map(JSON.init(any:)))
        case let d as [String: Any]: self = .object(d.mapValues(JSON.init(any:)))
        default: self = .null
        }
    }

    var anyValue: Any {
        switch self {
        case .null: NSNull()
        case .bool(let b): b
        case .int(let i): i
        case .double(let d): d
        case .string(let s): s
        case .array(let a): a.map(\.anyValue)
        case .object(let o): o.mapValues(\.anyValue)
        }
    }

    func serialized() throws -> String {
        let data = try JSONSerialization.data(withJSONObject: anyValue)
        return String(decoding: data, as: UTF8.self)
    }

    subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    subscript(key: String) -> JSON {
        get { self[key] ?? .null }
        set { if case .object(var o) = self { o[key] = newValue; self = .object(o) } }
    }

    var objectValue: [String: JSON]? { if case .object(let o) = self { return o }; return nil }
    var arrayValue: [JSON]? { if case .array(let a) = self { return a }; return nil }
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var intValue: Int? {
        switch self { case .int(let i): i; case .double(let d): Int(d); default: nil }
    }
    var doubleValue: Double? {
        switch self { case .double(let d): d; case .int(let i): Double(i); default: nil }
    }
}
