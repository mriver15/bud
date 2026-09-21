import AppKit
import SwiftUI

/// Renders each real surface to a PNG so the interface can actually be looked at.
///
/// This exists because live pixels are unavailable: `screencapture` needs the
/// Screen Recording permission, which a terminal-launched process does not have.
/// An offscreen `cacheDisplay` capture draws the view hierarchy through `drawRect`,
/// so it reproduces layout, typography, spacing, colour and hierarchy faithfully.
///
/// One surface does not capture at all: anything containing `Composer` comes out
/// fully transparent, and the runner reports it as `BLANK`. Bisecting ruled out
/// the obvious suspects — `EmptyStateView` captures, plain and `interactive()`
/// glass both capture, and so do plain and self-focusing `TextField`s, so it is
/// neither the material layer nor first-responder state. The cause is not
/// isolated. The panel is captured from the live app with `screencapture`
/// instead, which is a better test of it anyway.
///
/// What it cannot reproduce is compositor work: `CABackdropLayer` sampling the
/// desktop, and therefore the Liquid Glass blur itself. Surfaces are drawn over a
/// desktop-like backdrop so the glass tint and specular edge are still readable,
/// and the glass pipeline's existence is proven separately by `--verify-ui`.
/// A value filled in by an async step and read once the run loop has pumped.
///
/// The harness is synchronous and drives async work through `runLoop`, so a
/// result has to live somewhere the async step and the sync flow both reach.
@MainActor
private final class Deferred<T> {
    var value: T?
}

@MainActor
public enum UIRender {
    /// Names to render. Empty renders everything. The window server and SwiftUI
    /// layout make each surface cost seconds, so iterating on one of them by
    /// rendering all thirty is a long wait for a small change.
    @MainActor private static var only: String = ""

    public static func run(outputDirectory: String, only matching: String = "") -> Never {
        only = matching
        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        var written: [String] = []

        // MARK: Model

        let model = AppModel()
        runLoop(1.5)
        Task { await model.start() }
        runLoop(6.0)

        let store = model.marketplace
        store.isInstalled = { [weak model] server in
            guard let model else { return false }
            return model.mcp.servers.contains { $0.registryName == server.name }
        }
        Task { await store.loadInitial() }
        runLoop(8.0)

        // MARK: MCP tool selection

        // The picker only exists inside an expanded server row, and it is the one
        // place a server's cost is visible before a request. Rendered against
        // whatever server is actually connected rather than a fixture, so the
        // numbers in the picture are real ones.
        if let server = model.mcp.servers.first(where: { !model.mcp.discoveredTools(id: $0.id).isEmpty }) {
            emit(
                "mcp-tools",
                DiagnosticsPanel(config: server, mcp: model.mcp)
                    .padding(Bud.Space.md)
                    .background(Color.black.opacity(0.30)),
                width: Bud.contentMeasure,
                // Tall enough for the whole panel. A frame smaller than its
                // content does not clip it — SwiftUI draws the overflow — so an
                // undersized harness invents collisions that the app never has.
                height: 620,
                directory: directory,
                into: &written
            )
        }

        // MARK: Chat surfaces

        for (name, turn) in Self.sampleTurns() {
            emit(
                name,
                TranscriptRow(turn: turn, model: model, isLatest: true)
                    .frame(width: Bud.contentMeasure - 24),
                width: Bud.contentMeasure,
                height: 360,
                directory: directory,
                into: &written
            )
        }

        // The same reasoning turn in each of the three modes. The default folds it
        // away once the answer lands — which is the point of the default and also
        // means the default looks exactly like the old behaviour in a screenshot.
        // So the proof that it is visible at all has to be taken with it on.
        if let reasoning = Self.sampleTurns().first(where: { $0.0 == "turn-reasoning" })?.1 {
            for (suffix, mode) in [
                ("always", ReasoningVisibility.always),
                ("hidden", ReasoningVisibility.hidden),
            ] {
                model.config.reasoningVisibility = mode
                emit(
                    "reasoning-\(suffix)",
                    TranscriptRow(turn: reasoning, model: model, isLatest: true)
                        .frame(width: Bud.contentMeasure - 24)
                        .background(Color.black.opacity(0.30)),
                    width: Bud.contentMeasure,
                    height: 420,
                    directory: directory,
                    into: &written
                )
            }
            // Left as it was found: every later surface draws with the real setting.
            model.config.reasoningVisibility = .whileThinking
        }

        // The panel's glass wrapper is replaced by an equivalent tinted fill.
        // `cacheDisplay` cannot composite the backdrop, so the wrapper would
        // contribute nothing but a flat tint anyway; this keeps the capture about
        // layout. Glass rendering itself is proven in the live app by
        // `--verify-ui`.
        emit(
            "chat-empty",
            ChatView(model: model)
                .frame(width: Bud.panelWidth, height: Bud.panelHeight)
                .background(Color.black.opacity(0.30)),
            width: Bud.panelWidth,
            height: Bud.panelHeight,
            directory: directory,
            into: &written
        )

        emit(
            "chat-transcript",
            ScrollView {
                // Built once: `sampleTurns` assembles fresh turns every call, and
                // asking for it per row would build the whole set once per row.
                let sample = Self.sampleTurns()
                VStack(alignment: .leading, spacing: Bud.Space.lg) {
                    ForEach(Array(sample.enumerated()), id: \.element.1.id) { index, pair in
                        TranscriptRow(
                            turn: pair.1,
                            model: model,
                            isLatest: index == sample.count - 1
                        )
                    }
                }
                .padding(Bud.Space.md)
                // The same column the app puts these rows in. Rendered without
                // it the harness showed a full-width transcript that the app
                // never draws, which is worse than showing nothing.
                .frame(maxWidth: Bud.contentMeasure, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .frame(width: Bud.panelWidth, height: Bud.panelHeight)
            .background(Color.black.opacity(0.30)),
            width: Bud.panelWidth,
            height: Bud.panelHeight,
            directory: directory,
            into: &written
        )

        // MARK: Browser

        // A real page in the real view, loaded from a local file so the picture
        // does not depend on a site being up. What it shows is what the tools
        // drive — there is only one web view.
        let page = directory.appendingPathComponent("browser-page.html")
        try? Self.browserFixture.write(to: page, atomically: true, encoding: .utf8)
        Task { try? await model.browser.open(page.path) }
        runLoop(4.0)
        emit(
            "browser",
            BrowserView(model: model)
                .frame(width: Bud.panelWidth, height: Bud.panelHeight)
                .background(Color.black.opacity(0.30)),
            width: Bud.panelWidth,
            height: Bud.panelHeight,
            directory: directory,
            into: &written
        )

        // MARK: A browser call in the transcript

        // Through the provider itself, so the picture is of the real result the
        // real tool returns — screenshot file, spec and all — rather than a
        // reconstruction of one.
        let browserTurn = Deferred<Turn>()
        Task { @MainActor in
            try? await model.browser.open(page.path)
            let provider = BrowserToolProvider(engine: model.browser)
            let result = await provider.invoke(
                tool: "browser_open",
                arguments: .object(["url": .string(page.path)]),
                callID: "render-browser"
            )
            browserTurn.value = Turn(
                role: .assistant,
                segments: [
                    .tool(
                        id: "browser-segment",
                        call: ToolCall(
                            id: "render-browser",
                            name: "browser_open",
                            arguments: "{\"url\":\"browser-page.html\"}"
                        ),
                        providerName: "Browser",
                        state: .succeeded,
                        resultText: result.text,
                        ui: result.ui,
                        app: nil
                    ),
                ]
            )
        }
        runLoop(4.0)
        if let turn = browserTurn.value {
            emit(
                "browser-in-chat",
                TranscriptRow(turn: turn, model: model, isLatest: true)
                    .padding(Bud.Space.md)
                    .frame(width: Bud.contentMeasure, alignment: .leading)
                    .background(Color.black.opacity(0.30)),
                width: Bud.contentMeasure,
                height: 640,
                directory: directory,
                into: &written
            )
        } else {
            written.append("browser-in-chat: BLANK (the tool returned no result)")
        }

        // MARK: History

        // Against the real archive rather than fixtures, so the rows in the
        // picture are rows that exist. Empty when there is nothing saved, which
        // is itself a state worth seeing.
        emit(
            "history",
            ConversationHistoryView(model: model)
                .frame(width: Bud.panelWidth, height: Bud.panelHeight)
                .background(Color.black.opacity(0.30)),
            width: Bud.panelWidth,
            height: Bud.panelHeight,
            directory: directory,
            into: &written
        )

        // MARK: Find

        // The find state is driven directly. The bar itself needs a keystroke to
        // open, but what is worth looking at is the marking and the dimming, and
        // `TranscriptRow` takes both as parameters — so this is the real render
        // path, not a reproduction of it.
        do {
            let sample = Self.sampleTurns()
            let query = "service"
            let found = Set(sample.filter { $0.1.matches(query) }.map(\.1.id))
            emit(
                "transcript-find",
                ScrollView {
                    VStack(alignment: .leading, spacing: Bud.Space.lg) {
                        ForEach(Array(sample.enumerated()), id: \.element.1.id) { _, pair in
                            TranscriptRow(
                                turn: pair.1,
                                model: model,
                                highlight: query,
                                isDimmed: !found.contains(pair.1.id)
                            )
                        }
                    }
                    .padding(Bud.Space.md)
                    .frame(maxWidth: Bud.contentMeasure, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .frame(width: Bud.panelWidth, height: Bud.panelHeight)
                .background(Color.black.opacity(0.30)),
                width: Bud.panelWidth,
                height: Bud.panelHeight,
                directory: directory,
                into: &written
            )
        }

        // MARK: Generative UI

        let spec: JSONValue = .object([
            "title": .string("Server Health"),
            "components": .array([
                .object([
                    "type": .string("metrics"),
                    "items": .array([
                        .object(["label": .string("Requests"), "value": .string("18.4k"), "delta": .string("+12%"), "trend": .string("up")]),
                        .object(["label": .string("p95"), "value": .string("142ms"), "delta": .string("-8%"), "trend": .string("down")]),
                        .object(["label": .string("Errors"), "value": .string("0.4%"), "trend": .string("flat")]),
                    ]),
                ]),
                .object([
                    "type": .string("row"),
                    "children": .array([
                        "comfy", "bud", "learniwashere", "openclaw",
                        "arpunkememb", "career-ops", "p-vulnerable", "competitivefin",
                    ].map { name in
                        .object([
                            "type": .string("text"),
                            "value": .string(name),
                            "style": .string("caption"),
                        ])
                    }),
                ]),
                .object([
                    "type": .string("table"),
                    "columns": .array([.string("Service"), .string("Region"), .string("Status")]),
                    "rows": .array([
                        .array([.string("api"), .string("us-east-1"), .string("healthy")]),
                        .array([.string("worker"), .string("eu-west-1"), .string("degraded")]),
                        .array([.string("scheduler"), .string("us-east-1"), .string("healthy")]),
                    ]),
                ]),
                .object([
                    "type": .string("progress"),
                    "label": .string("Deploy"),
                    "value": .number(0.72),
                    "caption": .string("rolling out 9/12"),
                ]),
                .object([
                    "type": .string("callout"),
                    "kind": .string("warning"),
                    "title": .string("Region degraded"),
                    "value": .string("eu-west-1 is serving elevated latency. Failover is available."),
                ]),
                .object([
                    "type": .string("button"),
                    "label": .string("Fail over"),
                    "symbol": .string("arrow.triangle.branch"),
                    "action": .object(["id": .string("f"), "prompt": .string("fail over")]),
                    "style": .string("primary"),
                ]),
            ]),
        ])

        emit(
            "generative-ui",
            GenerativeUIView(spec: spec, onAction: { _ in }, onPrompt: { _ in })
                .padding(Bud.Space.md)
                .frame(width: Bud.panelWidth - 24),
            width: Bud.panelWidth,
            height: 620,
            directory: directory,
            into: &written
        )

        // MARK: A rendered team

        // Sprites written the way a tool's images are: real PNGs in Bud's own
        // directory, referenced by file URL, which is the only path the renderer
        // will read from. What this is testing is the layout — six of something
        // is where sizing stops being a detail.
        func sprite(_ hue: Double) -> String {
            let size = 120
            let image = NSImage(size: NSSize(width: size, height: size))
            image.lockFocus()
            NSColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: size, height: size).fill()
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSRect(x: size / 4, y: size / 4, width: size / 2, height: size / 2).fill()
            image.unlockFocus()
            guard let tiff = image.tiffRepresentation,
                  let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            else { return "" }
            return ImageAssets.store(base64: data.base64EncodedString(), mimeType: "image/png")?
                .absoluteString ?? ""
        }

        let team: [(String, String, String, Double)] = [
            ("Blaziken", "Fire / Fighting", "Adamant · Speed Boost", 0.02),
            ("Garchomp", "Dragon / Ground", "Jolly · Rough Skin", 0.14),
            ("Rotom-Wash", "Electric / Water", "Bold · Levitate", 0.55),
            ("Corviknight", "Steel / Flying", "Impish · Mirror Armor", 0.62),
            ("Amoonguss", "Grass / Poison", "Relaxed · Regenerator", 0.30),
            ("Kingambit", "Dark / Steel", "Adamant · Supreme Overlord", 0.75),
        ]
        let tiles: [JSONValue] = team.map { name, types, ability, hue in
            .object([
                "type": .string("card"),
                "title": .string(name),
                "subtitle": .string(types),
                "children": .array([
                    .object([
                        "type": .string("image"),
                        "url": .string(sprite(hue)),
                        "alt": .string(name),
                        "width": .number(96),
                        "height": .number(96),
                        "radius": .number(10),
                        "action": .object([
                            "id": .string("explain-\(name)"),
                            "prompt": .string("Explain what \(name) does on this team."),
                        ]),
                    ]),
                    .object([
                        "type": .string("text"),
                        "value": .string(ability),
                        "style": .string("caption"),
                    ]),
                ]),
            ])
        }
        let teamSpec: JSONValue = .object([
            "title": .string("Team"),
            "components": .array([
                .object([
                    "type": .string("grid"),
                    "columns": .number(3),
                    "children": .array(tiles),
                ]),
            ]),
        ])
        emit(
            "team",
            GenerativeUIView(spec: teamSpec, onAction: { _ in }, onPrompt: { _ in })
                .padding(Bud.Space.md)
                .frame(width: Bud.contentMeasure)
                .background(Color.black.opacity(0.30)),
            width: Bud.contentMeasure,
            height: 560,
            directory: directory,
            into: &written
        )

        // MARK: A team, looked up

        // The whole story in one picture: nothing below knows a single URL. Six
        // names go in, six pictures come back, and the grid is built out of what
        // came back. The species artwork is the article's own lead image, which is
        // what a filename search would never have found.
        let looked = Deferred<[String: FoundImage]>()
        let lookedFor = ["Blaziken", "Garchomp", "Rotom", "Corviknight", "Amoonguss", "Kingambit"]
        Task {
            let found = await ImageSearch.find(lookedFor)
            looked.value = Dictionary(found.map { ($0.query, $0) }, uniquingKeysWith: { first, _ in first })
        }
        runLoop(20.0)

        let found = looked.value ?? [:]
        let foundTiles: [JSONValue] = foundTilesFrom(lookedFor, found)
        let foundSpec: JSONValue = .object([
            "title": .string("Team, looked up"),
            "components": .array([
                .object([
                    "type": .string("grid"),
                    "columns": .number(3),
                    "children": .array(foundTiles),
                ]),
                .object([
                    "type": .string("callout"),
                    "kind": .string("info"),
                    "title": .string("Where these came from"),
                    "value": .string(
                        lookedFor.compactMap { found[$0] }
                            .map { "\($0.title) — \($0.credit ?? "unstated")" }
                            .joined(separator: " · ")
                    ),
                ]),
            ]),
        ])
        emit(
            "looked-up",
            GenerativeUIView(spec: foundSpec, onAction: { _ in }, onPrompt: { _ in })
                .padding(Bud.Space.md)
                .frame(width: Bud.contentMeasure)
                .background(Color.black.opacity(0.30)),
            width: Bud.contentMeasure,
            height: 620,
            directory: directory,
            into: &written
        )

        // MARK: Skills

        emit(
            "skills",
            SkillsSettingsView(registry: model.skills)
                .padding(Bud.Space.lg)
                .frame(width: 900, height: 660, alignment: .topLeading)
                .background(Color.black.opacity(0.30)),
            width: 900,
            height: 660,
            directory: directory,
            into: &written
        )

        // MARK: What a risky skill looks like

        // A synthetic report rather than a downloaded one: the point is the
        // screen, and finding a real skill with a real credential-stealing script
        // in it is not something to go looking for.
        let flagged = SkillScanReport(
            findings: [
                SkillFinding(
                    severity: .dangerous,
                    title: "Reads credentials",
                    detail: "Paths holding keys and tokens. A skill has almost no reason to open them. Found: “~/.ssh/id_rsa”.",
                    file: "scripts/sync.py"
                ),
                SkillFinding(
                    severity: .dangerous,
                    title: "Pipes a download into a shell",
                    detail: "Whatever is at the other end runs with your permissions, and what it is cannot be checked from here. Found: “curl -fsSL https://… | sh”.",
                    file: "scripts/setup.sh"
                ),
                SkillFinding(
                    severity: .caution,
                    title: "A runnable script",
                    detail: "“scripts/setup.sh” can be executed. Skills may ship scripts, so this is normal — read it if you did not expect one.",
                    file: "scripts/setup.sh"
                ),
                SkillFinding(
                    severity: .caution,
                    title: "Reaches the network",
                    detail: "Not wrong in itself — plenty of skills fetch something — but it is where data would leave from. Found: “curl -fsSL”.",
                    file: "scripts/setup.sh"
                ),
            ],
            fileCount: 14,
            byteCount: 96_400,
            executables: ["scripts/setup.sh", "scripts/sync.py"],
            declaresTools: "Bash(curl:*) Read"
        )
        emit(
            "skill-review",
            SkillReviewSheet(
                pending: SkillRegistry.PendingSkill(
                    entry: AvailableSkill(
                        source: SkillSource.curated[0],
                        folder: "skills/example",
                        name: "example-sync",
                        summary: "Syncs things.",
                        isInstalled: false
                    ),
                    report: flagged
                ),
                onInstall: {},
                onCancel: {}
            )
            .background(Color.black.opacity(0.55)),
            width: 620,
            height: 620,
            directory: directory,
            into: &written
        )

        // MARK: Memory

        // The empty state first. The scratch store this mode opens has had
        // nothing remembered into it, which is exactly what a fresh install
        // looks like — and seeding first would mean never seeing it at all.
        emit(
            "memory-empty",
            MemorySettingsView()
                .padding(Bud.Space.lg)
                .frame(width: 900, height: 660, alignment: .topLeading)
                .background(Color.black.opacity(0.30)),
            width: 900,
            height: 660,
            directory: directory,
            into: &written
        )

        // Then the same surface with notes in it, written through the store
        // rather than inserted into the table, so the picture is of the real
        // write path. Taller than the pane on purpose: the pane scrolls, and the
        // point of the picture is all three groups at once.
        Self.seedMemory()
        emit(
            "memory",
            MemorySettingsView()
                .padding(Bud.Space.lg)
                .frame(width: 900, height: 1_200, alignment: .topLeading)
                .background(Color.black.opacity(0.30)),
            width: 900,
            height: 1_200,
            directory: directory,
            into: &written
        )

        // MARK: Settings tabs

        // Seeded above, so `settings-memory` shows the same notes in the pane the
        // rail actually draws — the tab is only real if it is reachable from it.
        for tab in SettingsTab.allCases {
            // Taller than the window on purpose. These panes scroll, and a capture
            // that stops at the fold is a picture of the settings nobody looked at
            // — the limits, the last card on General, were below it for two
            // releases. The frame is a review artifact, not a claim about the
            // window's size, which is still 620.
            //
            // General grew a Context budget section below the prompt, so it gets a
            // taller capture than the other tabs; a section that renders off the
            // bottom of its own review image is a section nobody reviewed.
            let generalHeight: CGFloat = tab == .general ? 2_400 : 1_500
            emit(
                "settings-\(tab.rawValue)",
                SettingsView(model: model, initialTab: tab)
                    .frame(width: 900, height: generalHeight),
                width: 900,
                height: generalHeight,
                directory: directory,
                into: &written
            )
        }

        // MARK: The confirmation surface
        //
        // Rendered over a transcript-shaped backdrop rather than on its own,
        // because what matters is whether it reads as a decision standing in
        // front of the conversation rather than beside it.

        for (label, request) in [
            ("confirm-command", ToolConfirmation(
                tool: "run_shell",
                headline: "Run this command?",
                detail: "rm -rf ./build && swift build -c release",
                note: "in ~/Projects/bud",
                isCommand: true
            )),
            ("confirm-write", ToolConfirmation(
                tool: "write_file",
                headline: "Write this file?",
                detail: "/Users/someone/Projects/bud/Sources/Bud/Core/ToolConfirmation.swift",
                note: "1,284 characters",
                preview: "import Foundation\n\n/// One thing the agent wants to do to the machine, waiting for a person\nto agree to it.",
                isCommand: false
            )),
        ] {
            emit(
                label,
                ZStack {
                    VStack(alignment: .leading, spacing: Bud.Space.sm) {
                        ForEach(0..<6, id: \.self) { row in
                            RoundedRectangle(cornerRadius: Bud.Radius.control)
                                .fill(.white.opacity(0.06))
                                .frame(height: row.isMultiple(of: 3) ? 46 : 18)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(Bud.Space.md)
                    ToolConfirmationView(request: request, onAnswer: { _ in })
                }
                .frame(width: 520, height: 420)
                .background(Color.black.opacity(0.30)),
                width: 520,
                height: 420,
                directory: directory,
                into: &written
            )
        }

        // MARK: The budget warning
        //
        // Rendered standalone because the condition that shows it — a
        // conversation at 80% of its ceiling — is a state the harness does not
        // otherwise reach, and the whole point of the banner is that it appears
        // before the ceiling does.

        emit(
            "budget-banner",
            BudgetBanner(
                spent: 1_600,
                budget: 2_000,
                onNewChat: {},
                onCompact: {},
                onRaiseBudget: {}
            )
            .padding(Bud.Space.md)
            .frame(width: Bud.contentMeasure)
            .background(Color.black.opacity(0.30)),
            width: Bud.contentMeasure,
            height: 200,
            directory: directory,
            into: &written
        )

        // MARK: The overwrite confirmation
        //
        // The one confirmation that did not exist before: replacing a file is the
        // only write that destroys content, and the dialog has to say so — plus
        // the directory-scope button that makes a batch of edits ask once.

        emit(
            "confirm-overwrite",
            ToolConfirmationView(
                request: ToolConfirmation(
                    tool: "write_file",
                    headline: "Replace this file?",
                    detail: "/Users/someone/Projects/bud/Sources/Bud/Core/Domain.swift",
                    note: "1,284 bytes on disk",
                    preview: "public struct Turn: Sendable, Identifiable {",
                    isCommand: false,
                    risk: .localWrite,
                    overwrites: true,
                    overwrittenBytes: 1_284,
                    scopeDirectory: "/Users/someone/Projects/bud/Sources/Bud/Core"
                ),
                onAnswer: { _ in }
            )
            .padding(Bud.Space.md)
            .frame(width: 520, height: 420)
            .background(Color.black.opacity(0.30)),
            width: 520,
            height: 420,
            directory: directory,
            into: &written
        )

        // MARK: Onboarding
        //
        // Rendered for the same reason the banner is: the condition that shows it
        // is a state the harness cannot reach through the real panel, and a flow
        // nobody reviewed is a flow nobody should walk.

        emit(
            "onboarding",
            OnboardingView(state: OnboardingState(model: model), onDismiss: {})
                .frame(width: 640, height: 720),
            width: 640,
            height: 720,
            directory: directory,
            into: &written
        )

        // MARK: Marketplace with live registry data

        emit(
            "marketplace",
            MarketplaceView(store: store, mcp: model.mcp, model: model)
                .padding(Bud.Space.lg)          // the pane inset the shell supplies
                .frame(width: 900, height: 620),
            width: 900,
            height: 620,
            directory: directory,
            into: &written
        )

        // The Glama pane, driven with the real key so the credit line and the
        // per-record listing links are actually on screen rather than assumed.
        // Glama's API Data License requires both, so this is a compliance check
        // as much as a layout one.
        let glamaKey = BudConfigLoader.load().glamaAPIKey
        if glamaKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            print("  skip marketplace-glama (no Glama key configured)")
        } else {
            store.glamaAPIKey = glamaKey
            store.source = .glama
            runLoop(10.0)
            emit(
                "marketplace-glama",
                MarketplaceView(store: store, mcp: model.mcp, model: model)
                    .padding(Bud.Space.lg)      // the pane inset the shell supplies
                    .frame(width: 900, height: 620),
                width: 900,
                height: 620,
                directory: directory,
                into: &written
            )
        }

        // MARK: Sprites from a URL

        // The shape the getcompetitive server is being asked to feed: six species
        // resolved to artwork URLs, laid out as a team. Two things are being
        // checked and neither can be answered from the source — that a remote PNG
        // actually loads and draws, and that a grid of them looks deliberate at
        // more than one count.
        let spriteURLs: [(String, String, Int)] = [
            ("Sneasler", "Poison / Fighting", 903),
            ("Annihilape", "Fighting / Ghost", 979),
            ("Lucario-Mega", "Fighting / Steel", 10059),
            ("Corviknight", "Steel / Flying", 823),
            ("Basculegion", "Water / Ghost", 902),
            ("Kingambit", "Dark / Steel", 983),
        ]

        // Fetched once up front so the cache is warm. `AsyncImage` shares
        // `URLSession.shared`, so the render below reads them from memory rather
        // than waiting on six sockets inside a layout pass.
        let warmed = Deferred<Int>()
        Task {
            var loaded = 0
            for (_, _, number) in spriteURLs {
                let address = "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/other/official-artwork/\(number).png"
                if let url = URL(string: address),
                   let (data, _) = try? await URLSession.shared.data(from: url),
                   !data.isEmpty {
                    loaded += 1
                }
            }
            warmed.value = loaded
        }
        runLoop(30.0)
        print("  sprites fetched: \(warmed.value ?? 0) of \(spriteURLs.count)")

        func spriteTiles(_ species: [(String, String, Int)]) -> [JSONValue] {
            species.map { name, types, number in
                .object([
                    "type": .string("card"),
                    "title": .string(name),
                    "subtitle": .string(types),
                    "children": .array([
                        .object([
                            "type": .string("image"),
                            "url": .string(
                                "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/other/official-artwork/\(number).png"
                            ),
                            "alt": .string(name),
                            "width": .number(96),
                            "height": .number(96),
                            "fit": .string("fit"),
                            "radius": .number(10),
                        ]),
                    ]),
                ])
            }
        }

        for (label, columns, slice) in [
            ("sprites-narrow", 3, spriteURLs),
            ("sprites-4col", 4, Array(spriteURLs.prefix(8))),
            ("sprites-2col", 2, Array(spriteURLs.prefix(5))),
        ] {
            let spec: JSONValue = .object([
                "title": .string("Team"),
                "components": .array([
                    .object([
                        "type": .string("grid"),
                        "columns": .number(Double(columns)),
                        "children": .array(spriteTiles(slice)),
                    ]),
                ]),
            ])
            // The narrow one is rendered at the panel's own minimum width, which is
            // the only size where a three-column grid has to hold a 96-point sprite
            // in a cell barely wider than it. The frame has to match the window or
            // the capture is a clipped wide layout rather than a narrow one.
            let measure: CGFloat = label == "sprites-narrow" ? 520 : Bud.contentMeasure
            emit(
                label,
                GenerativeUIView(spec: spec, onAction: { _ in }, onPrompt: { _ in })
                    .padding(Bud.Space.md)
                    .frame(width: measure)
                    .background(Color.black.opacity(0.30)),
                width: measure,
                height: 700,
                directory: directory,
                into: &written
            )
        }

        // MARK: Delegation

        // Two real delegations through the real path: the agent registry names a
        // scout and a reviewer, `spawn_subagents` is invoked with those names, and
        // the panel is drawn from the runs that come back. The prompts are trivial
        // because what is being looked at is the screen, not the model's diligence
        // — but the runs, the agents, the models and the tool counts are all real.
        // Representative rather than installed: the roster's third group is what a
        // skill declaring `agent:` adds, and a screenshot of the feature should
        // show it rather than a section that only appears on someone else's
        // machine. The built-ins and the MCP agent beside it are real.
        var sampleSkills = SkillStore.installed()
        sampleSkills.append(
            Skill(
                name: "release-notes",
                summary: "Turn a range of commits into release notes.",
                license: nil,
                compatibility: nil,
                metadata: [:],
                allowedTools: "run_shell read_file",
                delegation: "Write the release notes for a range of commits. Hand it the range.",
                instructions: """
                    Read the commits in the range you were given with `git log`, group them \
                    by what they changed for the reader rather than by author or date, and \
                    write the notes in the project's existing voice. Leave out anything \
                    that is not a change a user of the project would notice.
                    """
            )
        )
        model.agents.source = { (sampleSkills, model.mcp.servers) }
        model.agents.rebuild(skills: sampleSkills, servers: model.mcp.servers)

        // Awaited, and run without tools so each is a single round trip. Left
        // running, they stream tokens into the panel for the whole of the rest of
        // the render, which redraws it continuously — correct for the app, and
        // minutes per screenshot for the harness.
        let delegated = Deferred<[SubagentRun]>()
        Task {
            await model.agents.refresh()
            _ = await model.subagents.invoke(
                tool: "spawn_subagents",
                arguments: .object([
                    "tasks": .array([
                        .object([
                            "agent": .string("scout"),
                            "title": .string("Check the release notes"),
                            "prompt": .string(
                                "In under 40 words: what is a scout for, and what should it "
                                    + "never do?"
                            ),
                            "allow_tools": .bool(false),
                        ]),
                        .object([
                            "agent": .string("reviewer"),
                            "title": .string("Review the naming"),
                            "prompt": .string(
                                "Read Sources/Bud/Core/ToolProvider.swift around ToolNaming and "
                                    + "report anything about the sanitising rules that looks "
                                    + "wrong or under-specified. Under 40 words."
                            ),
                        ]),
                    ]),
                ]),
                callID: "render-delegation"
            )
        }
        runLoop(25.0)

        emit(
            "agents-delegates",
            SubagentPanel(supervisor: model.subagents, model: model, pane: .delegates)
                .padding(Bud.Space.lg)
                .frame(width: Bud.contentMeasure, height: 620)
                .background(Color.black.opacity(0.30)),
            width: Bud.contentMeasure,
            height: 620,
            directory: directory,
            into: &written
        )

        emit(
            "agents-activity",
            SubagentPanel(supervisor: model.subagents, model: model, pane: .activity)
                .padding(Bud.Space.lg)
                .frame(width: Bud.contentMeasure, height: 620)
                .background(Color.black.opacity(0.30)),
            width: Bud.contentMeasure,
            height: 620,
            directory: directory,
            into: &written
        )

        emit(
            "subagents",
            SubagentPanel(supervisor: model.subagents, model: model)
                .frame(width: Bud.panelWidth, height: 520),
            width: Bud.panelWidth,
            height: 520,
            directory: directory,
            into: &written
        )

        print("rendered \(written.count) surfaces")
        exit(0)
    }

    // MARK: - Capture

    /// The tile a looked-up picture becomes, or a note that nothing was found —
    /// an empty card is a worse answer than one that says so.
    @MainActor
    private static func foundTilesFrom(_ names: [String], _ found: [String: FoundImage]) -> [JSONValue] {
        names.map { name in
            let image = found[name]
            var children: [JSONValue] = []
            if let image {
                children.append(.object([
                    "type": .string("image"),
                    "url": .string(image.url),
                    "alt": .string(name),
                    "width": .number(96),
                    "height": .number(96),
                    "radius": .number(10),
                ]))
                let kind: String
                switch image.source {
                case .article: kind = "the article"
                case .artwork: kind = "official artwork"
                case .search: kind = "a match on the words"
                }
                children.append(.object([
                    "type": .string("text"),
                    "value": .string(kind + " · " + image.title),
                    "style": .string("caption"),
                ]))
            } else {
                children.append(.object([
                    "type": .string("text"),
                    "value": .string("Nothing found."),
                    "style": .string("caption"),
                ]))
            }
            return .object([
                "type": .string("card"),
                "title": .string(name),
                "children": .array(children),
            ])
        }
    }

    private static func emit<V: View>(
        _ name: String,
        _ view: V,
        width: CGFloat,
        height: CGFloat,
        directory: URL,
        into written: inout [String]
    ) {
        // Skipped before the hosting view is built rather than after: laying the
        // view out is the expensive part, and this is the only way to make the
        // filter worth having.
        guard only.isEmpty || name.contains(only) else { return }
        let root = ZStack {
            // Stand-in for the desktop the panel would be floating over. Without
            // it, glass tints and hairline edges composite against a void.
            LinearGradient(
                colors: [
                    Color(red: 0.16, green: 0.18, blue: 0.30),
                    Color(red: 0.30, green: 0.22, blue: 0.34),
                    Color(red: 0.42, green: 0.26, blue: 0.28),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            view
        }
        .frame(width: width, height: height)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: root)
        window.contentView?.layoutSubtreeIfNeeded()
        runLoop(0.7)
        window.displayIfNeeded()

        guard let contentView = window.contentView,
              let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else {
            FileHandle.standardError.write(Data("FAIL  \(name): could not allocate a bitmap\n".utf8))
            return
        }
        contentView.cacheDisplay(in: contentView.bounds, to: rep)

        guard let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("FAIL  \(name): could not encode PNG\n".utf8))
            return
        }
        let url = directory.appendingPathComponent("\(name).png")
        try? png.write(to: url)

        let distinct = Self.distinctColours(rep)
        // A flat fill yields one or two colours. Anything real — even just the
        // backdrop gradient — yields dozens. A capture that drew nothing must be
        // reported as such rather than quietly counted as a success.
        let verdict = distinct >= 8 ? "ok   " : "BLANK"
        print("  \(verdict) \(name).png  \(rep.pixelsWide)x\(rep.pixelsHigh)  \(distinct) distinct colours")
        if distinct >= 8 { written.append(name) }
    }

    /// Counts distinct quantised colours in a coarse sample of the bitmap.
    private static func distinctColours(_ rep: NSBitmapImageRep) -> Int {
        let step = max(1, rep.pixelsWide / 120)
        var distinct: Set<Int> = []
        var y = 0
        while y < rep.pixelsHigh {
            var x = 0
            while x < rep.pixelsWide {
                if let colour = rep.colorAt(x: x, y: y) {
                    let r = Int(colour.redComponent * 31)
                    let g = Int(colour.greenComponent * 31)
                    let b = Int(colour.blueComponent * 31)
                    let a = Int(colour.alphaComponent * 31)
                    distinct.insert(r << 15 | g << 10 | b << 5 | a)
                }
                x += step
            }
            y += step
        }
        return distinct.count
    }

    private static func runLoop(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: - Sample data

    private static let browserFixture = """
    <!doctype html>
    <html><head><meta charset="utf-8"><title>Package runs</title>
    <style>
      body { font: 14px -apple-system, system-ui, sans-serif; margin: 0; padding: 28px;
             background: #101216; color: #e8eaee; }
      h1 { font-size: 20px; margin: 0 0 4px; }
      p.sub { margin: 0 0 20px; color: #9aa2b1; }
      table { border-collapse: collapse; width: 100%; }
      th, td { text-align: left; padding: 9px 10px; border-bottom: 1px solid #232833; }
      th { color: #9aa2b1; font-weight: 500; font-size: 12px; text-transform: uppercase; }
      .ok { color: #4fd08a; } .warn { color: #e0b341; }
      button { font: inherit; padding: 7px 14px; border-radius: 7px; border: 1px solid #2d3442;
               background: #1b202a; color: #e8eaee; }
      input { font: inherit; padding: 7px 10px; border-radius: 7px; border: 1px solid #2d3442;
              background: #171b22; color: #e8eaee; width: 220px; }
    </style></head>
    <body>
      <h1>Package runs</h1>
      <p class="sub">Last 24 hours across 6 runners</p>
      <div style="display:flex;gap:10px;margin-bottom:22px">
        <input placeholder="Filter by package">
        <button>Refresh</button>
        <button>Export CSV</button>
      </div>
      <table>
        <tr><th>Package</th><th>Runner</th><th>Duration</th><th>Status</th></tr>
        <tr><td>registry-client</td><td>eu-west-1</td><td>1m 12s</td><td class="ok">passed</td></tr>
        <tr><td>auth-service</td><td>eu-west-1</td><td>3m 04s</td><td class="ok">passed</td></tr>
        <tr><td>worker-pool</td><td>us-east-1</td><td>8m 41s</td><td class="warn">retried</td></tr>
        <tr><td>edge-proxy</td><td>ap-south-1</td><td>2m 18s</td><td class="ok">passed</td></tr>
      </table>
    </body></html>
    """

    private static func sampleTurns() -> [(String, Turn)] {
        var reasoning = Turn(role: .assistant)
        reasoning.appendReasoning(
            "The user wants the current state of the deployment. I should check the MCP server "
            + "for the service list before answering, rather than guessing from context."
        )
        reasoning.appendText(
            "Three services are reporting. `api` and `scheduler` are healthy; **worker** in "
            + "`eu-west-1` is degraded with elevated p95 latency.\n\n"
            + "Failover is available if you want it."
        )

        var tool = Turn(role: .assistant)
        tool.segments.append(
            .tool(
                id: "t1",
                call: ToolCall(id: "c1", name: "infra__list_services", arguments: #"{"region":"eu-west-1"}"#),
                providerName: "infra",
                state: .succeeded,
                resultText: "worker  degraded  p95=812ms\napi     healthy   p95=141ms",
                ui: nil,
                app: nil
            )
        )
        tool.segments.append(.text(id: "t2", text: "One service is degraded in `eu-west-1`."))

        var failed = Turn(role: .assistant)
        failed.segments.append(
            .tool(
                id: "f1",
                call: ToolCall(id: "c2", name: "infra__restart", arguments: #"{"service":"worker"}"#),
                providerName: "infra",
                state: .failed,
                resultText: "The server exited with status 3.\nstderr: permission denied for region eu-west-1",
                ui: nil,
                app: nil
            )
        )

        var running = Turn(role: .assistant)
        running.segments.append(
            .tool(
                id: "r1",
                call: ToolCall(id: "c3", name: "web_fetch", arguments: #"{"url":"https://status.example.com"}"#),
                providerName: "Bud",
                state: .running,
                resultText: nil,
                ui: nil,
                app: nil
            )
        )
        running.isStreaming = true

        var notice = Turn(role: .assistant)
        notice.segments.append(
            .notice(
                id: "n1",
                text: "Stopped after 24 tool rounds without a final answer. Raise the round limit in Settings.",
                kind: .warning
            )
        )

        let user = Turn(
            role: .user,
            segments: [.text(id: "u1", text: "What's the state of the eu-west-1 deployment right now?")]
        )

        return [
            ("turn-user", user),
            ("turn-reasoning", reasoning),
            ("turn-tool-success", tool),
            ("turn-tool-failed", failed),
            ("turn-tool-running", running),
            ("turn-notice", notice),
        ]
    }

    // MARK: - Memory fixture

    /// One note for the memory render: what it says, the scope it is filed under,
    /// and how long before the render it was written.
    private struct MemoryNote {
        let text: String
        let scope: String
        /// Seconds before now.
        ///
        /// `BudStore.remember` stamps the moment it is called, so a fixture of
        /// nine notes written in the same millisecond would render nine copies of
        /// "now" — and the ordering and the relative ages are two of the things
        /// this surface has to get right, so a picture that cannot show them is
        /// not evidence of anything.
        let ago: TimeInterval
    }

    /// Nine notes across the three scopes, in the voice the model writes them in:
    /// one self-contained sentence each, with no conversation around it.
    private static let memoryNotes: [MemoryNote] = [
        MemoryNote(
            text: "Keeps the shell in ~/Projects/bud and reads build output there.",
            scope: "general",
            ago: 8 * 60
        ),
        MemoryNote(
            text: "Bud's prose uses British spelling: recognise, behaviour, colour — comments, copy and commit messages alike.",
            scope: "project",
            ago: 31 * 60
        ),
        MemoryNote(
            text: "Comments explain why. One that restates the code is treated as a defect.",
            scope: "project",
            ago: 5 * 3_600
        ),
        MemoryNote(
            text: "Wants a failing build fixed before it is asked to review anything.",
            scope: "general",
            ago: 86_400
        ),
        MemoryNote(
            text: "Wants the answer first and the reasoning after; says so when a reply warms up instead.",
            scope: "user",
            ago: 2 * 86_400
        ),
        MemoryNote(
            text: "No third-party packages. Anything new comes from the standard library or does not get added.",
            scope: "project",
            ago: 4 * 86_400
        ),
        MemoryNote(
            text: "Works in Swift 6 with strict concurrency. Objects to @unchecked Sendable used to quiet the compiler.",
            scope: "user",
            ago: 6 * 86_400
        ),
        MemoryNote(
            text: "Prefers a short answer to a complete one — say what is missing rather than padding the list.",
            scope: "user",
            ago: 13 * 86_400
        ),
        MemoryNote(
            text: "Dislikes being asked to confirm what the code can answer.",
            scope: "general",
            ago: 21 * 86_400
        ),
    ]

    /// Writes the fixture through the store, then moves the timestamps back.
    ///
    /// `remember` rather than an insert of its own, so the render exercises the
    /// write the app actually performs. The backdating is the one thing the store
    /// cannot be asked for — nothing in the app writes a note in the past — and
    /// it is safe here because the only caller is `--render-ui`, which opens a
    /// scratch database that is thrown away when the process exits.
    private static func seedMemory() {
        for note in memoryNotes {
            BudStore.remember(note.text, scope: note.scope, source: "render")
        }
        BudDatabase.shared.transaction { handle in
            for note in memoryNotes {
                guard let statement = Statement(handle, "UPDATE lessons SET created_at = ? WHERE text = ?;")
                else { continue }
                statement
                    .bind(1, Date().addingTimeInterval(-note.ago))
                    .bind(2, note.text)
                    .run()
            }
        }
    }
}

