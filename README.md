# DebugTrace

In-app debug tooling for Apple-platform apps: a privacy-labelled logger, debug traces, and
a debug server that language models can drive. You register debug endpoints once, and three
things use them:

- **Debug traces.** A button captures recent logs, persisted feature breadcrumbs, a snapshot
  of every traced endpoint, and device/process info into a zip. You can share the zip or
  upload it. Builds from `build-and-sign` sign it with a per-build Ed25519 key.
- **An HTTP server** you can query with `curl`. It documents itself at `GET /`, validates
  every argument, and returns one JSON envelope with hints on every error.
- **An MCP endpoint** (`POST /mcp`), so an agent gets every endpoint as a tool:
  `claude mcp add --transport http myapp http://<device>:<port>/mcp`.

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

let server = DebugTraceServer(configuration: .init(port: 8650))   // one fixed port per app
try await server.start()
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

## Endpoints

Queries whose arguments all have defaults are added to every trace automatically. Pass
`trace: .never` to leave one out, or `trace: .arguments([...])` to capture it with specific
arguments.

See [CLAUDE.md](CLAUDE.md) for the design rules, the wire formats and the security model.
