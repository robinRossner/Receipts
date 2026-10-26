import Foundation

/// Which AI backend runs the pipeline. To add one: add a case here, give it a display name,
/// add its settings fields to LLMSettings (+ Keys), build it in ProviderFactory.makeBackend,
/// and add its section in SettingsView.backendSection.
enum LLMBackend: String, CaseIterable, Identifiable, Sendable {
    case ollama

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ollama: return "Ollama (local)"
        }
    }
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
        static let debugDump = "pipeline.debugDump"
    }

    var backend: LLMBackend
    var ollamaEndpoint: String
    var ollamaVisionModel: String
    var ollamaTextModel: String
    var ollamaUseSchemaFormat: Bool
    /// Write each extraction to debug_output/<name>.json.
    var debugDump: Bool

    static let defaults = LLMSettings(
        backend: .ollama,
        ollamaEndpoint: OllamaClient.defaultBaseURL.absoluteString,
        ollamaVisionModel: "qwen2.5vl:7b",
        ollamaTextModel: "qwen2.5:7b-instruct",
        // Plain JSON mode is what extraction quality was tuned on; schema-constrained output is opt-in.
        ollamaUseSchemaFormat: false,
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
            debugDump: store.object(forKey: Keys.debugDump) as? Bool ?? d.debugDump
        )
    }
}
