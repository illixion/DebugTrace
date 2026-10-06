import Foundation

// The vocabulary of the debug server's on-device approval, kept here rather
// than in DebugTraceServer so DebugTraceUI can draw the prompt without linking
// the listener (a submission build leaves the server unlinked).

/// Someone on the Mac wants debug access to this app.
public struct DebugApprovalRequest: Sendable {
    /// What the client calls itself (`X-DebugTrace-Client`), e.g. "App Store page on Pegasus".
    /// Clients choose it, so it is a label, not an identity: the bearer token is what proves
    /// the caller has this build's ledger.
    public let client: String
    public let appName: String

    public init(client: String, appName: String) {
        self.client = client
        self.appName = appName
    }
}

public enum DebugApprovalDecision: Sendable {
    /// Until the app quits.
    case allowOnce
    /// Every launch of this build (`CFBundleVersion`), for this client name.
    case allowForBuild
    case deny
}

/// Offered after the person has declined twice: anyone can name themselves
/// anything, so a flood of prompts is answered by not prompting for a while.
public struct DebugSilenceOffer: Sendable {
    public let appName: String
    /// How long new clients would be refused without a prompt.
    public let duration: Duration

    public init(appName: String, duration: Duration) {
        self.appName = appName
        self.duration = duration
    }

    /// The offer's wording, shared by the system alert and DebugTraceUI's window.
    public static let title = "Stop asking for a while?"

    public var message: String {
        "You've declined two requests. For the next \(durationText), new requests to debug \(appName) "
            + "will be refused without asking. Clients you allowed keep working, and relaunching the app "
            + "starts asking again."
    }

    public var acceptLabel: String { "Silence for \(durationText)" }

    /// "an hour", "15 minutes".
    public var durationText: String {
        let minutes = Int(duration.components.seconds / 60)
        switch minutes {
        case 60: return "an hour"
        case let m where m % 60 == 0: return "\(m / 60) hours"
        case 1: return "a minute"
        default: return "\(max(minutes, 1)) minutes"
        }
    }
}

/// Draws the approval prompt in the app's own UI. DebugTraceUI's
/// `DebugApprovalCenter` is one; it registers itself as `current` once its
/// window can be opened, and the server's default `.ask` uses it before
/// falling back to a system alert.
///
/// The server shows one prompt at a time, so an implementation never has to
/// queue. Return nil when nothing can be shown right now: the server then
/// tries the system alert.
@MainActor
public protocol DebugApprovalPresenting: AnyObject {
    func ask(_ request: DebugApprovalRequest) async -> DebugApprovalDecision?
    /// True to silence prompts for `offer.duration`.
    func offerSilence(_ offer: DebugSilenceOffer) async -> Bool?
}

@MainActor
public enum DebugApprovalPresenter {
    /// Held weakly: a presenter that goes away stops being asked.
    public static var current: (any DebugApprovalPresenting)? {
        get { box?.value }
        set { box = newValue.map(WeakPresenter.init) }
    }

    private static var box: WeakPresenter?

    private final class WeakPresenter {
        weak var value: (any DebugApprovalPresenting)?
        init(_ value: any DebugApprovalPresenting) { self.value = value }
    }
}
