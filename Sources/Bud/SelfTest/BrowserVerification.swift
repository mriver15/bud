import AppKit
import SwiftUI
import Foundation
import Network

/// Drives the real browser against a local fixture, with no network.
///
/// Local rather than live on purpose. What is being tested is the part that is
/// easy to get subtly wrong and hard to notice — whether a ref survives to the
/// element it named, whether typing reaches a framework's listener, whether a
/// click sequence fires what the page is actually listening for. A live site
/// would test all of that plus its own uptime.
///
/// Needs a run loop: WebKit does its work out of process and reports back through
/// the main queue, so a synchronous suite would wait for a reply nobody could
/// deliver.
@MainActor
public enum BudBrowserVerification {
    public static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        Task { @MainActor in
            let report = await check()
            for failure in report.failures {
                FileHandle.standardError.write(Data("FAIL  \(failure)\n".utf8))
            }
            print(report.ok
                  ? "PASS  \(report.passed)/\(report.total) browser checks passed"
                  : "FAIL  \(report.passed)/\(report.total) browser checks passed")
            exit(report.ok ? 0 : 1)
        }

        app.run()
        exit(0)
    }

    private static func check() async -> SelfTestReport {
        let c = Checker(suite: "browser")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bud-browser-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let page = directory.appendingPathComponent("fixture.html")
        try? fixture.write(to: page, atomically: true, encoding: .utf8)

        let engine = BrowserEngine()

        do {
            try await engine.open(page.path)
            c.check("a local page loads", engine.state.url.hasSuffix("fixture.html"))

            // MARK: Reading

            let text = try await engine.readableText()
            c.check("the page text is readable", text.contains("Sign in"))
            c.check("and keeps the body copy", text.contains("Welcome back"))

            // MARK: Snapshot

            let snapshot = try await engine.snapshot()
            c.check("the snapshot names the page", snapshot.contains("Fixture page"))
            c.check("it reports the heading", snapshot.contains("heading \"Sign in\""))
            c.check("it reports the button", snapshot.contains("button \"Sign in\""))
            c.check("it reports a textbox by its placeholder",
                    snapshot.contains("textbox \"you@example.com\""))
            c.check("it reports a link", snapshot.contains("link \"Forgot password\""))
            c.check("it reports an unchecked box", snapshot.contains("(unchecked)"))
            c.check("and a checked one", snapshot.contains("(checked)"))
            c.check("it reports a disabled control", snapshot.contains("(disabled)"))
            c.check("every actionable line carries a ref", snapshot.contains("[ref="))

            // MARK: Acting

            guard let buttonRef = Self.ref(in: snapshot, for: "button \"Sign in\""),
                  let emailRef = Self.ref(in: snapshot, for: "textbox \"you@example.com\"")
            else {
                c.check("the snapshot yielded refs to act on", false)
                return c.report()
            }

            try await engine.click(ref: buttonRef)
            let afterClick = try await engine.evaluate("return document.getElementById('out').innerText") as? String
            c.equal("clicking a ref runs the page's own handler", afterClick, "clicked")

            // MARK: Typing

            try await engine.type(ref: emailRef, text: "someone@example.com", submit: false)
            // Read from the live DOM rather than the value attribute: a framework
            // that patches `value` would leave the attribute untouched, and this
            // is the check that catches typing that never reached the page.
            let typed = try await engine.evaluate("return document.getElementById('email').value") as? String
            c.equal("typing reaches the element", typed, "someone@example.com")

            let listened = try await engine.evaluate("return window.__emailEvents") as? String
            c.equal("typing fires the events frameworks listen for", listened, "input,change,")

            // MARK: Stale refs

            do {
                try await engine.click(ref: 9_999)
                c.check("acting on an unknown ref is refused", false)
            } catch {
                c.check("acting on an unknown ref is refused", true)
            }

            // A re-snapshot reassigns refs, so the previous generation must stop
            // working: clicking a number that now belongs to something else is the
            // failure that makes a browser tool dangerous.
            let refreshed = try await engine.snapshot()
            let refreshedRef = Self.ref(in: refreshed, for: "button \"Sign in\"")
            c.equal("refs survive a re-snapshot of the same page", refreshedRef, buttonRef)

            // MARK: Navigating by address

            c.equal("a bare host gains a scheme",
                    try BrowserEngine.resolve("example.com").absoluteString, "https://example.com")
            c.equal("a full URL is left alone",
                    try BrowserEngine.resolve("http://example.com/x").absoluteString,
                    "http://example.com/x")
            do {
                _ = try BrowserEngine.resolve("not a url")
                c.check("a non-address is refused", false)
            } catch {
                c.check("a non-address is refused", true)
            }

            // MARK: The page is a real page

            let shot = try await engine.screenshot()
            c.check("the page can be screenshotted (\(shot.count) bytes)", shot.count > 2_000)

            // MARK: It fills the surface it is shown in

            // The contract: the page view is the size of the surface showing it.
            // Worth pinning because the failure is silent — a view with no size
            // still loads, still reports its URL, and draws nothing, which looks
            // exactly like a page that failed. Nothing else here would notice.
            let model = AppModel()
            let surface = NSHostingView(rootView: BrowserView(model: model))
            surface.frame = NSRect(x: 0, y: 0, width: 700, height: 520)
            let window = NSWindow(
                contentRect: surface.frame, styleMask: [.borderless],
                backing: .buffered, defer: false
            )
            window.contentView = surface
            window.orderFront(nil)
            // Long enough for SwiftUI to place the container and run its layout.
            try await Task.sleep(for: .milliseconds(500))

            let shown = model.browser.webView.frame
            c.check(
                "the page view fills the surface (\(Int(shown.width))x\(Int(shown.height)))",
                shown.width > 400 && shown.height > 300
            )
            window.orderOut(nil)

            // MARK: Hovering, choosing, waiting

            let beforeHover = try await engine.evaluate(
                "return document.getElementById('menuBody').style.display"
            ) as? String
            c.equal("the hover target starts hidden", beforeHover, "none")

            let hoverShot = try await engine.snapshot()
            guard let menuRef = Self.ref(in: hoverShot, for: "button \"Open menu\""),
                  let regionRef = Self.ref(in: hoverShot, for: "combobox \"Region\"")
            else {
                c.check("the snapshot yielded the new refs", false)
                return c.report()
            }

            try await engine.hover(ref: menuRef)
            let afterHover = try await engine.evaluate(
                "return document.getElementById('menuBody').style.display"
            ) as? String
            c.equal("hovering runs what the page listens for", afterHover, "block")

            try await engine.select(ref: regionRef, value: "us", label: nil)
            let chosen = try await engine.evaluate("return document.getElementById('region').value") as? String
            c.equal("choosing by value works", chosen, "us")

            try await engine.select(ref: regionRef, value: nil, label: "Europe")
            let byLabel = try await engine.evaluate("return document.getElementById('region').value") as? String
            c.equal("choosing by visible text works", byLabel, "eu")

            do {
                try await engine.select(ref: regionRef, value: nil, label: "Nowhere")
                c.check("choosing an option that is not there is refused", false)
            } catch {
                c.check("choosing an option that is not there is refused", true)
            }

            // The fixture adds this after 700ms, so a wait that returns true has
            // actually waited rather than found it already there.
            let arrived = try await engine.wait(text: "Arrived late", selector: nil, timeout: 5)
            c.check("waiting finds content that arrives late", arrived)

            let never = try await engine.wait(text: "never appears", selector: nil, timeout: 1)
            c.check("waiting gives up on what never arrives", !never)

            let messages = try await engine.consoleMessages()
            c.check("the console is captured (\(messages.count) entries)",
                    messages.contains { $0.contains("fixture ready") })
            c.check("including warnings", messages.contains { $0.contains("a warning") })

            // MARK: As tools

            // The layer the model actually touches: argument parsing, the wording
            // of a refusal, and whether a result carries what the next call needs.
            let toolEngine = BrowserEngine()
            let provider = BrowserToolProvider(engine: toolEngine)

            let descriptors = await provider.toolDescriptors()
            c.check("the provider offers its tools (\(descriptors.count))", descriptors.count >= 8)
            c.check(
                "every tool name is model-legal",
                descriptors.allSatisfy {
                    $0.name.range(of: #"^[a-zA-Z0-9_-]{1,64}$"#, options: .regularExpression) != nil
                }
            )

            let opened = await provider.invoke(
                tool: "browser_open",
                arguments: .object(["url": .string(page.path)]),
                callID: "browser-tool-1"
            )
            c.check("opening through the tool works", !opened.isError)
            c.check("and returns an outline of what it opened", opened.text.contains("button \"Sign in\""))

            let noURL = await provider.invoke(tool: "browser_open", arguments: .object([:]), callID: "t2")
            c.check("a call with no url is refused", noURL.isError)

            let unknown = await provider.invoke(tool: "browser_nope", arguments: .object([:]), callID: "t3")
            c.check("an unknown tool is refused", unknown.isError)

            // A ref the page no longer has has to come back as something the model
            // can act on. A crash ends the turn; a silent success sends it on with
            // a wrong idea of what happened.
            let stale = await provider.invoke(
                tool: "browser_click",
                arguments: .object(["ref": .number(4_242)]),
                callID: "t4"
            )
            c.check("a stale ref is refused", stale.isError)
            c.check("and the refusal says how to fix it",
                    stale.text.lowercased().contains("snapshot"))
        } catch {
            c.check("the browser completed without throwing (\(error.localizedDescription))", false)
        }

        // MARK: Cancelling a page load

        // A load that is cancelled has to release the waiter waiting on it: a
        // `pendingLoad` continuation nobody resumed would leave every later tool
        // call queued behind it, which is a hang nobody sees until the next click.
        guard let (stallURL, stopStalling) = try? await Self.startStallingEndpoint() else {
            c.check("cancel: a stalling endpoint could be started", false)
            return c.report()
        }
        defer { stopStalling() }

        let loadTask = Task { try await engine.open(stallURL.absoluteString) }
        // Wait for WebKit to report itself loading, so the stop lands on a
        // genuinely in-flight navigation rather than one that was only queued.
        let inFlight = await Self.waitUntil(timeout: 10) { engine.webView.isLoading }
        c.check("cancel: the slow load was in flight when stopped", inFlight)
        engine.webView.stopLoading()

        // The cancelled load must settle: reaching the await at all is the proof
        // that the continuation was resumed rather than leaked.
        var cancelledCleanly = false
        do {
            try await loadTask.value
        } catch {
            cancelledCleanly = true
        }
        c.check("cancel: a cancelled load throws rather than hangs", cancelledCleanly)
        // The engine's own published state clears the moment the waiter is
        // resumed — deterministic. WKWebView's `isLoading` is WebKit-internal
        // and stays true while a stalled socket is open, which is the flake
        // that failed CI: the property under test is that the *stop landed*,
        // and the engine's flag is where that is recorded.
        c.check("cancel: ...and the engine is no longer loading", !engine.state.isLoading)

        // The engine must still be usable afterwards: a second load succeeds.
        do {
            try await engine.open(page.path)
            c.check("cancel: a second load succeeds after a cancelled one",
                    engine.state.url.hasSuffix("fixture.html"))
        } catch {
            c.check("cancel: a second load succeeds after a cancelled one", false)
        }

        return c.report()
    }

    /// Polls a condition until it holds or the deadline passes. WebKit reports
    /// navigation back through the main queue, and there is no update cycle to
    /// observe it from inside a verification run.
    private static func waitUntil(
        timeout: TimeInterval,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }

    /// A local HTTP endpoint that accepts the connection and then stays silent.
    ///
    /// The value is a load that is genuinely pending: a page that loads instantly
    /// could never prove that cancelling releases the waiter. Loopback is exempt
    /// from App Transport Security, so plain `http://127.0.0.1` is reachable with
    /// no configuration.
    private static func startStallingEndpoint() async throws -> (url: URL, stop: () -> Void) {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
        }
        listener.start(queue: .global())
        // The OS assigns an ephemeral port once the listener is ready; poll for it
        // rather than observing the state handler, so nothing hops between queues
        // while the verification stays on the main actor. The port reads zero until
        // the bind has completed, so only a non-zero one is accepted.
        for _ in 0..<200 {
            if let port = listener.port?.rawValue, port > 0 {
                return (URL(string: "http://127.0.0.1:\(port)/slow")!, { listener.cancel() })
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        listener.cancel()
        throw BrowserError.script("the stalling endpoint never bound a port")
    }

    /// The ref an outline line carries, matched on its start so a ref is never
    /// taken from a line about something else.
    private static func ref(in snapshot: String, for line: String) -> Int? {
        guard let start = snapshot.range(of: "- " + line) else { return nil }
        let rest = snapshot[start.upperBound...]
        guard let open = rest.range(of: "[ref=") else { return nil }
        let digits = rest[open.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    private static let fixture = """
    <!doctype html>
    <html>
    <head><meta charset="utf-8"><title>Fixture page</title></head>
    <body>
      <h1>Sign in</h1>
      <p>Welcome back. Use your account to continue.</p>
      <form id="form" onsubmit="event.preventDefault();">
        <label for="email">Email</label>
        <input id="email" name="email" type="text" placeholder="you@example.com">
        <input id="password" name="password" type="password" placeholder="Password">
        <label for="remember">Remember me</label>
        <input id="remember" type="checkbox">
        <input id="terms" type="checkbox" checked>
        <button id="go" type="button">Sign in</button>
        <button id="later" type="button" disabled>Continue later</button>
      </form>
      <a href="#reset">Forgot password</a>
      <select id="region" aria-label="Region">
        <option value="">Choose a region</option>
        <option value="eu">Europe</option>
        <option value="us">United States</option>
      </select>
      <button id="menu" type="button">Open menu</button>
      <div id="menuBody" style="display:none">Menu is open</div>
      <div id="out">idle</div>
      <script>
        // Records what the page was told, so a test can tell typing that reached
        // the DOM from typing that only set a property.
        window.__emailEvents = '';
        const email = document.getElementById('email');
        email.addEventListener('input', () => { window.__emailEvents += 'input,'; });
        email.addEventListener('change', () => { window.__emailEvents += 'change,'; });

        document.getElementById('go').addEventListener('click', () => {
          document.getElementById('out').innerText = 'clicked';
        });
        document.getElementById('menu').addEventListener('mouseenter', () => {
          document.getElementById('menuBody').style.display = 'block';
        });

        console.log('fixture ready');
        console.warn('a warning');
        setTimeout(() => {
          const late = document.createElement('div');
          late.id = 'late';
          late.textContent = 'Arrived late';
          document.body.appendChild(late);
        }, 700);
      </script>
    </body>
    </html>
    """
}
