# Inspecting a running app

When an app is in a bad state (a view that is blank, clipped, stale or missing), these are the
tools, in the order to reach for them. All of them go through the `apps` MCP tools (`call`).

| Question | Tool |
|---|---|
| What did the app log, and what led up to it? | `_logs` (live tail with `afterSequence`/`waitSeconds`), `_features` (breadcrumbs, survive a crash) |
| What does it look like? | `_screenshot` |
| What is on screen, as text, and where? | `_screen` |
| What does the model behind the view hold? | an endpoint the app registered, or `inject` with `run` (evaluates Swift in the live app) |
| Is it hung or spinning? | `_profile` (`threads=all`) |
| Is memory the problem? | `_memory` before and after |
| Why does a SwiftUI `body` re-run, or not? | patch in `let _ = Self._printChanges()` with `inject`, plus `@PatchRefresh` ([live-patching.md](live-patching.md)) |
| Did it crash? | the `.ips`: `xcrun devicectl device info files --domain-type systemCrashLogs` |

## `_screenshot` and `_screen`

Both are queries on development builds only. They are **not** `releaseSafe`: the server does not
register them in a release build, the confidential profile refuses them, and traces never carry them.

**`_screenshot`** returns a PNG (an image in MCP). `window` is an index from `_screen` (default 0);
`scale` is pixels per point (0.25 to 3); `background` is what is drawn behind the window.

- **visionOS:** drawn with `CALayer.render(in:)`. `drawHierarchy` returns a blank image for a visionOS window
  (measured on a Vision Pro, xrTimer, 2026-10-07), because the system renders the content. A visionOS
  window is glass with no backdrop of its own, so the default `background=auto` fills dark: without it
  white text vanishes on a white page. Use `light` or `transparent` if you want those.
- **iOS and tvOS:** `drawHierarchy`. Standard, but not yet checked on a device here.
- **macOS:** the content view's cached display.
- **Not captured:** content a renderer composites itself (RealityKit, Metal, an immersive space). The
  window is there; that content is blank. An immersive-only app has no window at all and the reply says so.

**`_screen`** returns the accessibility tree per visible window: each element's `label`, `value`, `hint`,
`traits` and `frame`, nested as the app nests them. It shows which views exist, what they say and where
they sit, which is usually enough to find the odd one. On a Vision Pro it listed xrTimer's SwiftUI
elements ("No Timers", the "New Timer" button) with frames. A view with no accessibility content
(decoration, an unlabelled image) is absent: pair it with `_screenshot`.

## The prompt

Showing the screen needs the person at the device, like patching, but asked a little differently:

- **Every call asks**, with "Allow This Capture" or "Don't Allow". A decline covers that call only.
- **"Allow for 15 Minutes"** lets that client capture without asking again for 15 minutes, for both
  tools. It is remembered in memory only (not across launches), per client name, and covers nothing but
  screen capture: patching still asks for every patch.
- Debug access must already be allowed; the capture prompt comes on top of it.

An agent should therefore capture when it needs to see something, not poll. A reply that says it is
waiting means the prompt is open on the device: ask the person to tap, then retry.
