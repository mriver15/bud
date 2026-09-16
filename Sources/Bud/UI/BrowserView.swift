import AppKit
import SwiftUI

/// The browser surface: an address bar over the live page.
///
/// It shows the same view the tools drive. That is the point of having it — a
/// result that says "clicked ref 7" is a different thing when the page it clicked
/// is on screen beside the transcript, and a model that has wandered somewhere
/// unhelpful is visible rather than reported.
struct BrowserView: View {
    let model: AppModel

    @BudState private var address = ""
    /// True while the field holds something the user typed and the page has not
    /// overruled yet, so a load never overwrites a half-typed address.
    @BudState private var isEditingAddress = false
    @BudState private var errorText: String?
    @FocusState private var isAddressFocused: Bool

    private var engine: BrowserEngine { model.browser }

    var body: some View {
        VStack(spacing: 0) {
            bar
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.6)
            page
        }
        .onAppear { syncAddress() }
        .onChange(of: engine.revision) { _, _ in
            syncAddress()
            errorText = engine.lastError
        }
    }

    // MARK: - Address bar

    private var bar: some View {
        HStack(spacing: Bud.Space.sm) {
            navigationButton("chevron.left", help: "Back", enabled: engine.canGoBack) {
                Task { await run { try await engine.goBack() } }
            }
            navigationButton("chevron.right", help: "Forward", enabled: engine.canGoForward) {
                Task { await run { try await engine.goForward() } }
            }
            navigationButton(
                engine.state.isLoading ? "xmark" : "arrow.clockwise",
                help: engine.state.isLoading ? "Stop" : "Reload",
                enabled: !engine.state.url.isEmpty
            ) {
                if engine.state.isLoading {
                    engine.webView.stopLoading()
                } else {
                    Task { await run { try await engine.reload() } }
                }
            }

            HStack(spacing: Bud.Space.xs) {
                Image(systemName: "globe")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)

                TextField("Enter an address", text: $address)
                    .textFieldStyle(.plain)
                    .font(Bud.Font.callout)
                    .focused($isAddressFocused)
                    .onSubmit { go() }
                    .onChange(of: isAddressFocused) { _, focused in
                        if !focused { syncAddress() }
                    }

                if engine.state.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                }
            }
            .padding(.horizontal, Bud.Space.sm)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: Bud.Radius.control, style: .continuous)
                    .fill(.ultraThinMaterial)
            }

            if let title = engine.state.title.isEmpty ? nil : engine.state.title {
                Text(title)
                    .font(Bud.Font.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(maxWidth: 220, alignment: .trailing)
                    .help(title)
            }
        }
        .padding(.horizontal, Bud.Space.md)
        .padding(.vertical, Bud.Space.sm)
    }

    private func navigationButton(
        _ symbol: String,
        help: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(enabled ? Color.secondary : Color.secondary.opacity(0.35))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    // MARK: - Page

    @ViewBuilder
    private var page: some View {
        ZStack {
            PageHost(engine: engine)

            if engine.state.url.isEmpty, let errorText {
                EmptyStateView(
                    systemImage: "exclamationmark.triangle",
                    title: "That did not load",
                    message: errorText
                )
            } else if engine.state.url.isEmpty {
                EmptyStateView(
                    systemImage: "globe",
                    title: "No page open",
                    message: "Type an address above, or ask Bud to look something up — the page it opens appears here."
                )
            }
        }
    }

    // MARK: - Actions

    private func go() {
        let target = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        isEditingAddress = false
        isAddressFocused = false
        Task { await run { try await engine.open(target) } }
    }

    /// The address follows the page unless the field is being typed in.
    private func syncAddress() {
        guard !isAddressFocused, !isEditingAddress else { return }
        address = engine.state.url
    }

    private func run(_ work: () async throws -> Void) async {
        do {
            try await work()
            errorText = nil
        } catch let error as BrowserError {
            errorText = error.errorDescription
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - The page itself

/// Puts the engine's own view on screen.
///
/// Reparented rather than mirrored: a second web view showing the same URL would
/// be a different page a moment later, and the surface would be a re-enactment of
/// what the tools did rather than what they did.
private struct PageHost: NSViewRepresentable {
    let engine: BrowserEngine

    func makeCoordinator() -> Coordinator { Coordinator(engine: engine) }

    func makeNSView(context: Context) -> NSView {
        let container = BrowserContainer()
        container.wantsLayer = true
        engine.detachForDisplay()
        container.addSubview(engine.webView)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if engine.webView.superview !== container {
            engine.webView.removeFromSuperview()
            container.addSubview(engine.webView)
        }
        container.needsLayout = true
    }

    /// Put it back in the offscreen window rather than letting it be released
    /// with the view tree. The session — cookies, scroll position, the page being
    /// read — belongs to the app, not to the surface that happened to be showing.
    static func dismantleNSView(_ container: NSView, coordinator: Coordinator) {
        coordinator.engine.park()
    }

    final class Coordinator {
        let engine: BrowserEngine
        init(engine: BrowserEngine) { self.engine = engine }
    }
}

/// Sizes the page to whatever the surface gives it.
///
/// A `WKWebView` added to a fresh container is framed against that container's
/// bounds *at the moment it is added*, which for a SwiftUI representable is zero,
/// because layout has not run yet. Autoresizing does recover from that — the
/// container grows by the full width, so the view does too — but only because it
/// started at zero and only grew. Setting the frame on every layout says what is
/// meant instead of relying on the arithmetic of an accident.
private final class BrowserContainer: NSView {
    override func layout() {
        super.layout()
        for subview in subviews { subview.frame = bounds }
    }
}
