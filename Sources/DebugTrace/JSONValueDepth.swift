import Foundation

// Deeply nested JSON, without depending on the caller's stack.
//
// Encoding, decoding, comparing and releasing a `JSONValue` all recurse once
// per level, through a dozen frames of Foundation's coders each. A secondary
// thread or a Swift task has a 512 KB stack, which a few hundred levels
// exhaust: MetricKit's call-stack trees nest one level per stack frame, and a
// 300-frame crash report encoded on a task took Hypnos down mid-film, then on
// every relaunch while it retried the same report (visionOS, 2026-10-11).
// Foundation's coders also refuse anything past 512 levels, so deeper values
// were silently dropped or written as `null`.
//
// So: `DebugDeepStack` runs work on a thread with room for tens of thousands
// of levels, `serialized`/`parse`/`redact` move there by themselves for a deep
// value, and `JSONValue.writeIteratively` / `parseIteratively` have no depth
// limit at all. Crash reports are flattened at intake (DebugCrashReports), so
// what is stored and uploaded is shallow.

/// Runs work on a thread with a large stack.
enum DebugDeepStack {
    /// Virtual size; only the pages a deep value actually touches are used.
    static let stackSize = 64 << 20
    /// Values deeper than this move to the deep stack. A 512 KB stack held
    /// about 150 levels of Foundation's encoder; this leaves room for callers'
    /// own frames.
    static let depthThreshold = 64

    private static let key = "DebugTrace.deepStack"

    static var isOnDeepStack: Bool { Thread.current.threadDictionary[key] != nil }

    /// `body` on the deep stack (inline when already there), waiting for it.
    static func run<T>(_ body: () throws -> T) rethrows -> T {
        if isOnDeepStack { return try body() }
        return try withoutActuallyEscaping(body) { body in
            let box = UnsafeBox(body)
            let done = DispatchSemaphore(value: 0)
            let thread = Thread {
                Thread.current.threadDictionary[key] = true
                box.result = Result { try box.body!() }
                // Released before the caller resumes: `body` is borrowed
                // (withoutActuallyEscaping), and the thread outlives the
                // signal by a little.
                box.body = nil
                done.signal()
            }
            thread.stackSize = stackSize
            thread.qualityOfService = Thread.current.qualityOfService
            thread.start()
            done.wait()
            return try box.result!.get()
        }
    }

    private final class UnsafeBox<T>: @unchecked Sendable {
        var body: (() throws -> T)?
        var result: Result<T, any Error>?
        init(_ body: @escaping () throws -> T) { self.body = body }
    }
}

extension JSONValue {
    /// Nesting depth (a scalar is 0), measured without recursion.
    public var depth: Int {
        var deepest = 0
        var pending: [(JSONValue, Int)] = [(self, 0)]
        while let (value, level) = pending.popLast() {
            deepest = max(deepest, level)
            switch value {
            case .array(let items): for item in items { pending.append((item, level + 1)) }
            case .object(let members): for item in members.values { pending.append((item, level + 1)) }
            default: break
            }
        }
        return deepest
    }

    var isDeep: Bool { depth > DebugDeepStack.depthThreshold }

    /// Largest bracket nesting in JSON text, without parsing it.
    static func nesting(of data: Data) -> Int {
        var level = 0, deepest = 0
        var inString = false, escaped = false
        for byte in data {
            if inString {
                if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { inString = false }
                continue
            }
            switch byte {
            case 0x22: inString = true
            case 0x5B, 0x7B: level += 1; deepest = max(deepest, level)
            case 0x5D, 0x7D: level -= 1
            default: break
            }
        }
        return deepest
    }

    /// Releases a value without recursing: a deep tree's release otherwise
    /// recurses once per level on whatever stack drops the last reference.
    /// Leaves `.null` behind, so the loop holds the only reference.
    static func dismantle(_ value: inout JSONValue) {
        var pending: [JSONValue] = [value]
        value = .null
        while let next = pending.popLast() {
            switch next {
            case .array(let items): pending.append(contentsOf: items)
            case .object(let members): pending.append(contentsOf: members.values)
            default: break
            }
        }
    }
}

// MARK: - Writing without recursion

extension JSONValue {
    /// The same JSON `serialized` writes (keys sorted, slashes unescaped,
    /// non-finite numbers spelled out), for values past Foundation's 512-level
    /// limit. Pretty output indents by two spaces like `JSONEncoder`.
    static func writeIteratively(_ root: JSONValue, pretty: Bool) -> Data {
        enum Step {
            case value(JSONValue, indent: Int)
            case text(String)
        }
        var out = ""
        var steps: [Step] = [.value(root, indent: 0)]
        func newline(_ indent: Int) -> String { pretty ? "\n" + String(repeating: "  ", count: indent) : "" }
        while let step = steps.popLast() {
            switch step {
            case .text(let text):
                out += text
            case .value(let value, let indent):
                switch value {
                case .null: out += "null"
                case .bool(let flag): out += flag ? "true" : "false"
                case .int(let number): out += String(number)
                case .double(let number):
                    out += number.isFinite ? Self.numberText(number) : Self.quoted(Self.nonFiniteSpelling(number))
                case .string(let text): out += Self.quoted(text)
                case .array(let items):
                    guard !items.isEmpty else { out += "[]"; continue }
                    out += "["
                    // Pushed in reverse: the stack pops the first element first.
                    steps.append(.text(newline(indent) + "]"))
                    for (offset, item) in items.enumerated().reversed() {
                        steps.append(.value(item, indent: indent + 1))
                        steps.append(.text((offset == 0 ? "" : ",") + newline(indent + 1)))
                    }
                case .object(let members):
                    guard !members.isEmpty else { out += "{}"; continue }
                    out += "{"
                    steps.append(.text(newline(indent) + "}"))
                    for (offset, key) in members.keys.sorted().enumerated().reversed() {
                        steps.append(.value(members[key]!, indent: indent + 1))
                        steps.append(.text((offset == 0 ? "" : ",") + newline(indent + 1)
                                           + Self.quoted(key) + (pretty ? " : " : ":")))
                    }
                }
            }
        }
        return Data(out.utf8)
    }

    private static func numberText(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return "\(value)"
    }

    private static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

// MARK: - Parsing without recursion

extension JSONValue {
    struct ParseError: Error, CustomStringConvertible {
        let offset: Int
        let reason: String
        var description: String { "JSON: \(reason) at byte \(offset)" }
    }

    /// A JSON parser with no depth limit and no recursion, for text past
    /// Foundation's 512 levels. Numbers parse as `JSONDecoder` reads them:
    /// integers that fit as `.int`, everything else as `.double`.
    static func parseIteratively(_ data: Data) throws -> JSONValue {
        let bytes = [UInt8](data)
        var index = 0
        enum Container {
            case array([JSONValue])
            case object([String: JSONValue], key: String?)
        }
        var stack: [Container] = []
        var result: JSONValue?

        func fail(_ reason: String) -> ParseError { ParseError(offset: index, reason: reason) }
        func skipSpace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }
        func parseString() throws -> String {
            index += 1 // opening quote
            var scalars = String.UnicodeScalarView()
            var run: [UInt8] = []
            func flush() {
                if !run.isEmpty { scalars.append(contentsOf: String(decoding: run, as: UTF8.self).unicodeScalars); run.removeAll() }
            }
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 0x22 { index += 1; flush(); return String(scalars) }
                if byte != 0x5C { run.append(byte); index += 1; continue }
                flush()
                index += 1
                guard index < bytes.count else { throw fail("unterminated escape") }
                let code = bytes[index]
                index += 1
                switch code {
                case 0x22: scalars.append("\"")
                case 0x5C: scalars.append("\\")
                case 0x2F: scalars.append("/")
                case 0x62: scalars.append("\u{08}")
                case 0x66: scalars.append("\u{0C}")
                case 0x6E: scalars.append("\n")
                case 0x72: scalars.append("\r")
                case 0x74: scalars.append("\t")
                case 0x75:
                    func hex4() throws -> UInt32 {
                        guard index + 4 <= bytes.count,
                              let value = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16)
                        else { throw fail("bad \\u escape") }
                        index += 4
                        return value
                    }
                    var value = try hex4()
                    if (0xD800..<0xDC00).contains(value), index + 1 < bytes.count, bytes[index] == 0x5C, bytes[index + 1] == 0x75 {
                        index += 2
                        let low = try hex4()
                        value = 0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00)
                    }
                    scalars.append(Unicode.Scalar(value) ?? "\u{FFFD}")
                default: throw fail("bad escape")
                }
            }
            throw fail("unterminated string")
        }
        func parseScalar() throws -> JSONValue {
            let start = index
            while index < bytes.count, !",]} \t\n\r".utf8.contains(bytes[index]) { index += 1 }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            switch text {
            case "null": return .null
            case "true": return .bool(true)
            case "false": return .bool(false)
            default:
                if let number = Int(text) { return .int(number) }
                if let number = Double(text), text.first.map({ $0 == "-" || $0.isNumber }) == true { return .double(number) }
                throw fail("unexpected token")
            }
        }
        /// Adds a finished value to the open container, or makes it the result.
        func deliver(_ value: JSONValue) throws {
            guard let top = stack.popLast() else {
                guard result == nil else { throw fail("trailing value") }
                result = value
                return
            }
            switch top {
            case .array(var items):
                items.append(value)
                stack.append(.array(items))
            case .object(var members, let key):
                guard let key else { throw fail("value without a key") }
                members[key] = value
                stack.append(.object(members, key: nil))
            }
        }

        while true {
            skipSpace()
            guard index < bytes.count else { break }
            let byte = bytes[index]
            switch byte {
            case 0x5B: index += 1; stack.append(.array([]))
            case 0x7B: index += 1; stack.append(.object([:], key: nil))
            case 0x5D:
                index += 1
                guard case .array(let items)? = stack.popLast() else { throw fail("unbalanced ]") }
                try deliver(.array(items))
            case 0x7D:
                index += 1
                guard case .object(let members, nil)? = stack.popLast() else { throw fail("unbalanced }") }
                try deliver(.object(members))
            case 0x2C:
                index += 1
            case 0x22:
                let text = try parseString()
                if case .object(let members, nil)? = stack.last {
                    skipSpace()
                    guard index < bytes.count, bytes[index] == 0x3A else { throw fail("expected :") }
                    index += 1
                    stack[stack.count - 1] = .object(members, key: text)
                } else {
                    try deliver(.string(text))
                }
            default:
                try deliver(try parseScalar())
            }
        }
        guard stack.isEmpty, let result else { throw fail("unexpected end") }
        return result
    }
}

// MARK: - Encoding into a JSONValue directly

/// An `Encoder` that builds a `JSONValue` with no JSON text in between, so
/// it has no depth limit, and lets the caller replace any nested value
/// (`intercept`). DebugCrashReports uses it to flatten MetricKit's frame
/// trees as they are encoded. Spells dates, data, URLs and non-finite
/// numbers as `JSONValue(encoding:)` does.
final class JSONValueEncoder {
    /// Return a replacement for a value about to be encoded, or nil.
    var intercept: ((Any) -> JSONValue?)?

    func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        let node = Node()
        try encode(value, into: node, path: [])
        return node.finish()
    }

    fileprivate func encode<T: Encodable>(_ value: T, into node: Node, path: [any CodingKey]) throws {
        if let replacement = intercept?(value) { node.value = replacement; return }
        switch value {
        case let json as JSONValue: node.value = json
        case let date as Date: node.value = .string(DebugTime.iso(date))
        case let data as Data: node.value = .string(data.base64EncodedString())
        case let url as URL: node.value = .string(url.absoluteString)
        case let number as Double: node.value = Self.number(number)
        case let number as Float: node.value = Self.number(Double("\(number)") ?? Double(number))
        case let number as UInt64 where number > UInt64(Int.max): node.value = .double(Double(number))
        case let number as UInt where number > UInt(Int.max): node.value = .double(Double(number))
        default: try value.encode(to: Impl(owner: self, node: node, codingPath: path))
        }
    }

    fileprivate static func number(_ value: Double) -> JSONValue {
        value.isFinite ? .double(value) : .string(JSONValue.nonFiniteSpelling(value))
    }

    /// A value under construction; containers fill it in place.
    fileprivate final class Node {
        var value: JSONValue = .null
        var members: [String: Node]?
        var items: [Node]?

        func finish() -> JSONValue {
            // Iterative: a node tree as deep as the value it builds.
            var order: [Node] = []
            var pending = [self]
            while let next = pending.popLast() {
                order.append(next)
                if let members = next.members { pending.append(contentsOf: members.values) }
                if let items = next.items { pending.append(contentsOf: items) }
            }
            for node in order.reversed() {
                if let members = node.members {
                    node.value = .object(members.mapValues(\.value))
                } else if let items = node.items {
                    node.value = .array(items.map(\.value))
                }
                node.members = nil
                node.items = nil
            }
            return value
        }
    }

    fileprivate struct Impl: Encoder {
        let owner: JSONValueEncoder
        let node: Node
        let codingPath: [any CodingKey]
        var userInfo: [CodingUserInfoKey: Any] { [:] }

        func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
            if node.members == nil { node.members = [:]; node.items = nil }
            return KeyedEncodingContainer(Keyed<Key>(owner: owner, node: node, codingPath: codingPath))
        }

        func unkeyedContainer() -> any UnkeyedEncodingContainer {
            if node.items == nil { node.items = []; node.members = nil }
            return Unkeyed(owner: owner, node: node, codingPath: codingPath)
        }

        func singleValueContainer() -> any SingleValueEncodingContainer {
            Single(owner: owner, node: node, codingPath: codingPath)
        }
    }

    fileprivate struct Keyed<Key: CodingKey>: KeyedEncodingContainerProtocol {
        let owner: JSONValueEncoder
        let node: Node
        let codingPath: [any CodingKey]

        private func child(_ key: Key) -> Node {
            let child = Node()
            node.members?[key.stringValue] = child
            return child
        }

        mutating func encodeNil(forKey key: Key) throws { child(key).value = .null }
        mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
            let target = child(key)
            try owner.encode(value, into: target, path: codingPath + [key])
            _ = target.finish()
        }
        mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
            let target = child(key)
            target.members = [:]
            return KeyedEncodingContainer(Keyed<NestedKey>(owner: owner, node: target, codingPath: codingPath + [key]))
        }
        mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
            let target = child(key)
            target.items = []
            return Unkeyed(owner: owner, node: target, codingPath: codingPath + [key])
        }
        mutating func superEncoder() -> any Encoder {
            Impl(owner: owner, node: child(Key(stringValue: "super")!), codingPath: codingPath)
        }
        mutating func superEncoder(forKey key: Key) -> any Encoder {
            Impl(owner: owner, node: child(key), codingPath: codingPath + [key])
        }
    }

    fileprivate struct IndexKey: CodingKey {
        var stringValue: String { "\(intValue!)" }
        var intValue: Int?
        init(_ index: Int) { intValue = index }
        init?(stringValue: String) { return nil }
        init?(intValue: Int) { self.intValue = intValue }
    }

    fileprivate struct Unkeyed: UnkeyedEncodingContainer {
        let owner: JSONValueEncoder
        let node: Node
        let codingPath: [any CodingKey]
        var count: Int { node.items?.count ?? 0 }

        private func next() -> Node {
            let child = Node()
            node.items?.append(child)
            return child
        }

        mutating func encodeNil() throws { next().value = .null }
        mutating func encode<T: Encodable>(_ value: T) throws {
            let path = codingPath + [IndexKey(count)]
            let target = next()
            try owner.encode(value, into: target, path: path)
            _ = target.finish()
        }
        mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
            let path = codingPath + [IndexKey(count)]
            let target = next()
            target.members = [:]
            return KeyedEncodingContainer(Keyed<NestedKey>(owner: owner, node: target, codingPath: path))
        }
        mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
            let path = codingPath + [IndexKey(count)]
            let target = next()
            target.items = []
            return Unkeyed(owner: owner, node: target, codingPath: path)
        }
        mutating func superEncoder() -> any Encoder {
            let path = codingPath + [IndexKey(count)]
            return Impl(owner: owner, node: next(), codingPath: path)
        }
    }

    fileprivate struct Single: SingleValueEncodingContainer {
        let owner: JSONValueEncoder
        let node: Node
        let codingPath: [any CodingKey]

        mutating func encodeNil() throws { node.value = .null }
        mutating func encode(_ value: Bool) throws { node.value = .bool(value) }
        mutating func encode(_ value: String) throws { node.value = .string(value) }
        mutating func encode(_ value: Double) throws { node.value = JSONValueEncoder.number(value) }
        mutating func encode(_ value: Float) throws { node.value = JSONValueEncoder.number(Double("\(value)") ?? Double(value)) }
        mutating func encode(_ value: Int) throws { node.value = .int(value) }
        mutating func encode(_ value: Int8) throws { node.value = .int(Int(value)) }
        mutating func encode(_ value: Int16) throws { node.value = .int(Int(value)) }
        mutating func encode(_ value: Int32) throws { node.value = .int(Int(value)) }
        mutating func encode(_ value: Int64) throws { node.value = .int(Int(value)) }
        mutating func encode(_ value: UInt) throws { node.value = value > UInt(Int.max) ? .double(Double(value)) : .int(Int(value)) }
        mutating func encode(_ value: UInt8) throws { node.value = .int(Int(value)) }
        mutating func encode(_ value: UInt16) throws { node.value = .int(Int(value)) }
        mutating func encode(_ value: UInt32) throws { node.value = .int(Int(value)) }
        mutating func encode(_ value: UInt64) throws { node.value = value > UInt64(Int.max) ? .double(Double(value)) : .int(Int(value)) }
        mutating func encode<T: Encodable>(_ value: T) throws {
            try owner.encode(value, into: node, path: codingPath)
            _ = node.finish()
        }
    }
}
