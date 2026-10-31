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

#if os(macOS)
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
        case .anthropicAPI:
            let provider = AnthropicAPIProvider(apiKey: KeychainStore.read(.anthropicAPIKey), model: settings.anthropicModel)
            return Backend(id: provider.id, extraction: provider, classification: provider, health: provider)
        case .claudeSubscriptionToken, .claudeCodeLogin:
            let provider = ClaudeCLIProvider(
                authMode: backend == .claudeSubscriptionToken ? .oauthToken : .existingLogin,
                binaryPath: ClaudeCLILocator.resolve(configured: settings.claudeCLIPath),
                model: settings.claudeCLIModel,
                oauthToken: backend == .claudeSubscriptionToken ? KeychainStore.read(.claudeOAuthToken) : nil
            )
            return Backend(id: provider.id, extraction: provider, classification: provider, health: provider)
        }
    }

    /// The backends to try, in order: the selected one, then local Ollama when a Claude backend
    /// is selected and "Fall back to local Ollama" is on. Ollama is only started/checked when it
    /// is in this chain.
    static func backendChain(for settings: LLMSettings) -> [LLMBackend] {
        var chain = [settings.backend]
        if settings.backend.isClaude && settings.fallbackToOllama { chain.append(.ollama) }
        return chain
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
#else
/// The iPhone app has no AI of its own: the server reads receipts. These providers exist only so the shared
/// code (which can add a manual line item) compiles; they never reach a model. A new item gets the
/// "Other > Miscellaneous" category flagged for review (an empty answer), which the user can change by hand.
struct CloudOnlyProvider: ReceiptExtractionProvider, ItemClassificationProvider, LLMProviderHealth {
    var id: String { "cloud-only" }

    func extractReceipt(jpeg: Data, prompt: String, schema: JSONSchema, maxOutputTokens: Int) async throws -> LLMResponse {
        throw LLMProviderError.allProvidersFailed(["Receipts are read by the server on the iPhone"])
    }

    func classify(prompt: String, schema: JSONSchema, maxOutputTokens: Int) async throws -> LLMResponse {
        LLMResponse(text: "{}", providerId: id)
    }

    func readiness() async -> ProviderStatus { .ready }
}

enum ProviderFactory {
    static func backendChain(for settings: LLMSettings) -> [LLMBackend] { [] }

    static func makeServices(settings: LLMSettings, env: AppEnvironment) -> PipelineServices {
        let provider = CloudOnlyProvider()
        return PipelineServices(extraction: provider, classification: provider, health: provider, debugDump: false)
    }
}
#endif
