import CoreFoundation
import Foundation

/// A JSON document as a value.
///
/// Everything that leaves the process goes through this type: endpoint
/// results, the snapshot, the manifest. Having one representation is what lets
/// the redactor walk a result without knowing where it came from, and what
/// lets a trace store exactly what `curl` would have printed.
public enum JSONValue: Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Equality

/// Numbers compare by value: JSON has one number type, so `2.0` written out
/// reads back as `.int(2)`, and the two must stay equal across a round trip.
extension JSONValue: Hashable {
    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.array(let a), .array(let b)): return a == b
        case (.object(let a), .object(let b)): return a == b
        case (.int(let a), .int(let b)): return a == b
        case (.int, .double), (.double, .int), (.double, .double):
            return lhs.doubleValue == rhs.doubleValue
        default: return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .null: hasher.combine(0)
        case .bool(let value): hasher.combine(value)
        case .int(let value): hasher.combine(Double(value))
        case .double(let value): hasher.combine(value)
        case .string(let value): hasher.combine(value)
        case .array(let value): hasher.combine(value)
        case .object(let value): hasher.combine(value)
        }
    }
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Bool before Int: JSONDecoder refuses to read `1` as a Bool and
        // `true` as an Int, so this order is unambiguous.
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value):
            // A non-finite number is not JSON. RAVEDebugServer learned this
            // from a compositor's `inf` far plane taking a headset down on a
            // /state poll (2026-08-27); the spelling is kept from there.
            if value.isFinite {
                try container.encode(value)
            } else {
                try container.encode(Self.nonFiniteSpelling(value))
            }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    static func nonFiniteSpelling(_ value: Double) -> String {
        value.isNaN ? "nan" : (value > 0 ? "inf" : "-inf")
    }
}

// MARK: - Serialization

extension JSONValue {
    /// Keys sorted, so two captures of the same state diff cleanly.
    public func serialized(pretty: Bool = false) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty
            ? [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
            : [.sortedKeys, .withoutEscapingSlashes]
        // Cannot fail: every case encodes, non-finite doubles included.
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }

    public func serializedString(pretty: Bool = false) -> String {
        String(decoding: serialized(pretty: pretty), as: UTF8.self)
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

// MARK: - Conversion in

extension JSONValue {
    /// Encodes any `Encodable` through `JSONEncoder`, keeping its property
    /// names as written. No key strategy is applied: `convertToSnakeCase`
    /// would also rewrite the keys of every dictionary a provider returns
    /// (category names, file paths), which is data, not naming.
    public init<T: Encodable>(encoding value: T) throws {
        if let json = value as? JSONValue {
            self = json
            return
        }
        let data = try Self.valueEncoder().encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    static func valueEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(DebugTime.iso(date))
        }
        encoder.dataEncodingStrategy = .base64
        return encoder
    }

    /// Converts the loosely typed values the pre-registry debug servers
    /// returned (`[String: Any]` built by hand). Anything unrecognised is
    /// described rather than dropped, so a SIMD vector reads as its
    /// description instead of vanishing from the output.
    public init(any value: Any?) {
        guard let value else {
            self = .null
            return
        }
        // An Optional boxed in Any is not caught by the `guard` above.
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            if let child = mirror.children.first {
                self = JSONValue(any: child.value)
            } else {
                self = .null
            }
            return
        }
        // A real Objective-C NSNumber (from JSONSerialization, UserDefaults,
        // KVC) has to be told apart from a Swift Int/Bool first: `as? Bool`
        // succeeds on NSNumber(1), and `as? NSNumber` succeeds on a Swift
        // Int through bridging.
        if type(of: value) is NSNumber.Type, let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .double(number.doubleValue)
            } else {
                self = .int(number.intValue)
            }
            return
        }
        switch value {
        case let json as JSONValue: self = json
        case is NSNull: self = .null
        case let v as Bool: self = .bool(v)
        case let v as Int: self = .int(v)
        case let v as Int8: self = .int(Int(v))
        case let v as Int16: self = .int(Int(v))
        case let v as Int32: self = .int(Int(v))
        case let v as Int64: self = .int(Int(v))
        case let v as UInt: self = .int(Int(clamping: v))
        case let v as UInt8: self = .int(Int(v))
        case let v as UInt16: self = .int(Int(v))
        case let v as UInt32: self = .int(Int(v))
        case let v as UInt64: self = .int(Int(clamping: v))
        case let v as Double: self = .double(v)
        case let v as Float: self = .double(Double(v))
        case let v as CGFloat: self = .double(Double(v))
        case let v as String: self = .string(v)
        case let v as Substring: self = .string(String(v))
        case let v as Date: self = .string(DebugTime.iso(v))
        case let v as URL: self = .string(v.absoluteString)
        case let v as UUID: self = .string(v.uuidString)
        case let v as Data: self = .string(v.base64EncodedString())
        case let v as [String: Any]:
            self = .object(v.mapValues { JSONValue(any: $0) })
        case let v as [AnyHashable: Any]:
            var object: [String: JSONValue] = [:]
            for (key, element) in v { object[String(describing: key.base)] = JSONValue(any: element) }
            self = .object(object)
        case let v as [Any]:
            self = .array(v.map { JSONValue(any: $0) })
        case let v as any Encodable:
            self = (try? JSONValue(encoding: v)) ?? .string(String(describing: v))
        default:
            self = .string(String(describing: value))
        }
    }
}

// MARK: - Reading

extension JSONValue {
    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public subscript(index: Int) -> JSONValue? {
        if case .array(let array) = self, array.indices.contains(index) { return array[index] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value) where value.rounded() == value && abs(value) < 9e15: return Int(value)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// The name of this value's JSON type, for error messages.
    var typeName: String {
        switch self {
        case .null: "null"
        case .bool: "boolean"
        case .int: "integer"
        case .double: "number"
        case .string: "string"
        case .array: "array"
        case .object: "object"
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByNilLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(nilLiteral: ()) { self = .null }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

/// Timestamps everywhere in this package: ISO 8601, UTC, milliseconds. One
/// spelling, so a model correlating a log line with a breadcrumb and a
/// snapshot never has to reconcile formats or time zones.
public enum DebugTime {
    public static func iso(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}
