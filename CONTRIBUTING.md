# Contributing

Bud is a small, opinionated project. The notes below are what you need to make a
change that fits.

## Before you start

Open an issue for anything larger than a fix — a new tool, a new provider, a
change to how sessions or storage work. Bud has one convention per problem and a
patch that introduces a second one will be asked to use the first, which is a
waste of your time if it could have been settled in a paragraph.

Security problems go to [SECURITY.md](SECURITY.md), not to a public issue.

## Build and verify

```bash
swift build                 # debug
./Scripts/build-app.sh      # -> build/Bud.app
```

Every check is compiled into the app, so there is nothing to install and no test
target to configure:

| | what it covers | needs |
|---|---|---|
| `--self-test` | every subsystem's contract, ~800 checks | nothing |
| `--verify-ui` | the two surfaces only a render can confirm | nothing |
| `--verify-browser` | the browser engine driving real WebKit | network |
| `--verify-live` | a real model turn against a real MCP server | an API key |

Run `--self-test` before you open a pull request. It is fast and offline, and it
is what CI runs. CI runs `--verify-ui` and `--verify-browser` too; `--verify-live`
deliberately is not in CI, because it needs secrets a fork will not have.

## What belongs in a check

A check earns its place by failing when the code is wrong. The suite is full of
checks that assert observable behaviour — a boundary, an invariant, a transition,
a precedence order, a real error — and empty of checks that assert wiring, field
copies, defaults, or that a function returns something rather than nothing.

Two rules that follow from that:

- **Do not pin text.** Asserting that an error message contains a particular
  sentence means the next person to improve that sentence breaks the suite for no
  reason. Assert the failure, not its wording.
- **Make fixtures realistic.** If a fixture only passes because it does not look
  like real input, the check is testing the fixture. When a new rule breaks an old
  fixture, the fixture is usually what is wrong.

Name each check as the claim it makes, so a failure reads as a sentence:

```swift
c.equal("the second call does not re-read the file", client.readCount, 1)
c.check("a refused host is refused after a redirect too", !allowsRedirect)
```

## Style

- Swift 6 language mode, strict concurrency. Everything crossing an isolation
  boundary is `Sendable` and the compiler is expected to prove it.
- **No third-party packages.** Bud builds with SwiftPM against the system SDK
  alone. That is a feature, not an accident — a second browser or a formatting
  library is a dependency someone else has to trust. `import Security` and the
  rest of the system frameworks are fine; a `Package.swift` dependency is not.
- Comments explain **why**. The code says what it does. A comment that restates
  the line below it will be removed, and a comment explaining a non-obvious
  decision is the most valuable thing in the file.
- Prose is British English ("licence", "recognised", "behaviour"); identifiers are
  not affected.
- Errors should say what was wrong, what was expected, and what to do next.

## Commits and pull requests

One change per pull request, with a subject line that completes "This commit
will…". The body explains what was wrong and why the fix is the right one —
`git log` is the only design document this project keeps, and it is read more
often than the README.

Please do not include reformatting, renames, or unrelated cleanups in a fix. They
make the diff unreviewable and hide the change that matters.

## Forks

Two things point at the upstream author and need changing if you ship your own
build:

- `BudConfig.defaultUpdateRepo` (`Sources/Bud/Core/BudConfig.swift`) — the
  repository updates are checked against.
- `UpdateTrust.publicKey` (`Sources/Bud/Update/UpdateModel.swift`) — the Ed25519
  key releases must be signed with. Generate your own with
  `./Scripts/bud-update-keygen.sh`; the private half belongs in
  `~/.bud/keys/update-signing.key` at mode 0600 and never in the repository.

Releases built without a key still run. They just cannot offer updates, and Bud
will report that rather than install anything it cannot verify.
