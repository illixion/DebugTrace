# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.
It says where things are. **What the package does, how an app adopts it and why it is built this
way live in [`Docs/`](Docs/README.md)**: read the page for your task, and update that page in
the same change when behavior changes. Do not grow this file with explanations.

**DebugTrace**: one registry of debug endpoints per app, read by three consumers (the debug
trace zip, the HTTP server, the MCP endpoint). An app registers an endpoint once and it shows
up in all three. That is the whole design.

## Where the code is

| Product | Sources | What |
|---|---|---|
| `DebugTrace` | `Sources/DebugTrace` | `DebugLogger` + log buffer (`DebugLogger.swift`), `DebugSurface` registry with `DebugEndpoint`/`DebugParameter`, trace builder and zip, log reader, breadcrumbs, `DebugCrashReports` (MetricKit intake), redactor, credential. Links nothing. |
| `DebugTraceUI` | `Sources/DebugTraceUI` | `DebugTraceView`/`DebugTraceButton`, `DebugApprovalWindow`, `DebugPatchRefresh` (`@PatchRefresh` and friends) |
| `DebugTraceServer` | `Sources/DebugTraceServer` | HTTP + MCP listener, approval, `_profile` (`DebugProfiler` over the C walker `DebugTraceSampler`), `_screenshot`/`_screen` (`DebugScreenCapture`), patch-runtime loader |
| `DebugTraceInject` | `Sources/DebugTraceInject` | `_inject` / `_patches`: loads a signed patch dylib. Embedded by `build-and-sign --inject`, never linked by apps. |
| `debugtrace-mcp` | `Tools/debugtrace-mcp` | the `apps` MCP server every agent uses (stdio, no dependencies): `apps`, `help`, `call`, `trace`, `inject` |
| `debugtrace-inject` | `Tools/debugtrace-inject` | patch pipeline: the Python driver `debugtrace-inject` and the SwiftSyntax `Rewriter/` |

Tests: `Tests/DebugTraceTests`, `…ServerTests`, `…InjectTests` (Swift) and `Tests/DebugTraceMCPTests`
(Python, covers both tools). Wire formats other repos depend on: [Docs/traces.md](Docs/traces.md).

## Docs map

| Topic | Page |
|---|---|
| Adding it to an app, step by step | [integration.md](Docs/integration.md) |
| Briefing an agent to integrate an app | [delegating-an-integration.md](Docs/delegating-an-integration.md) |
| `DebugLogger`, privacy levels, release mode | [logging-and-privacy.md](Docs/logging-and-privacy.md) |
| Endpoint design rules, the envelope, MCP | [endpoints.md](Docs/endpoints.md) |
| When the server runs, tokens, approval, Bonjour, confidential profile | [server-and-security.md](Docs/server-and-security.md) |
| `_screenshot`, `_screen` and the other ways to inspect a broken app | [inspecting-a-running-app.md](Docs/inspecting-a-running-app.md) |
| `inject`, the rewriter, SwiftUI refresh | [live-patching.md](Docs/live-patching.md) |
| Trace layout, signing, upload | [traces.md](Docs/traces.md) |
| Why a separate package, isolation, consumers | [design.md](Docs/design.md) |

## Rules to keep when changing code

Each is explained in the page named; this is the checklist.

- **Every server error carries a `hint`**; arguments are declared and validated, never silently ignored
  ([endpoints.md](Docs/endpoints.md)). The same goes for `debugtrace-mcp`: it forgives a model's
  guesses (`args`/`params`/`input` for `arguments`, `name` for `endpoint`, `bundleId` for `app`, `app@device`),
  says which it accepted, and rejects others with a did-you-mean. A new tool must keep that.
- **Logging goes through `DebugLogger`** with deliberate privacy labels; exports are redacted
  ([logging-and-privacy.md](Docs/logging-and-privacy.md)).
- **`DebugTrace.mark`/`begin`/`end` stay synchronous and lock-guarded**; `DebugSurface` and the server stay `@MainActor` ([design.md](Docs/design.md)).
- **Keep the `listening on port N` wording and the markers `DEBUGTRACE_STDERR`, `DEBUGTRACE_SERVER`**: `build-and-sign` greps for them ([server-and-security.md](Docs/server-and-security.md)).
- **Nothing a stranger can read may identify the app, build or device** (Bonjour, unauthenticated `GET /`).
- **Listing apps sends no request to any app** (`apps` reads records only; a test enforces it).
- **The trace wire formats change only together with the appstore repo** ([traces.md](Docs/traces.md)).
- **A patch applies all or nothing**; `inject` says "rebuild" for anything a patch cannot do ([live-patching.md](Docs/live-patching.md)).
- **A new endpoint's `releaseSafe` is a decision**: only data with no personal content.

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

The tests use `/usr/bin/unzip` to check the zip writer, and `node` (if present) to prove the
store's Node-side Ed25519 verify accepts what CryptoKit signs.
