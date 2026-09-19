# Bud

A native macOS assistant that lives in a floating Liquid Glass panel. Chat with
any provider, connect any MCP server, browse a marketplace of them, delegate to
subagents, drive a real browser, remember things across chats, and let the model
draw its own interface when prose is the wrong shape.

Built for macOS 26 with Swift 6 strict concurrency. No third-party packages.

![Bud's panel on an empty chat: a floating glass window with a sparkle-marked header reading Bud, tabs for Chat, Agents, Browser and History, the words "Ask me something" over a one-line introduction, four suggested questions chosen by what is installed, and a composer showing the active model, reasoning effort and tool count](docs/panel.png)

---

## Contents

- [What it does](#what-it-does) — menu-bar life, reasoning visibility, MCP
  servers, marketplace, browser, delegation, generated interfaces, cost
  budgeting, skills, stored results, images, memory
- [Built-in tools](#built-in-tools) · [Trust model](SECURITY.md)
- [Requirements](#requirements) · [Download](#download) ·
  [First launch](#first-launch) · [Build](#build) ·
  [Configuration](#configuration) · [Usage](#usage) ·
  [What Bud doesn't do](#what-bud-doesnt-do) ·
  [Architecture](#architecture) · [Verification](#verification) ·
  [Licence](#licence)

---

## What it does

**Lives in the menu bar.** Bud is an accessory app with no Dock icon, and it puts
**nothing on screen until you ask**. Launch it and you get a sparkle in the menu
bar — no window, no corner bubble, nothing to dismiss. Summon the panel from that
sparkle or with a `bud://` link; `Esc` puts it away again.

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
Connectors install in one click over HTTP; directory entries publish no run
command at all, so their slugs are checked against npm and become `npx -y <pkg>`
only when the package really exists — otherwise the record is linked to its
repository rather than given a fabricated command.

> **Glama's API Data License is not public domain.** It requires a visible credit
> to Glama on any screen showing its data, and a link from *every individual
> record* back to that record's own Glama listing. Bud implements both — the
> credit sits on the marketplace pane and each card carries a "View on Glama"
> link. If you need a surface where no visible credit fits, Glama offers a
> commercial licence that waives this.

**A real browser, built in.** Bud ships a native browser — WebKit, not a bundled
Chromium — with thirteen tools covering what a Playwright install would provide,
and no Node, no `npx`, no download behind any of it. The page lives in the
Browser surface; the model reads it as an *outline* — headings, links, buttons,
fields and checkboxes, each action carrying a ref — and acts through the refs
(`browser_click`, `browser_type`, `browser_hover`, `browser_select`,
`browser_press`, `browser_scroll`), so it does what a person does: read the
labels, click the thing. Every action returns a fresh outline, so there is no
stale map to click through, and a ref that is stale or invented fails loudly
instead of clicking whatever happens to sit at that position now.

Browsing is a session, not a series of lookups. One web view lives for the life
of the app, so a sign-in survives the tool calls that follow it; a desktop user
agent keeps mobile layouts out; `file://` URLs open through the read-access path
WebKit actually allows. `browser_console` returns what the page logged and what
it threw — captured by a hook injected at document start, before the page's own
scripts run, because the error worth having is usually the one thrown while the
page is still initialising. Every action also captures a screenshot and shows it
beside the tool row: the model reads the outline, the user sees the page it
acted on. A page that never settles cannot hang the agent — loads time out at
45 seconds.

**Delegation, to something with a name.** Ask Bud to split work and it runs each
slice concurrently in a fresh context with its own tool loop, then reports back.
The Agents tab shows both halves of that: **Delegates** — everything it can hand
work to — and **Activity** — every run live, with state, duration, tool calls and
streamed reasoning.

A delegate is a name, a set of instructions, and a tool list, and they come from
three places:

| Where from | What it is |
|---|---|
| **Built in** | `scout` (read-only investigation), `reviewer` (read-only judgement), `builder` (does the work) |
| **Your skills** | Any skill with `agent:` in its frontmatter. Its body becomes the instructions and its `allowed-tools` becomes the tool list — which is what that field was always for |
| **Your MCP servers** | Every connected server, as a delegate scoped to *its own tools*. For a server that answers with three hundred rows of JSON, this is the point: something reads all of it and comes back with the six lines that mattered |

The roster is generated into `spawn_subagents`' description, so the model chooses
from what actually exists rather than from a list written down once and left to
rot. A subagent may delegate onward — one level, with children counted against
their parent's slot rather than the pool's, so nesting cannot starve the pool it
is running in.

**A server can hand its tools to its agent** (MCP → a server → Tools & log). The
main agent then carries the server's *name* instead of its schemas. On the 21-tool
server this was measured against — 17,915 tokens per request down to 5,494, a 69%
cut, reproducible with `--measure` — at the cost of a delegation per question. Off
by default, per server, because a single instant lookup is slower that way and a
bulky one is not.

**Generated interfaces.** For comparisons, dashboards and status reports, the
model emits a declarative UI spec instead of a wall of text: cards, metrics,
tables, charts, progress, callouts, code, images and buttons. Buttons can carry
a follow-up prompt, so a generated surface can drive the conversation.

**What a request costs is measured, and bounded.** Every tool is charged on every
request whether or not it is called, so `--measure` reports what the prefix carries
— split per tool group (native, browser, generated-ui, memory, skills, subagents,
and each connected MCP server), with a leaderboard of the heaviest individual
tools, and `--self-test` fails if the built-in block grows past its ceiling. At
80% of a conversation's token budget the panel warns — with *Start new chat*,
*Compact context*, or *Raise budget* on the banner rather than in a settings page.
Past 120,000 characters of conversation the oldest tool results are emptied from what the
model is sent: the user keeps seeing them, and the model is told it can call again.

**You can watch it think.** Reasoning models stream their thinking, and the
transcript shows it while it arrives and folds it away when the answer lands.
Settings → General offers *While thinking*, *Always*, or *Hidden*; opening or
closing a panel by hand overrides whichever is set, so a turn folding itself away
never closes something you deliberately opened.

**Skills load themselves, and the list ranks.** Skill bodies arrive only when one
is used — the ones installed here average around twelve thousand characters each.
The catalogue that says what is installed is ranked against the current message:
what looks relevant gets its whole description, everything else gets one line, and
**nothing is ever dropped from the list** — because the matching that would have to
drop things scores nothing at all
for "W-9" against a skill described as "PDF", and the model knows they are the same
thing. Skills may declare `metadata.triggers` to close that gap from the other
side.

**Nothing a tool returns is lost.** A result too large to send is written to
`~/.bud/store/` and the model is handed a handle rather than a truncated head with
a note saying how much is missing. `read_stored` searches it or reads a line range,
and handles are validated as handles — `store_` and eight hex characters — because
one arrives from a model and becomes a path. The transcript still shows the whole
result; only the model is bounded.

**Memory that outlives the chat.** `remember` writes something worth carrying out
of a conversation — a preference, a convention, a fact you are tired of repeating —
and `recall` reads it back. The scope decides how a note travels: `user` notes are
who you are and what you care about, and they ride in every request, because a
colleague does not forget that between sentences. `project` and `general` notes are
ranked against what you are currently talking about.

Ranked rather than filtered, which is the same argument the skill catalogue makes: a
note sharing no words with your message may still be the one that matters, and term
matching cannot know that. So the notes that score are shown in full, and the rest
are still listed one line each — `recall` reads any of them whole.

Everything it keeps is visible and deletable in Settings → Memory. Memory you
cannot inspect is indistinguishable from memory that is wrong.

**Pictures, without a picture source.** A surface that needs an image asks
`find_image` for one — one thing or a whole set in a single call. Wikipedia
answers for anything with an article, which is what a team sheet, a gallery of
places or a product comparison actually needs; anything else falls back to a
search of Wikimedia Commons. Both are keyless. Every result says where it came
from and under what licence, and says whether it is *the article for the thing*
or merely *closest file whose name matched* — because those are different
answers, and a surface showing the wrong picture is worse than one showing none.
An MCP server can still return images directly, in which case they render under
the tool row and no lookup happens.

**Local capabilities out of the box.** `read_file` (text, PDFs, and the text out
of an image), `search_files`, `write_file`, `list_files`, `run_shell` and
`web_fetch` are built in, alongside the browser and memory tools — so Bud is
useful before you connect anything.

**Every conversation is kept.** The History surface is the whole archive —
searchable, renamable, deletable — while the menu bar shortcuts the last few.

---

## Built-in tools

Everything below ships with Bud. MCP servers add their own tools, namespaced
`mcp__<server>__<tool>`; built-ins are never namespaced.

| Provider | Tools |
|---|---|
| **Bud** (native) | `read_file` — text, PDFs, and text out of images · `search_files` — regex search across folders · `write_file` · `list_files` — glob-listed paths · `run_shell` — zsh, bounded timeout · `web_fetch` — HTML to readable text · `read_stored` — search and paged reads of spilled results |
| **Browser** | `browser_open` · `browser_snapshot` · `browser_read` · `browser_click` · `browser_type` · `browser_hover` · `browser_select` · `browser_wait` · `browser_console` · `browser_press` · `browser_scroll` · `browser_back` · `browser_screenshot` |
| **Memory** | `remember` — file a fact under `general`, `user` or `project` · `recall` — bounded, line-cut reads |
| **Skills** | `skill` — load a skill's instructions by name |
| **Interface** | `render_ui` — draw a declarative surface · `find_image` — licensed pictures, Wikipedia first, Wikimedia Commons as fallback |
| **Subagents** | `spawn_subagents` — split work across concurrent, isolated runs |

---

## Requirements

- **Apple Silicon.** Bud builds and runs `arm64` only; there is no Intel build.
- **macOS 26.0 or later**, for Liquid Glass.
- **Swift 6.2 or later.** Xcode 26 or the Command Line Tools both provide one.
- **An API key** for a hosted provider, or a local runtime such as Ollama, which
  needs none. See [Configuration](#configuration) for where to put it.

No Xcode project is required — the build uses SwiftPM and assembles the app bundle
by hand. The Command Line Tools alone are enough, which is what this project is
built with.

---

## Download

[Releases](https://github.com/mriver15/bud/releases/latest) carries a built
`Bud-<version>.zip`. Unzip it, move `Bud.app` wherever you keep applications, and
open it.

The app is **ad-hoc signed, not notarised** — there is no paid developer
certificate behind this project, so the first launch needs one confirmation:
**right-click the app and choose Open**, then Open again. Double-clicking first
only tells you macOS cannot verify the developer, which is accurate. After that,
macOS remembers and it opens normally.

Updates arrive through the app itself and are checked against a key compiled into
it; a first copy is only as trustworthy as the release page you downloaded it
from. See [SECURITY.md](SECURITY.md).

---

## First launch

Bud starts with nothing configured, so the first thing it needs is a key.

1. Open it and look for the sparkle in the menu bar — there is no window.
2. Click the sparkle, then `⌘,` for Settings → General.
3. Paste a key for any provider. DeepSeek is the default; Gemini, OpenAI and
   Anthropic are a dropdown away. [Ollama](https://ollama.com) needs no key at
   all — install it, pull a model, and it appears in the same menu.
4. Ask it something.

Settings writes `~/.bud/config.json`, and that file is the whole configuration —
it can be written by hand instead. Three fields are enough to start:

```json
{
  "provider": "deepseek",
  "providerKeys": { "deepseek": "sk-..." },
  "providerModels": { "deepseek": "deepseek-v4-flash" }
}
```

Or skip the file: `DEEPSEEK_API_KEY`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY` and
`GEMINI_API_KEY` are all read from the environment, as is one for each of the
other supported providers. The file wins over the environment, and the
environment wins over a shell profile, so a key you set deliberately is never
shadowed by one you set and forgot.

Everything else — MCP servers, the marketplace, subagents, memory, skills — is
optional. Nothing is connected on first run and Bud is useful without any of it.

---

## Build

```bash
git clone https://github.com/mriver15/bud bud && cd bud
./Scripts/build-app.sh          # -> build/Bud.app
open build/Bud.app
```

Debug build: `./Scripts/build-app.sh debug`

Building it yourself avoids the Gatekeeper step entirely, because the copy is
yours rather than downloaded.

---

## Configuration

Bud reads configuration in this order, highest priority first:

| Source | Purpose |
|---|---|
| `~/.bud/config.json` | Bud's own settings |
| `~/.omp/agent/config.yml` | If you also run oh-my-pi, its `modelRoles.default` is picked up as a model choice |
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
| OpenAI-compatible | 175 of 217 as the catalogue stood in September 2026 — including several with nothing to do with OpenAI |
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

### Updates

Bud replaces itself. The About pane checks a release feed, verifies what it finds,
and swaps the app in place.

**A signature, not just TLS.** Every manifest is Ed25519-signed and the public half
is compiled into the app. Encryption alone cannot decide whether to run code: a
manifest arrives over the network and then says *what to execute*, so it is
verified before any field inside it is read. The signature covers a flat,
line-oriented field list rather than the JSON document — signing re-encoded JSON
would require the signer and the verifier to agree on key order, whitespace,
number formatting and Unicode escaping, which are four independent ways to
produce a signature that is valid but does not verify. The release notes are
covered too, by hash, since they contain newlines.

**What is checked before anything is replaced:**

| Gate | What it prevents |
|---|---|
| Ed25519 signature | A forged manifest |
| Schema | Fields this build would silently disregard |
| Channel | Handing a stable user a prerelease |
| `minOS` | Installing something that will not run here |
| Build number | Sideways and backwards moves, so a replayed manifest cannot downgrade |
| Download host | Turning a leaked signing key into an arbitrary download |
| SHA-256 | Bytes other than the ones that were signed |
| Bundle identifier | An archive containing something that is not Bud |
| Code signature | A bundle macOS will refuse to launch |
| Same-filesystem staging | A half-installed app |

Staging happens beside the destination and both moves are renames, so the window
in which no app exists is a single syscall — and if the second rename fails the
first is undone, because leaving no app at all is worse than leaving the old one.

**Publishing a release.** Generate the signing key once:

```
Scripts/bud-update-keygen.sh
```

Paste the public key it prints into `UpdateTrust.publicKey`, then:

```
Scripts/bud-release.sh --version 1.1.0 --build 3 --notes notes.md            # build + sign
Scripts/bud-release.sh --version 1.1.0 --build 3 --publish                   # …and upload
```

The private key stays in `~/.bud/keys/update-signing.key`, never in the repo. If
it is lost no future release can be signed, and already-installed copies will
refuse everything.

**Driving it without the UI:**

```
Bud --check-update   --feed https://example.com/appcast.json
Bud --install-update --feed http://127.0.0.1:8000/appcast.json
```

The updater replaces the bundle it is running from, so the only convincing test is
to let it do exactly that to a real copy of the app.

**Settings.** `updateRepo`, `updateFeedURL` (for a feed that is not GitHub),
`updateToken` (a private repo's token, falling back to `GH_TOKEN`, `GITHUB_TOKEN`
or `BUD_UPDATE_TOKEN`), `updateChannel`, and `autoCheckUpdates`. A background check
is silent when it fails — a laptop that is offline should not open with an error
nobody asked for — but a check the user asked for always reports.

---

## Usage

| Action | How |
|---|---|
| Show or hide the panel | The menu-bar sparkle, or a `bud://` link |
| Put it away | `Esc` |
| Park it in a corner as a bubble | The collapse control in the panel header |
| Move the bubble to another corner | Drag it and release |
| Send | `Enter` |
| Newline | `⇧Return` |
| Stop generating | The stop button that appears while a reply streams |
| Switch model | Header model chip |
| Slash commands | Type `/` in the composer |
| Settings | `⌘,` |

Slash commands: `/new` (a fresh transcript), `/tools`, `/settings`, `/mcp`,
`/marketplace`, `/agents`.

### Driving Bud from outside

Bud registers a `bud://` URL scheme, so anything that can open a link can talk to
it — Shortcuts, a shell alias, a script, a calendar alert.

```bash
open "bud://ask?text=Summarise%20my%20Downloads%20folder"   # opens the panel, text in the composer
open "bud://toggle"                                          # show it or put it away
open "bud://settings"                                        # open Settings
open "bud://history"                                         # open the conversation list
open "bud://new"                                             # start a fresh transcript
```

The text is percent-encoded like any URL query value. Unrecognised routes are
ignored rather than opening the panel into an undefined state.

`ask` puts the text in the composer and waits for you to press Send — it does not
send on its own. Treat the scheme the way you would treat a shell: anything able
to open a link can put words in front of a model that has tools, so the press of
Send is the point at which the instruction becomes yours rather than a caller's.

---

## What Bud doesn't do

- **Not on iOS, Windows or Linux.** macOS 26 on Apple Silicon only. There is no
  Intel build and no plan for one.
- **Not notarised.** Ad-hoc signed, so the first launch of a downloaded copy
  needs one confirmation. See [Download](#download).
- **Not a widget.** It is a real application that happens to have no windows
  until you ask for one — a WidgetKit widget could not host a chat, hold a
  browser session, or run a subagent.
- **Not a model.** It has no weights and does no inference of its own; it talks
  to providers you configure, or to a local runtime such as Ollama.
- **No voice, no image generation, no fine-tuning.**
- **No sandbox.** Tools run as you, with your permissions. That is the point,
  and [SECURITY.md](SECURITY.md) is the honest accounting of it.
- **No telemetry.** Nothing is reported anywhere. The only hosts Bud ever
  contacts are the provider you configured, the MCP servers you connected, the
  marketplace catalogue, GitHub for updates, Wikimedia for `find_image`, and npm
  when resolving a package to install — and you can watch every one of them in
  the tool log.

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
│   ├── NativeTools.swift     file, search, shell, web and stored-result tools
│   ├── MemoryTools.swift     remember/recall over the SQLite store
│   └── StoredResults.swift   overflow store and validated handles
├── Providers/
│   ├── ProviderRegistry.swift          known providers, dialects, env vars
│   ├── ProviderCredentials.swift       resolved credentials + the factory
│   ├── OpenAICompatibleBackend.swift   175 of 217 providers
│   ├── AnthropicMessagesBackend.swift  Anthropic Messages
│   └── GoogleGenerativeAIBackend.swift Gemini
├── MCP/                      JSON-RPC, stdio + HTTP transports, manager
├── Marketplace/              registry client, store, browser UI
├── Subagents/                agent registry, the pool, delegation UI
├── Browser/                  WebKit engine + the thirteen browser tools
├── Skills/                   skill scan, ranking, store, the `skill` tool
├── GenUI/                    UI spec language, renderer, render_ui + find_image
├── Update/                   signed manifests, checker, in-place installer
├── UI/                       glass design system, chat, settings, panel
└── SelfTest/                 offline assertion suite (`--self-test`)

Sources/BudMain/              the `bud` executable's entry point
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
./.build/debug/Bud --self-test          # every subsystem's contract — offline
./.build/debug/Bud --verify-ui          # the real panel, and its committed layers
./.build/debug/Bud --verify-browser     # real WebKit, against real pages
./.build/debug/Bud --verify-live        # a real model and a real MCP server; needs a key
./.build/debug/Bud --render-ui /tmp/ui  # writes a PNG of every surface
./.build/debug/Bud --measure            # what a request costs, tool by tool
./.build/debug/Bud --profile            # where a turn's time goes, phase by phase
```

Each one prints its own total, so there is no count here to go stale. CI runs
`--measure` and `--profile` on every push and keeps the output as an artifact, so
prompt-size and latency regressions are diffs against a baseline rather than
against memory.

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

Three limits are worth knowing, because all three can be mistaken for product bugs:

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
- **A full pass is slow, and can stall.** Most of the run is fixed cost — the model
  start, the marketplace probe, the window server — so even a named surface takes
  about two minutes before its PNG appears. A full pass has also been seen to stop
  partway and then sit idle rather than finish, at 0% CPU, with no further output;
  the same stop reproduces on checkouts from before the surface it stopped at
  existed, so it belongs to the harness rather than to any one view. Naming what
  you want — `--render-ui /tmp/ui browser` — renders those and skips the rest,
  which is both what you usually want and has not been seen to stall.

To capture real pixels, grant Screen Recording to your terminal and use
`screencapture -x out.png`. Note that on macOS 26 `-l<windowid>` and `-R<x,y,w,h>`
are both unreliable for a floating panel, so capture the full screen and crop.

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

MIT — see [LICENSE](LICENSE). Use it, change it, ship it, sell it; the only
condition is that the copyright notice comes along.
