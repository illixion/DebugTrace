# Integrating DebugTrace into an app

Everything an app has to do, in order. Steps 1 to 4 are required; 5 to 8 are optional and say
when you want them. A step ends with how to check it. A delegated agent follows the same
page (see [delegating-an-integration.md](delegating-an-integration.md)).

**What you get:** `DebugLogger` lines in an in-app ring buffer, a debug server that language
models and `curl` can query on development builds, a debug trace the user can send, and (with
`--inject`) live code patching. Nothing listens in an App Store or TestFlight build.

**Platforms:** iOS 17, tvOS 17, visionOS 1, macOS 14. watchOS is not declared.

## 1. Link the package

DebugTrace is a local Swift package referenced by relative path, not a versioned URL. Add an
`XCLocalSwiftPackageReference` to the app's project whose `relativePath` points at the
checkout (`../DebugTrace` for a project one folder below `~/Projects`, `../../DebugTrace` two
below) and link these products to the **app target**:

| Product | Needed for | Link when |
|---|---|---|
| `DebugTrace` | `DebugLogger`, `DebugSurface`, traces, breadcrumbs | always |
| `DebugTraceServer` | the HTTP + MCP server | you want agents or `curl` to reach the app |
| `DebugTraceUI` | `DebugTraceButton`, the approval window, `@PatchRefresh` | the app has a UI (all of them do) |
| `DebugTraceInject` | nothing: do **not** link it | `--inject` embeds the runtime for you |

How to add them:

- **A project that uses RAVESDK or RAVEEngine already links `DebugTrace` indirectly** (their
  logging targets depend on it). It still needs the products above linked directly to import
  them from app code.
- **There is no Xcode MCP tool for package references or product dependencies.** Edit
  `project.pbxproj` by hand: one `XCLocalSwiftPackageReference`, one `XCSwiftPackageProductDependency`
  per product, one `PBXBuildFile` per product in the Frameworks phase, and the entries in the
  target's `packageProductDependencies`. xrTimer's project is the smallest worked example
  (`~/Projects/xrTimer/xrTimer.xcodeproj/project.pbxproj`, search for `DebugTrace`). Check
  with `plutil -lint`, then build.
- Xcode in the GUI works too: File ▸ Add Package Dependencies ▸ Add Local.

**Check:** `import DebugTrace` compiles in an app file.

## 2. Start it at launch

```swift
import DebugTrace
import DebugTraceServer
import DebugTraceUI
import SwiftUI

@main
struct MyApp: App {
    init() {
        // Every subsystem string the app (and its packages) logs with: _logs reads these from the OS log.
        DebugTrace.configure(.init(subsystems: [Bundle.main.bundleIdentifier ?? "MyApp"]))
        DebugTraceServer.startIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .debugApprovalPrompts()          // on every window that can appear
        }
        // The server's "Allow debug access?" prompt, as a window of its own. Required on visionOS
        // (a system alert is hidden by 3D content and absent in an immersive-only app); use on macOS too.
        DebugApprovalWindow()
    }
}
```

- `startIfRequested()` is a no-op unless the build is a development build signed by
  build-and-sign or the launch sets `DEBUGTRACE_SERVER=1`. It never listens in a release
  build. Calling it unconditionally is the intended use.
- Put `.debugApprovalPrompts()` on **every** window group the app has, and keep the
  `DebugApprovalWindow()` scene. On iOS and tvOS a system alert is used when no presenter is
  registered, so both are optional there.
- An app that already has an `init()` or an app-delegate launch hook adds the two lines
  there. Keep them early: before anything logs.

**Check:** build and run. With `build-and-sign --mcp` the console shows `listening on port N`.

## 3. Switch logging to `DebugLogger`

`DebugLogger` is a drop-in for `os.Logger`. Change the declaration, not the call sites:

```swift
// before
private let log = Logger(subsystem: "com.example.app", category: "Net")
// after
import DebugTrace
private let log = DebugLogger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "Net")
```

- A bare `os.Logger` still works but its lines never reach the in-app console or a trace.
- `NSLog` and `print` are not captured. Convert them (`NSLog` → `DebugLogger` first).
- **Review the privacy labels while you are there** ([logging-and-privacy.md](logging-and-privacy.md)):
  `.public` only for values the code defines (states, counts, codes); user, network and
  filesystem values stay private; credentials are `.sensitive`. Cloud models read these logs.
- Packages the app owns take their logger from the app (a hook that passes a
  `DebugLogMessage`, never a finished `String`, so each value keeps its privacy).

**Check:** later, `call _logs` returns the app's own lines.

## 4. Build and deploy with build-and-sign

`~/bin/build-and-sign` (alias `bas`) reads the repo's `build-signing.conf`:

```
PROJECT_PATH="MyApp.xcodeproj"
SCHEME_NAME="MyApp"
TARGET_NAME="MyApp"
PLATFORM="visionOS"
BUILD_BUNDLE_ID="com.example.myapp"
DEVICE_NAME="AVP"
```

Nothing DebugTrace-specific is needed in the conf. For every dev build of an app that links
DebugTrace the script writes `DebugTraceCredential.plist` (trace-signing key, upload URL,
command token) into the bundle, adds `NSLocalNetworkUsageDescription` and
`NSBonjourServices` to the Info.plist of that build only when the app has none, and records
the build in the key ledger.

```bash
build-and-sign                  # a launched debug session by default (--mcp)
build-and-sign --no-mcp         # install only; the server still runs, attach later
build-and-sign --mcp --inject   # also embed the live-patching runtime
```

**Check:** call the `apps` tool (or `debugtrace-mcp discover`): the app is listed. Then
`help` for the app, and `call _info`. The device asks "Allow debug access?" the first time:
tap Allow. If the reply says it is waiting, that is the prompt.

## 5. Add endpoints for the app's own state (optional, the main payoff)

```swift
DebugSurface.shared.register([
    .query("player", "Player position and mode", releaseSafe: false) { _ in
        Player(x: game.x, y: game.y, flying: game.flying)          // any Encodable
    },
    .command("teleport", "Move the player; returns the new position",
             parameters: [.number("x", "world x", required: true),
                          .number("z", "world z", required: true)]) { args in
        game.teleport(x: try args.requireDouble("x"), z: try args.requireDouble("z"))
    },
])
```

Rules that keep the API usable by a model are in [endpoints.md](endpoints.md): camelCase
names, a unit in every key, a `hint` on every error, commands return the resulting state.
Register from `@MainActor` code, once, after the models exist. Queries whose arguments all
have defaults are added to every trace.

## 6. A "send a trace" control (optional, for support)

```swift
import DebugTraceUI
Section("Developer") { DebugTraceButton() }     // capture → review → share / upload
```

The person can read every file before sending. In a release build the sheet describes the
trace in end-user terms and includes only `releaseSafe` endpoints.

## 7. Live code patching (optional, development only)

`build-and-sign --mcp --inject` and the `inject` tool need no app change. A patched SwiftUI
`body` does not re-run until its inputs change; the app opts in to a refresh. See
[live-patching.md](live-patching.md#making-swiftui-redraw-after-a-patch).

## 8. Shipping, and apps with private content

- **Submission builds.** The server and the patch runtime are separate products precisely so a
  submission build can leave them unlinked. A build that links them is still inert in release
  mode (App Store or TestFlight): `start()` throws and the runtime never loads.
- **Apps that carry private messages** (a chat client) use the confidential profile:
  `DebugTraceServer.startIfRequested(configuration: .init(confidential: true))`, only content-free
  `releaseSafe` queries, `includesSystemLog: false` in `DebugTrace.configure(...)` if a linked
  framework may log people,
  the share extension left unlinked, and a test that seeds personal values and fails if one
  reaches a reply. RegentChat is the model ([server-and-security.md](server-and-security.md#confidential-profile)).
- **Opting out of the server** for a build: `DEBUGTRACE_SERVER=off` in `build-signing.conf`
  (or `DEBUGTRACE_SERVER=0` in one launch). Opting out of patching: `DEBUGTRACE_INJECT=off`.

## Done checklist

- [ ] Products linked; project builds for every platform the app ships on.
- [ ] `DebugTrace.configure` and `startIfRequested()` at launch; `.debugApprovalPrompts()` on
      every window group and the `DebugApprovalWindow()` scene (visionOS and macOS).
- [ ] No bare `os.Logger`, `NSLog` or `print` left in app-owned code; privacy labels reviewed.
- [ ] `build-and-sign --mcp` deploys; `apps` lists the app; `call _info` and `call _logs` answer.
- [ ] The app's own state is exposed through at least one endpoint, and each endpoint's
      `releaseSafe` was a decision, not a default.
- [ ] A **normal** build of the app still builds and launches with no server flags set.
- [ ] Tests that the app has still pass.
