import Foundation

/// A minimal MCP server that speaks the real protocol over stdio, used by
/// `--verify-live`.
///
/// Verification needs a server that is always available and never flaky. Driving
/// this process through `MCPClient` exercises the entire stack for real — process
/// spawning, newline-delimited JSON-RPC framing, the initialize handshake, cursor
/// pagination, tool discovery, namespacing and `tools/call` — with no network and
/// no dependency on npx, uvx, node or python being installed.
///
/// It is also genuinely useful by hand: point any MCP client at
/// `<binary> --mcp-echo-server` to check the client's own plumbing.
public enum EchoMCPServer {
    public static func run() -> Never {
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let request = JSONValue(parsing: trimmed) else { continue }

            // Notifications carry no id and must not be answered.
            let id = request["id"]
            guard let method = request["method"]?.stringValue else { continue }
            if id == nil { continue }

            let result = respond(method: method, params: request["params"] ?? .object([:]))
            var envelope: [String: JSONValue] = [
                "jsonrpc": "2.0",
                "id": id ?? .null,
            ]
            switch result {
            case .value(let value):
                envelope["result"] = value
            case .error(let message):
                envelope["error"] = .object(["code": .number(-32601), "message": .string(message)])
            }
            emit(.object(envelope))
        }
        exit(0)
    }

    /// A local result type: `Result`'s failure must conform to `Error`, and a
    /// bare message string is the whole payload here.
    private enum Reply {
        case value(JSONValue)
        case error(String)
    }

    private static func respond(
        method: String,
        params: JSONValue
    ) -> Reply {
        switch method {
        case "initialize":
            return .value(.object([
                "protocolVersion": .string(
                    params["protocolVersion"]?.stringValue ?? "2025-06-18"
                ),
                "capabilities": .object([
                    "tools": .object(["listChanged": false]),
                ]),
                "serverInfo": .object([
                    "name": .string("bud-echo"),
                    "version": .string("1.0.0"),
                ]),
            ]))

        case "ping":
            return .value(.object([:]))

        case "tools/list":
            // Reported as one page with no cursor: the client must still handle
            // the nextCursor field being absent.
            return .value(.object([
                "tools": .array([
                    .object([
                        "name": .string("echo"),
                        "description": .string("Echo a message back. Used to verify the tool pipeline."),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "message": .object([
                                    "type": .string("string"),
                                    "description": .string("Text to echo."),
                                ]),
                            ]),
                            "required": .array([.string("message")]),
                        ]),
                    ]),
                    .object([
                        "name": .string("add"),
                        "description": .string("Add two integers."),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "a": .object(["type": .string("integer")]),
                                "b": .object(["type": .string("integer")]),
                            ]),
                            "required": .array([.string("a"), .string("b")]),
                        ]),
                    ]),
                    .object([
                        "name": .string("delay"),
                        "description": .string("Wait the given number of milliseconds before answering. Used to verify cancellation."),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "milliseconds": .object(["type": .string("integer")]),
                            ]),
                            "required": .array([.string("milliseconds")]),
                        ]),
                    ]),
                ]),
            ]))

        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return .error("tools/call requires 'name'")
            }
            let arguments = params["arguments"] ?? .object([:])
            switch name {
            case "echo":
                let message = arguments["message"]?.stringValue ?? ""
                return .value(textResult("echo: \(message)"))
            case "add":
                let a = arguments["a"]?.doubleValue ?? 0
                let b = arguments["b"]?.doubleValue ?? 0
                let sum = a + b
                let rendered = sum == sum.rounded()
                    ? String(Int64(sum)) : String(sum)
                return .value(textResult(rendered))
            case "delay":
                // A blocking sleep on purpose: a test server that answers
                // instantly cannot prove that cancelling a turn stops the tools
                // it was waiting on. Capped so a broken cancellation cannot
                // hang a suite forever.
                let milliseconds = min(arguments["milliseconds"]?.doubleValue ?? 2_000, 30_000)
                Thread.sleep(forTimeInterval: milliseconds / 1_000)
                return .value(textResult("done after \(Int(milliseconds))ms"))
            case "fail":
                // Lets the caller prove that an error result is surfaced as an
                // error rather than as an empty success.
                return .value(.object([
                    "isError": .bool(true),
                    "content": .array([
                        .object(["type": .string("text"), "text": .string("deliberate failure")]),
                    ]),
                ]))
            default:
                return .error("unknown tool '\(name)'")
            }

        case "resources/list":
            return .value(.object(["resources": .array([])]))
        case "prompts/list":
            return .value(.object(["prompts": .array([])]))

        default:
            return .error("unknown method '\(method)'")
        }
    }

    private static func textResult(_ text: String) -> JSONValue {
        .object([
            "content": .array([
                .object(["type": .string("text"), "text": .string(text)]),
            ]),
        ])
    }

    private static func emit(_ value: JSONValue) {
        FileHandle.standardOutput.write(Data((value.encodedString() + "\n").utf8))
    }
}
