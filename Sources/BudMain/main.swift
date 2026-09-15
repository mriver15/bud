import BudKit
import Foundation

let arguments = CommandLine.arguments

// Acts as a real MCP server over stdio. Used by `--verify-live` to exercise the
// whole client stack without depending on npx, uvx or the network.
if arguments.contains("--mcp-echo-server") {
    EchoMCPServer.run()
}

// Offline assertion suite. Deterministic, no network. The release gate.
if arguments.contains("--self-test") {
    let report = BudSelfTest.run()
    for failure in report.failures {
        FileHandle.standardError.write(Data("FAIL  \(failure)\n".utf8))
    }
    print(report.ok
          ? "PASS  \(report.passed)/\(report.total) checks passed"
          : "FAIL  \(report.passed)/\(report.total) checks passed")
    exit(report.ok ? 0 : 1)
}

// Launches the real panel and inspects the rendered layer tree, then exits.
// Proves Liquid Glass is live rather than a flat fallback.
if arguments.contains("--verify-ui") {
    BudUIVerification.run()
}

// End-to-end checks against the live DeepSeek API, the live MCP registry, and a
// real MCP server process.
if arguments.contains("--verify-live") {
    let report = await BudLiveVerification.run()
    for failure in report.failures {
        FileHandle.standardError.write(Data("FAIL  \(failure)\n".utf8))
    }
    print(report.ok
          ? "PASS  \(report.passed)/\(report.total) live checks passed"
          : "FAIL  \(report.passed)/\(report.total) live checks passed")
    exit(report.ok ? 0 : 1)
}

// Renders each real surface to a PNG for visual review, then exits.
if let index = arguments.firstIndex(of: "--render-ui") {
    let path = arguments.count > index + 1
        ? arguments[index + 1]
        : FileManager.default.temporaryDirectory.appendingPathComponent("bud-ui").path
    UIRender.run(outputDirectory: path)
}

BudApp.main()
