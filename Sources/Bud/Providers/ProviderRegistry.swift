import Foundation

/// The wire protocol a provider speaks.
///
/// Providers do not map one-to-one onto protocols — 175 of the 217 in the
/// models.dev catalogue speak the OpenAI dialect, including several that are not
/// OpenAI — so the transport is chosen by protocol and the base URL selects the
/// provider. That is why adding a provider is usually a one-line registry entry
/// rather than a new client.
public enum WireFormat: String, Codable, Sendable, CaseIterable, Identifiable {
    /// `POST {base}/chat/completions`, server-sent events.
    case openAICompatible
    /// `POST {base}/v1/messages`, server-sent events.
    case anthropicMessages
    /// `POST {base}/v1beta/models/{model}:streamGenerateContent`.
    case googleGenerativeAI

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .openAICompatible: return "OpenAI-compatible"
        case .anthropicMessages: return "Anthropic Messages"
        case .googleGenerativeAI: return "Google Generative AI"
        }
    }
}

/// A provider Bud can talk to.
public struct ProviderDescriptor: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var wireFormat: WireFormat
    /// Base URL *without* the endpoint path: the client appends its own.
    public var baseURL: String
    /// Environment variables consulted, in order, when no key is stored.
    ///
    /// Several providers publish more than one name for the same credential —
    /// Google ships both `GEMINI_API_KEY` and `GOOGLE_GENERATIVE_AI_API_KEY` — and
    /// a user should not have to guess which one Bud wants.
    public var envKeys: [String]
    public var docURL: String?
    /// Local runtimes need no credential, and asking for one would be noise.
    public var requiresKey: Bool
    /// A sensible starting model, used to prefill the field for a new provider.
    public var defaultModel: String?
    /// Shown in Settings, for anything a user should know before configuring it.
    public var note: String?

    public init(
        id: String,
        name: String,
        wireFormat: WireFormat,
        baseURL: String,
        envKeys: [String] = [],
        docURL: String? = nil,
        requiresKey: Bool = true,
        defaultModel: String? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.name = name
        self.wireFormat = wireFormat
        self.baseURL = baseURL
        self.envKeys = envKeys
        self.docURL = docURL
        self.requiresKey = requiresKey
        self.defaultModel = defaultModel
        self.note = note
    }

    /// True for the entry that lets a user reach anything not listed here.
    public var isCustom: Bool { id == ProviderRegistry.customID }
}

/// The providers Bud ships knowing about.
///
/// Curated rather than fetched. models.dev lists 217 providers but carries no
/// base URLs — those come from each provider's SDK — so a complete catalogue
/// would mean maintaining 217 endpoints. These are the ones with stable, public,
/// documented endpoints; anything else is reachable through the custom entry,
/// which needs nothing but a base URL and a key.
public enum ProviderRegistry {
    public static let customID = "custom"

    public static let all: [ProviderDescriptor] = [
        // MARK: OpenAI-compatible
        ProviderDescriptor(
            id: "deepseek", name: "DeepSeek", wireFormat: .openAICompatible,
            baseURL: "https://api.deepseek.com/v1", envKeys: ["DEEPSEEK_API_KEY"],
            docURL: "https://api-docs.deepseek.com", defaultModel: "deepseek-v4-flash"
        ),
        ProviderDescriptor(
            id: "openai", name: "OpenAI", wireFormat: .openAICompatible,
            baseURL: "https://api.openai.com/v1", envKeys: ["OPENAI_API_KEY"],
            docURL: "https://platform.openai.com/docs", defaultModel: "gpt-4o"
        ),
        ProviderDescriptor(
            id: "anthropic", name: "Anthropic", wireFormat: .anthropicMessages,
            baseURL: "https://api.anthropic.com", envKeys: ["ANTHROPIC_API_KEY"],
            docURL: "https://docs.anthropic.com", defaultModel: "claude-sonnet-4-6"
        ),
        ProviderDescriptor(
            id: "google", name: "Google Gemini", wireFormat: .googleGenerativeAI,
            baseURL: "https://generativelanguage.googleapis.com",
            envKeys: ["GEMINI_API_KEY", "GOOGLE_GENERATIVE_AI_API_KEY", "GOOGLE_API_KEY"],
            docURL: "https://ai.google.dev/gemini-api/docs", defaultModel: "gemini-2.5-pro"
        ),
        ProviderDescriptor(
            id: "openrouter", name: "OpenRouter", wireFormat: .openAICompatible,
            baseURL: "https://openrouter.ai/api/v1", envKeys: ["OPENROUTER_API_KEY"],
            docURL: "https://openrouter.ai/docs",
            note: "One key, hundreds of models across many vendors."
        ),
        ProviderDescriptor(
            id: "groq", name: "Groq", wireFormat: .openAICompatible,
            baseURL: "https://api.groq.com/openai/v1", envKeys: ["GROQ_API_KEY"],
            docURL: "https://console.groq.com/docs"
        ),
        ProviderDescriptor(
            id: "mistral", name: "Mistral", wireFormat: .openAICompatible,
            baseURL: "https://api.mistral.ai/v1", envKeys: ["MISTRAL_API_KEY"],
            docURL: "https://docs.mistral.ai"
        ),
        ProviderDescriptor(
            id: "xai", name: "xAI", wireFormat: .openAICompatible,
            baseURL: "https://api.x.ai/v1", envKeys: ["XAI_API_KEY"],
            docURL: "https://docs.x.ai"
        ),
        ProviderDescriptor(
            id: "together", name: "Together", wireFormat: .openAICompatible,
            baseURL: "https://api.together.xyz/v1", envKeys: ["TOGETHER_API_KEY"],
            docURL: "https://docs.together.ai"
        ),
        ProviderDescriptor(
            id: "cerebras", name: "Cerebras", wireFormat: .openAICompatible,
            baseURL: "https://api.cerebras.ai/v1", envKeys: ["CEREBRAS_API_KEY"],
            docURL: "https://inference-docs.cerebras.ai"
        ),
        ProviderDescriptor(
            id: "fireworks", name: "Fireworks", wireFormat: .openAICompatible,
            baseURL: "https://api.fireworks.ai/inference/v1", envKeys: ["FIREWORKS_API_KEY"],
            docURL: "https://docs.fireworks.ai"
        ),
        ProviderDescriptor(
            id: "deepinfra", name: "DeepInfra", wireFormat: .openAICompatible,
            baseURL: "https://api.deepinfra.com/v1/openai", envKeys: ["DEEPINFRA_API_KEY"],
            docURL: "https://deepinfra.com/docs"
        ),
        ProviderDescriptor(
            id: "perplexity", name: "Perplexity", wireFormat: .openAICompatible,
            baseURL: "https://api.perplexity.ai", envKeys: ["PERPLEXITY_API_KEY"],
            docURL: "https://docs.perplexity.ai"
        ),
        ProviderDescriptor(
            id: "moonshot", name: "Moonshot", wireFormat: .openAICompatible,
            baseURL: "https://api.moonshot.cn/v1", envKeys: ["MOONSHOT_API_KEY"],
            docURL: "https://platform.moonshot.cn/docs"
        ),
        ProviderDescriptor(
            id: "zai", name: "Z.ai", wireFormat: .openAICompatible,
            baseURL: "https://api.z.ai/api/paas/v4", envKeys: ["ZAI_API_KEY", "ZHIPUAI_API_KEY"],
            docURL: "https://docs.z.ai"
        ),
        ProviderDescriptor(
            id: "minimax", name: "MiniMax", wireFormat: .openAICompatible,
            baseURL: "https://api.minimax.chat/v1", envKeys: ["MINIMAX_API_KEY"],
            docURL: "https://platform.minimaxi.com/document"
        ),
        ProviderDescriptor(
            id: "qwen", name: "Qwen (DashScope)", wireFormat: .openAICompatible,
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            envKeys: ["DASHSCOPE_API_KEY"], docURL: "https://help.aliyun.com/zh/model-studio"
        ),
        ProviderDescriptor(
            id: "nvidia", name: "NVIDIA NIM", wireFormat: .openAICompatible,
            baseURL: "https://integrate.api.nvidia.com/v1", envKeys: ["NVIDIA_API_KEY"],
            docURL: "https://docs.nvidia.com/nim"
        ),
        ProviderDescriptor(
            id: "huggingface", name: "Hugging Face", wireFormat: .openAICompatible,
            baseURL: "https://router.huggingface.co/v1", envKeys: ["HF_TOKEN", "HUGGINGFACE_API_KEY"],
            docURL: "https://huggingface.co/docs/inference-providers"
        ),
        ProviderDescriptor(
            id: "venice", name: "Venice", wireFormat: .openAICompatible,
            baseURL: "https://api.venice.ai/api/v1", envKeys: ["VENICE_API_KEY"],
            docURL: "https://docs.venice.ai"
        ),
        ProviderDescriptor(
            id: "nanogpt", name: "NanoGPT", wireFormat: .openAICompatible,
            baseURL: "https://nano-gpt.com/api/v1", envKeys: ["NANO_GPT_API_KEY"],
            docURL: "https://docs.nano-gpt.com"
        ),

        // MARK: Local runtimes
        ProviderDescriptor(
            id: "ollama", name: "Ollama", wireFormat: .openAICompatible,
            baseURL: "http://localhost:11434/v1",
            docURL: "https://docs.ollama.com/api/openai-compatibility",
            requiresKey: false,
            note: "Runs on this Mac. No key needed."
        ),
        ProviderDescriptor(
            id: "lmstudio", name: "LM Studio", wireFormat: .openAICompatible,
            baseURL: "http://localhost:1234/v1",
            docURL: "https://lmstudio.ai/docs/api/openai-api",
            requiresKey: false,
            note: "Runs on this Mac. No key needed."
        ),
        ProviderDescriptor(
            id: "llamacpp", name: "llama.cpp", wireFormat: .openAICompatible,
            baseURL: "http://localhost:8080/v1",
            docURL: "https://github.com/ggml-org/llama.cpp/tree/master/tools/server",
            requiresKey: false,
            note: "Runs on this Mac. No key needed."
        ),

        // MARK: Anything else
        ProviderDescriptor(
            id: customID, name: "Custom (OpenAI-compatible)", wireFormat: .openAICompatible,
            baseURL: "", envKeys: [],
            note: "Any endpoint that speaks the OpenAI chat-completions API — a gateway, a proxy, or a provider not listed here. Set the base URL, key and model yourself."
        ),
    ]

    /// Always non-empty, so callers never have to handle a missing provider.
    public static let fallback = all.first { $0.id == "deepseek" } ?? all[0]

    public static func provider(id: String) -> ProviderDescriptor? {
        all.first { $0.id == id }
    }

    /// Resolves an id to a descriptor, falling back rather than failing: a config
    /// naming a provider this build does not know about should still start.
    public static func provider(orFallback id: String) -> ProviderDescriptor {
        provider(id: id) ?? fallback
    }

    /// Grouped for display in Settings.
    public static var groups: [(title: String, providers: [ProviderDescriptor])] {
        [
            ("Hosted", all.filter { !$0.isCustom && $0.id != "ollama" && $0.id != "lmstudio" && $0.id != "llamacpp" }),
            ("Local", all.filter { $0.id == "ollama" || $0.id == "lmstudio" || $0.id == "llamacpp" }),
            ("Other", all.filter(\.isCustom)),
        ]
    }
}
