import Foundation

/// One declared argument of an endpoint.
///
/// Declaring parameters, rather than letting handlers read a raw query
/// dictionary, is what gives a model a JSON Schema for every endpoint and lets
/// the registry reject a hallucinated argument name before the handler runs.
/// The old servers read `?x=` and silently ignored `?pos_x=`, so a model got a
/// plausible-looking result for a call that never did what it asked.
public struct DebugParameter: Sendable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case string, integer, number, boolean
    }

    public let name: String
    public let kind: Kind
    public let description: String
    public let required: Bool
    public let defaultValue: JSONValue?
    public let choices: [String]?
    public let minimum: Double?
    public let maximum: Double?

    public init(
        name: String,
        kind: Kind,
        description: String,
        required: Bool = false,
        defaultValue: JSONValue? = nil,
        choices: [String]? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil
    ) {
        self.name = name
        self.kind = kind
        self.description = description
        self.required = required
        self.defaultValue = defaultValue
        self.choices = choices
        self.minimum = minimum
        self.maximum = maximum
    }

    public static func string(
        _ name: String, _ description: String,
        required: Bool = false, default value: String? = nil, choices: [String]? = nil
    ) -> DebugParameter {
        DebugParameter(name: name, kind: .string, description: description, required: required,
                       defaultValue: value.map(JSONValue.string), choices: choices)
    }

    public static func integer(
        _ name: String, _ description: String,
        required: Bool = false, default value: Int? = nil, range: ClosedRange<Int>? = nil
    ) -> DebugParameter {
        DebugParameter(name: name, kind: .integer, description: description, required: required,
                       defaultValue: value.map(JSONValue.int),
                       minimum: range.map { Double($0.lowerBound) }, maximum: range.map { Double($0.upperBound) })
    }

    public static func number(
        _ name: String, _ description: String,
        required: Bool = false, default value: Double? = nil, range: ClosedRange<Double>? = nil
    ) -> DebugParameter {
        DebugParameter(name: name, kind: .number, description: description, required: required,
                       defaultValue: value.map(JSONValue.double),
                       minimum: range?.lowerBound, maximum: range?.upperBound)
    }

    public static func boolean(
        _ name: String, _ description: String,
        required: Bool = false, default value: Bool? = nil
    ) -> DebugParameter {
        DebugParameter(name: name, kind: .boolean, description: description, required: required,
                       defaultValue: value.map(JSONValue.bool))
    }

    // MARK: Schema

    /// JSON Schema for this parameter, as MCP's `inputSchema` wants it.
    public var jsonSchema: JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string(kind.rawValue),
            "description": .string(description),
        ]
        if let defaultValue { schema["default"] = defaultValue }
        if let choices { schema["enum"] = .array(choices.map(JSONValue.string)) }
        if let minimum { schema["minimum"] = kind == .integer ? .int(Int(minimum)) : .double(minimum) }
        if let maximum { schema["maximum"] = kind == .integer ? .int(Int(maximum)) : .double(maximum) }
        return .object(schema)
    }

    /// A value that passes validation, for generated examples.
    public var exampleValue: JSONValue {
        if let choices, let first = choices.first { return .string(first) }
        if let defaultValue { return defaultValue }
        switch kind {
        case .string: return .string(name)
        case .integer: return .int(Int(minimum ?? 0))
        case .number: return .double(minimum ?? 0)
        case .boolean: return .bool(true)
        }
    }

    /// `x (number, required, 0…1)`, for hints.
    var signature: String {
        var parts = [kind.rawValue]
        if required { parts.append("required") }
        if let choices { parts.append(choices.joined(separator: "|")) }
        if let minimum, let maximum { parts.append("\(Self.format(minimum))…\(Self.format(maximum))") }
        if let defaultValue { parts.append("default \(defaultValue.serializedString())") }
        return "\(name) (\(parts.joined(separator: ", ")))"
    }

    private static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }

    // MARK: Coercion

    /// Validates `raw` against this parameter, converting the strings a query
    /// string delivers into the declared type.
    func coerce(_ raw: JSONValue, endpoint: String) throws(DebugError) -> JSONValue {
        let value: JSONValue
        switch kind {
        case .string:
            switch raw {
            case .string: value = raw
            case .int, .double, .bool: value = .string(raw.serializedString())
            default: throw mismatch(raw, endpoint: endpoint)
            }
        case .integer:
            if let integer = raw.intValue {
                value = .int(integer)
            } else if case .string(let text) = raw, let integer = Int(text.trimmingCharacters(in: .whitespaces)) {
                value = .int(integer)
            } else {
                throw mismatch(raw, endpoint: endpoint)
            }
        case .number:
            if let number = raw.doubleValue {
                value = .double(number)
            } else if case .string(let text) = raw, let number = Double(text.trimmingCharacters(in: .whitespaces)) {
                value = .double(number)
            } else {
                throw mismatch(raw, endpoint: endpoint)
            }
        case .boolean:
            switch raw {
            case .bool: value = raw
            case .int(0): value = .bool(false)
            case .int(1): value = .bool(true)
            case .string(let text):
                switch text.lowercased() {
                // A bare `?flag` arrives as the empty string and means true.
                case "", "1", "true", "yes", "on": value = .bool(true)
                case "0", "false", "no", "off": value = .bool(false)
                default: throw mismatch(raw, endpoint: endpoint)
                }
            default: throw mismatch(raw, endpoint: endpoint)
            }
        }

        if let choices, case .string(let text) = value, !choices.contains(text) {
            throw .invalidArgument(
                "argument '\(name)' of '\(endpoint)' must be one of \(choices.joined(separator: ", ")); got '\(text)'",
                hint: DebugSuggest.closest(to: text, in: choices).map { "did you mean '\($0)'?" })
        }
        if let number = value.doubleValue {
            if let minimum, number < minimum {
                throw .invalidArgument("argument '\(name)' of '\(endpoint)' must be ≥ \(Self.format(minimum)); got \(number)")
            }
            if let maximum, number > maximum {
                throw .invalidArgument("argument '\(name)' of '\(endpoint)' must be ≤ \(Self.format(maximum)); got \(number)")
            }
        }
        return value
    }

    private func mismatch(_ raw: JSONValue, endpoint: String) -> DebugError {
        .invalidArgument(
            "argument '\(name)' of '\(endpoint)' must be \(kind == .integer ? "an" : "a") \(kind.rawValue); got \(raw.typeName) \(raw.serializedString())",
            hint: "expected \(signature)")
    }
}

/// Validated arguments, with defaults applied. Every declared parameter that
/// is required or has a default is present; nothing undeclared is.
public struct DebugArguments: Sendable {
    public let values: [String: JSONValue]
    public let endpoint: String

    public init(_ values: [String: JSONValue], endpoint: String = "") {
        self.values = values
        self.endpoint = endpoint
    }

    public subscript(name: String) -> JSONValue? { values[name] }
    public func has(_ name: String) -> Bool { values[name] != nil }

    public func string(_ name: String) -> String? { values[name]?.stringValue }
    public func int(_ name: String) -> Int? { values[name]?.intValue }
    public func double(_ name: String) -> Double? { values[name]?.doubleValue }
    public func bool(_ name: String) -> Bool? { values[name]?.boolValue }

    public func requireString(_ name: String) throws(DebugError) -> String {
        guard let value = string(name) else { throw missing(name) }
        return value
    }

    public func requireInt(_ name: String) throws(DebugError) -> Int {
        guard let value = int(name) else { throw missing(name) }
        return value
    }

    public func requireDouble(_ name: String) throws(DebugError) -> Double {
        guard let value = double(name) else { throw missing(name) }
        return value
    }

    public func requireBool(_ name: String) throws(DebugError) -> Bool {
        guard let value = bool(name) else { throw missing(name) }
        return value
    }

    private func missing(_ name: String) -> DebugError {
        .invalidArgument("missing argument '\(name)' for '\(endpoint)'",
                         hint: "see _help?endpoint=\(endpoint)")
    }
}

/// Nearest-name suggestions for the "did you mean" hints.
public enum DebugSuggest {
    public static func closest(to input: String, in candidates: [String], limit: Int = 1) -> String? {
        ranked(input, in: candidates, limit: limit).first
    }

    public static func ranked(_ input: String, in candidates: [String], limit: Int = 3) -> [String] {
        let needle = input.lowercased()
        let scored = candidates.compactMap { candidate -> (String, Int)? in
            let lowered = candidate.lowercased()
            if lowered == needle { return (candidate, 0) }
            // Contained either way reads as a strong match: `teleport` for
            // `teleportAim`, `log` for `_logs`.
            if lowered.contains(needle) || needle.contains(lowered) { return (candidate, 1) }
            let distance = levenshtein(needle, lowered)
            let tolerance = max(2, min(needle.count, lowered.count) / 3)
            return distance <= tolerance ? (candidate, distance + 1) : nil
        }
        return scored.sorted { $0.1 < $1.1 || ($0.1 == $1.1 && $0.0 < $1.0) }.prefix(limit).map(\.0)
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1,
                                 previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
