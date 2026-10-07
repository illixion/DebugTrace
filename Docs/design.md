# Design decisions

Why DebugTrace is shaped the way it is, the threading rules that must hold, and where it is used.

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

See [server-and-security.md](server-and-security.md#confidential-profile) for the confidential profile that RegentChat uses.
