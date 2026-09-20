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
                    reason: String(format: "provider answered %d of %d in %.2f ms",
                                   batch.answers.count, questions.count, latencyMs)
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
                    reason: "provider failed after " + String(format: "%.2f ms", latencyMs)
                        + " — deterministic batch used instead"
                )
                return Evaluation(batch: batch, fellBack: true, latencyMs: latencyMs)
            }
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
