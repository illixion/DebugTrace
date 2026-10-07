# Endpoints and the API a model sees

How to register endpoints, and the properties the server keeps so that a language model
reading it cold uses it correctly. Setup is in [integration.md](integration.md#5-add-endpoints-for-the-apps-own-state-optional-the-main-payoff).

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

Built-ins every app gets: `_info`, `_logs`, `_features`, `_memory`, `_snapshot`, `_trace`; development builds with the server also get `_screenshot` and `_screen` ([inspecting-a-running-app.md](inspecting-a-running-app.md)). `_memory` is
read-only and `releaseSafe` (sizes only): footprint, peak, `availableBytes` (headroom before jetsam,
`os_proc_available_memory`), malloc totals, Metal's allocated bytes and the largest kinds of mapped
memory by dirty size; ~3 ms on a Vision Pro. Call it before and after an action to see what grew.
The server adds `_profile` (sampling profiler; in DebugTraceServer, so App Store builds, which leave the
server unlinked, carry no code that suspends threads): `seconds`, `intervalMs`, `threads=main|all`.
Per thread: busy % (leaf not in a wait), self and inclusive top functions, hottest stacks. The stack
walk is C (`DebugTraceSampler`) because nothing may allocate or touch the Swift runtime while a
thread is suspended. Frame-pointer walk; app symbols resolve through `dladdr` and are demangled,
system libraries' private symbols (`<redacted>` to `dladdr`) are named from the
device's own `dyld_shared_cache_<arch>.symbols`, which an app can read and map
(`DebugSharedCacheSymbols`; ~70 ms the first time, clean file pages, no Mac or Xcode symbol download).
Swift and C++ names are demangled. Where that file is missing (macOS) they stay `(private in <library>)`. Measured on Oneiros on a Vision
Pro: ~7 µs per sample, 113 ms total pause over 3 s of all-thread sampling. Not `releaseSafe` (the
confidential profile refuses it). Unnamed threads are listed as `unnamed thread <id>`. Traces made
over HTTP download from `GET /_traces/<id>.zip`. `_tools` and `_call` are plain-HTTP
spellings of MCP's `tools/list` and `tools/call`.

When adding an endpoint, mark it `releaseSafe` only if its data has no personal content:
versions, counts, modes, health, error states. File names, URLs, account names, message
text and locations are personal.

Queries whose arguments all have defaults are added to every trace automatically. Pass
`trace: .never` to leave one out, or `trace: .arguments([...])` to capture it with specific
arguments.
