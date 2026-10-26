import Foundation

/// Everything the pipeline needs from the outside besides the database: the LLM providers for
/// each step plus pipeline switches. Built by ProviderFactory, held by ReceiptStore, and passed
/// by value into ReceiptPipeline, so a receipt in flight keeps the providers it started with.
struct PipelineServices: Sendable {
    let extraction: any ReceiptExtractionProvider
    let classification: any ItemClassificationProvider
    let health: any LLMProviderHealth
    let debugDump: Bool
}

enum ProviderFactory {
    /// One backend, as all three roles. A new backend only needs a case here (see LLMBackend).
    private struct Backend {
        let id: String
        let extraction: any ReceiptExtractionProvider
        let classification: any ItemClassificationProvider
        let health: any LLMProviderHealth
    }

    private static func makeBackend(_ backend: LLMBackend, settings: LLMSettings, env: AppEnvironment) -> Backend {
        switch backend {
        case .ollama:
            let url = URL(string: settings.ollamaEndpoint).flatMap { $0.host == nil ? nil : $0 } ?? OllamaClient.defaultBaseURL
            let provider = OllamaProvider(
                client: OllamaClient(baseURL: url),
                visionModel: settings.ollamaVisionModel,
                textModel: settings.ollamaTextModel,
                useSchemaFormat: settings.ollamaUseSchemaFormat,
                logDirectory: env.logDir
            )
            return Backend(id: provider.id, extraction: provider, classification: provider, health: provider)
        }
    }

    /// The backends to try, in order. Today just the selected one; a "fallback backend" setting
    /// would append here and FallbackProvider takes care of the rest.
    static func backendChain(for settings: LLMSettings) -> [LLMBackend] {
        [settings.backend]
    }

    static func makeServices(settings: LLMSettings, env: AppEnvironment) -> PipelineServices {
        let backends = backendChain(for: settings).map { makeBackend($0, settings: settings, env: env) }
        if backends.count <= 1 {
            let backend = backends.first ?? makeBackend(.ollama, settings: settings, env: env)
            return PipelineServices(
                extraction: backend.extraction, classification: backend.classification,
                health: backend.health, debugDump: settings.debugDump
            )
        }
        return PipelineServices(
            extraction: FallbackProvider<any ReceiptExtractionProvider>(backends.map(\.extraction)),
            classification: FallbackProvider<any ItemClassificationProvider>(backends.map(\.classification)),
            health: FallbackProvider<any LLMProviderHealth>(backends.map(\.health), ids: backends.map(\.id)),
            debugDump: settings.debugDump
        )
    }
}
