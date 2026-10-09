# The debug trace

What a trace contains, how it is signed and uploaded, and the wire formats that other repos
depend on.

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

**OS diagnostics (MetricKit)** (`DebugCrashReports`): `DebugTrace.configure` subscribes to MetricKit
(`MetricManager` on 27+, `MXMetricManager` before; not on tvOS), which hands the app the crash,
hang, CPU- and disk-write-exception diagnostics of an earlier run at its next launch. Each is kept
in `Application Support/DebugTrace/Diagnostics/<id>.json` (newest 20, 14 days). Where the build has
an upload URL, the launch that receives one captures a trace and uploads it with `note` "Automatic
report: …"; the store's answer is final for a 4xx and a network failure retries at the next launch.
Turn it off with `collectsDiagnostics: false`.

- A hand-made trace carries the last week's reports as context too.
- Files are `crashes/<id>.json`: `{id, receivedAt, source, kinds, report}`, `report` being
  MetricKit's own JSON. On 27+ (`source: MetricManager`) that is `{crashDiagnostic | hangDiagnostic
  | …, environment, timeRange, version}`; the crashed build is `environment.applicationBuildVersion`,
  which can differ from the trace's `app.build` (the build that reported it). Before 27
  (`source: MXMetricManager`) it is the `MXDiagnosticPayload`, with `diagnosticMetaData` per entry.
  Either way it is a call-stack tree of binary UUIDs and offsets, not an `.ips`.
- **Symbolicating:** match a frame's `binaryUUID` to `dwarfdump --uuid <App>.app.dSYM`, then
  `atos -arch arm64 -o <dSYM>/Contents/Resources/DWARF/<App> -l 0x100000000 0x100000000+<offsetIntoBinaryTextSegment>`
  (an executable's text segment starts at 0x100000000). Checked on xrTimer 2026-10-09: an
  injected out-of-range crash resolved to its closure and line.
- No wire-format change: the store verifies any listed file, and `crashes/` is just more files.
- Measured on the Vision Pro with a `build-and-sign --no-mcp` build: the crash was delivered
  and uploaded within seconds of relaunching the app.
- MetricKit sends no report for every event (hangs need the device to be sampling), and the
  lead-up to a crash is only in `breadcrumbs*.jsonl`. The `.ips` itself stays on the device:
  `xcrun devicectl device copy from --device <d> --domain-type systemCrashLogs`.

**Limits, which no code here can lift:**

- The buffer and `OSLogStore` both cover only the current run. `DebugBreadcrumbs` is the one
  thing that persists across launches, so a crash's lead-up lives there.
- `OSLogStore` never returns `.debug` entries and loses `.info` ones within minutes. That's
  why the app's own lines come from the buffer instead.
