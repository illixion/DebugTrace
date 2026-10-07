# DebugTrace

In-app debug tooling for Apple-platform apps: a privacy-labelled logger, debug traces, and
a debug server that language models can drive. You register debug endpoints once, and three
things use them:

- **Debug traces.** A button captures recent logs, persisted feature breadcrumbs, a snapshot
  of every traced endpoint, and device/process info into a zip. You can share the zip or
  upload it. Builds from [`build-and-sign`](https://github.com/illixion/appstore) sign it with a per-build Ed25519 key.
- **An HTTP server** you can query with `curl`. It documents itself at `GET /`, validates
  every argument, and returns one JSON envelope with hints on every error.
- **An MCP endpoint** (`POST /mcp`), so an agent gets every endpoint as a tool. On the Mac,
  `Tools/debugtrace-mcp` gives every agent one entry for all running apps.

```swift
import DebugTrace
import DebugTraceServer

DebugTrace.configure(.init(subsystems: ["com.example.app", "com.example.engine"]))

DebugSurface.shared.register([
    .query("player", "Player position and mode") { _ in
        Player(x: game.x, y: game.y, flying: game.flying)      // any Encodable
    },
    .command("teleport", "Move the player; returns the new position",
             parameters: [.number("x", "world x", required: true),
                          .number("z", "world z", required: true)]) { args in
        game.teleport(x: try args.requireDouble("x"), z: try args.requireDouble("z"))
    },
])

DebugTrace.begin("world.streaming", "seed 42")        // feature breadcrumbs, any thread

DebugTraceServer.startIfRequested()                  // dev builds from build-and-sign, or `bas --mcp`
```

```swift
import DebugTraceUI

Section("Developer") { DebugTraceButton() }            // capture → review → share / upload
```

## Logging

`DebugLogger` is a drop-in for `os.Logger`: the same methods and `privacy:` spelling. Every
line lands in an in-memory ring, which the in-app console and traces read. It also goes to
the unified log, so Xcode and `log stream` still work. Nothing is written to disk.

```swift
static let net = DebugLogger(subsystem: "com.example.app", category: "Net")

net.info("fetched \(count) items in \(ms, privacy: .public) ms from \(url)")  // url: private
net.error("login failed for \(email, privacy: .private(mask: .hash)): \(code, privacy: .public)")
net.debug("frame \(index)")        // lazy: not even built when debug capture is off
```

Privacy follows os_log. Numbers and booleans are public by default; everything else is
private unless marked `.public`. `.sensitive` values are never kept.

- **Development builds** show private values on the device's own console only.
- **Exports** withhold private values: traces, server replies, the clipboard and the OS log
  all show `<private>` (or a per-launch salted hash with `mask: .hash`), and the result is run
  through a secret redactor.
- **Release builds** (App Store and TestFlight, detected automatically) never store private
  values at all. They capture no debug lines unless asked to, and the debug server won't
  start. Their traces include only endpoints marked `releaseSafe: true`, so a user can send
  one to support. The user can read every file before sending.

## Live code patching

Launch with `build-and-sign --mcp --inject`, edit a Swift file, and the `inject` tool of the `apps` MCP
server replaces the changed function bodies in the running app in a few seconds, state intact. The app
needs no change: `--inject` embeds the patch runtime and `DebugTraceServer` loads it (or link
`DebugTraceInject` and call `register()` yourself). `inject` with `run` evaluates a Swift function body
in the live app. It cannot change stored properties, initializers or type headers; it says so and you
rebuild. The patch is signed with your development certificate and the device asks "Allow code
changes?" once per launch, so the debug token alone cannot make an app run code. An `--inject` build
runs Swift about 25-35% slower (measured on a game), so profile a normal build. See [Docs/live-patching.md](Docs/live-patching.md).

## Profiling and memory

Every app with the server gets `_profile` and `_memory`:

- `_profile seconds=3 threads=all`: samples every thread's stack for a few seconds and reports per
  thread how busy it was, the hottest functions (self and inclusive) and the hottest stacks. System
  frameworks' private functions are named from the device's own shared-cache symbols, Swift and C++
  demangled. Costs ~7 µs per sample; not in App Store builds (it lives in `DebugTraceServer`).
- `_memory`: footprint, peak, headroom before the system kills the app, malloc and Metal totals, and
  the largest kinds of mapped memory. Call it before and after an action to see what grew.

`Configuration(confidential: true)` limits the server to queries marked `releaseSafe` and no commands
(no logs, snapshots, traces or patching), for apps that hold private messages.

## Endpoints

Queries whose arguments all have defaults are added to every trace automatically. Pass
`trace: .never` to leave one out, or `trace: .arguments([...])` to capture it with specific
arguments.

Adding it to an app: [Docs/integration.md](Docs/integration.md). Everything else (design rules, wire formats, the security
model, live patching) is under [Docs/](Docs/README.md); [CLAUDE.md](CLAUDE.md) maps the code.

## Companion project

[**appstore**](https://github.com/illixion/appstore) is the other half: a personal LAN/tailnet
app store whose `bin/build-and-sign` gives each dev build its own trace-signing key, and whose
web UI receives and verifies uploaded traces and shows the live debug servers of running apps.
