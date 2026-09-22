import AppKit
import SwiftUI
import WebKit

// MARK: - Render phase

/// Where a tool row's app is in the resolve-and-render cycle.
public enum MCPAppPhase: Equatable {
    case loading
    case rendered(MCPAppResource)
    case failed(String)
}

/// The isolated renderer behind one app: a nonpersistent web view whose top
/// document is Bud's own host page, with the app running in a sandboxed iframe
/// inside it.
///
/// Every isolation decision lives here, and each one is the difference between a
/// host and a browser:
/// - a **nonpersistent** data store, so the app leaves no cookies or storage;
/// - the app in an `allow-scripts`-only iframe, opaque origin, so it can never
///   reach the top page's `messageHandlers` or touch another app's DOM;
/// - the Content-Security-Policy the server declared, with restrictive defaults,
///   injected before a byte of the app parses;
/// - main-frame navigation denied for anything but the host page.
@MainActor
public final class MCPAppCoordinator: NSObject, WKNavigationDelegate {
    public let webView: WKWebView
    public let bridge: MCPAppBridge
    public let resource: MCPAppResource
    public let attachment: MCPAppAttachment

    /// The app asked for a different size (its content outgrew the shell). The
    /// shell listens and grows the frame, because a pinned height is what clips
    /// the bottom of a tall app.
    public var onSizeChange: ((CGSize?) -> Void)?

    private var delivered = false
    private var injected = false
    private var tornDown = false

    public init(
        resource: MCPAppResource,
        attachment: MCPAppAttachment,
        onServerToolCall: @escaping (JSONValue) async -> JSONValue
    ) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.suppressesIncrementalRendering = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let controller = WKUserContentController()
        configuration.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: configuration)
        let bridge = MCPAppBridge()
        self.webView = webView
        self.bridge = bridge
        self.resource = resource
        self.attachment = attachment

        super.init()

        controller.add(bridge, name: MCPAppBridge.messageHandlerName)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground") // transparent over the glass panel
        bridge.webView = webView
        bridge.onReady = { [weak self] in
            guard let self else { return }
            self.didInitialize = true
            self.deliver()
        }
        bridge.onSizeChange = { [weak self] size in
            self?.onSizeChange?(size)
        }
        bridge.onServerToolCall = onServerToolCall

        webView.loadHTMLString(MCPAppBridge.hostPageHTML, baseURL: nil)
    }

    /// The app completed `ui/notifications/initialized` and was handed its input
    /// and result. Observable so a test can watch the handshake without replacing
    /// the delivery closure.
    public private(set) var didInitialize = false

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // `loadHTMLString` does not reliably reflect the base URL in `webView.url`,
        // so the one-shot flag is the guard, not the address: the host page is the
        // only thing that ever finishes loading, and the resource goes in once.
        guard !injected else { return }
        injected = true
        let call = "window.__budSetResource(" + MCPAppBridge.jsString(resource.wrappedHTML) + ")"
        webView.evaluateJavaScript(call)
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // The only top-frame navigation that is ever legitimate is the host page
        // itself (about:blank, loaded with no base URL). Everything else — a
        // redirect, a link, a scheme with no handler — is refused.
        guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
        let allowed = url.scheme == "about"
        decisionHandler(allowed ? .allow : .cancel)
    }

    /// The handshake is done: the input and the complete result go over, in that
    /// order, and exactly once.
    private func deliver() {
        guard !delivered else { return }
        delivered = true
        bridge.deliverInput(attachment.arguments)
        bridge.deliverResult(attachment.callResult)
    }

    /// Before the view is unmounted, the app is told. Its reply no longer
    /// matters, so it is a fire-and-forget request.
    public func teardown() {
        guard !tornDown else { return }
        tornDown = true
        bridge.teardown()
        webView.stopLoading()
    }
}

/// The SwiftUI surface for one rendered app.
public struct MCPAppWebView: NSViewRepresentable {
    let resource: MCPAppResource
    let attachment: MCPAppAttachment
    let onServerToolCall: (JSONValue) async -> JSONValue
    let onUserMessage: (JSONValue) async -> JSONValue
    let onUpdateModelContext: (JSONValue) -> Void
    let onSizeChange: (CGSize?) -> Void

    public func makeCoordinator() -> MCPAppCoordinator {
        let coordinator = MCPAppCoordinator(
            resource: resource,
            attachment: attachment,
            onServerToolCall: onServerToolCall
        )
        coordinator.onSizeChange = onSizeChange
        coordinator.bridge.onUserMessage = onUserMessage
        coordinator.bridge.onUpdateModelContext = onUpdateModelContext
        return coordinator
    }

    public func makeNSView(context: Context) -> WKWebView {
        context.coordinator.webView
    }

    public func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.onSizeChange = onSizeChange
        context.coordinator.bridge.onUserMessage = onUserMessage
        context.coordinator.bridge.onUpdateModelContext = onUpdateModelContext
    }

    public static func dismantleNSView(_ nsView: WKWebView, coordinator: MCPAppCoordinator) {
        coordinator.teardown()
    }
}

// MARK: - The shell

/// What the transcript renders for a tool call that produced an app: the web
/// view at a reading height that grows with the app's own reported size, a thin
/// border when the server asked for one, and a caption that says what it is and
/// where it came from.
///
/// The loading, failure and text fallback live in the tool row, which owns the
/// asynchronous resolve; this is only the resolved surface.
public struct MCPAppShell: View {
    let resource: MCPAppResource
    let attachment: MCPAppAttachment
    let onServerToolCall: (JSONValue) async -> JSONValue
    let onUserMessage: (JSONValue) async -> JSONValue
    let onUpdateModelContext: (JSONValue) -> Void

    @BudState private var height: CGFloat = 520

    public var body: some View {
        VStack(alignment: .leading, spacing: Bud.Space.xs) {
            MCPAppWebView(
                resource: resource,
                attachment: attachment,
                onServerToolCall: onServerToolCall,
                onUserMessage: onUserMessage,
                onUpdateModelContext: onUpdateModelContext
            ) { size in
                guard let size else { return }
                // The app reports its content height; the host fits it, within
                // the flexible bound it declared, so a tall app is not clipped.
                height = min(max(size.height, 240), 900)
            }
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                    .strokeBorder(
                        (resource.prefersBorder ?? false) ? Color.white.opacity(0.18) : .clear,
                        lineWidth: 0.6
                    )
            }
            Text("\(attachment.toolName) — app from the MCP server")
                .font(Bud.Font.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
