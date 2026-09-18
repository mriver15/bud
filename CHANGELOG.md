# Changelog

Every published release of Bud, newest first.

Each entry is the note that shipped with it — the same text the updater shows
before installing, and the same text on the release page. It is reproduced here so
the record lives in the repository rather than only in a list of tags, and so a
change can be found by reading rather than by guessing which version to open.

Version numbers are stamped at release time by `Scripts/build-app.sh`; there is no
version file in the tree, because a number that has to be edited by hand is one
that will eventually disagree with the appcast.


## Bud 1.0.0

Three changes with one idea behind them: **every capability is a tax on every
request, paid whether or not it is used.** The question is never "is this useful"
but "is it useful often enough to be resident".

### `render_ui` was carrying its documentation twice

The DSL reference lived in two places: once as a legend of the component shapes,
and again as a sentence on each field of the schema — where, because that schema is
flat, every sentence had to begin by naming the component it belonged to. *"card:
accent colour name or #RRGGBB hex"* said what the legend had already said, in the
one form that cannot be loaded lazily.

It is written once now. The legend is the vocabulary and stays; the scattered copy
is gone.

| | before | after |
|---|---|---|
| `render_ui` | 8,673 | **5,158** |
| prefix, direct | 71,661 | **68,146** |
| prefix, handed to an agent | 21,976 | **18,461** |

Nothing structural was removed — every component, field name, type and enum value
is still there, which is what the provider validates against. What went was 3,515
characters of prose saying it twice.

Proven by asking a model to render a table from the new schema and checking that a
surface came back. That is the only honest way to answer whether a schema is still
sufficient.

### The conversation had no ceiling

A tool result is capped at 24,000 characters when it arrives. Nothing capped the
total, so every round re-sent every result the conversation had ever produced — and
the conversations that need length most are the ones that called the most tools.

There is a budget now, 120,000 characters by default, and it empties the contents
of the oldest tool results. **Only contents**: a call and its result have to stay
paired or the provider rejects the whole request, so a dropped result becomes a line
saying what it was and how big. Never the newest — that is the one the model has not
read yet.

You keep seeing everything. `turns` holds the full text, the transcript still shows
it, and the model is told it can call the tool again.

### The budget is enforced

Every win in this project came from measuring, and `--measure` was itself wrong for
a release. Nothing failed when the block grew, which is how one MCP server reached
49,685 characters — 70% of a request — without anyone noticing.

`--self-test` now measures the built-in block and fails on:

- any tool over **6,500 characters** — one tool large enough to matter alone
- the block over **30,000** — the figure a request actually pays
- any schema carrying more than **3,000 characters of prose** — documentation that
  cannot be loaded lazily, which is what `render_ui` had

The failure names the tool and the amount. The caps are constants the assertions
read, so the sentence and the test cannot come apart.

**A ratchet, not a target.** When it fails, the question is not how to raise it.

### Also

`--measure` now splits every tool into prose, schema, and the skeleton left when
the schema's own strings come out — the measurement that made all of this visible.

---

## Bud 0.5.1

### `--measure` says which half of a tool is removable

A tool costs prose plus a schema, and the two cannot be treated alike: the schema
is what the provider validates arguments against, so a model that has not seen it
writes arguments that fail. The prose *inside* a schema is documentation, and
documentation can be moved somewhere it is loaded only when it is needed.

One number per tool hid that completely. `render_ui` is 408 characters of prose
and 8,183 of schema — so moving the *description* somewhere lazy, the obvious
first guess, would have saved 408 characters and looked like a failure.

```
render_ui    8,673    prose 408 · schema 8,183 (skeleton 2,675)
of 70,442 characters of tools, 48,467 are prose
```

**69% of the tool block is documentation rather than structure.**

---

## Bud 0.5.0

### Handing a server's tools to its agent

A server with twenty-one tools puts twelve thousand tokens in front of the model
on every request, for a surface it uses one or two tools of. The tools were never
the problem — the schemas are, and they are charged whether or not any of them is
used.

**MCP → a server → Tools & log → "Hand these tools to the _server_ agent".**

| | tools | characters | per request |
|---|---|---|---|
| direct | 46 | 70,442 | **17,915 tokens** |
| handed to the agent | 25 | 20,757 | **5,494 tokens** |

Measured on a real server, on this machine, with `--measure`. The main agent stops
carrying the schemas and reaches the tools by delegating to the agent that holds
them, which keeps its own full list.

**It is not free, so it is not the default.** A question answered by one instant
lookup is now answered a round trip later. It pays for itself when a server is
bulky and its answers are; tick the box per server, next to the figure it changes.

The switch is arranged so the failure mode cannot happen: tools are hidden from
the main agent *after* the descriptor pass that rebuilds the agent roster, so a
tool that leaves the model's list always has an agent that can still call it. The
live suite asserts exactly that — the tool leaves one list, stays served, and still
answers.

### A bug I put in and took out

Adding one field to `MCPServerConfig` **emptied the server list of every config
written before it existed** — silently, with the servers still sitting in the file
and the only symptom that they had stopped connecting. Swift's synthesized decoder
requires every non-optional key, so a missing `delegated` failed the whole array.

Caught by `--measure` reporting `0/0 configured servers` where it had reported
`1/1` a minute earlier. `MCPServerConfig` now decodes leniently: a key the file does
not have takes its default. That is a whole class of failure, not one instance of
it, and there is a test for a config written before the field existed.

### And a measurement that was lying

`--measure` counted the registry rather than what a request carries, so it reported
all 21 tools as present after they had been handed over — understating the feature
it was being used to evaluate. It filters exactly as a request does now.

### Also

`--measure` says what each server would save: "could hand to its agent and save
49,685".

---

## Bud 0.4.0

### The screen was showing fifty-four of my test runs

The Agents tab listed nothing but `verify`, over and over. Every one of those rows
came from `--verify-live`, which spawns a subagent to prove subagents work and
records the run in the real database — because `--self-test` redirects the store
and `--verify-live` never did. The gate was writing into the thing it was checking.

Three fixes, because one was not enough:

- **No command-line mode can reach your data.** They point the store at a scratch
  file before anything else runs, so a mode that forgets to think about it is still
  safe.
- **Your roster is clean.** The 54 rows were removed — every one matched the test's
  own prompt, so there was nothing to guess at. Your 16 conversations were not
  touched.
- **A run that finds nothing no longer looks like a shorter answer.** Deleting rows
  is a symptom; the reason they were invisible as junk is that nothing said
  "written by the gate".

### Work you can hand over, by name

Bud could already delegate, but only into an anonymous workstream: the model
invented a title and a prompt each time, and the subagent ran with every tool in
the session and the same instructions as everything else. Nothing could be offered,
chosen, described or improved, because there was nothing to name.

An agent is that name — instructions, a tool list, and optionally a model — and
they come from three places, which is the point:

| From | What |
|---|---|
| **Built in** | `scout` (read-only investigation), `reviewer` (read-only judgement), `builder` (does the work) |
| **Your skills** | Any skill with `agent:` in its frontmatter. Its body becomes the instructions; its `allowed-tools` becomes the tool list |
| **Your MCP servers** | Every connected server, scoped to *its own* tools |

`scout` and `reviewer` cannot write and cannot run a shell. That is enforced by the
tool list rather than asked for in a prompt, which is why `search_files` now exists:
without it, the only agents that could search a codebase were the ones that could
also delete it.

**The field that was never used.** `allowed-tools` has been parsed from the day
skills were added and ignored ever since. It is now the tool list of the agent a
skill becomes — which is the only reading of it that means anything.

### Delegation that does not deadlock

A subagent may now delegate onward, one level. The interesting part is the
accounting: nested runs take **no pool slot**, because a parent holding a slot while
waiting for a child to be admitted is a deadlock the moment the pool fills with
parents doing the same thing. Children belong to their parent's slot, the depth
limit bounds the tree, and four children per call bounds the widest part of it.

The model is told what it can delegate to, generated from the roster on every
request rather than written into the prompt once — a list that is not regenerated
is wrong from the first skill you install, and wrong in the direction that costs a
round trip.

### The screen

Two panes, because the two questions are asked at different times. **Delegates** is
what it can hand work to, grouped by where each came from. **Activity** is what it
has handed work to — now carrying the agent each run ran as, with anything a
subagent delegated indented under the run that asked for it.

### Also

- A tool list containing a wildcard is described rather than counted. A server
  exposing twenty-one tools was being shown as "1 tool", which was a count of the
  patterns rather than of the tools.
- `--render-ui` takes a filter, so re-rendering one surface no longer means
  laying out all thirty.

---

## Bud 0.3.2

### A picture, when nothing else has one

Bud could already draw an image in a generated surface, but only if something else
had produced one. Ask for a team and you get six names, a tidy grid, and no
pictures — and the answer to that is not "write an MCP server that returns
sprites", because the same hole appears for a bird, a city, a product or a diagram.

`find_image` fills it. One thing, or a whole set in a single call:

```
find_image {"queries": ["Blaziken", "Garchomp", "Rotom", "Corviknight"]}
```

Wikipedia answers first, so anything with an article comes back as its own lead
image — which is what a team sheet, a gallery of places or a product comparison
actually needs, and what a search over filenames would never find. Anything else
falls back to a search of Wikimedia Commons. Both are keyless, and every result
carries the page it came from and its licence where the source states one.

**The results say which kind they are.** The strongest answer is *the article for
the thing*; the fallback is *a match on the words*, which is a different claim and
sometimes a photograph of somebody in a costume. The model choosing between them
is told which it is holding, because a surface showing the wrong picture is worse
than one showing none.

An MCP server returning images directly is unchanged: those render under the tool
row and nothing is looked up.

### Three bugs, all found by rendering it

**The Pokémon logo, four times over.** Rendered as a team, four of six cards showed
the generic Pokémon logo. The summary endpoint follows redirects and does not say
it did: asked for "Rotom" it answers with *List of generation IV Pokémon*, whose
lead image is the logo. A standard page, a real picture, an answer to a question
nobody asked. The resolved title now has to be the title asked for — a parenthetical
is still the thing ("Rotom (Pokémon)"), a different subject is not.

**Multi-word lookups returned nothing.** `URL(string:)` re-encodes an already
encoded `%`, so `sunset over mountains` was being searched for as the literal text
`sunset%2520over%2520mountains`. Single words have no space, which is why only
phrases failed. Both endpoints are composed with `URLComponents` now.

**The results came back in a random order.** `pages` is a JSON object and objects
have no order, so "the first result" was whatever the dictionary felt like. The
response carries the search rank on every page; that is the order now.

A fourth, smaller one: a query that found nothing was dropped from the answer
silently, which is what kept the encoding bug invisible.

### Also

An offline suite for the reading — the response shapes that are not an article,
the ranks, the licence and address handling — and live checks that ask Wikipedia
for a Blaziken and render what comes back.

---

## Bud 0.3.1

### Images you can lay out

The `image` component now takes a size, and stops at it. Before, an image with no
stated size stretched to whatever contained it — a 96-pixel sprite arrived at the
width of the panel, which is the wrong answer for everything except a screenshot.

```
{"type":"image","url":"…","width":96,"height":96,"fit":"fit","radius":10,
 "action":{"id":"explain","prompt":"Explain what this does on the team."}}
```

- **width / height** in points; leave one out and the image keeps its aspect ratio
- **fit** — `fit` shows the whole image, `fill` crops it to the box, which is what
  makes a row of thumbnails line up instead of each being a different size
- **radius** — corner rounding, `0` for square
- **action** — makes the image tappable, with the same contract as a button: the
  host hears about it, and a `prompt` continues the conversation

Sizes are clamped. A generated spec is free to say `40000`, and a view that tries
to lay that out is a hung window rather than a wrong picture.

`grid` and `card` were already there. Six sprites in a 3×2 grid of cards is now
four lines of spec.

### A tool can just return the picture

**This is the part worth knowing about.** An MCP server that answered with an
image content block had its bytes thrown away: the model was told
`[image image/png, 41234 bytes]` and you saw nothing.

Now the bytes are written into `~/.bud/images/` and drawn under the tool row. So
your getcompetitive MCP does not need a public URL — it can return the sprite
directly and it appears, one tile for one image, a grid for several.

The model still gets the placeholder line, because it cannot look at a picture.

Written by their **bytes**, not by what the server called them: a PNG arrives
whatever the declared type says, and anything that is not an image is refused.
Capped at 12MB and pruned to the newest 80, because an answer that carries an
image leaves a file behind every time.

### A crash, caught by rendering it

Adding the new fields put a **second `height` key** into the `render_ui` schema,
which is built as a dictionary. That is a fatal `Duplicate values for key` the
moment the tool list is assembled — a launch crash, not a cosmetic one. It never
reached a test because no suite builds that schema; the render harness did, on its
first attempt.

---

## Bud 0.3.0

An optimisation release, and an honest one: I found and fixed a real hot spot, and
**I could not reproduce the slowdown that prompted this**.

### What was actually slow

The prompt is rebuilt on every round, and it lists every installed skill. That
meant reading and parsing every `SKILL.md` and walking every skill folder — to
produce the same string, twenty-four times a turn.

| | before | after |
|---|---|---|
| skill list | 1.07 ms | **0.06 ms** |
| per request | 1.32 ms | **0.30 ms** |
| per 24-round turn | 32 ms | **8 ms** |

The listing is now cached, keyed on a fingerprint of what it was built from —
the size and modification time of each manifest and its folder. Not a flag: this
design invites you to edit a skill by hand, and a cache that stopped noticing
would quietly undo that. Two bugs found while proving it: a file added beside a
`SKILL.md` did not change the fingerprint, and the timestamp was rounded to the
second, so two edits in one tick looked like one.

### `--profile`

New. Reports what a request costs **in time**, where `--measure` reports it in
characters. Same reason: the expensive part of an assistant is the part that runs
on every request, and none of it is visible from outside.

### What I could not reproduce

Measured with the marketplace open and a multi-round run going:

- **CPU 1.9%**, memory flat at ~196MB
- a turn took **3.2s with the marketplace open and 3.2s with it closed**
- the marketplace itself costs ~34MB and about 1% CPU

Nothing in that is heavy. The honest conclusion is that I have not found your
slowdown, and the fix above — while real — is too small to be the cause.

### The hypothesis I tried and backed out of

Markets and lists draw every row as `.ultraThinMaterial`. A material blurs
whatever is behind it, so a streaming transcript animating behind three hundred
cards makes all of them re-sample, every frame. That cost lands on the
compositor, so it never appears as CPU time in the process — and **with a locked
screen nothing is drawn at all**, which is very likely why my measurements show
nothing.

I built a flat, unblurred row surface and switched the seven per-row call sites.
It rendered the cards near-white with their text invisible. I could not diagnose
it by measurement — the fill behaved nothing like its stated alpha — and I cannot
see the screen to iterate, so **I reverted it**. Shipping a visual regression for
an unmeasured gain is the wrong trade.

The enum and the parameter are gone with it; there is no half-finished switch
left in the tree.

---

## Bud 0.2.1

### Skills are checked before they are installed

A skill is two risks behind one door: **instructions that go into the model's
context**, and **code it ships that can run**. Both are decided before anything
reaches your machine.

Every skill is scanned on the way in. What it finds falls into three kinds:

- **Refused** — a symbolic link pointing out of the folder, a file name that
  escapes it, or a compiled program whose behaviour cannot be read. Nothing about
  these can be made safe by looking harder.
- **Needs review** — a recursive delete aimed at your machine or your home,
  a download piped straight into a shell, an encoded payload decoded and run,
  a read of `~/.ssh` or a keychain, `sudo`, `eval` on anything assembled at
  runtime, or, in the instructions themselves: *ignore previous instructions*,
  *do not tell the user*, *without asking*, *print your system prompt*, *send this
  to…*. **You are shown each one, with the file and the matched text, and
  installing takes a deliberate click.**
- **Worth knowing** — a runnable script, a network call, hidden or bidirectional
  characters, an unusually large bundle. Shown; nothing is blocked.

A skill with nothing to report installs without a prompt. A confirmation nobody
has a reason to read is one people learn to click through.

### What was reused rather than reinvented

- **macOS quarantine.** Everything installed is marked as having come from the
  internet, so Gatekeeper treats a script inside a skill exactly as it would a
  script you downloaded in a browser. `com.apple.quarantine`, set through
  `URLResourceValues`, not a scheme of ours.
- **The file reader.** `FileReading` already knew how to tell text from binary and
  how to decode what is not UTF-8, which is most of what classifying a skill's
  files needs.

### It is a screen, not a sandbox

Everything here can be worked around by someone who knows it exists. Its job is
to make the ordinary case visible and the obvious case impossible — not to certify
anything. What it does *not* do: run anything in isolation, check a signature,
or judge whether instructions are *subtle*. A skill that manipulates the model
without using any of the phrases above will pass.

### Calibration

The rules were tuned against a real published skill, not only against fixtures:
the `pdf` skill ships five Python scripts and mentions a URL, and raises nothing
dangerous. Two rules were wrong and the tests caught them:

- The recursive-delete rule required whitespace after the path, so
  `rm -rf ~/Documents` passed while `rm -rf ~` was caught.
- It would also have fired on `rm -rf ./build` and `rm -rf /tmp/work`, which is
  how a screen teaches people to ignore it. Scoped paths are now exempt, and the
  exemptions have their own checks.

---

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
