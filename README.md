# DebugTrace

In-app debug tooling for Apple-platform apps. You register debug endpoints once, and three
things use them:

- **Debug traces.** A button captures recent logs, persisted feature breadcrumbs, a snapshot
  of every traced endpoint, and device/process info into a zip. You can share the zip or
  upload it. Builds from `build-and-sign` sign it with a per-build Ed25519 key.
- **An HTTP server** you can query with `curl`. It documents itself at `GET /`, validates
  every argument, and returns one JSON envelope with hints on every error.
- **An MCP endpoint** (`POST /mcp`), so an agent gets every endpoint as a tool:
  `claude mcp add --transport http myapp http://<device>:8642/mcp`.

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

let server = DebugTraceServer()                       // developer-mode toggle
try await server.start()
```

```swift
import DebugTraceUI

Section("Developer") { DebugTraceButton() }            // capture → review → share / upload
```

Queries whose arguments all have defaults are added to every trace automatically. Pass
`trace: .never` to leave one out, or `trace: .arguments([...])` to capture it with specific
arguments.

See [CLAUDE.md](CLAUDE.md) for the design rules, the wire formats and the security model.
