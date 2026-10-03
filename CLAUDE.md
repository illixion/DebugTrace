# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**DebugTrace**: one registry of debug endpoints per app, read by three consumers:

- **the debug trace**: a zip of logs, feature breadcrumbs, a snapshot of every traced
  query, and device info. It is shared from a sheet or uploaded to the app store server.
- **the HTTP server**, used by `curl`.
- **the MCP endpoint**, which gives an agent every endpoint as a tool.

An app registers an endpoint once and it shows up in all three. That is the whole design.

Three products:

| Product | What | Links |
|---|---|---|
| `DebugTrace` | `DebugLogger` + in-process log buffer, `DebugSurface` registry, trace builder, log reader, breadcrumbs, redactor, credential | nothing |
| `DebugTraceUI` | `DebugTraceView` / `DebugTraceButton` (capture → review → share/upload) | SwiftUI |
| `DebugTraceServer` | `DebugTraceServer`: HTTP + MCP over a surface | Network |

The server is its own product so a submission build can leave it **unlinked**. The old
compile-flag strip (`ONEIROS_NO_DEBUG_SERVER`) removed the routes but still shipped the
transport, because SwiftPM cannot link a product per configuration.

## Why it is not a RAVE target

`~/Projects/CLAUDE.md` fixes the RAVE family at two packages. This package is a deliberate
exception, decided with the user on 2026-09-29, for three reasons:

- **Deployment floor.** RAVESDK's platforms are iOS 26 and up, and SwiftPM floors are
  package-wide. The web-yt-dlp player and RegentChat target iOS 18 and are meant to adopt
  this package.
- **It is tooling, not app SDK.** It is the app-side half of the build-and-sign / appstore
  infrastructure, which is slated to be open-sourced separately.
- **It replaces RAVEEngine's `RAVEDebugServer` outright** (no compatibility shim; the user
  pushes all repos together, so there is no public desync).

It depends on neither RAVE package, and neither depends on it. A RAVE target that wants to
contribute state (for example RAVEConsole's system monitor, or RAVEDiagnostics' metrics) does
it from the app, by registering an endpoint.

## Build and test

```bash
swift test                                   # macOS host; ~8 s (OSLogStore reads are slow on macOS)
swift test --filter DebugTraceServerTests    # one suite

# Device SDKs. -sdk is required: without it xcodebuild prints BUILD SUCCEEDED and compiles nothing
xcodebuild -scheme DebugTrace-Package -sdk xros      -destination 'generic/platform=visionOS' build
xcodebuild -scheme DebugTrace-Package -sdk iphoneos  -destination 'generic/platform=iOS' build
xcodebuild -scheme DebugTrace-Package -sdk appletvos -destination 'generic/platform=tvOS' build
```

The tests use `/usr/bin/unzip` to check the zip writer, and `node` (if present) to prove the
store's Node-side Ed25519 verify accepts what CryptoKit signs.

## The API is designed for a language model reading it cold

The server's main client is an LLM using `curl` or MCP. Keep these properties when adding
anything:

- **Self-describing.** `GET /` lists conventions and every endpoint, each with typed
  parameters, defaults, ranges and a runnable `curl` line. `?endpoint=<name>` narrows it
  to one. Help stays unauthenticated so a model can learn how to authenticate.
- **One envelope.** A success is `{ok: true, endpoint, elapsedMs, data}`. A failure is
  `{ok: false, error: {code, message, hint, details?}}`. **Every error needs a `hint` that
  says what to do next.** A model retries a hintless error verbatim.
- **Arguments are declared, validated and coerced** (`DebugParameter`). An unknown name
  gets a "did you mean". A type, choice or range violation is a 400. Nothing is silently
  ignored: the old servers ignored `?pos_x=` and a model saw a plausible result for a call
  that did nothing.
- **Queries vs commands.** Queries are GET, read-only, and marked `readOnlyHint` for MCP.
  Commands are POST, and `destructive: true` marks `destructiveHint`. GET on a command is a
  405 whose hint is the exact POST `curl` line.
- **Commands return the resulting state**, not just `ok`.
- **Naming.** Endpoint names are camelCase (`^[a-z][A-Za-z0-9]{0,47}$`, valid as MCP tool
  names and path segments). Built-ins start with `_`. JSON keys are camelCase with the unit
  in the name (`elapsedMs`, `footprintBytes`). No key-encoding strategy is applied, because
  `convertToSnakeCase` also rewrites dictionary keys, which are data. Times are ISO 8601
  UTC with milliseconds everywhere (`DebugTime.iso`).
- **Replies are redacted by default** (`DebugRedactor.standard`). The reader's transcript
  is a leak path too; see `~/Memory/home/feedback/redact_config_reads.md`.
- **MCP** is JSON-RPC over streamable HTTP at `POST /mcp`, answering every request with a
  single JSON body. It is stateless: no session id, no SSE (`GET /mcp` is a 405, which the
  spec allows). Tool failures are `isError: true` results, so the model sees the hint.
  Only malformed JSON-RPC gets a protocol error. Images come back as MCP image content.
  Protocol versions supported: 2025-06-18, 2025-03-26, 2024-11-05.

Built-ins every app gets: `_info`, `_logs`, `_features`, `_snapshot`, `_trace`. Traces made
over HTTP download from `GET /_traces/<id>.zip`. `_tools` and `_call` are plain-HTTP
spellings of MCP's `tools/list` and `tools/call`.

## Security model

- **Token.** `Authentication.automatic` (the default) takes `DEBUGTRACE_TOKEN` from the
  launch environment, which `bas --mcp` sets to a fresh per-launch token recorded only in
  that session's record. A bundle credential's `CommandToken` is the fallback; build-and-sign
  no longer writes one. With neither, the server is open.
- **Loopback is not exempt:** on iOS, other apps on the same device can reach 127.0.0.1.
- **Browsers are refused.** Any non-GET request carrying `Origin` gets a 403, so a web page
  can't POST commands through the user's browser. No CORS headers are sent. The old server
  sent `Access-Control-Allow-Origin: *`, which let any page read state.
- **Binding.** `.network` prohibits cellular. `.loopback` is loopback only.

## Logging and privacy

Apps log through **`DebugLogger`**, a drop-in for `os.Logger`: the same method names and
the same `\(value, privacy: .public)` spelling, so switching an app means changing its
logger declarations, not its call sites. Each line goes to two places:

- **`DebugLogBuffer.shared`**, an in-memory ring capped by count and bytes (default 5,000 /
  2 MB). It holds every level including debug, for the whole run. Nothing is written to disk,
  because the user ruled out disk persistence (SSD wear). Reading it is a lock and a copy,
  so the console tails it live and `_logs` defaults to it.
- **The unified log**, with hidden values already withheld, so Xcode and `log stream` still
  see every line. Private values never reach the OS log, in either mode.

`OSLogStore` is only for what the app doesn't control: Apple frameworks and packages still
on `os.Logger`. It's read on demand only (`_logs source=system`, `system-log.txt`), because
every read makes `logd` scan its whole archive. Polling it once a second slowed visionOS
apps to a crawl (fixed in RAVEConsole 2026-09-29, before the buffer existed).

**Privacy is the design constraint, not a filter bolted on.** Cloud LLMs read these logs
over the server, and the same traces are meant for App Store user support.

- **`privacy:` levels follow os_log.** `.auto` (the default) makes numbers and bools public
  and everything else private. `.private` shows only on the device's own screen in
  development mode. `.sensitive` is never stored at all. `mask: .hash` gives a short
  HMAC under a key made fresh at each launch: equal values match within a trace, but can't
  be joined across traces.
- **Every export withholds hidden values, then runs `DebugRedactor`**, which catches secrets
  a call site wrongly marked `.public`. Exports are traces, server replies, the console's
  copy button and the OS log. `contains` searches match the redacted text, so a search
  can't probe a hidden value.
- **Breadcrumb details are stored redacted** (they persist on disk), and event names must
  be code identifiers.
- **`DebugPrivacyMode`.** `.development` keeps private values in the buffer for the local
  console. `.release` drops them the moment they're logged and turns off debug capture by
  default. Release traces also carry only `releaseSafe: true` endpoints (the others are
  named in `withheldInRelease`) and no system log. `_logs source=system` is refused, and
  `DebugTraceServer.start()` throws unless `allowedInRelease`. The mode is detected: an
  App Store or TestFlight install (no embedded provisioning profile, or a Mac App Store
  receipt) is release. Detection fails safe: anything not provably a development build is
  release.
- **`includesSystemLog: false` keeps the unified log in the app entirely**, in development
  too: no `system-log.txt` in traces, and `_logs source=system` is refused. Set it when a
  linked framework may log people (RegentChat does, for LiveKit's participant and room
  lines). The app's own `DebugLogger` lines are unaffected.
- **The person sending a trace can read it first.** `DebugTraceView` opens every text file,
  and in release mode it describes the trace in end-user terms.

**`build-and-sign --log`** launches the app through `devicectl --console` and writes what it
prints to `build/device-console.log`, which an LLM reads. When the app contains DebugTrace
(the script greps the binary for the `DEBUGTRACE_STDERR` marker), it sets
`DEBUGTRACE_STDERR=1`. `DebugLogMirror` then writes each app line to stderr in `logs.txt`
format: only the app's lines, debug included, exported and redacted, in place of the whole
unified log. `--log-all` mirrors the whole unified log instead.

## The debug server runs only when asked for: `bas --mcp`

Every app links `DebugTraceServer` and calls `DebugTraceServer.startIfRequested()` once at
launch. The server starts only when the launch environment has `DEBUGTRACE_SERVER=1`, in a
development build, and only `build-and-sign --mcp` sets that. Every other launch, including
a relaunch from the home screen, runs no server, so MCP use is explicit. There are no in-app
toggles.

- **Ports are not identities.** The server takes the first free port in 8642–8691, so several
  apps can serve at once. Nothing maps ports to apps.
- **The registry is on the Mac, next to the pid files.** `bas --mcp` implies `--log`. The
  `devicectl --console` process it starts exits when the app does, so its pid is the
  session's liveness. After launch, `bas` reads the port from the server's
  `listening on port N` line and finds a reachable host: the device name lowercased first,
  which is its tailnet name (`avp`), then the CoreDevice tunnel address. It records the
  session in `~/.local/state/debugtrace/sessions/<bundle id>@<device>.json` with that pid.
- **One MCP entry for every agent.** `apps` runs `Tools/debugtrace-mcp`, a stdio server with no
  dependencies. It is registered at Claude Code user scope, and `agents-sync` copies it to
  Codex and Copilot. It reads the sessions on every call, drops those whose pid is gone, and
  checks `_info` so a reused port can't misroute. Its four tools never change: `apps`,
  `help`, `call` and `trace`. So an agent session that started before the app launched still
  works.
- **Auth needs no agent configuration.** `bas` keeps one token in
  `~/.config/debugtrace/token` (mode 600) and passes it as `DEBUGTRACE_TOKEN`.
  `Authentication.automatic` requires it, and `debugtrace-mcp` reads the same file.
- **App Store review sees nothing.** Nobody can set a launch environment on a store build,
  and `start()` refuses in release mode anyway. The Local Network prompt (binding a listener)
  therefore appears only in `bas --mcp` launches, and every app still needs
  `NSLocalNetworkUsageDescription` for those.

Keep the `listening on port N` wording and both marker strings (`DEBUGTRACE_STDERR`,
`DEBUGTRACE_SERVER`): the script depends on them.

When adding an endpoint, mark it `releaseSafe` only if its data has no personal content:
versions, counts, modes, health, error states. File names, URLs, account names, message
text and locations are personal.

## The trace

The layout is documented in `DebugTraceBuilder` and in the `README.md` written into every
zip. Signing:

- `manifest.json` lists the SHA-256 of every other file.
- `manifest.sig` is a raw 64-byte Ed25519 signature over manifest.json's exact bytes.
- The signature travels inside the zip, so a file shared by AirDrop and later dropped into
  the store verifies the same way as a direct upload.

A verifier must reject any file not listed in the manifest.

**Wire formats that other repos depend on**, so change them only together with those repos:

- `DebugTraceCredential.plist` (`Version`, `KeyID`, `SigningKey`, `UploadURL`; optional
  `CommandToken`) is written by `~/bin/build-and-sign` (Step 4.7) into every dev build of an
  app that links DebugTrace, whatever the launch flags, so Upload always works. Not for
  `--distribution`. The public half goes to the key ledger,
  `~/.local/state/debugtrace/keys/<keyId>.json`, which the appstore verifies against.
- `format: "debugtrace/1"`, the manifest keys and `manifest.sig` are verified by the
  appstore server (`~/Projects/appstore/server.js`).
- The upload is a POST of the zip body, `Content-Type: application/zip`, with
  `X-DebugTrace-Id` and `X-DebugTrace-Key-Id` headers, to `POST /api/traces`. The store
  answers `{error: "why"}` on refusal; `DebugTraceView` shows that reason. Verified traces
  land unpacked in `~/Projects/appstore/data/traces/<traceId>/files/`.

**Limits, which no code here can lift:**

- The buffer and `OSLogStore` both cover only the current run. `DebugBreadcrumbs` is the one
  thing that persists across launches, so a crash's lead-up lives there.
- `OSLogStore` never returns `.debug` entries and loses `.info` ones within minutes. That's
  why the app's own lines come from the buffer instead.

## Isolation

- `DebugSurface` and the server are `@MainActor`, like the servers they replace, so
  handlers read app models race-free.
- `DebugTrace.mark` / `begin` / `end` are **lock-guarded and synchronous**, callable from a
  render thread or a network callback. Do not make them async or actor-isolated, for the
  same reason as RAVEEngine's collection layer. Marks are file appends: feature-level
  events only, never per frame.

## Consumers and rollout (as of 2026-10-02)

Done: this package; Oneiros and spatial-ai-character on `DebugTraceServer`, with
`RAVEDebugServer` deleted and a `DebugTraceButton` in RAVEConsole; every RAVE app on
`DebugLogger` and `startIfRequested`; build-and-sign keys, the key ledger, and the appstore's
verified upload and Traces view. Not yet done:

4. Typed per-app providers. Raven's `LabControlServer`. The apps outside RAVE (web-yt-dlp,
   RegentChat; worldcast needs `NSLog` → `Logger` first).
