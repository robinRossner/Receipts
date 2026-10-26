import Foundation

/// The Ollama backend: wraps OllamaClient (HTTP) and OllamaProcessManager (start/check) behind
/// the provider protocols. One instance serves both steps, each with its own model.
struct OllamaProvider: ReceiptExtractionProvider, ItemClassificationProvider, LLMProviderHealth {
    /// Keeps both models resident between receipts instead of Ollama's 5-minute default.
    static let keepAlive = "30m"

    let client: OllamaClient
    let visionModel: String
    let textModel: String
    /// Send the JSON schema as Ollama's `format` (structured output) instead of plain JSON mode.
    let useSchemaFormat: Bool
    let logDirectory: URL

    var id: String { "ollama" }

    func extractReceipt(jpeg: Data, prompt: String, schema: JSONSchema, maxOutputTokens: Int) async throws -> LLMResponse {
        let text = try await client.chat(
            model: visionModel,
            prompt: prompt,
            imageData: jpeg,
            temperature: 0.1,
            numCtx: 8192,
            numPredict: maxOutputTokens,
            schema: useSchemaFormat ? schema : nil,
            keepAlive: Self.keepAlive
        )
        return LLMResponse(text: text, providerId: "\(id)/\(visionModel)")
    }

    func classify(prompt: String, schema: JSONSchema, maxOutputTokens: Int) async throws -> LLMResponse {
        // num_ctx: the numbered taxonomy plus a whole receipt's items outgrows Ollama's default window.
        let text = try await client.chat(
            model: textModel,
            prompt: prompt,
            temperature: 0.1,
            numCtx: 8192,
            numPredict: maxOutputTokens,
            schema: useSchemaFormat ? schema : nil,
            keepAlive: Self.keepAlive
        )
        return LLMResponse(text: text, providerId: "\(id)/\(textModel)")
    }

    func readiness() async -> ProviderStatus {
        let warning = await OllamaProcessManager.ensureReady(
            client: client, requiredModels: [visionModel, textModel], logDirectory: logDirectory
        )
        return warning.map(ProviderStatus.warning) ?? .ready
    }
}
