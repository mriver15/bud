# Changelog

Every published release of Bud, newest first.

Each entry is the note that shipped with it — the same text the updater shows
before installing, and the same text on the release page. It is reproduced here so
the record lives in the repository rather than only in a list of tags, and so a
change can be found by reading rather than by guessing which version to open.

Version numbers are stamped at release time by `Scripts/build-app.sh`; there is no
version file in the tree, because a number that has to be edited by hand is one
that will eventually disagree with the appcast.


## Bud 0.2.0

### Skills

Bud loads **Agent Skills** — the open format, a folder with a `SKILL.md` in it. Not
a format of its own: a skill you already use in another agent works here
unchanged, and one you write here works there. That is the only reason a
marketplace is worth building rather than a folder.

Skills load progressively, which is the point of the format:

1. **Discovery** — the name and description of every installed skill sit in the
   prompt. About 100 tokens each, so a hundred skills cost a page.
2. **Activation** — when a task matches, the model calls `skill` and reads the
   instructions.
3. **Execution** — the skill's own files, loaded only when it says to.

A skill called `pdf` is exactly a worked example: asked about extracting tables
and filling a form, Bud read the skill, then read `forms.md` out of the skill's
own folder because the skill told it to.

### The marketplace

**Settings › Skills.** Browse, install, remove.

Sources are **GitHub repositories**, because there is no registry to be a client
of: the format is open and the skills live in repositories. Bud reads a repo's
tree, finds every `SKILL.md` in it, and shows what it found with the description
each skill carries. Installing downloads the **whole folder** — scripts,
references, assets — because a skill installed without the files it references is
one that fails the first time it is followed.

Any repository with skill folders in it is a source: paste `owner/repo` and Bud
browses that. One is shipped, and it is the one that was checked rather than
guessed.

### Verified

`--self-test` 464 checks, `--verify-live` 85 — including a real install from the
real source, checked on disk and then removed.

Two bugs the work found, both of which would have shipped:

- **Descriptions read as ">"**. Several skills in the standard's own example
  collection write `description: >` and fold the text over several lines. The
  reader took the first line only, so the marketplace would have shown a page of
  blank descriptions — caused by the one construct a long description needs.
- **Resource paths came back absolute.** macOS resolves `/var` to `/private/var`
  in directory enumerations, so trimming a prefix silently failed and every
  listed file was named absolutely. A skill saying "run `scripts/extract.py`"
  would have pointed somewhere that does not exist.

---

## Bud 0.1.0

Seventeen releases of plumbing and one of feature. This is the version where the
parts are all present and the app stops being a prototype with a chat box in it.

---

### The tool layer actually works

Three bugs, all of the same shape: something was reported to the model that the
model could not then act on.

- **MCP tools were listed and uncallable.** Routing was built once at launch,
  before any server had connected, so a server installed or started afterwards had
  its tools offered to the model and every call refused with "Unknown tool". Not
  "it does not register the tools" — it registers them, shows them, and refuses
  them.
- **Tool names said MCP twice.** `mcp__<server>__<tool>` is now `<server>__<tool>`.
  Five characters per tool, on every request, against a 64-character ceiling that
  long server names were already pressing on.
- **`browser_open` told the model to snapshot after opening** — while already
  returning the snapshot. Every exchange carried the same outline twice.

### What a request costs, and how to cut it

`--measure` reports the prefix every request carries. On this machine it was
**66,111 characters — about 16,500 tokens — before a word of conversation**, and
79% of it was one MCP server.

84% of those bytes turned out to be description prose, so the block cannot be
trimmed; the only lever is not sending all of it. Every server now has a per-tool
allowlist, with its cost beside each tool. **25 tools to 3 takes the prefix from
66,111 characters to 19,004.**

### A window you can put down

Bud was a non-activating panel pinned above everything on every Space, with no
Dock icon, reachable only by ⌥⌘B. It is now an ordinary window — normal level,
goes behind, stays on its Space, standard controls — and it is in the Dock, in
Cmd-Tab and in Spotlight. The summon shortcut is gone, and so is the corner
bubble.

### Conversations you can manage

Copy an answer, retry a bad one, delete from a point. ⌘F finds within a chat and
⌘K opens the command palette. Export any conversation as Markdown, pin it to the
top, rename it. The header shows what the chat has cost, with an optional ceiling.

Retry is exact rather than approximate: the model's history holds tool call and
result messages that no turn records, so each exchange snapshots itself and retry
restores that.

### A browser, built in

WebKit, so nothing is downloaded before the first page and no Node install sits
behind it — this is what the Playwright MCP provides without the server. Thirteen
tools: open, snapshot, read, click, type, press, hover, select, wait, scroll,
back, console, screenshot.

`browser_snapshot` returns the page as an outline with a **ref** on everything you
can act on, and a stale ref fails rather than clicking whatever moved into that
position. Every action returns a picture of the page, shown under the tool row in
the chat.

### Reading what people drop

`read_file` required UTF-8 and refused everything else. It now reads a PDF's text
layer, the words inside an image via Vision, UTF-16, and anything else as Latin-1
— so a screenshot of an error is something Bud can answer from. A dropped image
stages its path like any other file, because the path leads somewhere.

---

### Upgrading

The database moves to v3. **Migrations now take a snapshot first**, written with
`VACUUM INTO` rather than a file copy — a WAL database is its main file *plus* the
write-ahead log, and copying only the first loses every transaction not yet
checkpointed. What it finds is kept beside the database as `bud.sqlite.backup-vN`.

Nothing else needs doing. Servers already installed keep sending every tool.

### Known gaps

Stated rather than left to be discovered:

- **File upload** in the browser — WebKit requires a genuine user gesture to open
  a file picker, and scripted clicks are not one.
- **Multiple browser tabs** — one web view, so no tab model.
- **Vision** — Bud reads the text *in* an image. It still cannot tell you what a
  photograph is of.



---


## Bud 0.0.17

### The browser stops calling itself twice

`browser_open` already returned the page outline, and its description still said
*"after this, call browser_snapshot"* — so the model did, and the same outline
appeared twice in every exchange. That was my description contradicting my own
tool. It now says the outline comes back with the call.

Measured on the same request: **~450 characters of tool output down to 156**, and
one call instead of two.

### Dropped files can be read

`read_file` required UTF-8 and refused everything else. Now it reads what is
actually legible in a file:

- **Text** — UTF-8, UTF-16 with a byte-order mark, and anything else as Latin-1,
  so a file saved by an app that does not write UTF-8 is still a text file.
- **PDF** — the text layer, page by page.
- **Images** — the words in the picture, read with Vision. A screenshot of an
  error, a slide, a receipt, a table: all text, and text is what Bud can use.
- **Anything else** — says what it found rather than dumping bytes.

A dropped image now stages its path like any other file, because the path leads
somewhere. The caption is honest about the limit: Bud reads the text *inside* a
picture and still cannot see the picture.

Verified end to end: pointed at a browser screenshot, Bud read the page's
headings, labels and field values out of the pixels.


_Released 2026-09-16._


---


## Bud 0.0.16

### The browser is visible in the chat

Every browser action now returns a **picture of the page**, rendered under the
tool row in the transcript. `browser_open`, `browser_click`, `browser_type`,
`browser_press`, `browser_hover`, `browser_select`, `browser_wait`,
`browser_back` and `browser_screenshot` all carry one.

The model does not read the image — it gets the outline as text, because a
screenshot is not something it can look at. **You** do. A tool row saying "clicked
ref 7" is much easier to trust, and to correct when it is wrong, with the page it
clicked beside it.

Only from Bud's own directory: a `render_ui` spec is model-authored, and one
allowed to name any path on disk would turn a UI surface into a way to probe the
filesystem.

Screenshots are pruned to the newest 60.

### Closer to Playwright

Five more tools, so the interactions that matter are all covered natively:

- **`browser_hover`** — menus and tooltips that only appear on hover
- **`browser_select`** — dropdowns, by value or by visible text
- **`browser_wait`** — for text or an element to appear, for pages that render late
- **`browser_console`** — what the page logged and what it threw, which is usually
  the only evidence of why a page that looks fine is not working

Console capture is installed at document start, so it is listening before the
page's own script runs — the error worth having is usually thrown while the page
is still initialising.

Thirteen browser tools in total, 4,373 characters (about 1,093 tokens).


_Released 2026-09-16._


---


## Bud 0.0.15

### A browser, built in

Bud can browse. **Browser** is a new surface: an address bar over a live page you
can watch it work in, because a result saying "clicked ref 7" means a lot more
when the page it clicked is beside it.

WebKit, not a bundled Chromium — it is already on the machine, nothing is
downloaded before the first page, and there is no Node install behind it. That is
the whole of *lightweight*: the alternative is a second browser shipped inside an
assistant.

### Browser tools, natively

Nine tools, no Playwright MCP server required:

`browser_open` · `browser_snapshot` · `browser_read` · `browser_click` ·
`browser_type` · `browser_press` · `browser_scroll` · `browser_back` ·
`browser_screenshot`

`browser_snapshot` is the one that matters. It returns the page as an outline —
headings, links, buttons, fields, checkbox states, disabled controls — with a
**ref** on everything you can act on. A model handed raw HTML picks selectors out
of a document it cannot see; handed an outline with refs, it does what a person
does: reads the labels and clicks the thing.

Snapshots are re-assignable, so a stale ref **fails** rather than clicking
whatever now sits at that position.

### Verified

30 checks against local fixtures, no network: refs resolve to the elements they
name, typing fires the events frameworks listen for, clicks run the page's own
handlers, stale refs are refused, and the page view fills the surface showing it.

Then end to end against the real model and the real internet — `browser_open` on
example.com returned the outline, and the model answered from it.


_Released 2026-09-16._


---


## Bud 0.0.14

### Reasoning effort, where you ask the question

The composer has an effort control: **Auto / Quick / Balanced / Deep**. It was in
Settings, which is the wrong place for a per-question decision — a lookup does
not need the depth a design question does, and nobody goes into settings between
turns.

### See what a drop took

Dropped files appear as chips above the input, with a **thumbnail** for images,
and an × to take one back off. Removing a chip also removes the line it put in
the composer, so no path is left behind for a file you just removed.

Images say plainly that Bud cannot read them. Better learned from the chip than
from an answer about a filename.

### Told when a long turn finishes

If a turn runs longer than a few seconds and you have moved on, Bud posts a
notification — or bounces the Dock icon if notifications are not permitted. Short
answers say nothing: those arrived while you were still watching.

Stopping a turn is not finishing it, and reports nothing.


_Released 2026-09-16._


---


## Bud 0.0.13

### Export a conversation

Right-click any conversation in **History** for **Copy as Markdown** or **Export
Markdown…**. The document keeps what was asked, the answer with its formatting,
and the tool calls with their output. Reasoning is quoted and tool output is
clipped — one tool call can be larger than the whole conversation around it.

### Pin and rename

Pin keeps a conversation at the top of the archive regardless of when it was last
touched, so the list stays usable past twenty conversations. Rename replaces the
automatic name from the first thing said — and it sticks, which it did not used
to: the title was recomputed from the transcript on every save, so any rename
would have been undone by the next turn.

Both are on the row's context menu, along with Delete.

### Schema v3

One more column for the pin.


_Released 2026-09-16._


---


## Bud 0.0.12

### What a conversation is costing

The header shows what the current chat has spent, with the split on hover. It is
the real figure — the one the provider returned — not an estimate.

Costs are remembered with the conversation, so reopening one from the archive
shows what it cost rather than starting from zero.

### A ceiling, if you want one

**Settings › Limits** has a token budget per chat. Once a conversation reaches
it, Bud stops starting new turns and says why. A new chat clears it.

Off by default: a ceiling nobody asked for is the app deciding when to stop
working.

### Schema v2

The database gained two columns. Migrations now take a snapshot first, with
`VACUUM INTO` rather than a file copy — a WAL database is its main file *plus*
the write-ahead log, and copying only the first loses everything not yet
checkpointed.


_Released 2026-09-16._


---


## Bud 0.0.11

### Find in this chat — ⌘F

A find bar over the transcript. Matching turns stay lit, everything else fades
back, and the query is marked wherever it appears in the prose. Enter walks the
results and wraps.

It searches tool arguments and results too, not just what was said — the output
you are trying to get back to is usually the reason you are searching.

### Command palette — ⌘K

The palette existed with no keyboard entry point. It opens with ⌘K, and each
command now shows its real shortcut. Only the real ones: `/new` is ⌘N, settings
is ⌘,, and the rest show nothing rather than an invented key.

Both commands are in the **menu bar**, which is the only place these shortcuts
are discoverable at all.


_Released 2026-09-16._


---


## Bud 0.0.10

### Copy an answer

Every message now has a **copy** button. It was the most common thing anyone does
with a reply and the only thing that had one was a fenced code block — copying
prose meant dragging a selection across it by hand.

Copy takes the prose, in order. Reasoning and tool activity are how the answer
was reached, not the answer.

### Retry

**Retry** asks the same question again and drops the answer you are looking at.
A failed tool call or a wrong answer no longer means retyping the question.

Retry is exact rather than approximate. The model-facing history holds tool call
and result messages that no turn records, so it cannot be unwound from the
transcript — so the state before each exchange is remembered instead, and retry
puts it back.

### Right-click

Copy, Retry and **Delete from here** are on the context menu of every message,
because hover is invisible until you happen to pass over a turn.

The actions are always shown on the newest message — that is the one anyone
copies or retries — and on hover everywhere else.

### Scope

Retry and Delete from here apply to exchanges **this session ran**. A
conversation loaded from the archive offers Copy only: its exchange boundaries
and model history were not saved, and a Retry that quietly did the wrong thing
would be worse than none.


_Released 2026-09-16._


---


## Bud 0.0.9

### Start a new chat where you are

You can now start a new conversation from the chat surface itself. There is a
**New chat** button in the header, and `/new` in the composer.

It was reachable before only through ⌘N, `/clear`, or a button on the *History*
tab — a strange place to go to start something new. `/clear` is now `/new`,
because "clear" reads as destructive when what it does is begin again.

Nothing is lost when you switch: the conversation you leave is saved first.

### The corner bubble is gone

Bud lives in the menu bar, which is the surface that is always there. A second
always-available thing competing with it was one affordance too many — and it was
the last window that wanted to float above everything.

There is now exactly one kind of window, and it behaves like a window.

### Removed with it

`bud://collapse` and `bud://expand`. The remaining links are `bud://ask`,
`bud://toggle`, `bud://new`, `bud://history`, and `bud://settings`.


_Released 2026-09-16._


---


## Bud 0.0.8

### Bud is a normal app now

It was a floating panel pinned above everything on every Space, with no Dock
icon, reachable only by a shortcut. There was no way to work behind it.

Now it is an ordinary window:

- It sits at the **normal window level**, so anything can go in front of it.
- It **goes behind** when you switch to another app.
- It stays on the Space you opened it on.
- It has the **three standard window controls**.

Clicking the Dock icon after closing reopens it — closing hides Bud rather than
ending it.

### Launch it however you like

Bud appears in the **Dock**, in **Cmd-Tab**, and in **Spotlight**. Launching it
opens the window.

The `⌥⌘B` summon shortcut is gone. It existed to reach an app with no Dock
presence; there is nothing hidden to reach now, and the Dock, Cmd-Tab and the
menu bar all work.

### Unchanged

Collapsing Bud to the corner bubble still keeps it above your windows — that is
what the bubble is for, and it is only ever reached by asking for it.


_Released 2026-09-16._


---


## Bud 0.0.7

### Choose which tools a server is allowed to send

A request now carries 66,111 characters before you type anything — about 16,500
tokens — and **79% of it is one MCP server**, 25 tool schemas at 52,031
characters. The heaviest single tool is 11,560 of that.

That block cannot be trimmed. 84% of those bytes are the description prose the
model needs to call the tool at all; stripping structure would save 3%. The only
real lever is not sending all of it.

**Settings › MCP › Tools & log** now lists every tool a server offers, with its
exact request cost beside it. Untick what you do not use.

Measured on `getcompetitive`: 25 tools down to 3 takes the prefix from
**66,111 characters to 19,004** — 16,527 tokens to 4,751, on every request.

Nothing changes until you ask it to. Every server already installed keeps sending
everything, and a tool you switch off says so if something calls it anyway.

### Also

- **`--measure`** reports what a request costs: system prompt, notes, tools, the
  heaviest individual tools, and a per-server total.
- **`--dump-tool <name>`** prints one tool definition exactly as the request
  carries it.


_Released 2026-09-16._


---


## Bud 0.0.6

### MCP tools now actually work

A real bug, and a bad one. Tool routing was built once, when Bud started, before
any MCP server had connected. A server installed or started afterwards had its
tools **listed and offered to the model, and every call refused** with "Unknown
tool". The tools were registered; the lookup that decides whether a name can be
called was not.

Routing is now rebuilt alongside the tool list, so the two cannot disagree.

### Simpler tool names

`mcp__<server>__<tool>` became `<server>__<tool>`. The prefix was repeating the
server name it sat next to — five characters per tool, on every request, against
a 64-character ceiling that long server names were already pressing on.

The double underscore stays: single underscores belong to built-in tools, so
`__` marks the server boundary.


_Released 2026-09-16._


---


## Bud 0.0.5

**`bud://history` opens the conversation history**, and `bud://new` returns you to
the chat instead of leaving you looking at the list you started it from.

The panel's surface now belongs to the model rather than to the view that draws
it, so anything that can reach Bud can point the panel at a screen. The History
surface previously had no addressable entry point at all — it could only be
reached by clicking.

Small release; 0.0.4 was the one with the database.


_Released 2026-09-16._


---


## Bud 0.0.4

### Conversations, runs and notes now live in SQLite

The history was one JSON file rewritten in full on every save — the cost of
saying one thing grew with everything you had ever said, and there was nowhere
to put anything that was not a conversation.

### Multiple conversations

A **History** surface in the panel header: search across titles and everything
said, switch between conversations, delete with confirmation. The menu bar keeps
its five most recent. The conversation you were in is still open when you come
back.

### Subagent runs outlive the session

Runs were a live activity feed, so anything dispatched and finished before a
restart left no trace. They are now recorded when they settle and read back on
launch.

### Bud keeps notes

It can save a fact worth carrying between conversations — how you like to be
answered, a convention of your project, a correction — and those notes are
carried into every later request. Ask it to remember something and it will.

### Fixed

**Only the first turn of a conversation was ever stored.** A prepared SQLite
statement cannot be re-run without a reset, so every execution after the first
silently did nothing. Every conversation saved until now had exactly one turn,
so the round-trip test asserted one turn and passed.

**Search never rejected a short query.** The length check measured the pattern
built from the query rather than the query itself, so a two-letter search
scanned the whole archive.

**Deleting the open conversation stopped all saving.** Nothing re-created the
conversation, so every turn after the delete would have been silently lost.

Your existing `~/.bud/conversations.json` is imported on first launch and
renamed to `conversations.imported.json` rather than deleted.


_Released 2026-09-16._


---


## Bud 0.0.3

### Conversations now survive quitting

Until now the transcript lived in memory, so quitting Bud threw the conversation
away. Chats are saved to `~/.bud/conversations.json` after each turn, restored
when Bud starts, and the last five are listed in the menu bar. "New chat" starts
a new one instead of discarding the current one.

### Reach Bud from wherever you are

- **Services menu.** Select text in any app, then Services → "Ask Bud about this".
  Bud comes up with the text staged in the composer.
- **Drop files on the panel.** Drag a file or folder in and its path lands in the
  composer, ready for a question.

Neither of these sends anything on your behalf — both stage what arrived and put
the caret after it, so you still say what you want done with it.

### Fixed: Bud could not remember what it had just said

A real bug, and a significant one. Only tool calls were ever added to the
model-facing history, so an assistant's written answer went on screen and nowhere
else. Every follow-up was sent with your questions and none of the answers —
"What did you just say?" had nothing to refer to. The transcript looked like a
conversation; the context was a monologue.

Found by saving the history and noticing the saved history had one message in it
where there should have been two.


_Released 2026-09-16._


---


## Bud 0.0.2

### Fixes

**Restart after an update now works.** It did not before: Bud installed the new
version, spawned the helper meant to bring it back, and then never quit — so the
helper waited two minutes for a process that was never going to exit and opened
nothing. The button appeared to do nothing because that is exactly what it did.

Two separate breaks, either sufficient on its own: the updater was built without
a way to quit the app, and the app's quit callback was declared but never
assigned by anything. The ability is now part of the updater's type rather than a
callback that has to be remembered, so it cannot go missing again.

### Also in this release

**Landscape panel.** 880x560, with one content column that the header, transcript
and composer all share. The starter prompts are a 2x2 grid.

**Glama servers are installable** when npm actually has the package. Directory
records publish no run command, so the slug is now checked against npm and
offered only when a real package answers. `getcompetitive` is one of them.


_Released 2026-09-15._


---


## Bud 0.0.1 — first published release

The first build published for self-updating. Everything before this was built
locally.

**Chat with any provider.** Three wire dialects — OpenAI-compatible, Anthropic
Messages and Google Generative AI — covering 23 hosted endpoints and the local
runtimes, with keys, base URLs, model choice and region stored per provider.
Includes Amazon Bedrock, region-aware, on both its chat-completions and native
Claude routes.

**Self-updating.** Bud checks a signed feed, verifies what it finds, and
replaces itself in place. Releases are Ed25519-signed, downloads are checksummed,
the archive is checked to contain Bud specifically, and the swap is a rename with
a rollback.

**Everything else**, already here: MCP servers over stdio and HTTP, a
marketplace with two sources, concurrent subagents, and generative UI.


_Released 2026-09-15._
