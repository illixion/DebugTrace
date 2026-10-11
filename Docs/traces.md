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
  (`source: MXMetricManager`) it is the `MXDiagnosticPayload`: `{crashDiagnostics: [{callStackTree,
  diagnosticMetaData: {appBuildVersion, signal, …}}], timeStampBegin, timeStampEnd}`.
  Either way it is a call-stack tree of binary UUIDs and offsets, not an `.ips`.
- **Frame trees are stored flat.** MetricKit nests a call stack one level per frame
  (`subFrames`). A 300-frame crash overflowed a Swift task's 512 KB stack while being
  encoded, which took Hypnos down mid-film and again on every relaunch while it retried
  (2026-10-11), and Foundation's coders refuse anything past 512 levels anyway. So every
  `rootFrames` (27+) or `callStackRootFrames` (older) becomes `frames`: the tree depth
  first, each frame with its `depth` (0 for a root) and no `subFrames`; a frame's children
  are the frames after it one level deeper, up to the next frame at its depth or less.
  The 27+ report is flattened as it is encoded (`JSONValueEncoder` with an intercept, on
  `DebugDeepStack`), an older payload after parsing, and a report stored nested by an older
  build when it is next read. The symbolicator reads both layouts. More generally,
  `JSONValue`'s `serialized`, `parse` and the redactor handle a value of any depth on any
  thread: past 64 levels they switch to iterative coders or a 64 MB stack
  (`JSONValueDepth.swift`).
- **Symbolicating:** `Tools/debugtrace-symbolicate <trace id>` prints the blamed thread (`--all`
  for every thread) with app frames resolved to function and line; Apple's frames stay
  `name +offset`. It reads the appstore's `data/traces/<id>/files/crashes/` and the dSYM archive.
  `build-and-sign` keeps the dSYMs of what each device is running, in
  `~/.local/state/debugtrace/dsyms/<bundleId>@<device>/` (`uuids.json` maps binary UUIDs to files):
  one slot per app and device, replaced by the next successful install to that device (the one
  it replaces stays once, as `<slot>.previous`: a crash is reported on the next launch, which may
  be of the updated build), so a
  device left on an old build can still be symbolicated after other devices and the build folder
  moved on. The slot is an APFS clone (no copy time; it costs disk only once the build folder's
  copy is overwritten, about 10 MB for xrTimer, 50–200 MB for the big apps). `--distribution`
  builds, `--no-deploy` and `--sign-only` keep nothing. By hand: match a frame's `binaryUUID` to
  `dwarfdump --uuid`, then `atos -arch arm64 -o <DWARF file> -l 0x100000000 0x100000000+<offsetIntoBinaryTextSegment>`
  (an executable's text segment starts at 0x100000000).
  Checked on xrTimer 2026-10-09: with the build folder's dSYM already replaced by a newer build,
  the archived one resolved the crash to its closure and line.
- **The `.ips` itself** (full crash log, Apple's frames symbolicated; the only report on tvOS) is
  pulled from each device by the appstore's poller (`devicectl … --domain-type systemCrashLogs`,
  also while the device is locked) and shown beside the traces. `debugtrace-symbolicate` reads an
  `.ips` too. The appstore links it to the trace of the same crash by app, pid and time.
- **Agents** reach all of this through the appstore's `bin/crash-reports` (`list`, `show`, `done`):
  `~/Projects/CLAUDE.md` tells them to look there first and, once a crash is fixed and verified, to
  move what they investigated to the Trash with `done`, never `rm`.
- No wire-format change: the store verifies any listed file, and `crashes/` is just more files.
- **Testing:** a simulator never delivers MetricKit diagnostics (checked on the visionOS 27
  simulator: the app crashed, nothing arrived in 90 s). Use a device. To exercise the pre-27
  `MXMetricManager` path on a 27 device, launch with `DEBUGTRACE_LEGACY_METRICKIT=1`
  (`devicectl device process launch --environment-variables '{"DEBUGTRACE_LEGACY_METRICKIT":"1"}'`);
  verified on the Vision Pro, 2026-10-09. Fault injection: crash once per install, then relaunch.
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
