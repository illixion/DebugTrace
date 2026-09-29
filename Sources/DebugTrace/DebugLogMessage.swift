import CryptoKit
import Foundation

/// How an interpolated value may be shown. Spelled like `OSLogPrivacy`, so a
/// call site written for `os.Logger` compiles unchanged against `DebugLogger`.
///
/// The rules, strictest last:
/// - `.public`: shown everywhere, including exports. Only for values that
///   are safe in a transcript a cloud model reads: counts, states, ids you
///   generated, error codes.
/// - `.private`: shown only on this device's own screen, and only in the
///   development privacy mode. Exports (traces, the debug server, the
///   clipboard) replace it with `<private>`. In release mode it is dropped
///   when logged and never stored.
/// - `.sensitive`: never shown or stored, in any mode.
/// - `.auto` (the default): numbers and booleans are public, everything else
///   is private — the same default os_log applies.
///
/// `mask: .hash` replaces a hidden value with a short salted hash instead
/// of `<private>`, so the same value can be recognised across lines of one
/// session without being revealed. The salt changes at every launch, so two
/// traces cannot be joined on it.
public struct DebugLogPrivacy: Sendable, Equatable {
    public enum Mask: Sendable, Equatable {
        case none, hash
    }

    enum Level: Sendable, Equatable {
        case auto, `public`, `private`, sensitive
    }

    let level: Level
    let mask: Mask

    public static let auto = DebugLogPrivacy(level: .auto, mask: .none)
    public static let `public` = DebugLogPrivacy(level: .public, mask: .none)
    public static let `private` = DebugLogPrivacy(level: .private, mask: .none)
    public static let sensitive = DebugLogPrivacy(level: .sensitive, mask: .none)

    public static func auto(mask: Mask) -> DebugLogPrivacy { DebugLogPrivacy(level: .auto, mask: mask) }
    public static func `private`(mask: Mask) -> DebugLogPrivacy { DebugLogPrivacy(level: .private, mask: mask) }
    public static func sensitive(mask: Mask) -> DebugLogPrivacy { DebugLogPrivacy(level: .sensitive, mask: mask) }

    /// `.auto` settled for a value's type.
    func resolved(scalar: Bool) -> DebugLogPrivacy {
        guard level == .auto else { return self }
        return DebugLogPrivacy(level: scalar ? .public : .private, mask: mask)
    }
}

/// A log message whose interpolated values carry their privacy. Written like
/// an `OSLogMessage`:
///
/// ```swift
/// log.info("joined \(room.id, privacy: .public) as \(user.email)")   // email: private
/// log.error("token refresh failed: \(error.code) \(token, privacy: .sensitive)")
/// ```
///
/// Values are rendered to text when the message is built, which os_log
/// defers. That is the price of keeping a copy in the in-process buffer;
/// `DebugLogger.debug` takes its message lazily so hot paths can skip it.
public struct DebugLogMessage: Sendable, ExpressibleByStringInterpolation {
    enum Segment: Sendable, Equatable {
        /// Literal text from the call site, and public values.
        case text(String)
        /// A value that is not public, kept only in development mode.
        case hidden(String, DebugLogPrivacy)
        /// A value that was never stored: its placeholder or salted hash.
        case withheld(String)
    }

    var segments: [Segment]

    public init(stringLiteral value: String) {
        segments = [.text(value)]
    }

    public init(stringInterpolation: StringInterpolation) {
        segments = stringInterpolation.segments
    }

    init(segments: [Segment]) {
        self.segments = segments
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        var segments: [Segment] = []

        public init(literalCapacity: Int, interpolationCount: Int) {
            segments.reserveCapacity(interpolationCount * 2 + 1)
        }

        public mutating func appendLiteral(_ literal: String) {
            guard !literal.isEmpty else { return }
            appendText(literal)
        }

        public mutating func appendInterpolation<T>(_ value: T, privacy: DebugLogPrivacy = .auto) {
            // Checked at run time too, because the optional overload below
            // forwards here with the wrapped type erased to `T`.
            let scalar = value is any BinaryInteger || value is any BinaryFloatingPoint || value is Bool
            append(String(describing: value), privacy.resolved(scalar: scalar))
        }

        public mutating func appendInterpolation<T: BinaryInteger>(_ value: T, privacy: DebugLogPrivacy = .auto) {
            append(String(value), privacy.resolved(scalar: true))
        }

        public mutating func appendInterpolation<T: BinaryFloatingPoint & CustomStringConvertible>(
            _ value: T, privacy: DebugLogPrivacy = .auto
        ) {
            append(value.description, privacy.resolved(scalar: true))
        }

        /// `OSLogFloatFormatting`'s common spellings: `format: .fixed(precision: 2)`.
        public mutating func appendInterpolation<T: BinaryFloatingPoint>(
            _ value: T, format: DebugLogFloatFormat, privacy: DebugLogPrivacy = .auto
        ) {
            append(format.render(Double(value)), privacy.resolved(scalar: true))
        }

        public mutating func appendInterpolation(_ value: Bool, privacy: DebugLogPrivacy = .auto) {
            append(value ? "true" : "false", privacy.resolved(scalar: true))
        }

        /// An optional prints its value, or `nil` — not `Optional(...)`.
        public mutating func appendInterpolation<T>(_ value: T?, privacy: DebugLogPrivacy = .auto) {
            guard let value else {
                appendText("nil")
                return
            }
            appendInterpolation(value, privacy: privacy)
        }

        private mutating func append(_ text: String, _ privacy: DebugLogPrivacy) {
            if privacy.level == .public {
                appendText(text)
            } else {
                segments.append(.hidden(text, privacy))
            }
        }

        private mutating func appendText(_ text: String) {
            if case .text(let previous)? = segments.last {
                segments[segments.count - 1] = .text(previous + text)
            } else {
                segments.append(.text(text))
            }
        }
    }

    // MARK: Rendering

    /// True when every value in the message is public.
    public var isPublic: Bool {
        !segments.contains { if case .hidden = $0 { true } else { false } }
    }

    /// For export: traces, the debug server, the clipboard, the OS log.
    /// Hidden values become `<private>` or their salted hash.
    public var redacted: String {
        render(revealPrivate: false)
    }

    /// For this device's own screen in development mode: private values
    /// in full, sensitive ones still withheld.
    public var revealed: String {
        render(revealPrivate: true)
    }

    func render(revealPrivate: Bool) -> String {
        var out = ""
        for segment in segments {
            switch segment {
            case .text(let text), .withheld(let text):
                out += text
            case .hidden(let value, let privacy):
                if revealPrivate && privacy.level == .private {
                    out += value
                } else {
                    out += Self.placeholder(for: value, privacy)
                }
            }
        }
        return out
    }

    /// The message with every hidden value already replaced, so the private
    /// text is no longer held anywhere. What release mode stores.
    func withholdingHiddenValues() -> DebugLogMessage {
        guard !isPublic else { return self }
        return DebugLogMessage(segments: segments.map { segment in
            if case .hidden(let value, let privacy) = segment {
                return .withheld(Self.placeholder(for: value, privacy))
            }
            return segment
        })
    }

    /// Development mode keeps private values for the device's own screen,
    /// but a sensitive value is never kept in either mode.
    func withholdingSensitiveValues() -> DebugLogMessage {
        DebugLogMessage(segments: segments.map { segment in
            if case .hidden(let value, let privacy) = segment, privacy.level == .sensitive {
                return .withheld(Self.placeholder(for: value, privacy))
            }
            return segment
        })
    }

    static func placeholder(for value: String, _ privacy: DebugLogPrivacy) -> String {
        switch privacy.mask {
        case .none: "<private>"
        case .hash: "<hash:\(DebugLogSalt.hash(value))>"
        }
    }

    /// Approximate memory held, for the buffer's byte cap.
    var byteCount: Int {
        segments.reduce(0) { total, segment in
            switch segment {
            case .text(let text), .withheld(let text): total + text.utf8.count
            case .hidden(let value, _): total + value.utf8.count
            }
        }
    }
}

/// Float formatting, spelled like `OSLogFloatFormatting`.
public enum DebugLogFloatFormat: Sendable {
    case fixed(precision: Int)
    case exponential(precision: Int)

    public static var fixed: DebugLogFloatFormat { .fixed(precision: 6) }

    func render(_ value: Double) -> String {
        switch self {
        case .fixed(let precision): String(format: "%.\(max(0, precision))f", value)
        case .exponential(let precision): String(format: "%.\(max(0, precision))e", value)
        }
    }
}

/// The per-launch salt behind `mask: .hash`.
enum DebugLogSalt {
    private static let salt: SymmetricKey = SymmetricKey(size: .bits256)

    static func hash(_ value: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: salt)
        return code.prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}
