# Bud

A native macOS assistant that lives in a floating Liquid Glass panel. Chat with
DeepSeek, connect any MCP server, browse a marketplace of them, delegate to
subagents, and let the model draw its own interface when prose is the wrong
shape.

Built for macOS 26 with Swift 6 strict concurrency. No third-party packages.

---

## What it does

**Floating glass panel.** An accessory app — no Dock icon. Summon it with `⌥⌘B`
from anywhere, drag it by its header, and it stays on top across Spaces without
stealing focus from whatever you were typing in.

**Chat that shows its work.** Reasoning streams into a collapsed disclosure,
tool calls appear as live rows with their arguments and results, and the answer
renders as markdown. Nothing is hidden behind a spinner.

**Any MCP server, one click.** Local `stdio` servers and remote
`streamable-http`/`sse` servers are both first-class. Connect with a command
line or a URL; Bud namespaces their tools as `mcp__<server>__<tool>` so two
servers can both expose `search` without colliding.

**Marketplace.** Browses the official MCP registry
(`registry.modelcontextprotocol.io`) — search, inspect, and install a server
without leaving the app. npm packages become `npx -y <pkg>`, PyPI packages
become `uvx <pkg>`, and remote servers just need their URL. Required environment
variables are surfaced as fields before install.

**Subagents.** Ask Bud to split work and it runs each slice concurrently in a
fresh context with its own tool loop, then reports back. The Agents tab shows
every run live — state, duration, tool calls, streamed reasoning.

**Generated interfaces.** For comparisons, dashboards and status reports, the
model emits a declarative UI spec instead of a wall of text: cards, metrics,
tables, charts, progress, callouts, code, images and buttons. Buttons can carry
a follow-up prompt, so a generated surface can drive the conversation.

**Local capabilities out of the box.** `read_file`, `write_file`, `list_files`,
`run_shell` and `web_fetch` are built in, so Bud is useful before you connect
anything.

---

## Requirements

- macOS 26.0 or later (Liquid Glass)
- Swift 6.2+ toolchain
- A DeepSeek API key

No Xcode required — the build uses SwiftPM and assembles the app bundle directly.

---

## Build

```bash
git clone <repo> bud && cd bud
./Scripts/build-app.sh          # -> build/Bud.app
open build/Bud.app
```

Debug build: `./Scripts/build-app.sh debug`

---

## Configuration

Bud reads configuration in this order, highest priority first:

| Source | Purpose |
|---|---|
| `~/.bud/config.json` | Bud's own settings |
| `~/.omp/agent/config.yml` | Your existing oh-my-pi setup (`modelRoles.default`) |
| built-in defaults | `deepseek-v4-flash` |

The API key is resolved from `~/.bud/config.json`, then the environment, then
your shell profile (`~/.zshrc`, `~/.zprofile`, …). The shell fallback exists
because an app launched from Finder inherits no shell environment — without it,
a first launch would appear to have no key even though your terminal does.

MCP servers persist to `~/.bud/mcp.json`. Both files are written with `0600`
permissions since they can hold credentials.

Models: `deepseek-v4-flash` (fast) and `deepseek-v4-pro` (deep). Reasoning effort
is picked up from the `:max` style suffix in your oh-my-pi config.

---

## Usage

| Action | How |
|---|---|
| Summon / hide the panel | `⌥⌘B` |
| Hide | `Esc` |
| Send | `Enter` |
| Newline | `Shift``Enter` |
| Stop generating | Stop button, or `/stop` |
| Switch model | Header model chip |
| Slash commands | Type `/` in the composer |
| Settings | `⌘,` |

Slash commands: `/clear`, `/tools`, `/settings`, `/mcp`, `/marketplace`,
`/agents`.

### Driving Bud from outside

Bud registers a `bud://` URL scheme, so anything that can open a link can talk to
it — Shortcuts, a shell alias, a script, a calendar alert.

```bash
open "bud://ask?text=Summarise%20my%20Downloads%20folder"   # opens the panel and sends
open "bud://toggle"                                          # show or hide the panel
open "bud://new"                                             # start a fresh transcript
```

The text is percent-encoded like any URL query value. Unrecognised routes are
ignored rather than opening the panel into an undefined state.

---

## Architecture

```
Sources/Bud/
├── BudApp.swift              app scenes, menu bar, lifecycle
├── AppModel.swift            root observable state, subsystem wiring
├── Core/
│   ├── BudConfig.swift       config resolution (oh-my-pi + local override)
│   ├── JSONValue.swift       dynamic JSON used by every wire format
│   ├── Domain.swift          transcript model: Turn / Segment / ChatMessage
│   ├── ChatBackend.swift     streaming backend contract
│   ├── DeepSeekClient.swift  SSE client, reasoning + tool-call deltas
│   ├── AgentRuntime.swift    the agent loop: stream, call tools, repeat
│   ├── ToolProvider.swift    tool contract + namespacing registry
│   └── NativeTools.swift     file, shell and web tools
├── MCP/                      JSON-RPC, stdio + HTTP transports, manager
├── Marketplace/              registry client, store, browser UI
├── Subagents/                concurrent supervisor + roster UI
├── GenUI/                    UI spec language, renderer, render_ui tool
├── UI/                       glass design system, chat, settings, panel
└── SelfTest/                 offline assertion suite (`--self-test`)
```

Three design decisions worth knowing:

**One loop, two projections.** The agent loop produces a model-facing
`[ChatMessage]` history and a user-facing `[Turn]` transcript from the same
sequence of events. They are not derived from each other on demand — both are
appended as events arrive — because the two have genuinely different shapes: one
assistant turn expands into a message carrying `tool_calls` plus one `tool`
message per result.

**Tool calls in a round run concurrently.** The model asking for several tools at
once is the definition of independent work. Results stream into the transcript as
each finishes, so a fast tool appears while a slow sibling is still running.

**Provider identity is namespaced, routing is by lookup.** Every tool name is
sanitised into the model-legal `^[a-zA-Z0-9_-]{1,64}$` space and mapped back
through a routing table, so an MCP server can expose tools with names the API
would otherwise reject.

---

## Verification

```bash
swift build
./.build/debug/Bud --self-test        # 105 checks, offline, deterministic
./.build/debug/Bud --verify-live      # 36 checks, live network + real MCP process
./.build/debug/Bud --verify-ui        # 16 checks, launches the real panel
./.build/debug/Bud --render-ui /tmp/ui  # writes a PNG of every surface
```

**`--self-test`** covers the surfaces where a silent bug is expensive: SSE frame
decoding (including the terminal frame that carries `finish_reason` *and* `usage`
together), the DeepSeek wire shape, JSON number encoding, MCP tool namespacing,
oh-my-pi config parsing, glob semantics, HTML-to-text extraction.

**`--verify-live`** drives the real `AppModel`, `MCPManager`, `ToolRegistry` and
`AgentRuntime` against the live DeepSeek API, the live MCP registry, and a real
MCP server process. The MCP half runs against this binary's own
`--mcp-echo-server` mode, so it needs no npx, uvx, node or python — it exercises
process spawning, JSON-RPC framing, the initialize handshake, tool discovery,
namespacing and `tools/call` for real, hermetically.

**`--verify-ui`** launches the actual floating panel and inspects the committed
layer tree. It asserts `CABackdropLayer` and the `SDF*` layers exist, which is
stronger than a screenshot for the thing that matters: a window that merely
*looks* translucent while the platform silently fell back to a grey fill would
pass visual review but cannot pass this. It exists because `screencapture` needs
the Screen Recording permission, which a terminal-launched process does not have.

**`--render-ui`** writes a PNG of every surface — transcript rows, all six
settings tabs, the marketplace, the subagent roster and a generative-UI panel —
over a desktop-like gradient so layout, spacing, typography and contrast can be
reviewed. It reports the number of distinct colours per surface and flags a blank
one rather than silently writing an empty file.

Two limits are worth knowing, because both can be mistaken for product bugs:

- **The backdrop is never composited.** `cacheDisplay` and `ImageRenderer` draw the
  view tree, not the window server's output, so the glass renders as a tint over
  whatever is behind it in the image rather than refracting a desktop. Glass
  content itself does draw — measured directly: a plain text node yields 87
  distinct colours, the same node with `.glassEffect` yields 84, and a glass
  sibling of a text node yields 98. Use `--verify-ui` and a real screenshot for
  appearance; use this for layout.
- **Some surfaces come out blank, and that is not a defect.** The harness prints
  `BLANK` rather than claiming success. Observed on the empty chat surface and on
  a lone user transcript row, while the same rows render correctly inside a
  populated transcript and the empty surface renders correctly in the running
  app. The cause is AppKit layout that only completes once a window is actually
  ordered on screen; an offscreen capture cannot reproduce it. Treat `BLANK` as
  "not verifiable this way", not as a failure.

To capture real pixels, grant Screen Recording to your terminal and use
`screencapture -x out.png` — note that on macOS 26 `-l<windowid>` and `-R<x,y,w,h>`
were both unreliable here, so capture the full screen and crop.

### Working without Xcode

This project builds with the Command Line Tools alone. That has one consequence
worth knowing before you edit a view:

> **Use `@BudState`, not `@State`.**

In the macOS 26 SDK, `@State` resolves to a *macro* (`SwiftUIMacros.StateMacro`),
and the plugin implementing it ships only inside Xcode. A Command-Line-Tools-only
toolchain lacks it, so every `@State` fails with "plugin for module
'SwiftUIMacros' not found".

`SwiftUICore.State` — the actual property-wrapper struct — is still public, and a
macro only wins the name `State` in attribute position. `Sources/Bud/Core/SwiftUICompat.swift`
therefore aliases it:

```swift
public typealias BudState = SwiftUICore.State
```

Same implementation, same semantics, working `$` binding projections. Every other
wrapper is unaffected and should be used unqualified: `@StateObject`,
`@ObservedObject`, `@EnvironmentObject`, `@Environment`, `@Binding`,
`@FocusState`, `@AppStorage`, `@SceneStorage`, `@Bindable`. `#Preview` is also a
macro and does not compile here — it is not used anywhere in this codebase.

If you install Xcode, `@State` starts working again and `@BudState` keeps working
too. Pick one spelling per codebase; do not mix.

---

## Licence

Private project.
