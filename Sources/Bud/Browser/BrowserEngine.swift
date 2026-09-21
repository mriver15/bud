import AppKit
import Foundation
import WebKit

/// What the page currently is.
public struct BrowserPageState: Sendable, Equatable {
    public var url: String
    public var title: String
    public var isLoading: Bool

    public static let empty = BrowserPageState(url: "", title: "", isLoading: false)
}

/// A real browser, driven natively.
///
/// WebKit rather than a bundled Chromium: it is already on the machine, it is
/// already what the panel uses to draw generated UI, and nothing has to be
/// downloaded before the first page loads. That is the whole of "lightweight" —
/// the alternative is a second browser shipped inside an assistant.
///
/// One web view, kept for the life of the app. State persists across tool calls
/// because browsing is a session — signing in, then clicking, then reading is one
/// activity, and a fresh renderer per call would lose the cookie between them.
///
/// The view lives in a window even when nothing is showing it. WebKit only lays
/// out and paints content that belongs to a window, so a view with no window can
/// navigate but cannot be snapshotted or read reliably.
@MainActor
public final class BrowserEngine: NSObject {
    /// The view the surface shows and the tools drive. One, not two: what the
    /// model is looking at and what is on screen have to be the same page, or the
    /// picture is a re-enactment.
    public let webView: WKWebView

    public private(set) var state = BrowserPageState.empty
    public private(set) var lastError: String?

    /// Bumped whenever the page settles, so a view can redraw its URL bar.
    public private(set) var revision = 0

    private var pendingLoad: CheckedContinuation<Void, Error>?
    private var isLoading = false
    private var parkingWindow: NSWindow?
    private var timeoutTask: Task<Void, Never>?

    /// Ids are assigned fresh on every snapshot, so a stale one is a ref the model
    /// invented or one a re-render invalidated. Failing loudly beats clicking
    /// whatever happens to sit at that position now.
    private var knownRefs: Set<Int> = []

    private static let loadTimeout: TimeInterval = 45

    public override init() {
        let configuration = WKWebViewConfiguration()
        // A real browsing session: sign-ins and preferences have to survive, or
        // half the pages worth automating are unreachable.
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.isElementFullscreenEnabled = false

        // Records what the page said to itself. Installed at document start so it
        // is listening before any of the page's own script runs — the error worth
        // having is usually the one thrown while the page is still initialising.
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.consoleHook,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        // A desktop user agent. Half the web serves a different site to whatever
        // it thinks is asking, and a mobile layout is the wrong one to automate.
        webView.customUserAgent = nil
        park()
    }

    // MARK: - Placement

    /// Holds the view in an offscreen window when no surface is showing it.
    ///
    /// Ordered in and fully transparent rather than merely hidden: an unparented
    /// or offscreen window is one WebKit may stop compositing, and a page that is
    /// not being composited cannot be snapshotted. `ignoresMouseEvents` keeps it
    /// from taking a click it is invisible for.
    public func park() {
        let window = parkingWindow ?? {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1280, height: 900),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.isExcludedFromWindowsMenu = true
            window.hasShadow = false
            window.collectionBehavior = [.stationary, .ignoresCycle]
            window.level = .normal
            parkingWindow = window
            return window
        }()
        guard webView.superview !== window.contentView else { return }
        webView.removeFromSuperview()
        webView.frame = window.contentView?.bounds ?? webView.frame
        webView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(webView)
        if !window.isVisible { window.orderFront(nil) }
    }

    /// Hands the view to a surface that will show it.
    public func detachForDisplay() {
        webView.removeFromSuperview()
    }

    // MARK: - Navigation

    public func open(_ target: String) async throws {
        let url = try Self.resolve(target)
        try await load(URLRequest(url: url))
    }

    public func goBack() async throws {
        guard webView.canGoBack else { throw BrowserError.noHistory }
        webView.goBack()
        try await settle()
    }

    public func goForward() async throws {
        guard webView.canGoForward else { throw BrowserError.noHistory }
        webView.goForward()
        try await settle()
    }

    public func reload() async throws {
        guard state.url.isEmpty == false else { throw BrowserError.noPage }
        webView.reload()
        try await settle()
    }

    public var canGoBack: Bool { webView.canGoBack }
    public var canGoForward: Bool { webView.canGoForward }

    private func load(_ request: URLRequest) async throws {
        lastError = nil
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pendingLoad = continuation
            isLoading = true
            state.isLoading = true
            revision &+= 1
            // A page that never reports back would hold the continuation for the
            // life of the app, and every later tool call would queue behind it.
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.loadTimeout))
                guard !Task.isCancelled else { return }
                self?.finish(load: BrowserError.timedOut)
            }
            // A local file is read through `loadFileURL`, which grants access to
            // its directory: `load(URLRequest)` on a `file://` URL is refused, so
            // opening a downloaded page would fail for a reason nobody could see.
            if let url = request.url, url.isFileURL {
                webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            } else {
                webView.load(request)
            }
        }
    }

    /// Waits for the page to settle after an action that navigates by itself.
    private func settle() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pendingLoad = continuation
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.loadTimeout))
                guard !Task.isCancelled else { return }
                self?.finish(load: nil)
            }
        }
    }

    /// Resumes exactly one waiter. Called from the delegate, from the timeout, and
    /// from a failed provisional load — so it has to be safe to call twice.
    private func finish(load error: Error?) {
        timeoutTask?.cancel()
        timeoutTask = nil
        isLoading = false
        state.isLoading = false
        refreshState()
        revision &+= 1
        if let error { lastError = error.localizedDescription }
        guard let continuation = pendingLoad else { return }
        pendingLoad = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    private func refreshState() {
        state = BrowserPageState(
            url: webView.url?.absoluteString ?? state.url,
            title: webView.title ?? state.title,
            isLoading: isLoading
        )
    }

    // MARK: - Reading

    /// The page's readable text.
    public func readableText(limit: Int = 40_000) async throws -> String {
        let raw = try await evaluate("return document.body ? document.body.innerText : ''") as? String ?? ""
        let collapsed = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .reduce(into: [String]()) { lines, line in
                // Runs of blank lines are layout, not content.
                if line.isEmpty, lines.last?.isEmpty != false { return }
                lines.append(line)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "\n…[truncated]"
    }

    /// Runs JavaScript in the page and returns whatever it produced.
    ///
    /// The result is round-tripped through JSON because that is the only shape
    /// WebKit hands back reliably across the process boundary — a bare object
    /// arrives as an opaque bridge reference that is useless to a tool result.
    @discardableResult
    public func evaluate(_ script: String, arguments: [String: Any] = [:]) async throws -> Any? {
        do {
            let result = try await webView.callAsyncJavaScript(
                script,
                arguments: arguments,
                in: nil,
                contentWorld: .page
            )
            return Self.unwrap(result)
        } catch {
            throw BrowserError.script(error.localizedDescription)
        }
    }

    /// `callAsyncJavaScript` delivers an object as its JSON text; a bare value
    /// arrives as itself. Both are returned as one thing so callers do not have
    /// to know which they got.
    private static func unwrap(_ result: Any?) -> Any? {
        guard let text = result as? String else { return result }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return text }
        return (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) ?? text
    }

    /// A structured outline of the page: what can be read, and what can be acted
    /// on, each action marked with the reference that acts on it.
    ///
    /// This is the tool that makes the rest usable. A model handed raw HTML picks
    /// selectors out of a document it cannot see; handed an outline with refs, it
    /// does what a person does — reads the labels and clicks the thing.
    ///
    /// `snapshot(maxLines:)` renders this to text; keeping the structure is what
    /// lets a delta compare refs and regions without re-parsing prose it just
    /// built.
    public func outline() async throws -> PageOutline {
        // The outline comes back as JSON text, which `unwrap` may already have
        // turned into a dictionary — so both shapes are accepted rather than
        // assuming the one that happens to arrive.
        let raw = try await evaluate(Self.snapshotScript)
        var parsed: [String: Any]?
        if let text = raw as? String {
            parsed = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        } else {
            parsed = raw as? [String: Any]
        }
        guard let lines = parsed?["lines"] as? [String],
              let refs = parsed?["refs"] as? [Int]
        else { throw BrowserError.script("the snapshot produced nothing readable") }

        knownRefs = Set(refs)
        let title = (parsed?["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? state.title
        // Each line is matched to its ref by the marker the script wrote into the
        // text, not by position in the list: headings and images carry none, so
        // an index into the lines would drift past the first of either.
        let outlined = lines.map { OutlineLine(text: $0, ref: Self.refMarker(in: $0)) }
        return PageOutline(url: state.url, title: title, lines: outlined)
    }

    /// The snapshot text: the structured outline rendered with a length cap.
    public func snapshot(maxLines: Int = 220) async throws -> String {
        try await outline().render(maxLines: maxLines)
    }

    /// The ref a rendered line carries, if it carries one.
    ///
    /// The script appends `[ref=N]` just after the label — before any `(checked)`,
    /// `(value: …)` or `-> href` it adds later — so it is read back here rather
    /// than guessed from the line's place in the list.
    private static func refMarker(in line: String) -> Int? {
        guard let open = line.range(of: "[ref=") else { return nil }
        let digits = line[open.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    // MARK: - Acting

    public func click(ref: Int) async throws {
        try requireRef(ref)
        let outcome = try await evaluate(Self.clickScript, arguments: ["ref": ref]) as? String
        guard outcome == "ok" else { throw BrowserError.staleRef(ref) }
        try await settleAfterAction()
    }

    public func type(ref: Int, text: String, submit: Bool) async throws {
        try requireRef(ref)
        let outcome = try await evaluate(
            Self.typeScript,
            arguments: ["ref": ref, "text": text, "submit": submit]
        ) as? String
        guard outcome == "ok" else { throw BrowserError.staleRef(ref) }
        if submit { try await settleAfterAction() }
    }

    public func press(_ key: String) async throws {
        _ = try await evaluate(Self.pressScript, arguments: ["pressedKey": key])
        try await settleAfterAction()
    }

    public func hover(ref: Int) async throws {
        try requireRef(ref)
        let outcome = try await evaluate(Self.hoverScript, arguments: ["ref": ref]) as? String
        guard outcome == "ok" else { throw BrowserError.staleRef(ref) }
    }

    /// Chooses an option in a `<select>`, by value or by its visible label.
    public func select(ref: Int, value: String?, label: String?) async throws {
        try requireRef(ref)
        let outcome = try await evaluate(
            Self.selectScript,
            arguments: ["ref": ref, "value": value ?? "", "label": label ?? ""]
        ) as? String
        switch outcome {
        case "ok":
            return
        case "missing":
            throw BrowserError.staleRef(ref)
        case "no-option":
            throw BrowserError.script("that dropdown has no option matching what was asked for")
        default:
            throw BrowserError.script("that element is not a dropdown")
        }
    }

    /// Waits for the page to catch up: text to appear, or an element to exist.
    ///
    /// Polled rather than event-driven because the page has no obligation to tell
    /// anyone it changed — a great deal of the web renders by mutating the DOM
    /// whenever a fetch resolves, and the DOM has no completion event.
    public func wait(
        text: String?,
        selector: String?,
        timeout: TimeInterval = 10
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let found = try await evaluate(
                Self.waitScript,
                arguments: ["text": text ?? "", "selector": selector ?? ""]
            ) as? Bool
            if found == true { return true }
            try await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    /// What the page logged, and what it threw.
    ///
    /// Usually the only evidence of why a page that looks fine is not working:
    /// a failed request, a framework complaining about a missing element, a
    /// script that threw before it finished wiring anything up.
    public func consoleMessages(limit: Int = 60) async throws -> [String] {
        // Accepted in both shapes for the same reason the snapshot is: the bridge
        // hands back an array as JSON text, which `unwrap` may already have turned
        // into a real array.
        let raw = try await evaluate(Self.consoleReadScript)
        var messages: [String] = []
        if let text = raw as? String {
            messages = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String] ?? []
        } else if let array = raw as? [Any] {
            messages = array.compactMap { $0 as? String }
        }
        return Array(messages.suffix(limit))
    }

    public func scroll(direction: String, amount: Int) async throws {
        _ = try await evaluate(
            Self.scrollScript,
            arguments: ["direction": direction, "amount": amount]
        )
    }

    /// A PNG of what the page looks like.
    ///
    /// Worth having even though the outline is usually enough: layout carries
    /// meaning that a DOM outline cannot — whether something is visible at all,
    /// what the error banner says, whether two things overlap.
    public func screenshot() async throws -> Data {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        let image = try await webView.takeSnapshot(configuration: configuration)
        guard let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:])
        else { throw BrowserError.script("the page produced no image") }
        return png
    }

    private func requireRef(_ ref: Int) throws {
        guard !knownRefs.isEmpty else {
            throw BrowserError.script("read the outline before acting on the page (browser_read, mode \"outline\") — it is what assigns refs")
        }
        guard knownRefs.contains(ref) else { throw BrowserError.staleRef(ref) }
    }

    /// A click or a keypress often starts a navigation that has not begun by the
    /// time the script returns. Without this the next read happens mid-load and
    /// reports the page that is being replaced.
    private func settleAfterAction() async throws {
        let before = state.url
        try await Task.sleep(for: .milliseconds(350))
        guard !isLoading, webView.url?.absoluteString != before else { return }
        try await settle()
    }

    // MARK: - Scripts

    private static let snapshotScript = """
    const visible = (el) => {
        if (!el.getClientRects().length) return false;
        const style = getComputedStyle(el);
        if (style.visibility === 'hidden' || style.display === 'none') return false;
        return !(style.opacity === '0');
    };
    const label = (el) => {
        const text = (el.getAttribute('aria-label') || el.getAttribute('placeholder')
            || el.getAttribute('title') || el.innerText || el.value || '').trim();
        return text.replace(/\\s+/g, ' ').slice(0, 120);
    };
    const role = (el) => {
        const explicit = el.getAttribute('role');
        if (explicit) return explicit;
        const tag = el.tagName.toLowerCase();
        if (tag === 'a') return 'link';
        if (tag === 'button') return 'button';
        if (tag === 'select') return 'combobox';
        if (tag === 'textarea') return 'textbox';
        if (tag === 'input') {
            const type = (el.getAttribute('type') || 'text').toLowerCase();
            if (type === 'submit' || type === 'button') return 'button';
            if (type === 'checkbox' || type === 'radio') return type;
            return 'textbox';
        }
        if (tag === 'h1' || tag === 'h2' || tag === 'h3') return 'heading';
        if (tag === 'img') return 'img';
        return null;
    };

    document.querySelectorAll('[data-bud-ref]').forEach((el) => el.removeAttribute('data-bud-ref'));

    const lines = [];
    const refs = [];
    let counter = 0;
    const interactive = new Set(['a', 'button', 'select', 'textarea', 'input']);

    const walk = (el) => {
        if (!(el instanceof Element)) return;
        if (el.hasAttribute('data-bud-ignore')) return;
        const tag = el.tagName.toLowerCase();
        if (tag === 'script' || tag === 'style' || tag === 'noscript') return;

        const r = role(el);
        const acts = interactive.has(tag)
            || el.hasAttribute('onclick')
            || el.hasAttribute('contenteditable')
            || (r !== null && ['button', 'link', 'textbox', 'combobox', 'checkbox', 'radio'].includes(r));

        if (r !== null && visible(el) && (acts || r === 'heading' || r === 'img')) {
            const name = label(el);
            if (name) {
                let line = `- ${r} "${name}"`;
                if (acts) {
                    counter += 1;
                    el.setAttribute('data-bud-ref', String(counter));
                    refs.push(counter);
                    line += ` [ref=${counter}]`;
                }
                if (tag === 'input' && el.type === 'checkbox') line += el.checked ? ' (checked)' : ' (unchecked)';
                else if (tag === 'input' || tag === 'textarea') {
                    if (el.value) line += ` (value: "${String(el.value).slice(0, 80)}")`;
                }
                if (el.disabled) line += ' (disabled)';
                if (tag === 'a' && el.getAttribute('href')) line += ` -> ${el.getAttribute('href').slice(0, 120)}`;
                lines.push(line);
            }
        }
        for (const child of el.children) walk(child);
    };

    walk(document.body || document.documentElement);
    return JSON.stringify({ lines: lines, refs: refs, title: document.title || '' });
    """

    private static let hoverScript = """
    const el = document.querySelector(`[data-bud-ref="${ref}"]`);
    if (!el) return 'missing';
    el.scrollIntoView({ block: 'center', inline: 'center' });
    const box = el.getBoundingClientRect();
    const at = { bubbles: true, cancelable: true, view: window,
                 clientX: box.left + box.width / 2, clientY: box.top + box.height / 2 };
    // The whole mouseover family: menus open on `mouseenter` often enough that
    // sending only `mouseover` leaves half of them shut.
    el.dispatchEvent(new PointerEvent('pointerover', at));
    el.dispatchEvent(new MouseEvent('mouseover', at));
    el.dispatchEvent(new MouseEvent('mouseenter', at));
    el.dispatchEvent(new MouseEvent('mousemove', at));
    return 'ok';
    """

    private static let selectScript = """
    const el = document.querySelector(`[data-bud-ref="${ref}"]`);
    if (!el) return 'missing';
    if (el.tagName.toLowerCase() !== 'select') return 'not-select';
    const options = Array.from(el.options || []);
    const wanted = options.find((o) => value && o.value === value)
        || options.find((o) => label && (o.textContent || '').trim() === label)
        || options.find((o) => label && (o.textContent || '').trim().toLowerCase().includes(label.toLowerCase()));
    if (!wanted) return 'no-option';
    el.value = wanted.value;
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    return 'ok';
    """

    private static let waitScript = """
    if (selector) return document.querySelector(selector) !== null;
    if (text) return (document.body ? document.body.innerText : '').includes(text);
    return true;
    """

    private static let consoleReadScript = """
    return JSON.stringify(window.__budConsole || []);
    """

    private static let consoleHook = """
    (() => {
      if (window.__budConsole) return;
      const entries = [];
      window.__budConsole = entries;
      const render = (arg) => {
        if (typeof arg === 'string') return arg;
        try { return JSON.stringify(arg); } catch (e) { return String(arg); }
      };
      const push = (level, args) => {
        try {
          entries.push(level + ': ' + args.map(render).join(' '));
          if (entries.length > 300) entries.shift();
        } catch (e) {}
      };
      ['log', 'info', 'warn', 'error', 'debug'].forEach((level) => {
        const original = console[level];
        console[level] = function (...args) {
          push(level, args);
          if (original) original.apply(console, args);
        };
      });
      window.addEventListener('error', (event) => {
        push('error', [event.message + ' at ' + (event.filename || '?') + ':' + (event.lineno || 0)]);
      });
      window.addEventListener('unhandledrejection', (event) => {
        const reason = event.reason;
        push('error', ['unhandled rejection: ' + (reason && reason.message ? reason.message : String(reason))]);
      });
    })();
    """

    private static let clickScript = """
    const el = document.querySelector(`[data-bud-ref="${ref}"]`);
    if (!el) return 'missing';
    el.scrollIntoView({ block: 'center', inline: 'center' });
    const box = el.getBoundingClientRect();
    const at = { bubbles: true, cancelable: true, view: window,
                 clientX: box.left + box.width / 2, clientY: box.top + box.height / 2 };
    // The full sequence, because plenty of pages listen for the pointer rather
    // than the click, and calling `.click()` alone skips them.
    el.dispatchEvent(new PointerEvent('pointerdown', at));
    el.dispatchEvent(new MouseEvent('mousedown', at));
    el.focus();
    el.dispatchEvent(new PointerEvent('pointerup', at));
    el.dispatchEvent(new MouseEvent('mouseup', at));
    el.click();
    return 'ok';
    """

    private static let typeScript = """
    const el = document.querySelector(`[data-bud-ref="${ref}"]`);
    if (!el) return 'missing';
    el.scrollIntoView({ block: 'center', inline: 'center' });
    el.focus();
    const proto = el instanceof HTMLTextAreaElement
        ? HTMLTextAreaElement.prototype
        : HTMLInputElement.prototype;
    const setter = Object.getOwnPropertyDescriptor(proto, 'value');
    // Through the native setter, so frameworks that patch `value` still see the
    // change: assigning `el.value` directly is invisible to React and its peers.
    if (setter && setter.set) setter.set.call(el, text);
    else el.value = text;
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    if (submit) {
        const form = el.form;
        if (form) {
            if (typeof form.requestSubmit === 'function') form.requestSubmit();
            else form.submit();
        } else {
            el.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
            el.dispatchEvent(new KeyboardEvent('keyup', { key: 'Enter', bubbles: true }));
            el.dispatchEvent(new KeyboardEvent('keypress', { key: 'Enter', bubbles: true }));
        }
    }
    return 'ok';
    """

    private static let pressScript = """
    const el = document.activeElement || document.body;
    const names = { Enter: 'Enter', Tab: 'Tab', Escape: 'Escape', Backspace: 'Backspace',
                    PageDown: 'PageDown', PageUp: 'PageUp', Home: 'Home', End: 'End',
                    ArrowDown: 'ArrowDown', ArrowUp: 'ArrowUp',
                    ArrowLeft: 'ArrowLeft', ArrowRight: 'ArrowRight' };
    const key = names[pressedKey] || pressedKey;
    el.dispatchEvent(new KeyboardEvent('keydown', { key: key, bubbles: true, cancelable: true }));
    el.dispatchEvent(new KeyboardEvent('keyup', { key: key, bubbles: true, cancelable: true }));
    if (key === 'Enter' && el.form && typeof el.form.requestSubmit === 'function') el.form.requestSubmit();
    return 'ok';
    """

    private static let scrollScript = """
    const step = amount;
    if (direction === 'top') window.scrollTo({ top: 0, behavior: 'instant' });
    else if (direction === 'bottom') window.scrollTo({ top: document.body.scrollHeight, behavior: 'instant' });
    else if (direction === 'up') window.scrollBy({ top: -step, behavior: 'instant' });
    else window.scrollBy({ top: step, behavior: 'instant' });
    return 'ok';
    """
}

// MARK: - Delegate

extension BrowserEngine: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(load: nil)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(load: BrowserError.transport(error.localizedDescription))
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(load: BrowserError.transport(error.localizedDescription))
    }

    /// A page that asks to open a window gets the navigation instead: there is
    /// one view, and a popup would be invisible with no way to reach it.
    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}

// MARK: - Errors

public enum BrowserError: LocalizedError {
    case invalidURL(String)
    case noHistory
    case noPage
    case timedOut
    case staleRef(Int)
    case script(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let raw):
            return "'\(raw)' is not a URL. Give a full address, or a host like example.com."
        case .noHistory:
            return "There is nowhere to go back or forward to."
        case .noPage:
            return "No page is open."
        case .timedOut:
            return "The page did not finish loading."
        case .staleRef(let ref):
            return "Ref \(ref) is not on the page any more. Read the outline again (browser_read, mode \"outline\") — refs are assigned by it, and they do not survive an action you did not take."
        case .script(let detail):
            return "The page script failed: \(detail)"
        case .transport(let detail):
            return "The page could not be loaded: \(detail)"
        }
    }
}

// MARK: - Addresses

extension BrowserEngine {
    /// Turns what someone typed into a URL.
    ///
    /// A bare host is the common case — nobody types a scheme — and guessing wrong
    /// sends the request to a search engine instead of the site, so the guess is
    /// made explicitly rather than by the loader.
    static func resolve(_ target: String) throws -> URL {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BrowserError.invalidURL(target) }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
            if ["http", "https", "file", "about", "data"].contains(scheme) { return url }
        }
        // An absolute path is a file to open. Checked against the filesystem
        // rather than by the leading slash alone, so a stray slash cannot turn a
        // half-typed host into a confident miss.
        if trimmed.hasPrefix("/"), FileManager.default.fileExists(atPath: trimmed) {
            return URL(fileURLWithPath: trimmed)
        }
        let looksLikeHost = trimmed.contains(".")
            && !trimmed.contains(" ")
            && !trimmed.hasPrefix("/")
        guard looksLikeHost else { throw BrowserError.invalidURL(target) }
        guard let url = URL(string: "https://\(trimmed)") else { throw BrowserError.invalidURL(target) }
        return url
    }
}
