# DebugTrace documentation

Start with the guide for what you are doing. Each page stands alone, so a person or an agent
working in another repo can read just the page it needs.

| I want to… | Read |
|---|---|
| Add DebugTrace to an app | [integration.md](integration.md) |
| Hand the integration of an app to an agent | [delegating-an-integration.md](delegating-an-integration.md) |
| Log through `DebugLogger`, decide what is private | [logging-and-privacy.md](logging-and-privacy.md) |
| Register endpoints, understand the API an LLM sees | [endpoints.md](endpoints.md) |
| Know when the server runs, who may use it, how it is secured | [server-and-security.md](server-and-security.md) |
| Find out what a broken app looks like and holds | [inspecting-a-running-app.md](inspecting-a-running-app.md) |
| Edit code in a running app (`inject`) and refresh SwiftUI | [live-patching.md](live-patching.md) |
| Understand the debug trace zip and its wire formats | [traces.md](traces.md) |
| Know why it is a separate package, its threading rules, who uses it | [design.md](design.md) |

The overview, the four products and the one-screen code example are in the repository
[README](../README.md). Contributor notes (what lives where, how to build and test) are in
[CLAUDE.md](../CLAUDE.md).

## Conventions in these pages

- **Must** and **never** are rules the code or a consumer depends on. Everything else is advice.
- Paths starting `~/` are on the maintainer's Mac (`~/bin/build-and-sign`, `~/Projects/…`).
  Another team adopting the package substitutes its own build tooling; the app-side steps do
  not change.
- A date in parentheses is when something was last verified, and on what.
