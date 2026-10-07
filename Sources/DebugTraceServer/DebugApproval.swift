import DebugTrace
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Whether a client must be allowed on the device before the server answers it.
public enum DebugApproval: Sendable {
    /// Ask the first time each client connects: in the app's own window when
    /// a `DebugApprovalPresenter` is registered (DebugTraceUI's
    /// `DebugApprovalWindow`), else with a system alert (UIKit or AppKit).
    case ask
    /// Ask with the app's own UI. `silence` answers the offer made after a
    /// second decline; without it the offer goes the `.ask` way.
    case custom(@MainActor @Sendable (DebugApprovalRequest) async -> DebugApprovalDecision,
                silence: (@MainActor @Sendable (DebugSilenceOffer) async -> Bool)? = nil)
    /// Never ask: tests, or an app that gates access some other way.
    case allowAll
}

/// Per-launch decisions, defended against a flood of prompts.
///
/// Anyone holding the token can call itself anything, and on a hostile
/// network the token may not be the only thing in the way (no-token servers).
/// So: one prompt per client however many requests are waiting, one prompt on
/// screen at a time however many clients are waiting, a queued prompt dropped
/// once nobody waits for it, and after every second decline an offer to stop
/// asking for an hour.
@MainActor
final class DebugApprovals {
    enum Answer: Equatable {
        case allowed
        case declined
        /// No prompt until then; clients already allowed are unaffected.
        case silenced(until: Date)
        /// The person hasn't answered within the timeout.
        case waiting
    }

    nonisolated static let declinesBeforeOffer = 2

    private let mode: DebugApproval
    private let defaults: UserDefaults
    private let build: String
    private let silenceDuration: Duration
    private let playsSound: Bool
    private var decided: [String: Bool] = [:]
    private var pending: [String: Task<Answer, Never>] = [:]
    /// Requests per client waiting on its prompt; a queued prompt whose
    /// requests have all timed out is never shown.
    private var waiting: [String: Int] = [:]
    private var promptOnScreen = false
    private var nextInLine: [CheckedContinuation<Void, Never>] = []
    private var declinesSinceOffer = 0
    private var silencedUntil: Date?

    init(mode: DebugApproval, defaults: UserDefaults = .standard,
         build: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "",
         silenceDuration: Duration = .seconds(3600), playsSound: Bool = false) {
        self.mode = mode
        self.playsSound = playsSound
        self.defaults = defaults
        self.build = build
        self.silenceDuration = silenceDuration
    }

    private var rememberedKey: String { "DebugTrace.allowedClients.\(build)" }

    private var silence: Date? {
        guard let silencedUntil, silencedUntil > Date() else { return nil }
        return silencedUntil
    }

    /// Whether `client` may be served. Waits up to `timeout` for the person at
    /// the device, including for prompts ahead of its own.
    func allowed(_ name: String, appName: String, purpose: DebugApprovalRequest.Purpose = .access,
                 detail: String? = nil, timeout: Duration) async -> Answer {
        if case .allowAll = mode { return .allowed }
        // Patching is its own question, asked for every patch: allowing a client
        // to read says nothing about letting it run code, and neither an allow
        // nor a decline carries over to the next patch. Each call gets a key of
        // its own, so two patches sent together are two prompts, never one answer.
        let client = purpose == .access ? name : "patch:\(UUID().uuidString)"
        if purpose == .access, let decision = decided[client] { return decision ? .allowed : .declined }
        if purpose == .access, (defaults.stringArray(forKey: rememberedKey) ?? []).contains(client) {
            decided[client] = true
            return .allowed
        }
        if purpose == .access, pending[client] == nil, let silence { return .silenced(until: silence) }
        let task = pending[client] ?? {
            let task = Task { @MainActor [weak self] () -> Answer in
                await self?.prompt(client, name: name, appName: appName, purpose: purpose, detail: detail) ?? .declined
            }
            pending[client] = task
            return task
        }()
        waiting[client, default: 0] += 1
        // Whichever comes first. Not a task group: that would wait for the
        // prompt even after the timeout won, since the prompt task can't be
        // cancelled from here.
        let answer = await withCheckedContinuation { (continuation: CheckedContinuation<Answer, Never>) in
            let once = ResumeOnce(continuation)
            Task { @MainActor in once.resume(await task.value) }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                once.resume(.waiting)
            }
        }
        waiting[client, default: 1] -= 1
        return answer
    }

    /// One client's turn at the screen, queued behind any prompt already up.
    private func prompt(_ client: String, name: String, appName: String,
                        purpose: DebugApprovalRequest.Purpose, detail: String?) async -> Answer {
        await takeTurn()
        defer { endTurn() }
        defer { pending[client] = nil }
        if purpose == .access, let silence { return .silenced(until: silence) }
        // Everyone who asked gave up while it queued: a flood of names left
        // behind no stack of prompts. The next request asks afresh.
        guard waiting[client, default: 0] > 0 else { return .waiting }
        let request = DebugApprovalRequest(client: name, appName: appName, purpose: purpose, detail: detail)
        let decision: DebugApprovalDecision
        let chime = chimeWhilePrompting(DebugApprovalChime.Kind(purpose))
        defer { chime?.cancel() }
        switch mode {
        case .custom(let handler, _): decision = await handler(request)
        case .ask: decision = await DebugApprovalPrompt.ask(request)
        case .allowAll: decision = .allowOnce
        }
        // One patch, one answer: nothing about it is kept.
        if purpose == .codePatching { return decision == .deny ? .declined : .allowed }
        switch decision {
        case .allowOnce:
            decided[client] = true
        case .allowForBuild:
            decided[client] = true
            // A custom handler may answer this; code patching is never remembered.
            if purpose == .access {
                let remembered = defaults.stringArray(forKey: rememberedKey) ?? []
                defaults.set(remembered + [client], forKey: rememberedKey)
            }
        case .deny:
            decided[client] = false
            if purpose == .access { declinesSinceOffer += 1 }
            if purpose == .access, declinesSinceOffer >= Self.declinesBeforeOffer {
                declinesSinceOffer = 0
                // Still this client's turn, so the offer can't stack on the next prompt.
                await offerSilence(appName: appName)
            }
        }
        return decided[client] == true ? .allowed : .declined
    }

    private func offerSilence(appName: String) async {
        let offer = DebugSilenceOffer(appName: appName, duration: silenceDuration)
        let chime = chimeWhilePrompting()
        defer { chime?.cancel() }
        let accepted: Bool
        if case .custom(_, let silence?) = mode {
            accepted = await silence(offer)
        } else {
            accepted = await DebugApprovalPrompt.offerSilence(offer)
        }
        guard accepted else { return }
        let (seconds, attoseconds) = silenceDuration.components
        silencedUntil = Date().addingTimeInterval(Double(seconds) + Double(attoseconds) / 1e18)
    }

    /// Starts the chime for a prompt about to be shown; the caller cancels it
    /// once the person has answered. Nil when sound is off.
    private func chimeWhilePrompting(_ kind: DebugApprovalChime.Kind = .access) -> Task<Void, Never>? {
        playsSound ? DebugApprovalChime.start(kind) : nil
    }

    private func takeTurn() async {
        guard promptOnScreen else {
            promptOnScreen = true
            return
        }
        await withCheckedContinuation { nextInLine.append($0) }
    }

    private func endTurn() {
        if nextInLine.isEmpty {
            promptOnScreen = false
        } else {
            nextInLine.removeFirst().resume()
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
    private var continuation: CheckedContinuation<DebugApprovals.Answer, Never>?
    init(_ continuation: CheckedContinuation<DebugApprovals.Answer, Never>) { self.continuation = continuation }
    func resume(_ value: DebugApprovals.Answer) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

/// The default prompt: the registered presenter's window, else a system alert
/// over whatever is on screen.
@MainActor
enum DebugApprovalPrompt {
    static func ask(_ request: DebugApprovalRequest) async -> DebugApprovalDecision {
        if let presenter = DebugApprovalPresenter.current, let decision = await presenter.ask(request) {
            return decision
        }
        let buttons: [(String, DebugApprovalDecision)] = request.purpose == .access
            ? [("Allow", .allowOnce), ("Always for This Build", .allowForBuild)]
            : [("Allow This Patch", .allowOnce)]
        return await alert(title: request.title, message: request.message, buttons: buttons,
                           cancel: ("Don't Allow", .deny))
    }

    static func offerSilence(_ offer: DebugSilenceOffer) async -> Bool {
        if let presenter = DebugApprovalPresenter.current, let accepted = await presenter.offerSilence(offer) {
            return accepted
        }
        return await alert(title: DebugSilenceOffer.title, message: offer.message,
                           buttons: [(offer.acceptLabel, true)], cancel: ("Keep Asking", false))
    }

    /// Nothing to present on (no UIKit window, as in an immersive-only space)
    /// answers with `cancel`.
    private static func alert<T: Sendable>(title: String, message: String, buttons: [(String, T)], cancel: (String, T)) async -> T {
        #if canImport(UIKit)
        guard let presenter = topViewController() else { return cancel.1 }
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            for (label, value) in buttons {
                alert.addAction(UIAlertAction(title: label, style: .default) { _ in continuation.resume(returning: value) })
            }
            alert.addAction(UIAlertAction(title: cancel.0, style: .cancel) { _ in continuation.resume(returning: cancel.1) })
            presenter.present(alert, animated: true)
        }
        #elseif canImport(AppKit)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        for (label, _) in buttons { alert.addButton(withTitle: label) }
        alert.addButton(withTitle: cancel.0)
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return index >= 0 && index < buttons.count ? buttons[index].1 : cancel.1
        #else
        return cancel.1
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
