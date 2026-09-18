import Foundation

/// `--profile`: what a request costs in time, and where.
///
/// The counterpart to `--measure`, which counts characters. Both exist for the
/// same reason: the expensive part of an assistant is the part that runs on
/// every single request, and none of it is visible from the outside. A slow
/// path that looks cheap is the one that ships.
@MainActor
public enum PerformanceProfileCLI {
    private static let iterations = 200

    public static func run(arguments: [String]) async -> Bool {
        BudConfigLoader.ensureDirectory()
        let config = BudConfigLoader.load()
        let env = AppEnvironment(config: config)
        let mcp = MCPManager()

        // A registry with the built-ins in it, so the measurement includes the
        // delegation description at the size it actually reaches the model.
        let warmupAgents = AgentRegistry()
        warmupAgents.rebuild(skills: [], servers: [])

        let providers: [any ToolProvider] = [
            NativeToolsProvider(),
            MemoryToolsProvider(),
            mcp,
            SubagentSupervisor(env: env, agents: warmupAgents),
            GenUIToolProvider(),
            BrowserToolProvider(engine: BrowserEngine()),
            SkillToolProvider(),
        ]
        for provider in providers {
            await env.registry.register(provider)
        }
        await mcp.connectAllAutoStart()
        await mcp.refreshTools()

        func time(_ label: String, _ work: () -> Void) -> Double {
            _ = work()  // warm the caches a first call would fill
            let start = Date()
            for _ in 0..<iterations { work() }
            let each = Date().timeIntervalSince(start) / Double(iterations) * 1000
            print("  \(label.padding(toLength: 34, withPad: " ", startingAt: 0))\(String(format: "%7.2f ms", each))")
            return each
        }

        let installed = SkillStore.installed()
        let toolCount = await env.registry.descriptors().count

        print("\nPer request — what runs before every model call\n")
        let skillMs = time("skill list for the prompt (\(installed.count) skill\(installed.count == 1 ? "" : "s"))") {
            _ = SkillContext.catalogue(query: "").text
        }
        let noteMs = time("remembered notes") { _ = BudStore.lessonContext() }
        let registryMs = await timeAsync("tool descriptors (\(toolCount) tools)") {
            _ = await env.registry.descriptors()
        }

        let building = SkillContext.catalogue(query: "").text.count + BudStore.lessonContext().count + config.systemPrompt.count
        let total = skillMs + noteMs + registryMs
        print("\n  " + String(repeating: "─", count: 52))
        print("  \("per request".padding(toLength: 34, withPad: " ", startingAt: 0))\(String(format: "%7.2f ms", total))")
        print("  \("of which is the system prompt".padding(toLength: 34, withPad: " ", startingAt: 0))\(String(format: "%7.2f ms", skillMs + noteMs))")
        print("  system prompt is \(building) characters")

        // A turn is several requests; the round limit is what makes this a
        // multiplier rather than a footnote.
        let rounds = max(1, config.maxToolRounds)
        print("\n  at the \(rounds)-round ceiling a single turn spends"
            + " \(String(format: "%.0f", total * Double(rounds))) ms rebuilding the same prompt")
        await mcp.shutdown()
        return true
    }

    private static func timeAsync(_ label: String, _ work: () async -> Void) async -> Double {
        await work()
        let start = Date()
        for _ in 0..<iterations { await work() }
        let each = Date().timeIntervalSince(start) / Double(iterations) * 1000
        print("  \(label.padding(toLength: 34, withPad: " ", startingAt: 0))\(String(format: "%7.2f ms", each))")
        return each
    }
}
