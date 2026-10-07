# Live code patching (`inject`)

Edit a Swift file, call `inject`, and the running app has the new code in seconds. App setup is
nothing for the patching itself, and one line per view for SwiftUI refresh (last section).

Edit a Swift file, call the `inject` tool, and the running app has the new code in about three
seconds with its state intact. No rebuild, no relaunch, no debugger (LLDB `expr` was tried and is
too slow). **Measured on a Vision Pro (visionOS 27.2, TXM):** rewrite 15 ms, compile 0.9 s warm
(6 s first), sign 0.3 s, load 0.2 s.

```
build-and-sign --mcp --inject      once: builds so functions are replaceable, launches, records the build
(edit Foo.swift as usual)
inject                             the `apps` MCP tool: patches what changed since the last injection
inject {run: "return model.speed"} also evaluates a Swift function body afterwards, result in `output`
```

**How it works.** The app is built with `ENABLE_TESTABILITY=YES` and `-Xfrontend
-enable-implicit-dynamic -enable-private-imports`, which makes every function replaceable and lets
a patch reach `private` members. For each changed file `Tools/debugtrace-inject/Rewriter` (a
SwiftSyntax tool built on first use against the Xcode toolchain's own SwiftSyntax, no package to
fetch) diffs the token stream against the file as the running app has it and emits
`@_dynamicReplacement` extensions for function and computed-property bodies that changed, copies new
methods as they are, and **refuses** what a patch cannot do (below). `debugtrace-inject` compiles
that with the module's own compiler arguments (recorded from `xcodebuild`'s log by `capture`),
`build-and-sign --sign-dylib` signs it with the development identity, and the app `dlopen`s it
through `_inject`. Later patches override earlier ones; a function changed back is replaced again
with its original body, because the diff is against the last-injected state (`build/inject/live/`),
not the build. A relaunch (`_patches` empty) resets that state to the build.

**What a patch cannot do**, and the reply says "rebuild" and applies **nothing** (never half):
stored properties (added, removed, or a changed initial value), initializers, type headers
(inheritance, generics), protocol requirements, new top-level declarations the rest of the app must
see. Check this before promising an edit can go live. **`#if` is evaluated, not refused.** `debugtrace-inject` turns the module's recorded arguments into a
build configuration (target triple → `os`/`arch`/`targetEnvironment`, `-D` conditions, `-swift-version`,
feature flags, and `canImport` against the -I/-F paths, the SDK's frameworks and its module maps) and the
rewriter keeps only each `#if`'s active branch (`SwiftIfConfig.removingInactive`) before diffing, so a
whole-file `#if os(visionOS)`, `#if DEBUG` in a body or `#if canImport(AppKit)` patch like any other code;
a change only in an inactive branch patches nothing. A condition it can't settle (a versioned
`canImport`) leaves that file's `#if`s refused, as before. Verified on Oneiros's
`GameSessionLifecycle.swift` (wrapped whole in `#if os(visionOS)`), 2026-10-07. A loaded dylib cannot be unloaded: undo by
editing back and injecting again.

**Security: signing, not the token, is the gate.** The OS loads a dylib only if the team that signed
the app signed it, so a client holding the bearer token (a sniffed LAN request, a made-up client
name) still cannot make the app run code without the signing key. On top of that: `_inject` is
`destructive`, needs the on-device approval like every command **plus its own prompt**
("Allow code changes?": `DebugApprovalRequest.purpose == .codePatching`, asked for **every
patch** (and for each `run` snippet), with the client's label for it and its size; "Allow This Patch" /
"Don't Allow" only, nothing remembered: not for the build, not for the launch, and a decline covers that
patch only; it does not count toward the silence offer; `DebugTraceServer.codePatchingEndpoints` lists the gated names),
refuses in release privacy mode,
and the product is separate so a **submission build leaves it unlinked** (code that loads
executable code at runtime is not something to ship to the App Store; `register` also no-ops in
release). No app needs to link anything: `build-and-sign --inject` compiles the runtime with the app's own
compiler arguments (`debugtrace-inject runtime`), embeds it as `Frameworks/DebugTraceInject.dylib`
(signed with the rest of the bundle), and `DebugTraceServer.start()` loads it when present
(`DebugPatchRuntimeLoader`; development privacy mode only). A build without `--inject`, and every
App Store build, has no such file. Layers of opt-out: don't pass `--inject`;
`DEBUGTRACE_INJECT=off` in a repo's build-signing.conf refuses the flag; `Configuration.loadsPatchRuntime
= false` in the app; release mode never loads. Linking `DebugTraceInject` and calling
`register()` still works for an app that wants it compiled in. `--inject` also sets
`DEAD_CODE_STRIPPING=NO`. Verified on the real xrTimer (28 s build+deploy, no source change).

**Seeing whether it is on, and patching twice.** `apps` lists `inject: {ready: true | false | "unknown"}` per app, from the session record (`injectDir`) alone, since listing apps sends no request; `unknown` is a Bonjour attach with no record. A method an earlier patch added exists only in that patch's dylib, so it cannot be a `@_dynamicReplacement` target; when the live file holds such a method the rewriter (given `--built`, the file as built) restates the file's whole accumulated patch in the new dylib (added methods copied again, every function that differs from the build replaced again), and the report says `cumulative`. Types an earlier patch added are not restated.

**Costs to know.** Implicit-dynamic makes every call to a replaceable function indirect and blocks
inlining, so an `--inject` build is not the shipping binary's performance: Oneiros spent 28-35% more
CPU in its frame work (measure with a normal build). `INJECT_SCOPE=app` (a repo conf, or the
environment) applies the flags to the app's own module only, via a `$(DTINJECT_FLAGS_$(WRAPPER_EXTENSION))`
macro that is empty for package targets: packages stay fully optimized and cost half as much in
Oneiros (+11-15%), but their code can't be patched, and `inject` refuses such a file with a hint
(`capture --scope` records which). A patch compiles per module, with that module's flags, so changes in several packages are
several dylibs. Not yet checked on a device: generics-heavy code, iOS.

## Gotchas found building it

So they are not rediscovered: without `-enable-testing` the
replaceable functions are `hidden` and loading fails with "symbol not found in flat namespace
…Tx"; `swiftc -emit-module-path … -o app` does not relink the executable, so emit the module
separately; an unsigned or ad-hoc dylib is refused ("missing code signature") while one signed
with the dev cert after install loads, including from the app's `tmp/`; an incremental build prints
no compile command for an up-to-date module, so `capture` keeps what an earlier build recorded
(`rm -rf build/DerivedData` if the record is missing).

## Making SwiftUI redraw after a patch

A patch replaces a function body in memory. SwiftUI calls a view's `body` again only when an
input of that view changes, so a patched `body` can sit unused until something recreates the
view (a tab switch does). Nothing refreshes automatically: an app opts in with one of three
tools from `DebugTraceUI` (`DebugPatchRefresh.swift`). The app links `DebugTraceUI` and
`import DebugTraceUI`; nothing else. The runtime posts a notification after each load and
these listen for it by name, because the runtime is embedded, not linked. All three do
nothing when no patch has loaded, so they can stay in an App Store build.

**1. Keep state, refresh one view.** Declare it in the view whose `body` you are patching:

```swift
struct TimerView: View {
    @PatchRefresh var patchRefresh   // never read; declaring it is enough
    @State private var seconds = 0
    var body: some View { ... }
}
```

The view's `@State` survives and its `body` re-runs after each patch. A child re-runs only if
its own inputs changed, so declare it in each view you edit.

**2. Rebuild a screen.** At the point where the screen is created:

```swift
SettingsScreen().rebuildsOnPatch()
```

Everything under it is recreated: `@State` is lost and `onAppear`/`task` run again.

**3. Reopen the window** (for an app with no tabs to switch). On the root view of a
`WindowGroup(id:)` (not a single `Window`, so a copy can open); not available on tvOS:

```swift
WindowGroup(id: "main") { ContentView().reopensWindowOnPatch("main") }
```

After each patch a copy of the window opens and the old one closes. State in models
survives; `@State` in the old window does not.

**Not yet verified on a device:** all three, and whether `@PatchRefresh` in a parent reaches
a patched child. Test on xrTimer or Oneiros before relying on them, and update this page.
