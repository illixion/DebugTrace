import DebugTrace
import SwiftUI

// The debug server's "Allow debug access?" prompt in a window of the app's
// own, for apps that may have no UIKit window to put a system alert over: an
// immersive space renders through RealityKit or Compositor Services, and the
// alert has nothing to attach to, so the request waits out its timeout and is
// refused. Lifted from LambdaVision. visionOS shows the window in front of
// full immersion, like a Console or Performance window.
//
// Two lines adopt it, and the server's default `.ask` picks it up with no
// configuration:
//
//     DebugApprovalWindow()                       // in the App's body
//     ContentView().debugApprovalPrompts()        // on any window that appears
//
// Without them, or on iOS and tvOS (no `Window` scene there; an app on those
// always has a UIKit window), the server falls back to the system alert.

#if os(visionOS) || os(macOS)

/// Shows the server's prompts, one at a time, in `DebugApprovalWindow`.
@MainActor
@Observable
public final class DebugApprovalCenter: DebugApprovalPresenting {
    public static let shared = DebugApprovalCenter()
    public static let windowID = "debugtrace-approval"

    enum Prompt {
        case access(DebugApprovalRequest)
        case silence(DebugSilenceOffer)
    }

    /// What the window shows; nil when nothing is waiting.
    private(set) var prompt: Prompt?

    @ObservationIgnored private var answer: ((Answer) -> Void)?
    @ObservationIgnored private var openWindow: OpenWindowAction?
    @ObservationIgnored private var dismissWindow: DismissWindowAction?
    @ObservationIgnored var windowVisible = false
    @ObservationIgnored private var closeTask: Task<Void, Never>?

    enum Answer {
        case access(DebugApprovalDecision)
        case silence(Bool)
    }

    /// Opening a window needs a SwiftUI action, and the request arrives from
    /// the server, not a view: `debugApprovalPrompts()` hands one over.
    func attach(open: OpenWindowAction, dismiss: DismissWindowAction) {
        openWindow = open
        dismissWindow = dismiss
        DebugApprovalPresenter.current = self
    }

    public func ask(_ request: DebugApprovalRequest) async -> DebugApprovalDecision? {
        guard case .access(let decision)? = await show(.access(request)) else { return nil }
        return decision
    }

    public func offerSilence(_ offer: DebugSilenceOffer) async -> Bool? {
        guard case .silence(let accepted)? = await show(.silence(offer)) else { return nil }
        return accepted
    }

    /// Nil when the window never appeared (the app didn't add
    /// `DebugApprovalWindow`): the server then tries its system alert rather
    /// than wait on a prompt nobody can see.
    private func show(_ prompt: Prompt) async -> Answer? {
        guard let openWindow else { return nil }
        closeTask?.cancel()
        self.prompt = prompt
        if !windowVisible {
            openWindow(id: Self.windowID)
            let deadline = ContinuousClock.now + .seconds(3)
            while !windowVisible, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard windowVisible else {
                self.prompt = nil
                return nil
            }
        }
        let answer = await withCheckedContinuation { continuation in
            self.answer = { continuation.resume(returning: $0) }
        }
        self.prompt = nil
        // The server shows the next queued prompt straight away; a moment's
        // grace lets it reuse this window instead of closing and reopening it.
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled, self.prompt == nil else { return }
            self.dismissWindow?(id: Self.windowID)
        }
        return answer
    }

    func respond(_ answer: Answer) {
        let resume = self.answer
        self.answer = nil
        resume?(answer)
    }

    /// The window was closed with a prompt still up: that's a no.
    func closedUnanswered() {
        switch prompt {
        case .access?: respond(.access(.deny))
        case .silence?: respond(.silence(false))
        case nil: break
        }
    }
}

/// The scene the prompts appear in. Add it to the App's body once. A single
/// `Window`, not a `WindowGroup`, so a prompt can never open a second copy;
/// that scene type needs visionOS 26, above this package's floor.
@available(visionOS 26.0, macOS 15.0, *)
public struct DebugApprovalWindow: Scene {
    public init() {}

    public var body: some Scene {
        Window("Debug Access", id: DebugApprovalCenter.windowID) {
            DebugApprovalView()
        }
        .windowResizability(.contentSize)
        // Only ever opened for a prompt: never at launch, and never restored
        // as an empty "No request is waiting" window.
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

struct DebugApprovalView: View {
    private var center = DebugApprovalCenter.shared

    var body: some View {
        VStack(spacing: 16) {
            switch center.prompt {
            case .access(let request)?:
                Image(systemName: request.purpose == .access ? "ladybug" : "curlybraces")
                    .font(.system(size: 40))
                Text(request.title)
                    .font(.title2.bold())
                Text(request.message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                VStack(spacing: 10) {
                    Button(request.purpose == .access ? "Allow" : "Allow Once") { center.respond(.access(.allowOnce)) }
                        .buttonStyle(.borderedProminent)
                    if request.purpose == .access {
                        Button("Always for This Build") { center.respond(.access(.allowForBuild)) }
                    }
                    Button("Don't Allow", role: .cancel) { center.respond(.access(.deny)) }
                }
            case .silence(let offer)?:
                Image(systemName: "bell.slash")
                    .font(.system(size: 40))
                Text(DebugSilenceOffer.title)
                    .font(.title2.bold())
                Text(offer.message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                VStack(spacing: 10) {
                    Button(offer.acceptLabel) { center.respond(.silence(true)) }
                        .buttonStyle(.borderedProminent)
                    Button("Keep Asking", role: .cancel) { center.respond(.silence(false)) }
                }
            case nil:
                Text("No request is waiting.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(32)
        .frame(width: 460)
        .debugApprovalPrompts()
        .onAppear { center.windowVisible = true }
        .onDisappear {
            center.windowVisible = false
            center.closedUnanswered()
        }
    }
}

extension View {
    /// Lets `DebugApprovalCenter` open its window from this view's scene, and
    /// makes it the server's prompt. Put it on every window that can be the
    /// first to appear.
    public func debugApprovalPrompts() -> some View {
        modifier(CaptureWindowActions())
    }
}

private struct CaptureWindowActions: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    func body(content: Content) -> some View {
        content.onAppear {
            DebugApprovalCenter.shared.attach(open: openWindow, dismiss: dismissWindow)
        }
    }
}

#else

extension View {
    /// No-op where there is no `Window` scene: the server's system alert has
    /// a UIKit window to sit on.
    public func debugApprovalPrompts() -> some View { self }
}

#endif
