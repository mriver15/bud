# Bud

A native macOS assistant that lives in a floating Liquid Glass panel. Chat with
any provider, connect any MCP server, browse a marketplace of them, delegate to
subagents, and let the model draw its own interface when prose is the wrong
shape.

Built for macOS 26 with Swift 6 strict concurrency. No third-party packages.

---

## What it does

**Lives in the menu bar.** Bud is an accessory app with no Dock icon, and it puts
**nothing on screen until you ask**. Launch it and you get a sparkle in the menu
bar — no window, no corner bubble, nothing to dismiss. Summon the panel with
`⌥⌘B`, from the menu bar, or with a `bud://` link; `Esc` or `⌥⌘B` puts it away
again.

If you want it within reach while you work, the panel's collapse control parks it
as a small glass bubble in a screen corner — showing a spinning ring while it
streams, one click from the composer. Drag it to any corner and it snaps there.
That state is only ever entered deliberately; nothing puts a window back on your
screen after you have dismissed it.

**Chat that shows its work.** Reasoning streams into a collapsed disclosure,
tool calls appear as live rows with their arguments and results, and the answer
renders as markdown. Nothing is hidden behind a spinner.

**Any MCP server, one click.** Local `stdio` servers and remote
`streamable-http`/`sse` servers are both first-class. Connect with a command
line or a URL; Bud namespaces their tools as `mcp__<server>__<tool>` so two
servers can both expose `search` without colliding.

**Marketplace, with two sources.** Browse the official MCP registry
(`registry.modelcontextprotocol.io`) — npm packages become `npx -y <pkg>`, PyPI
packages become `uvx <pkg>`, and required environment variables are surfaced as
fields before install. Or switch to **Glama**, which indexes hosted connectors.
Connectors install in one click over HTTP; entries that publish no run command
are linked instead of being given a fabricated one.

> **Glama's API Data License is not public domain.** It requires a visible credit
> to Glama on any screen showing its data, and a link from *every individual
> record* back to that record's own Glama listing. Bud implements both — the
> credit sits on the marketplace pane and each card carries a "View on Glama"
> link. If you need a surface where no visible credit fits, Glama offers a
> commercial licence that waives this.

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
- An API key for a hosted provider, or a local runtime such as Ollama (no key)

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

The Glama source needs an API key from `glama.ai/settings/api-keys`, resolved
from the stored config, then `GLAMA_API_KEY`, then your shell profile. Without
it the Glama pane shows a call to action rather than an error; the official
registry needs no key and works regardless.

### Providers

Bud speaks three wire protocols, which between them cover roughly 85% of the
providers in the [models.dev](https://models.dev) catalogue and ~92% of its
models:

| Dialect | Providers |
|---|---|
| OpenAI-compatible | 175 of 217 — including several with nothing to do with OpenAI |
| Anthropic Messages | Anthropic and gateways that resell Claude |
| Google Generative AI | Gemini |

Twenty-three hosted endpoints are configured out of the box (DeepSeek, OpenAI,
Anthropic, Gemini, OpenRouter, Groq, Mistral, xAI, Together, Cerebras, and the
rest — Bedrock counted twice, since AWS serves chat completions and Claude over
different routes), plus Ollama, LM Studio and llama.cpp for local models.
**Anything else works through the custom entry**, which needs nothing but a base
URL and a key — that is the whole point of splitting the transport from the
provider: a new OpenAI-compatible endpoint needs no code.

Keys, base URL overrides, model choice and region are all stored **per
provider**, so switching back and forth never asks you to re-enter anything, and
never carries one vendor's model id to another. Keys resolve from stored config,
then the environment, then your shell profile — the profile fallback is what
makes a Finder launch work, since it inherits no shell environment.

Amazon Bedrock is supported; Google Vertex is not, for different reasons.

**Bedrock** is two entries, because AWS splits it. `Amazon Bedrock` speaks the
OpenAI dialect on the `bedrock-runtime` endpoint, and `Amazon Bedrock (Claude)`
speaks the Anthropic Messages dialect so Claude is reachable natively — AWS does
not serve Claude over chat completions. Both take a Bedrock API key rather than
AWS credentials, and both ask for a region, because the region is part of the
host. Model IDs are cross-Region inference profiles, such as
`us.openai.gpt-5.6-sol` or `us.anthropic.claude-sonnet-5`; which models speak
chat completions at all is in [AWS's compatibility
table](https://docs.aws.amazon.com/bedrock/latest/userguide/models-api-compatibility.html).

**Vertex** is the one that genuinely does not fit. It accepts only Google Cloud
credentials — an Application Default Credentials chain, or a service-account
token that has to be exchanged and refreshed — and never a bearer key. That is an
authentication problem rather than a dialect one, so it is a different feature
from speaking a wire protocol.

---

## Usage

| Action | How |
|---|---|
| Show or hide the panel | `⌥⌘B` |
| Put it away | `Esc` |
| Park it in a corner as a bubble | The collapse control in the panel header |
| Move the bubble to another corner | Drag it and release |
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
open "bud://collapse"                                        # collapse to the corner bubble
open "bud://expand"                                          # open the full panel
open "bud://toggle"                                          # whichever is the other one
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
│   ├── BudConfig.swift       config resolution, per-provider keys and models
│   ├── JSONValue.swift       dynamic JSON used by every wire format
│   ├── Domain.swift          transcript model: Turn / Segment / ChatMessage
│   ├── ChatBackend.swift     the streaming contract every dialect implements
│   ├── AgentRuntime.swift    the agent loop: stream, call tools, repeat
│   ├── ToolProvider.swift    tool contract + namespacing registry
│   └── NativeTools.swift     file, shell and web tools
├── Providers/
│   ├── ProviderRegistry.swift          known providers, dialects, env vars
│   ├── ProviderCredentials.swift       resolved credentials + the factory
│   ├── OpenAICompatibleBackend.swift   175 of 217 providers
│   ├── AnthropicMessagesBackend.swift  Anthropic Messages
│   └── GoogleGenerativeAIBackend.swift Gemini
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
together), the OpenAI wire shape, provider registry integrity, the
single-provider config migration and its round trip, MCP tool namespacing,
oh-my-pi config parsing, glob semantics, HTML-to-text extraction.

**`--verify-live`** drives the real `AppModel`, `MCPManager`, `ToolRegistry` and
`AgentRuntime` against the live provider API, the live MCP registry, and a real
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

### Design system

Every gap and every type size comes from a constrained scale in
`Sources/Bud/UI/GlassKit.swift`. A value off the scale is a bug: arbitrary
numbers are what make a dense interface feel subtly unaligned, even when no
single element looks wrong.

| | |
|---|---|
| `Bud.Space` | `hairline` 2 · `xs` 4 · `snug` 6 · `sm` 8 · `md` 12 · `lg` 16 · `xl` 24 |
| `Bud.Font` | `hero` 20 · `title` 15 · `body` 13 · `callout` 12 · `caption` 11 · `micro` 10 · `mono` 12 · `metric` 26 |

Three rules follow from how the platform works, not from taste:

- **Glass is for the navigation layer, never content.** Toolbars, floating
  controls and the collapsed bubble use `.glassEffect`; message bubbles, cards,
  list rows and tables use a material fill. Apple's guidance is explicit that
  Liquid Glass floats *above* content — a chat bubble is content. Putting glass
  on it also makes the transcript shimmer as the desktop moves behind the panel.
- **Never stack glass on glass**, and group neighbouring glass controls in a
  `GlassEffectContainer` so they share one sampling region.
- **Tint only the primary action.** When everything is tinted, nothing stands out.

The header is responsive through `ViewThatFits` rather than a measured
threshold: it shows the full row, then drops the status words, then drops the tab
labels, taking the first variant that fits. No magic number, and no state that
can be one layout pass stale.

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
