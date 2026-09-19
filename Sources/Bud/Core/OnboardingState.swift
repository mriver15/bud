import Foundation
import Observation

// MARK: - Local runtime detection

/// Whether a local runtime answers on localhost.
///
/// Probed once and cached: two cheap GETs to endpoints the runtimes publish for
/// discovery, and the answer does not change while Bud is running — a user who
/// starts Ollama after Bud is up can pick it from Settings, which lists the local
/// runtimes regardless. The probe also reads the first model name each runtime
/// reports, because a local test round needs a concrete model id and asking for
/// one would be friction a detection response already spares us.
public enum LocalRuntimeDetector {
    public struct Detection: Sendable, Equatable {
        public var ollama: Bool
        public var lmStudio: Bool
        /// The first model each runtime lists, when it answered.
        public var ollamaModel: String?
        public var lmStudioModel: String?

        public var reachable: Bool { ollama || lmStudio }

        public init(
            ollama: Bool = false,
            lmStudio: Bool = false,
            ollamaModel: String? = nil,
            lmStudioModel: String? = nil
        ) {
            self.ollama = ollama
            self.lmStudio = lmStudio
            self.ollamaModel = ollamaModel
            self.lmStudioModel = lmStudioModel
        }
    }

    /// Two seconds is generous for localhost: anything that cannot answer that
    /// fast is not running, and two probes held behind a slow dead host would
    /// stall the panel's first appearance.
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 2
        c.timeoutIntervalForResource = 2
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    private static let lock = NSLock()
    private nonisolated(unsafe) static var cached: Detection?

    /// The most recent detection, or nil before `detect()` has run.
    public static var lastDetection: Detection? {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    /// Synchronous read for the onboarding gate: has a runtime been seen? False
    /// until a probe has completed, which is the conservative default for a
    /// first-run decision made before detection finishes.
    public static var hasReachableRuntime: Bool {
        lastDetection?.reachable ?? false
    }

    /// Probes both runtimes once, caches, and returns the result.
    public static func detect() async -> Detection {
        if let cached = lastDetection { return cached }
        async let ollama = probe("http://localhost:11434/api/tags")
        async let lmStudio = probe("http://localhost:1234/v1/models")
        let result = Detection(
            ollama: await ollama.reachable,
            lmStudio: await lmStudio.reachable,
            ollamaModel: await ollama.model,
            lmStudioModel: await lmStudio.model
        )
        store(result)
        return result
    }

    private static func store(_ result: Detection) {
        lock.lock(); cached = result; lock.unlock()
    }

    private static func probe(_ urlString: String) async -> (reachable: Bool, model: String?) {
        guard let url = URL(string: urlString) else { return (false, nil) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return (false, nil)
            }
            return (true, firstModelName(in: data))
        } catch {
            return (false, nil)
        }
    }

    /// Pulls the first model name out of either runtime's JSON: Ollama lists
    /// `models[].name`, LM Studio lists `data[].id`.
    private static func firstModelName(in data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        if let models = root["models"] as? [[String: Any]], let first = models.first {
            return first["name"] as? String
        }
        if let items = root["data"] as? [[String: Any]], let first = items.first {
            return first["id"] as? String
        }
        return nil
    }
}

// MARK: - Onboarding state

/// The first-run flow: pick a provider, prove the connection works, and leave
/// with a first response already on screen.
@MainActor
@Observable
public final class OnboardingState: Identifiable {
    public let id = UUID()

    public enum Step: Equatable {
        case choose, test, done
    }

    /// What the user is onboarding onto: a hosted provider or a local runtime.
    public enum Selection: Equatable {
        case hosted(providerID: String)
        case local(providerID: String)
    }

    /// Where the connection test stands.
    public enum TestState: Equatable {
        case idle
        case testing
        case passed
        case failed(String)
    }

    public let model: AppModel

    /// The one-time detection result, and whether the probe has run at all.
    public private(set) var detection: LocalRuntimeDetector.Detection?

    public var step: Step = .choose
    public var selection: Selection?
    /// The key the user is typing for a hosted provider. Read, never logged.
    public var apiKeyInput: String = ""
    /// The model id to test against and, on finish, to send with.
    public var modelIDInput: String = ""
    public var testState: TestState = .idle

    public init(model: AppModel) {
        self.model = model
    }

    /// Whether this run is a scratch store — the headless modes and
    /// `BUD_SCRATCH_STORE=1` runs — which must never see onboarding.
    ///
    /// The env var alone does not cover it: the command-line modes redirect the
    /// store directly, without setting the variable, so the redirected store is
    /// the signal that is reliable in both cases.
    public static var isScratchStore: Bool {
        StoredResults.overrideDirectory != nil
            || ProcessInfo.processInfo.environment["BUD_SCRATCH_STORE"] == "1"
    }

    /// Runs the local probe (skipping it when the answer is already obvious),
    /// then reports whether the sheet should present.
    ///
    /// This is the gate: onboarding is shown only when it has not been completed,
    /// nothing is configured, and this is not a scratch run.
    public func determinePresentation() async -> Bool {
        guard !model.config.hasCompletedOnboarding, !Self.isScratchStore else { return false }
        // A stored key anywhere already decides it: no probe needed.
        let hasKey = model.config.providerKeys.values.contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if hasKey { return false }
        detection = await LocalRuntimeDetector.detect()
        return model.config.needsProviderOnboarding
    }

    // MARK: Step 1

    /// The hosted providers worth offering, in registry order.
    public var hostedProviders: [ProviderDescriptor] {
        ProviderRegistry.all.filter { !$0.isCustom && $0.requiresKey }
    }

    /// The local runtimes that answered, in a stable order.
    public var detectedLocalRuntimes: [ProviderDescriptor] {
        guard let detection else { return [] }
        var out: [ProviderDescriptor] = []
        if detection.ollama, let d = ProviderRegistry.provider(id: "ollama") { out.append(d) }
        if detection.lmStudio, let d = ProviderRegistry.provider(id: "lmstudio") { out.append(d) }
        return out
    }

    public func chooseHosted(_ providerID: String) {
        selection = .hosted(providerID: providerID)
        step = .test
        testState = .idle
        apiKeyInput = ""
        modelIDInput = ProviderRegistry.provider(id: providerID)?.defaultModel ?? ""
    }

    public func chooseLocal(_ providerID: String) {
        selection = .local(providerID: providerID)
        step = .test
        testState = .idle
        apiKeyInput = ""
        modelIDInput = detectedModel(for: providerID) ?? ""
    }

    private func detectedModel(for providerID: String) -> String? {
        switch providerID {
        case "ollama": return detection?.ollamaModel
        case "lmstudio": return detection?.lmStudioModel
        default: return nil
        }
    }

    // MARK: Step 2

    public var chosenProvider: ProviderDescriptor? {
        switch selection {
        case .hosted(let id), .local(let id):
            return ProviderRegistry.provider(id: id)
        case nil:
            return nil
        }
    }

    public var chosenModel: String {
        let typed = modelIDInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        return chosenProvider?.defaultModel ?? ""
    }

    /// Whether the chosen provider needs a key at all.
    public var needsKey: Bool { chosenProvider?.requiresKey == true }

    /// One short message through the chosen provider's own backend, which is the
    /// connection test. Failure is translated into the one reason that matters —
    /// a rejected key, an unreachable provider, or a malformed model id — rather
    /// than the backend's raw wording.
    public func testConnection() async {
        guard let provider = chosenProvider else { return }
        let model = chosenModel
        guard !model.isEmpty else {
            testState = .failed("Enter a model id to test against.")
            return
        }
        let key: String
        if provider.requiresKey {
            let typed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
            // A blank field still finds a key Bud can resolve from the environment
            // or a shell profile — the same search the note above describes.
            key = typed.isEmpty ? self.model.config.resolvedKey(for: provider) : typed
            if key.isEmpty {
                testState = .failed("No key. Paste one above and test again.")
                return
            }
        } else {
            key = ""
        }
        testState = .testing
        let request = ChatRequest(
            model: model,
            messages: [ChatMessage(role: .user, content: "ping")],
            maxTokens: 1
        )
        let backend = ProviderBackendFactory.make(
            provider: provider,
            credentials: ProviderCredentials(apiKey: key, baseURL: nil, region: nil)
        )
        do {
            var sawAnything = false
            for try await event in backend.stream(request) {
                switch event {
                case .contentDelta, .reasoningDelta, .finish, .usage, .toolCallDelta:
                    sawAnything = true
                }
            }
            testState = sawAnything
                ? .passed
                : .failed("\(provider.name) accepted the request but sent nothing back.")
        } catch {
            testState = .failed(Self.translate(error, providerName: provider.name))
        }
    }

    /// Maps a backend failure onto one onboarding-relevant sentence.
    public static func translate(_ error: Error, providerName: String) -> String {
        guard let e = error as? ChatBackendError else {
            return error.localizedDescription
        }
        switch e {
        case .missingKey, .missingAPIKey:
            return "No key. Paste one above and test again."
        case .http(let status, _) where status == 401 || status == 403:
            return "That key was rejected (HTTP \(status)). Check it and try again."
        case .http(let status, _) where status == 400:
            return "\(providerName) says the request is malformed — the model id is the usual culprit."
        case .http(let status, _):
            return "\(providerName) answered with HTTP \(status)."
        case .transport:
            return "Can't reach \(providerName). Check the network, or that it's running."
        case .decoding:
            return "\(providerName) answered, but not in a shape Bud could read."
        }
    }

    // MARK: Step 3 / finish

    /// Leaves onboarding without choosing anything. The flag is set so the sheet
    /// never returns; the user configures a provider later, in Settings.
    public func skip() {
        markCompleted()
    }

    /// Commits the chosen provider, key and model, marks onboarding complete, and
    /// sends a harmless first prompt so a fresh install reaches a first response
    /// inside the flow rather than landing on an empty composer.
    public func finish() async {
        commit()
        markCompleted()
        await model.send("What can you do on this Mac?")
    }

    private func commit() {
        guard let provider = chosenProvider else { return }
        model.config.provider = provider.id
        if provider.requiresKey {
            model.config.apiKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let modelID = chosenModel
        if !modelID.isEmpty {
            model.config.model = modelID
        }
    }

    private func markCompleted() {
        model.config.hasCompletedOnboarding = true
        model.persistConfig()
    }
}
