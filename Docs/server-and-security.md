# The debug server: when it runs and how it is secured

Who can reach an app's debug server, how, and what protects it. Read before changing
authentication, approval, discovery or the confidential profile.

## When the server runs

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
    app's windows registers one (visionOS 26 / macOS 15); use it in **every visionOS app** (all of the
    portfolio's do, as of 2026-10-07): it opens as a utility panel in front of the person, while a UIKit
    alert attaches to the frontmost window, where 3D content (Hypnos's 3D player) hides it, and an
    immersive-only app has no window for it at all. `.custom(_:silence:)` is for
    an app's own UI; `.allowAll` is for tests. `debugtrace-mcp` calls itself "An agent on
    <host>" (`DEBUGTRACE_CLIENT_NAME` overrides), the appstore page "App Store page on <host>".
- **Three questions, asked differently.** Debug access (above) is asked once per client, optionally
  for the build. **Code changes** (`_inject`) are asked for every patch and never remembered
  ([live-patching.md](live-patching.md)). **Screen capture** (`_screenshot`, `_screen`) is asked for
  every call, with "Allow for 15 Minutes" as the only way to skip asking again
  ([inspecting-a-running-app.md](inspecting-a-running-app.md)). Each is its own `DebugApprovalRequest.Purpose`;
  allowing one says nothing about the others, and a decline of the latter two does not count toward the
  silence offer.
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

**The approval prompt chimes** (`Configuration.approvalSound`, default on): it is easy to miss on a
headset, so it plays a three-note descending mallet chime when shown (the code-changes prompt instead plays two sharp 1568 Hz pulses, xrTimer's interval beep, so it is told apart by ear) and every 8 s while unanswered. It is an
`AudioServices` alert sound: an `AVAudioPlayer` activates the app's audio session and **pauses
music in other apps** (seen on the Vision Pro, even with `mixWithOthers`); an alert sound only
ducks it.

## Confidential profile

`Configuration.confidential` (pass it to `startIfRequested(configuration:)`) is
default-deny: the server serves only queries marked `releaseSafe` (so `_info`, `_features` and the app's
own content-free ones) and **no command at all**, which also keeps `_inject` out and stops the patch
runtime loading. `_logs`, `_snapshot`, `_trace`, trace downloads and any other endpoint answer 404
like an unknown name, and the help and tool lists omit them. It limits what can be asked, not what a
safe endpoint returns, so keep the seeded-value leak test. RegentChat uses it (2026-10-07).

RegentChat adopted it on 2026-10-03 under a stricter rule than the default: two read-only,
content-free queries, `includesSystemLog: false`, the extension left unlinked, and a test
that seeds personal values and fails if one reaches a reply. Copy that shape for any app that
carries private messages.
