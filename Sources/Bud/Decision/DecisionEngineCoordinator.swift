import Foundation

/// The engine selection seam: builds the configured engine for one round and
/// guarantees the batch never comes back empty or broken.
///
/// The contract the harness relies on:
/// - `deterministic` is the floor — always available, no network, no failure
///   modes. The release gate "Bud works with the engine unconfigured" is this
///   path.
/// - `provider` runs the session model; the call's token spend is reported to
///   the session accounting, its latency to the evidence store, and *any*
///   failure — network, malformed output, a wrong-typed answer — falls back to
///   the deterministic batch rather than degrading the round.
/// - The shadow comparison always reads the deterministic view, so provider
///   judgments are measured against it, never confused with it.
public enum DecisionEngineCoordinator {
    public struct Evaluation: Sendable {
        public var batch: DecisionBatch
        /// True when the configured engine failed and the deterministic batch
        /// answered instead.
        public var fellBack: Bool
        /// Milliseconds the configured engine took, when it ran.
        public var latencyMs: Double?
    }

    public static func evaluate(
        selection: DecisionEngineID,
        env: AppEnvironment,
        state: DecisionState,
        questions: [DecisionQuestion]
    ) async -> Evaluation {
        switch selection {
        case .deterministic:
            let batch = await run(DeterministicDecisionEngine(), state: state, questions: questions)
            return Evaluation(batch: batch, fellBack: false, latencyMs: nil)

        case .provider:
            let config = env.config
            let engine = ProviderDecisionEngine(
                backend: env.makeBackend(),
                model: config.model,
                onUsage: { prompt, completion in env.recordUsage(prompt: prompt, completion: completion) }
            )
            return await runConfigured(
                engine, label: "provider", env: env, state: state, questions: questions
            )

        case .jev:
            let config = env.config
            // The TypeSafe SDK's own convention as the fallback source, so a
            // headless run can supply the key without the app having stored one.
            let stored = config.typesafeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = stored.isEmpty
                ? (ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"] ?? "")
                : stored
            guard !key.isEmpty else {
                let batch = await run(
                    DeterministicDecisionEngine(), state: state, questions: questions
                )
                CognitiveStore.recordContextEvent(
                    requestID: nil,
                    sourceType: "decision",
                    sourceID: nil,
                    action: "fallback",
                    score: nil,
                    reason: "jev selected but no TypeSafe API key is set — deterministic batch used"
                )
                return Evaluation(batch: batch, fellBack: true, latencyMs: nil)
            }
            let engine = JevDecisionEngine(
                apiKey: key,
                model: jevModel(config.jevModel),
                onUsage: { prompt, completion in env.recordUsage(prompt: prompt, completion: completion) }
            )
            return await runConfigured(
                engine, label: "jev", env: env, state: state, questions: questions
            )
        }
    }

    /// The model a Jev call is sent to: the configured pin, or the shipped alias
    /// when nothing is pinned.
    ///
    /// A cleared field is an empty string, and an empty `model` on the wire is a
    /// refused request rather than a default — so the fallback lives here, where
    /// the request is built, instead of being left to the server.
    static func jevModel(_ configured: String) -> String {
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? JevDecisionEngine.defaultModel : trimmed
    }

    /// The shared configured-engine path: run, account, and fall back to the
    /// deterministic batch with a named event on any failure.
    private static func runConfigured(
        _ engine: any DecisionEngine,
        label: String,
        env: AppEnvironment,
        state: DecisionState,
        questions: [DecisionQuestion]
    ) async -> Evaluation {
        let start = Date()
        do {
            let batch = try await engine.evaluate(state: state, questions: questions)
            let latencyMs = Date().timeIntervalSince(start) * 1000
            CognitiveStore.recordContextEvent(
                requestID: nil,
                sourceType: "decision",
                sourceID: nil,
                action: "engine",
                score: nil,
                reason: String(format: "%@ answered %d of %d in %.2f ms",
                               label, batch.answers.count, questions.count, latencyMs)
            )
            return Evaluation(batch: batch, fellBack: false, latencyMs: latencyMs)
        } catch {
            let latencyMs = Date().timeIntervalSince(start) * 1000
            let batch = await run(
                DeterministicDecisionEngine(), state: state, questions: questions
            )
            CognitiveStore.recordContextEvent(
                requestID: nil,
                sourceType: "decision",
                sourceID: nil,
                action: "fallback",
                score: nil,
                reason: "\(label) failed after " + String(format: "%.2f ms", latencyMs)
                    + " — deterministic batch used instead"
            )
            return Evaluation(batch: batch, fellBack: true, latencyMs: latencyMs)
        }
    }

    private static func run(
        _ engine: any DecisionEngine,
        state: DecisionState,
        questions: [DecisionQuestion]
    ) async -> DecisionBatch {
        (try? await engine.evaluate(state: state, questions: questions))
            ?? DecisionBatch(engineID: engine.id, answers: [])
    }
}
