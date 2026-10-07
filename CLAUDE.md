# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**DebugTrace**: one registry of debug endpoints per app, read by three consumers:

- **the debug trace**: a zip of logs, feature breadcrumbs, a snapshot of every traced
  query, and device info. It is shared from a sheet or uploaded to the app store server.
- **the HTTP server**, used by `curl`.
- **the MCP endpoint**, which gives an agent every endpoint as a tool.

An app registers an endpoint once and it shows up in all three. That is the whole design.

Four products:

| Product | What | Links |
|---|---|---|
| `DebugTrace` | `DebugLogger` + in-process log buffer, `DebugSurface` registry, trace builder, log reader, breadcrumbs, redactor, credential | nothing |
| `DebugTraceUI` | `DebugTraceView` / `DebugTraceButton` (capture → review → share/upload); `DebugApprovalWindow` (the server's prompt in a window of its own) | SwiftUI |
| `DebugTraceServer` | `DebugTraceServer`: HTTP + MCP over a surface | Network |
| `DebugTraceInject` | `_inject` / `_patches`: load a signed patch into the running app (live code patching, below) | `dlopen` |

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

`python3 -m unittest discover -s Tests/DebugTraceMCPTests` tests `Tools/debugtrace-mcp`.

`Tools/debugtrace-mcp` forgives the guesses a model makes: `args`/`params`/`input` for
`arguments`, `name` for `endpoint`, `bundleId` for `app`, a JSON-string `arguments`, and an
endpoint's arguments flattened next to `endpoint`. It says in the reply which it accepted, and
rejects any other name with a did-you-mean and the valid list. Keep that when adding a tool: a
silently ignored parameter runs a command with its defaults.

The tests use `/usr/bin/unzip` to check the zip writer, and `node` (if present) to prove the
store's Node-side Ed25519 verify accepts what CryptoKit signs.

## The API is designed for a language model reading it cold

The server's main client is an LLM using `curl` or MCP. Keep these properties when adding
anything:

- **Self-describing.** `GET /` lists conventions and every endpoint, each with typed
  parameters, defaults, ranges and a runnable `curl` line. `?endpoint=<name>` narrows it
  to one. Help stays unauthenticated so a model can learn how to authenticate, but without
  the token it shows only that: no app identity, no endpoint list (see "No fingerprints").
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
  launch environment, else the bundle credential's `CommandToken`. build-and-sign writes a
  per-build `CommandToken` into the credential and into the key ledger record (mode 600), and
  `bas --mcp` passes that same token, so a session and a later attach agree. With neither,
  the server is open.
- **Approval on the device.** After the token check, each client must be allowed in the app
  (`Configuration.approval`, `.ask` by default): the first request from a client name
  (`X-DebugTrace-Client`, else the User-Agent) shows "Allow debug access?" with *Allow* (this
  launch), *Always for This Build* (remembered in UserDefaults per `CFBundleVersion`) and
  *Don't Allow* (sticks for the launch). Concurrent requests share one prompt; a request waits
  up to `approvalTimeout` (60 s), then gets a 403 saying the prompt is open. Help (`GET /`)
  needs no approval, and shows the app only with the token. The name is the client's own label, not an identity: the
  token is what proves the caller holds this build's ledger, which is why a flood of made-up
  names is handled as spam rather than authenticated away:
  - **One prompt on screen at a time.** Prompts for different clients queue behind each other,
    and a queued prompt whose requests have all timed out is dropped, never shown.
  - **Silence after the second decline.** Every second *Don't Allow* is followed by "Stop
    asking for a while?": *Silence for an hour* refuses new clients without asking (403 naming
    the end time) until it expires or the app relaunches; clients already allowed keep working.
    The offer takes the declined prompt's turn, so it can't stack on the next one.
  - **The prompt's UI.** `.ask` uses a registered `DebugApprovalPresenter` first, else a system
    alert. DebugTraceUI's `DebugApprovalWindow` scene plus `.debugApprovalPrompts()` on the
    app's windows registers one (visionOS 26 / macOS 15); use it in any app that can show only an
    immersive space, where a UIKit alert has nothing to attach to. `.custom(_:silence:)` is for
    an app's own UI; `.allowAll` is for tests. `debugtrace-mcp` calls itself "An agent on
    <host>" (`DEBUGTRACE_CLIENT_NAME` overrides), the appstore page "App Store page on <host>".
- **Loopback is not exempt:** on iOS, other apps on the same device can reach 127.0.0.1.
- **Browsers are refused.** Any non-GET request carrying `Origin` gets a 403, so a web page
  can't POST commands through the user's browser. No CORS headers are sent. The old server
  sent `Access-Control-Allow-Origin: *`, which let any page read state.
- **Binding.** `.network` prohibits cellular. `.loopback` is loopback only.
- **Use Tailscale, not the LAN, from anywhere but home.** The server speaks plain HTTP, so on
  a LAN the bearer token, and the replies, cross the network in clear: anyone who can sniff
  it (open Wi-Fi, hotels, conferences) can replay the token, and copy the approved client's
  label with it. Over Tailscale WireGuard encrypts both. `bas --mcp` already prefers the
  device's tailnet name.
- **No fingerprints.** A dev build carries its server onto every network it joins, so nothing
  it shows a stranger may say which app, build or device it is. The Bonjour record and
  instance name are opaque (below), and `GET /` without the token is reduced to how to
  authenticate. A tokenless server (an Xcode run with `DEBUGTRACE_SERVER=1`) has nothing to
  gate on and shows its full help.
- **Power.** An idle listener costs nothing: a suspended app gets no CPU however many
  sockets it holds, and a connection to it isn't delivered until it resumes, so the open port
  can't wake the device. The advertisement is answered by `mDNSResponder`, which runs anyway.
  iOS reclaims a suspended app's listener; the server notices on resume and listens again.

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

## When the debug server runs

Every app links `DebugTraceServer` and calls `DebugTraceServer.startIfRequested()` once at
launch. It starts in a **development** build when either:

- build-and-sign signed it, so its credential carries a `CommandToken`. That is every launch
  of such a build, from the home screen too, so a client can **attach to an app that is
  already running** with its state intact. `DEBUGTRACE_SERVER=0` in the launch environment,
  or `DEBUGTRACE_SERVER=off` in a repo's build-signing.conf, turns this off.
- the launch environment sets `DEBUGTRACE_SERVER=1` (`bas --mcp`, or an Xcode scheme).

An Xcode run has no credential, so it listens only when asked. A release build (App Store,
TestFlight) never listens: `requested(...)` and `start()` both refuse.

- **No Local Network prompt in shipped apps.** The prompt comes from binding the listener.
  build-and-sign adds `NSLocalNetworkUsageDescription` and `NSBonjourServices`
  (`_debugtrace._tcp`) to the Info.plist of the dev builds it signs, only when absent. An app's
  own Info.plist doesn't need either key for debugging, so an App Store build of an app with no
  LAN feature carries neither and never prompts.
- **Bonjour.** The listener advertises `_debugtrace._tcp` as `debugtrace-<nonce>` with TXT
  `txtvers=2`, `n` (a random nonce, new per listener) and `t` (base64url of the first 12
  bytes of `HMAC-SHA256(token, "debugtrace-advert|" + n)`), when the Info.plist declares
  that type; iOS refuses undeclared types, so without it the server still runs,
  unadvertised. No app name, bundle id or stable id, so the record can't identify the app or
  follow the device between networks. `debugtrace-mcp` browses with `dns-sd -Z`, finds the
  ledger record whose token makes that tag, and lists the app under that record's identity.
  `txtvers=1` records from older builds, which name their `keyId`, are still recognised.
  `debugtrace-mcp discover` prints the same as JSON (no tokens) for other tools, such as the
  appstore page. Bonjour is local-network only; over Tailscale, `bas --mcp` records a session.
- **Ports are not identities.** The server takes the first free port in 8642–8691, so several
  apps can serve at once. Discovery and session records carry the port.
- **Session records** (`bas --mcp`, which implies `--log`) live in
  `~/.local/state/debugtrace/sessions/<bundle id>@<device>.json`, with the pid of the
  `devicectl --console` process as liveness. `bas` reads the port from the server's
  `listening on port N` line and finds a reachable host: the device name lowercased first
  (its tailnet name, `avp`), then the CoreDevice tunnel address. A record wins over the same
  app's Bonjour advertisement, since it also has the console log.
- **One MCP entry for every agent.** `apps` runs `Tools/debugtrace-mcp`, a stdio server with no
  dependencies, registered at Claude Code user scope and copied to Codex and Copilot by
  `agents-sync`. It reads records and browses on each call (cached 5 s), and checks `_info` so
  a reused port can't misroute. Its five tools never change: `apps`, `help`, `call`, `trace`, `inject`.
- **Live tail.** `_logs` takes `afterSequence` (a reply's `lastSequence`) and `waitSeconds`
  (long poll, up to 25 s) on the app's own buffer. The cursor is clamped to what exists.

Keep the `listening on port N` wording and both marker strings (`DEBUGTRACE_STDERR`,
`DEBUGTRACE_SERVER`): the script depends on them.

When adding an endpoint, mark it `releaseSafe` only if its data has no personal content:
versions, counts, modes, health, error states. File names, URLs, account names, message
text and locations are personal.

## Live code patching (`inject`)

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
(inheritance, generics), anything inside `#if`, new top-level declarations the rest of the app must
see. Check this before promising an edit can go live. A loaded dylib cannot be unloaded: undo by
editing back and injecting again.

**Security: signing, not the token, is the gate.** The OS loads a dylib only if the team that signed
the app signed it, so a client holding the bearer token (a sniffed LAN request, a made-up client
name) still cannot make the app run code without the signing key. On top of that: `_inject` is
`destructive`, needs the on-device approval like every command, refuses in release privacy mode,
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

**Costs to know.** Implicit-dynamic makes every call to a replaceable function indirect, so an
`--inject` build is not the shipping binary's performance (frame-budget apps: measure with a normal
build). A patch compiles per module, with that module's flags, so changes in several packages are
several dylibs. Not yet checked: SwiftUI view refresh after a patch (`DebugTraceInject.generation`
is there for `.id(...)`), generics-heavy code, iOS.

**Gotchas found building it**, so they are not rediscovered: without `-enable-testing` the
replaceable functions are `hidden` and loading fails with "symbol not found in flat namespace
…Tx"; `swiftc -emit-module-path … -o app` does not relink the executable, so emit the module
separately; an unsigned or ad-hoc dylib is refused ("missing code signature") while one signed
with the dev cert after install loads, including from the app's `tmp/`; an incremental build prints
no compile command for an up-to-date module, so `capture` keeps what an earlier build recorded
(`rm -rf build/DerivedData` if the record is missing).

**The approval prompt chimes** (`Configuration.approvalSound`, default on): it is easy to miss on a
headset, so it plays a three-note descending mallet chime when shown and every 8 s while unanswered. It is an
`AudioServices` alert sound: an `AVAudioPlayer` activates the app's audio session and **pauses
music in other apps** (seen on the Vision Pro, even with `mixWithOthers`); an alert sound only
ducks it.

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

4. Typed per-app providers. Raven's `LabControlServer`. The apps outside RAVE (web-yt-dlp;
   worldcast needs `NSLog` → `Logger` first).

RegentChat adopted it on 2026-10-03 under a stricter rule than the default: two read-only,
content-free queries, `includesSystemLog: false`, the extension left unlinked, and a test
that seeds personal values and fails if one reaches a reply. Copy that shape for any app that
carries private messages.
