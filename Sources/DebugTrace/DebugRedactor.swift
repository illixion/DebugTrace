import Foundation

/// Scrubs secrets out of everything that leaves the process: trace files,
/// HTTP replies, MCP results.
///
/// The HTTP replies are included on purpose. Their reader is a model whose
/// transcript is itself a leak path — a token that reaches a tool result is
/// in the conversation for good. So the server redacts by default too, and an
/// app that needs a raw value exposes it deliberately under its own name.
///
/// This is a backstop for the common shapes (bearer tokens, URL credentials,
/// `password=`), not a guarantee. Endpoints should not return secrets in the
/// first place.
public struct DebugRedactor: Sendable {
    public struct Rule: @unchecked Sendable {
        // NSRegularExpression is immutable and documented thread-safe; it is
        // simply not annotated Sendable.
        public let name: String
        let regex: NSRegularExpression
        let template: String

        public init(name: String, pattern: String, template: String) throws {
            self.name = name
            self.regex = try NSRegularExpression(pattern: pattern)
            self.template = template
        }

        func apply(_ text: String) -> String {
            let range = NSRange(text.startIndex..., in: text)
            return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
        }
    }

    public static let marker = "<redacted>"

    public var rules: [Rule]
    /// Object keys whose value is replaced outright, whatever it looks like.
    public var sensitiveKey: NSRegularExpression?

    public init(rules: [Rule], sensitiveKeyPattern: String?) {
        self.rules = rules
        self.sensitiveKey = sensitiveKeyPattern.flatMap { try? NSRegularExpression(pattern: $0) }
    }

    public static let none = DebugRedactor(rules: [], sensitiveKeyPattern: nil)

    public static let standard: DebugRedactor = {
        // Force-tried: these are literals, covered by DebugRedactorTests.
        let rules = [
            try! Rule(name: "private-key-block",
                      pattern: #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#,
                      template: "<redacted private key>"),
            try! Rule(name: "authorization-scheme",
                      pattern: #"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}"#,
                      template: "$1 \(marker)"),
            try! Rule(name: "url-userinfo",
                      pattern: #"(?i)\b([a-z][a-z0-9+.-]*://)[^/\s:@]+:[^/\s@]+@"#,
                      template: "$1\(marker)@"),
            try! Rule(name: "query-secret",
                      pattern: #"(?i)([?&;](?:access_token|refresh_token|id_token|token|api_?key|key|secret|client_secret|password|passwd|pwd|auth|signature|sig|code|session_?id|sid)=)[^&#\s"']+"#,
                      template: "$1\(marker)"),
            try! Rule(name: "jwt",
                      pattern: #"\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}"#,
                      template: "<redacted jwt>"),
            try! Rule(name: "assignment",
                      pattern: #"(?i)\b(password|passwd|secret|client_secret|token|api[_-]?key|access[_-]?token|refresh[_-]?token|auth[_-]?token)(["']?\s*[=:]\s*["']?)[^\s"',;&]+"#,
                      template: "$1$2\(marker)"),
        ]
        return DebugRedactor(
            rules: rules,
            sensitiveKeyPattern: #"(?i)^(password|passwd|secret|token|authorization|cookie|set-cookie|private_?key|signing_?key)$|(?i)(access_?token|refresh_?token|id_?token|auth_?token|api_?key|client_?secret|password|passphrase)$"#)
    }()

    /// A copy with one more rule, for an app-specific shape (a Home
    /// Assistant long-lived token, a Signal identifier).
    public func adding(name: String, pattern: String, template: String = DebugRedactor.marker) throws -> DebugRedactor {
        var copy = self
        copy.rules.append(try Rule(name: name, pattern: pattern, template: template))
        return copy
    }

    public func redact(_ text: String) -> String {
        rules.reduce(text) { $1.apply($0) }
    }

    public func redact(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let text): return .string(redact(text))
        case .array(let array): return .array(array.map(redact))
        case .object(let object):
            var out: [String: JSONValue] = [:]
            for (key, element) in object {
                if isSensitive(key: key), !Self.isEmptyish(element) {
                    out[key] = .string(Self.marker)
                } else {
                    out[key] = redact(element)
                }
            }
            return .object(out)
        default: return value
        }
    }

    func isSensitive(key: String) -> Bool {
        guard let sensitiveKey else { return false }
        return sensitiveKey.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil
    }

    /// `hasToken: false` or `token: null` is useful state, not a secret.
    private static func isEmptyish(_ value: JSONValue) -> Bool {
        switch value {
        case .null, .bool: true
        case .string(let text): text.isEmpty
        default: false
        }
    }
}
