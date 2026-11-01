import Foundation

/// Which AI backend runs the pipeline. To add one: add a case here, give it a display name,
/// add its settings fields to LLMSettings (+ Keys), build it in ProviderFactory.makeBackend,
/// and add its section in SettingsView.backendSection.
enum LLMBackend: String, CaseIterable, Identifiable, Sendable {
    case ollama
    case anthropicAPI
    case claudeSubscriptionToken
    case claudeCodeLogin

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ollama: return "Ollama (local)"
        case .anthropicAPI: return "Claude API (API key)"
        case .claudeSubscriptionToken: return "Claude subscription token"
        case .claudeCodeLogin: return "Claude Code CLI (existing login)"
        }
    }

    /// Sends receipt data to Anthropic (privacy note + optional Ollama fallback).
    var isClaude: Bool { self != .ollama }
}

/// The one Claude model + thinking depth every Claude backend uses (Claude API, subscription token, Claude Code
/// login). Picked from a 30-receipt comparison (docs/decisions.md). Hardcoded on purpose, not a setting; the
/// server's counterpart is RECEIPTS_LLM_MODEL / RECEIPTS_LLM_EFFORT (backend/receipts/settings.py).
enum ClaudeModel {
    /// Exact model id: the Messages API `model` and the CLI's `--model`.
    static let id = "claude-haiku-5-5"
    /// Messages API `output_config.effort` and the CLI's `--effort`.
    static let effort = "high"
}

/// User-editable AI settings, stored in UserDefaults. SettingsView binds the same keys through
/// @AppStorage; the pipeline reads an immutable snapshot via `load()`.
struct LLMSettings: Sendable, Equatable {
    enum Keys {
        static let backend = "llm.backend"
        static let ollamaEndpoint = "llm.ollama.endpoint"
        static let ollamaVisionModel = "llm.ollama.visionModel"
        static let ollamaTextModel = "llm.ollama.textModel"
        static let ollamaUseSchemaFormat = "llm.ollama.useSchemaFormat"
        static let claudeCLIPath = "llm.claudeCLI.path"
        static let fallbackToOllama = "llm.fallbackToOllama"
        static let debugDump = "pipeline.debugDump"
    }

    var backend: LLMBackend
    var ollamaEndpoint: String
    var ollamaVisionModel: String
    var ollamaTextModel: String
    var ollamaUseSchemaFormat: Bool
    /// Empty = auto-detect (ClaudeCLILocator). Secrets (API key, token) live in KeychainStore, not here.
    var claudeCLIPath: String
    /// With a Claude backend selected, retry failed calls on local Ollama.
    var fallbackToOllama: Bool
    /// Write each extraction to debug_output/<name>.json.
    var debugDump: Bool

    static let defaults = LLMSettings(
        // The Claude connection: the existing `claude` CLI login. Ollama stays selectable in Settings.
        backend: .claudeCodeLogin,
        ollamaEndpoint: "http://127.0.0.1:11434",   // OllamaClient.defaultBaseURL (not compiled into the iPhone app)
        ollamaVisionModel: "qwen2.5vl:7b",
        ollamaTextModel: "qwen2.5:7b-instruct",
        // Plain JSON mode is what extraction quality was tuned on; schema-constrained output is opt-in.
        ollamaUseSchemaFormat: false,
        claudeCLIPath: "",
        fallbackToOllama: true,
        debugDump: true
    )

    static func load(from store: UserDefaults = .standard) -> LLMSettings {
        let d = defaults
        func string(_ key: String, _ fallback: String) -> String {
            let value = store.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? fallback : value
        }
        return LLMSettings(
            backend: store.string(forKey: Keys.backend).flatMap(LLMBackend.init(rawValue:)) ?? d.backend,
            ollamaEndpoint: string(Keys.ollamaEndpoint, d.ollamaEndpoint),
            ollamaVisionModel: string(Keys.ollamaVisionModel, d.ollamaVisionModel),
            ollamaTextModel: string(Keys.ollamaTextModel, d.ollamaTextModel),
            ollamaUseSchemaFormat: store.object(forKey: Keys.ollamaUseSchemaFormat) as? Bool ?? d.ollamaUseSchemaFormat,
            claudeCLIPath: store.string(forKey: Keys.claudeCLIPath)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? d.claudeCLIPath,
            fallbackToOllama: store.object(forKey: Keys.fallbackToOllama) as? Bool ?? d.fallbackToOllama,
            debugDump: store.object(forKey: Keys.debugDump) as? Bool ?? d.debugDump
        )
    }
}
