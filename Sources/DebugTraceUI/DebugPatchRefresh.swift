// What to do in SwiftUI after `inject` loads a patch.
//
// A patch replaces a function body in memory. SwiftUI only calls a view's `body`
// again when an input of that view changes, so a patched `body` can sit unused
// until something else (a tab switch) recreates the view. Nothing here is
// automatic: an app opts in, per view or per window, in one of three ways.
//
//   @PatchRefresh var patchRefresh          // inside a view: its body re-runs, @State kept
//   SomeView().rebuildsOnPatch()            // the whole subtree is rebuilt, @State lost
//   RootView().reopensWindowOnPatch("main") // a copy of the window opens, this one closes
//
// All three do nothing unless a patch loads, so they can stay in an App Store
// build. The runtime posts `DebugPatchRefresh.notification` (it cannot be
// linked from here: it is embedded into dev builds, not linked).

import Combine
import SwiftUI

public enum DebugPatchRefresh {
    /// Posted on the main thread by `DebugTraceInject` after every patch loads.
    public static let notification = Notification.Name("com.illixion.debugtrace.patchLoaded")
}

@MainActor
final class DebugPatchObserver: ObservableObject {
    @Published private(set) var generation = 0
    // Cancels itself when the observer goes away.
    private var subscription: AnyCancellable?

    init() {
        subscription = NotificationCenter.default.publisher(for: DebugPatchRefresh.notification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.generation += 1 } }
    }
}

/// Declare it in a view whose `body` you are patching: `@PatchRefresh var patchRefresh`.
/// The view's `body` runs again after each patch, with its `@State` intact. The
/// view's children re-run only if their own inputs changed, so declare it in the
/// view whose body you edit.
@MainActor
@propertyWrapper
public struct PatchRefresh: DynamicProperty {
    @StateObject private var observer = DebugPatchObserver()
    public init() {}
    public var wrappedValue: Int { observer.generation }
}

extension View {
    /// Rebuilds this view and everything under it after each patch. Its `@State`
    /// is lost and `onAppear`/`task` run again, so use it on a screen, not on the
    /// root of an app that holds its state in `@State`.
    public func rebuildsOnPatch() -> some View {
        modifier(DebugRebuildOnPatch())
    }

#if !os(tvOS)
    /// After each patch, opens another window of the `WindowGroup(id:)` and closes
    /// this one, which recreates every view in it. For an app with no tabs to
    /// switch. State held in `@State` of the old window is lost; state in the
    /// app's models is not.
    public func reopensWindowOnPatch(_ id: String) -> some View {
        modifier(DebugReopenWindowOnPatch(id: id))
    }
#endif
}

private struct DebugRebuildOnPatch: ViewModifier {
    @StateObject private var observer = DebugPatchObserver()
    func body(content: Content) -> some View {
        content.id(observer.generation)
    }
}

#if !os(tvOS)
private struct DebugReopenWindowOnPatch: ViewModifier {
    let id: String
    @StateObject private var observer = DebugPatchObserver()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.onChange(of: observer.generation) {
            openWindow(id: id)
            dismiss()
        }
    }
}
#endif
