# Delegating an integration to an agent

Integrating an app is mechanical enough to hand to an agent working in that app's repo.
This page is the brief to give it, what to check when it reports back, and the mistakes
agents have made or are likely to make. The steps themselves are in
[integration.md](integration.md); the agent reads that page and does not need this repo's
`CLAUDE.md`.

## The brief

Give the agent this, with the app's path filled in:

> Integrate DebugTrace into `<app path>`. Read `~/Projects/DebugTrace/Docs/integration.md`
> and follow it in order, steps 1 to 4 required. Rules:
>
> - Work in the app's repo only. Do not edit `~/Projects/DebugTrace` or any shared package;
>   if something there blocks you, stop and report it.
> - Edit `project.pbxproj` by hand for the package reference (there is no tool), then run
>   `plutil -lint` and build. Never rewrite it wholesale.
> - Convert logging to `DebugLogger` in app-owned code and decide each `privacy:` label.
>   Default to private; `.public` only for values the code defines.
> - Mark each endpoint you add `releaseSafe` only if its data has no personal content, and
>   say why in a comment.
> - Build for every platform the app ships on. Run the app's tests.
> - Deploy with `build-and-sign` and verify with the `apps` MCP tools (`apps`, `help`,
>   `call _info`, `call _logs`). If a reply says it is waiting for approval, ask me to tap
>   Allow on the device, then retry.
> - Commit when done and verified (unsigned, on the default branch, no push). Report the
>   SHA and the checklist from the end of integration.md with each item ticked or explained.

Delegate several apps at once by giving each agent its own app; they share nothing but the
read-only DebugTrace checkout. Each app is its own repo, so there are no merge conflicts to
manage. Worktrees of Apple apps go through `apple-worktree`, as everywhere under `~/Projects`.

## What to check when it reports back

1. **The diff is small.** A typical integration touches `project.pbxproj`, the app entry
   point, logger declarations and, optionally, one endpoints file. A diff that rewrites the
   project file or reformats unrelated code is wrong: send it back.
2. **No secrets or personal values at `.public`.** Search the diff for `privacy: .public` and
   read each one.
3. **`apps` lists the app** and `call _info` returns the build you just deployed. Ask for the
   reply, not a statement that it works.
4. **The release path is intact.** The agent should have confirmed that a normal launch (no
   server flags) still works and that the app does not import `DebugTraceInject`.
5. **Private-content apps** (messages, accounts, health, location) use the confidential
   profile. If the agent did not raise this, ask it whether the app has private content.

## Mistakes to expect

- **Linking `DebugTraceInject`.** Not needed: `--inject` embeds the runtime.
- **Omitting `DebugApprovalWindow()` on visionOS.** The server then falls back to a system
  alert that 3D content can hide, and an immersive-only app never shows it. The symptom is
  every call replying "waiting for approval".
- **Registering endpoints off the main actor** or before the models exist.
- **Marking an endpoint `releaseSafe` to make a trace complete.** It ships to users.
- **Leaving `print`/`NSLog`** in app code and then finding `_logs` empty.
- **Building with plain `xcodebuild` and expecting the server.** The credential and token come
  from `build-and-sign`; an Xcode run listens only with `DEBUGTRACE_SERVER=1`.
- **`xcodebuild` without `-sdk`** for the package itself prints `BUILD SUCCEEDED` and
  compiles nothing.
- **Editing `Package.swift` of the app's local packages** to add the dependency, when the
  app target is where it belongs.

## When an agent is stuck

The `apps` replies carry a `hint` for every error: follow it before improvising. The
sections of [server-and-security.md](server-and-security.md) explain approval, tokens and why
a client can be refused. If the app has a layout the guide does not cover (extensions, several
targets, an app with its own server), have the agent report rather than invent a convention,
and add what is learned to [integration.md](integration.md).
