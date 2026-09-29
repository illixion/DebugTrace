import Foundation

/// A failure an endpoint reports to its caller.
///
/// The caller is usually a language model driving `curl` or MCP, so every
/// error says what to do next: `hint` names the fix ("did you mean `x`?",
/// "POST it instead", "call `_help?endpoint=...`"). An error without a hint
/// is one the model will retry verbatim.
public struct DebugError: Error, Sendable, Equatable, Codable {
    public enum Code: String, Sendable, Codable {
        case invalidArgument = "invalid_argument"
        case notFound = "not_found"
        case methodNotAllowed = "method_not_allowed"
        case unauthenticated
        case forbidden
        case failedPrecondition = "failed_precondition"
        case unavailable
        case timeout
        case tooLarge = "too_large"
        case `internal`
    }

    public var code: Code
    public var message: String
    public var hint: String?
    public var details: JSONValue?

    public init(_ code: Code, _ message: String, hint: String? = nil, details: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.hint = hint
        self.details = details
    }

    public static func invalidArgument(_ message: String, hint: String? = nil) -> DebugError {
        DebugError(.invalidArgument, message, hint: hint)
    }

    /// The app is not in a state where this endpoint can run (no world
    /// loaded, renderer not attached). Say which state is missing.
    public static func failedPrecondition(_ message: String, hint: String? = nil) -> DebugError {
        DebugError(.failedPrecondition, message, hint: hint)
    }

    public static func unavailable(_ message: String, hint: String? = nil) -> DebugError {
        DebugError(.unavailable, message, hint: hint)
    }

    public var httpStatus: Int {
        switch code {
        case .invalidArgument: 400
        case .unauthenticated: 401
        case .forbidden: 403
        case .notFound: 404
        case .methodNotAllowed: 405
        case .failedPrecondition: 409
        case .tooLarge: 413
        case .internal: 500
        case .unavailable: 503
        case .timeout: 504
        }
    }

    public var json: JSONValue {
        var object: [String: JSONValue] = ["code": .string(code.rawValue), "message": .string(message)]
        if let hint { object["hint"] = .string(hint) }
        if let details { object["details"] = details }
        return .object(object)
    }

    /// Wraps whatever a handler threw.
    static func wrapping(_ error: any Error) -> DebugError {
        if let debugError = error as? DebugError { return debugError }
        return DebugError(.internal, String(describing: error))
    }
}
