import Foundation
import WebKit

// MARK: - Bridge policy

/// What the host will do on the app's behalf. Deliberately tiny in V1, because
/// each row here is a capability the app gets, and a read-only app should get
/// as close to none as it can.
public enum MCPAppPolicy {
    /// An external link the app asked to open. Only the browser schemes are
    /// honoured, and the URL must be well-formed — everything else is refused.
    public static func openableLink(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else { return nil }
        return url
    }
}

// MARK: - The bridge

/// The `postMessage` bridge between a sandboxed app and the native host.
///
/// The WKWebView's top document is Bud's own page; the app runs in a sandboxed
/// `iframe` inside it, with an opaque origin and `allow-scripts` only, so it can
/// never reach `window.webkit.messageHandlers` — that object exists only on the
/// top page, and the iframe is not same-origin with it. The top page relays
/// `postMessage` between the two, which is the whole bridge.
///
/// On the native side this is a JSON-RPC server: requests get a response, and
/// the `ui/initialize` handshake plus `tool-input`/`tool-result` delivery happen
/// here, nowhere else.
@MainActor
public final class MCPAppBridge: NSObject, WKScriptMessageHandler {
    public static let messageHandlerName = "budApp"
    public static let hostOrigin = "mcpapp://host/"

    public weak var webView: WKWebView?

    /// The view finished `ui/notifications/initialized`; safe to deliver input.
    public var onReady: (() -> Void)?
    /// The app asked for a different size, when its content outgrew the shell.
    public var onSizeChange: ((CGSize?) -> Void)?
    /// A message the app sent the host (V1: none are implemented; kept for the
    /// future bridge rows).
    public var onMessage: ((String, JSONValue) -> Void)?
    /// The app asked the server to run a tool on its behalf. Wired by the view
    /// to the MCP manager; returns the wire `CallToolResult` to send back.
    public var onServerToolCall: ((JSONValue) async -> JSONValue)?
    /// The app asked to send a message to the agent. Async because it waits on a
    /// person to confirm; returns the wire result to send back.
    public var onUserMessage: ((JSONValue) async -> JSONValue)?
    /// The app pushed context the agent should carry into future turns.
    /// Synchronous: the host stores it and acknowledges.
    public var onUpdateModelContext: ((JSONValue) -> Void)?

    private var initialized = false
    private var nextID = 1
    /// Every message the host page forwarded, requests and notifications both.
    /// Diagnostic surface: proves a message reached native at all.
    public private(set) var receivedCount = 0

    // MARK: Incoming

    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        receivedCount += 1
        let value = JSONValue(any: message.body)
        guard let method = value["method"]?.stringValue else { return }
        let params = value["params"] ?? .object([:])
        if let id = value["id"], !id.isNull {
            // `tools/call` is the one route that talks to the server, and the
            // server is async, so it cannot share the synchronous answer path.
            if method == "tools/call", let onServerToolCall {
                Task { [weak self] in
                    guard let self else { return }
                    let result = await onServerToolCall(params)
                    self.send(JSONRPCResponse(id: id, result: result).json)
                }
                return
            }
            // `ui/message` waits on a person to confirm, so it too cannot share
            // the synchronous answer path.
            if method == "ui/message", let onUserMessage {
                Task { [weak self] in
                    guard let self else { return }
                    let result = await onUserMessage(params)
                    self.send(JSONRPCResponse(id: id, result: result).json)
                }
                return
            }
            switch respond(method, params) {
            case .result(let result):
                send(JSONRPCResponse(id: id, result: result).json)
            case .error(let error):
                send(JSONRPCResponse(id: id, error: error).json)
            }
        } else {
            handleNotification(method, params: params)
        }
    }

    /// The answer for a request the host serves synchronously. Anything it does
    /// not serve fails closed as a *JSON-RPC error* — never a `result` that only
    /// looks like an answer — so the app's SDK rejects the promise rather than
    /// handing its result handler an empty object.
    private enum Response {
        case result(JSONValue)
        case error(JSONRPCError)
    }

    private func respond(_ method: String, _ params: JSONValue) -> Response {
        switch method {
        case "ui/initialize":
            return .result(initializeResult())
        case "ping":
            return .result(.object([:]))
        case "ui/open-link":
            guard let url = params["url"]?.stringValue,
                  let approved = MCPAppPolicy.openableLink(url)
            else {
                return .error(JSONRPCError(
                    code: -32000,
                    message: "Link opening denied: only http and https are allowed."
                ))
            }
            NSWorkspace.shared.open(approved)
            return .result(.object([:]))
        case "ui/request-display-mode":
            // Only inline exists, so the answer is always inline.
            return .result(.object(["mode": .string("inline")]))
        case "tools/call":
            // Routed asynchronously above; this is the no-handler fallback.
            return .error(JSONRPCError(code: -32000, message: "tools/call is not available in this version."))
        case "ui/message":
            // Routed asynchronously above when a handler is wired; otherwise it
            // cannot be answered and the app is told so.
            return .error(JSONRPCError(code: -32000, message: "ui/message is not available in this version."))
        case "ui/update-model-context":
            onUpdateModelContext?(params)
            return .result(.object([:]))
        case "resources/read":
            return .error(JSONRPCError(code: -32000, message: "resources/read is not available in this version."))
        default:
            return .error(JSONRPCError(code: -32601, message: "Method not found: \(method)"))
        }
    }

    private func handleNotification(_ method: String, params: JSONValue) {
        switch method {
        case "ui/notifications/initialized":
            initialized = true
            onReady?()
        case "ui/notifications/size-changed":
            let width = params["width"]?.doubleValue.map { CGFloat($0) }
            let height = params["height"]?.doubleValue.map { CGFloat($0) }
            if let width, let height {
                onSizeChange?(CGSize(width: width, height: height))
            } else {
                onSizeChange?(nil)
            }
        default:
            onMessage?(method, params)
        }
    }

    // MARK: Host → app

    /// Sends a notification (no id) to the app.
    public func notify(_ method: String, params: JSONValue) {
        send(JSONRPCRequest(method: method, params: params).json)
    }

    /// Sends a request (with id) and ignores the reply — used for teardown,
    /// where the app's answer no longer matters.
    public func request(_ method: String, params: JSONValue) {
        let id = JSONValue.number(Double(nextID))
        nextID += 1
        send(JSONRPCRequest(id: id, method: method, params: params).json)
    }

    public func deliverInput(_ arguments: JSONValue) {
        notify("ui/notifications/tool-input", params: .object(["arguments": arguments]))
    }

    public func deliverResult(_ result: JSONValue) {
        notify("ui/notifications/tool-result", params: result)
    }

    public func deliverCancelled(_ reason: String) {
        notify("ui/notifications/tool-cancelled", params: .object(["reason": .string(reason)]))
    }

    public func teardown() {
        guard initialized else { return }
        request("ui/resource-teardown", params: .object([:]))
    }

    // MARK: Initialization result

    private func initializeResult() -> JSONValue {
        .object([
            "protocolVersion": .string("2026-01-26"),
            "hostCapabilities": .object([
                "openLinks": .object([:]),
                "logging": .object([:]),
            ]),
            "hostInfo": .object([
                "name": .string("Bud"),
                "version": .string("1.0"),
            ]),
            "hostContext": .object([
                "theme": .string("dark"),
                "displayMode": .string("inline"),
                "availableDisplayModes": .array([.string("inline")]),
                "containerDimensions": .object(["maxHeight": .number(900), "maxWidth": .number(820)]),
                "platform": .string("desktop"),
                "userAgent": .string("Bud"),
                "locale": .string(Locale.current.identifier),
                "timeZone": .string(TimeZone.current.identifier),
                "deviceCapabilities": .object([
                    "touch": .bool(false),
                    "hover": .bool(true),
                ]),
                "styles": .object([
                    "variables": .object(Self.themeVariables),
                ]),
            ]),
        ])
    }

    /// The standardized CSS custom properties, in the `light-dark()` form the
    /// spec expects. Bud is dark glass, so the light half mirrors the dark half;
    /// apps read these through `applyHostStyleVariables` and fall back on their
    /// own defaults for anything the host does not send.
    ///
    /// Every key here must be in the SDK's `styles.variables` enum, which is
    /// *strict*: a key it does not know — `--color-accent` included — is an
    /// `unrecognized_keys` failure that rejects the whole `ui/initialize`
    /// response, so the app never sends `initialized` and the handshake dies.
    /// No accent key survives this gate, so it is deliberately absent.
    nonisolated static let themeVariables: [String: JSONValue] = [
        "--color-background-primary": .string("light-dark(#ffffff, #171717)"),
        "--color-background-secondary": .string("light-dark(#f3f4f6, #242424)"),
        "--color-background-tertiary": .string("light-dark(#e5e7eb, #2e2e2e)"),
        "--color-text-primary": .string("light-dark(#111827, #fafafa)"),
        "--color-text-secondary": .string("light-dark(#4b5563, #d4d4d4)"),
        "--color-text-tertiary": .string("light-dark(#6b7280, #9ca3af)"),
        "--color-border-primary": .string("light-dark(#e5e7eb, #3f3f3f)"),
        "--font-sans": .string("-apple-system, system-ui, sans-serif"),
        "--font-mono": .string("ui-monospace, SFMono-Regular, monospace"),
    ]

    // MARK: Transport

    private func send(_ json: JSONValue) {
        guard let webView else { return }
        lastSent = json.encodedString()
        let call = "window.__budDeliver(" + Self.jsString(json.encodedString()) + ")"
        webView.evaluateJavaScript(call) { [weak self] _, error in
            self?.lastDeliveryError = error?.localizedDescription
        }
    }

    /// The last message the host sent the app, and any error delivering it —
    /// diagnostic surface for the handshake.
    public private(set) var lastSent: String?
    public private(set) var lastDeliveryError: String?

    /// A JSON string as a single-quoted JavaScript string literal. The string is
    /// always our own JSON, but escaping is cheap insurance against a result the
    /// app echoes back into the bridge.
    static nonisolated func jsString(_ text: String) -> String {
        var out = "'"
        for scalar in text.unicodeScalars {
            switch scalar {
            case "'": out += "\\'"
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "'"
    }

    /// The trusted host page: an empty shell that creates the sandboxed iframe
    /// and relays `postMessage`. It is Bud's own content, never the server's.
    public static let hostPageHTML = """
    <!doctype html><html><head><meta charset="utf-8"></head>
    <body style="margin:0;background:transparent">
    <script>
    (function () {
      "use strict";
      var iframe = document.createElement("iframe");
      iframe.setAttribute("sandbox", "allow-scripts");
      iframe.style.cssText = "border:0;width:100%;height:100%;display:block;position:fixed;inset:0";
      document.body.appendChild(iframe);

      window.__budSetResource = function (html) {
        iframe.srcdoc = html;
      };

      window.addEventListener("message", function (event) {
        if (event.source !== iframe.contentWindow) { return; }
        if (!event.data || typeof event.data !== "object") { return; }
        window.webkit.messageHandlers.budApp.postMessage(event.data);
      });

      window.__budDeliver = function (text) {
        iframe.contentWindow.postMessage(JSON.parse(text), "*");
      };
    })();
    </script>
    </body></html>
    """
}
