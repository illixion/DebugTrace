import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Someone on the Mac wants debug access to this app.
public struct DebugApprovalRequest: Sendable {
    /// What the client calls itself (`X-DebugTrace-Client`), e.g. "App Store page on Pegasus".
    /// Clients choose it, so it is a label, not an identity: the bearer token is what proves
    /// the caller has this build's ledger.
    public let client: String
    public let appName: String
}

public enum DebugApprovalDecision: Sendable {
    /// Until the app quits.
    case allowOnce
    /// Every launch of this build (`CFBundleVersion`), for this client name.
    case allowForBuild
    case deny
}

/// Whether a client must be allowed on the device before the server answers it.
public enum DebugApproval: Sendable {
    /// Ask with a system alert (UIKit or AppKit) the first time each client connects.
    case ask
    /// Ask with the app's own UI.
    case custom(@MainActor @Sendable (DebugApprovalRequest) async -> DebugApprovalDecision)
    /// Never ask: tests, or an app that gates access some other way.
    case allowAll
}

/// Per-launch decisions, with one prompt per client however many requests are waiting.
@MainActor
final class DebugApprovals {
    private let mode: DebugApproval
    private let defaults: UserDefaults
    private let build: String
    private var decided: [String: Bool] = [:]
    private var pending: [String: Task<Bool, Never>] = [:]

    init(mode: DebugApproval, defaults: UserDefaults = .standard,
         build: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") {
        self.mode = mode
        self.defaults = defaults
        self.build = build
    }

    private var rememberedKey: String { "DebugTrace.allowedClients.\(build)" }

    /// True when `client` may be served. Waits up to `timeout` for the person
    /// at the device; nil means they haven't answered yet.
    func allowed(_ client: String, appName: String, timeout: Duration) async -> Bool? {
        if case .allowAll = mode { return true }
        if let decision = decided[client] { return decision }
        if (defaults.stringArray(forKey: rememberedKey) ?? []).contains(client) {
            decided[client] = true
            return true
        }
        let task = pending[client] ?? {
            let task = Task { @MainActor [weak self] () -> Bool in
                guard let self else { return false }
                let request = DebugApprovalRequest(client: client, appName: appName)
                let decision: DebugApprovalDecision
                switch self.mode {
                case .custom(let handler): decision = await handler(request)
                case .ask: decision = await DebugApprovalPrompt.ask(request)
                case .allowAll: decision = .allowOnce
                }
                self.pending[client] = nil
                switch decision {
                case .allowOnce:
                    self.decided[client] = true
                case .allowForBuild:
                    self.decided[client] = true
                    let remembered = self.defaults.stringArray(forKey: self.rememberedKey) ?? []
                    self.defaults.set(remembered + [client], forKey: self.rememberedKey)
                case .deny:
                    self.decided[client] = false
                }
                return self.decided[client] ?? false
            }
            pending[client] = task
            return task
        }()
        // Whichever comes first. Not a task group: that would wait for the
        // prompt even after the timeout won, since the prompt task can't be
        // cancelled from here.
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
            let once = ResumeOnce(continuation)
            Task { @MainActor in once.resume(await task.value) }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                once.resume(nil)
            }
        }
    }

    /// The client name a request goes by: its `X-DebugTrace-Client` header,
    /// else its User-Agent's product, cleaned to something short and printable.
    nonisolated static func clientName(header: String?, userAgent: String?) -> String {
        let raw = header ?? userAgent.map { String($0.split(separator: " ").first ?? "") } ?? ""
        let cleaned = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "An unnamed client" : String(cleaned.prefix(80))
    }
}

@MainActor
private final class ResumeOnce {
    private var continuation: CheckedContinuation<Bool?, Never>?
    init(_ continuation: CheckedContinuation<Bool?, Never>) { self.continuation = continuation }
    func resume(_ value: Bool?) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

/// The default prompt: a system alert over whatever is on screen.
@MainActor
enum DebugApprovalPrompt {
    static func ask(_ request: DebugApprovalRequest) async -> DebugApprovalDecision {
        let title = "Allow debug access?"
        let message = "\(request.client) wants to read \(request.appName)'s logs and run its debug commands."
        #if canImport(UIKit)
        guard let presenter = topViewController() else { return .deny }
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Allow", style: .default) { _ in continuation.resume(returning: .allowOnce) })
            alert.addAction(UIAlertAction(title: "Always for This Build", style: .default) { _ in continuation.resume(returning: .allowForBuild) })
            alert.addAction(UIAlertAction(title: "Don't Allow", style: .cancel) { _ in continuation.resume(returning: .deny) })
            presenter.present(alert, animated: true)
        }
        #elseif canImport(AppKit)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Always for This Build")
        alert.addButton(withTitle: "Don't Allow")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .allowOnce
        case .alertSecondButtonReturn: return .allowForBuild
        default: return .deny
        }
        #else
        return .deny
        #endif
    }

    #if canImport(UIKit)
    /// The frontmost view controller of the active scene, or nil when the app
    /// shows no window (an immersive-only space, say): then nobody can answer.
    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first
        guard var controller = window?.rootViewController else { return nil }
        while let next = controller.presentedViewController, !next.isBeingDismissed { controller = next }
        return controller
    }
    #endif
}
