import Foundation

// The LLM layer, split the way the persistence layer is: the pipeline (prompts, JSON parsing,
// retries, validation) only talks to these protocols, and each backend (today: Ollama) is one
// concrete type behind them. ProviderFactory picks the implementation from LLMSettings.

/// A JSON Schema describing the object an LLM call must return. Providers that support
/// constrained/structured output (Ollama's `format`, Claude's structured outputs) can pass it
/// through; others may ignore it, so callers still parse and validate leniently.
struct JSONSchema: @unchecked Sendable {  // `root` is an immutable plist-style dictionary.
    let name: String
    let root: [String: Any]

    var jsonString: String {
        (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

/// Raw model output plus which provider (and model) produced it - recorded in the debug dump
/// and the classification log.
struct LLMResponse: Sendable {
    let text: String
    let providerId: String
}

enum ProviderStatus: Sendable, Equatable {
    case ready
    case warning(String)

    var warningMessage: String? {
        if case .warning(let message) = self { return message }
        return nil
    }
}

enum LLMProviderError: Error, LocalizedError {
    case allProvidersFailed([String])

    var errorDescription: String? {
        switch self {
        case .allProvidersFailed(let details):
            return "Every AI backend failed: " + details.joined(separator: "; ")
        }
    }
}

/// Vision step: straightened receipt JPEG + prompt in, raw JSON text out.
protocol ReceiptExtractionProvider: Sendable {
    var id: String { get }
    func extractReceipt(jpeg: Data, prompt: String, schema: JSONSchema, maxOutputTokens: Int) async throws -> LLMResponse
}

/// Text step: classification prompt in, raw JSON text out.
protocol ItemClassificationProvider: Sendable {
    var id: String { get }
    func classify(prompt: String, schema: JSONSchema, maxOutputTokens: Int) async throws -> LLMResponse
}

/// Startup / settings-change check: is the backend reachable and configured? Implementations
/// may do setup work here (OllamaProvider starts `ollama serve` if needed).
protocol LLMProviderHealth: Sendable {
    func readiness() async -> ProviderStatus
}

/// Tries each provider in order, moving on when one throws or answers with something that
/// contains no JSON object at all. Deeper validation (taxonomy numbers, receipt math) stays in
/// ReceiptExtractor / ItemCategorizer. The answering provider's id is in `LLMResponse`.
struct FallbackProvider<Provider: Sendable>: Sendable {
    let providers: [Provider]
    let providerIds: [String]

    var id: String { "fallback(\(providerIds.joined(separator: ",")))" }

    fileprivate func firstUsable(_ call: (Provider) async throws -> LLMResponse) async throws -> LLMResponse {
        var failures: [String] = []
        for (provider, providerId) in zip(providers, providerIds) {
            do {
                let response = try await call(provider)
                if JSONUtil.extractObject(response.text) != nil { return response }
                failures.append("\(providerId): no JSON object in response")
            } catch {
                failures.append("\(providerId): \(error.localizedDescription)")
            }
            print("LLM provider \(providerId) failed, trying next: \(failures.last ?? "")")
        }
        throw LLMProviderError.allProvidersFailed(failures)
    }
}

extension FallbackProvider: ReceiptExtractionProvider where Provider == any ReceiptExtractionProvider {
    init(_ providers: [any ReceiptExtractionProvider]) {
        self.init(providers: providers, providerIds: providers.map(\.id))
    }

    func extractReceipt(jpeg: Data, prompt: String, schema: JSONSchema, maxOutputTokens: Int) async throws -> LLMResponse {
        try await firstUsable { try await $0.extractReceipt(jpeg: jpeg, prompt: prompt, schema: schema, maxOutputTokens: maxOutputTokens) }
    }
}

extension FallbackProvider: ItemClassificationProvider where Provider == any ItemClassificationProvider {
    init(_ providers: [any ItemClassificationProvider]) {
        self.init(providers: providers, providerIds: providers.map(\.id))
    }

    func classify(prompt: String, schema: JSONSchema, maxOutputTokens: Int) async throws -> LLMResponse {
        try await firstUsable { try await $0.classify(prompt: prompt, schema: schema, maxOutputTokens: maxOutputTokens) }
    }
}

extension FallbackProvider: LLMProviderHealth where Provider == any LLMProviderHealth {
    init(_ providers: [any LLMProviderHealth], ids: [String]) {
        self.init(providers: providers, providerIds: ids)
    }

    /// Ready if any backend in the chain is ready; otherwise all warnings, labelled.
    func readiness() async -> ProviderStatus {
        var warnings: [String] = []
        for (provider, providerId) in zip(providers, providerIds) {
            switch await provider.readiness() {
            case .ready: return .ready
            case .warning(let message): warnings.append("\(providerId): \(message)")
            }
        }
        return warnings.isEmpty ? .ready : .warning(warnings.joined(separator: "\n"))
    }
}
