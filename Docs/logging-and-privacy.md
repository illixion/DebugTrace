# Logging and privacy

`DebugLogger`, what each privacy level does, and what leaves the device. Switching an app over is
step 3 of [integration.md](integration.md#3-switch-logging-to-debuglogger).

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
