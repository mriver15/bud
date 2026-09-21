import Foundation

/// Dynamic JSON tree shared by every subsystem: the DeepSeek wire format, MCP
/// JSON-RPC payloads, the marketplace registry, and generative-UI specs.
///
/// Ordering of object keys is preserved on decode so that round-tripping an
/// arbitrary server payload does not reshuffle it.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue {
    /// Characters of string content in this value, as opposed to the keys, types
    /// and punctuation holding it together.
    ///
    /// Asked of a tool schema, this answers whether the schema is carrying
    /// documentation — which can be moved somewhere it is loaded on demand — or
    /// shape, which cannot.
    public var stringContentLength: Int {
        switch self {
        case .string(let value): return value.count
        case .array(let items): return items.reduce(0) { $0 + $1.stringContentLength }
        case .object(let pairs): return pairs.values.reduce(0) { $0 + $1.stringContentLength }
        case .null, .bool, .number: return 0
        }
    }
}

// MARK: - Accessors

extension JSONValue {
    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var doubleValue: Double? {
        switch self {
        case .number(let d): return d
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    /// Lenient: models and MCP servers both emit numbers where a string is
    /// expected (and vice versa), so coerce rather than fail the whole call.
    public var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .number(let d): return d == d.rounded() && abs(d) < 1e15
            ? String(Int64(d)) : String(d)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    public subscript(index: Int) -> JSONValue? {
        guard let a = arrayValue, a.indices.contains(index) else { return nil }
        return a[index]
    }
}

// MARK: - Encoding helpers

extension JSONValue {
    /// Parses a JSON document. Returns `nil` for empty input so callers can
    /// treat "model sent no arguments" the same as `{}`.
    public init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        self = value
    }

    /// Parses `text`, falling back to an empty object. Tool arguments arrive as
    /// a raw string from the model and are frequently blank.
    public static func objectOrEmpty(parsing text: String) -> JSONValue {
        if let v = JSONValue(parsing: text), v.objectValue != nil { return v }
        return .object([:])
    }

    public func encodedString(pretty: Bool = false) -> String {
        let encoder = JSONEncoder()
        if pretty {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        } else {
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        }
        guard let data = try? encoder.encode(self), let s = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return s
    }
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let d = try? c.decode(Double.self) {
            self = .number(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let d):
            // Emit integral doubles as integers; the DeepSeek and MCP schemas
            // both reject `1.0` where an integer is declared.
            if d == d.rounded(), abs(d) < 1e15 {
                try c.encode(Int64(d))
            } else {
                try c.encode(d)
            }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { self = .number(Double(value)) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

// MARK: - Conversion

extension JSONValue {
    /// Converts an arbitrary `Any` produced by `JSONSerialization`, which the
    /// MCP and registry clients use where a schema is not statically known.
    public init(any value: Any) {
        switch value {
        case let v as JSONValue: self = v
        case is NSNull: self = .null
        // NSNumber must come first: both `Bool` and `Int` bridge to NSNumber, and
        // `NSNumber(value: 1) as? Bool` succeeds via `boolValue` — which would
        // turn a JSON-RPC request id of `1` into `true` and every numeric field
        // into a boolean. The CF type id is what tells a boolean apart from a
        // number; everything else is a number.
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                self = .number(n.doubleValue)
            }
        case let b as Bool: self = .bool(b)
        case let i as Int: self = .number(Double(i))
        case let i as Int64: self = .number(Double(i))
        case let d as Double: self = .number(d)
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map(JSONValue.init(any:)))
        case let o as [String: Any]: self = .object(o.mapValues(JSONValue.init(any:)))
        default: self = .null
        }
    }

    /// Bridges back to a Foundation object for `JSONSerialization` call sites
    /// that cannot use `Codable`.
    public var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let d): return d == d.rounded() && abs(d) < 1e15 ? Int64(d) : d
        case .string(let s): return s
        case .array(let a): return a.map(\.anyValue)
        case .object(let o): return o.mapValues(\.anyValue)
        }
    }
}
