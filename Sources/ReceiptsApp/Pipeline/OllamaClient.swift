import Foundation

enum OllamaError: Error, LocalizedError {
    case requestFailed(String)
    case badResponseShape

    var errorDescription: String? {
        switch self {
        case .requestFailed(let msg): return "Ollama request failed: \(msg)"
        case .badResponseShape: return "Ollama returned an unexpected response shape."
        }
    }
}

/// Talks to a locally-running Ollama server over its HTTP API - replaces the Python `ollama`
/// client library used in scan_and_parse_receipt.py and categorize_item.py. Same two calls the
/// Python code made: a vision-model chat (image + prompt) and a text-model chat (prompt only).
/// Only OllamaProvider / OllamaProcessManager use this; the pipeline goes through the provider
/// protocols in LLMProvider.swift.
struct OllamaClient: Sendable {
    static let defaultBaseURL = URL(string: "http://127.0.0.1:11434")!

    let baseURL: URL

    init(baseURL: URL = OllamaClient.defaultBaseURL) {
        self.baseURL = baseURL
    }

    /// True when the endpoint is on this machine, i.e. we may start `ollama serve` ourselves.
    var isLocal: Bool {
        ["127.0.0.1", "localhost", "::1", "[::1]"].contains(baseURL.host?.lowercased() ?? "")
    }

    /// - Parameters:
    ///   - imageData: JPEG bytes, base64-encoded into the request the way Ollama's HTTP API
    ///     expects (the Python `ollama` client did this base64 encoding internally).
    ///   - schema: when set, sent as Ollama's structured-output `format` (a JSON schema, needs
    ///     Ollama 0.5+); otherwise plain JSON mode (`format: "json"`).
    ///   - keepAlive: how long Ollama keeps the model loaded after this call (e.g. "30m"), so
    ///     back-to-back receipts don't pay the model load time again.
    func chat(
        model: String,
        prompt: String,
        imageData: Data? = nil,
        temperature: Double = 0.1,
        numCtx: Int? = nil,
        numPredict: Int? = nil,
        schema: JSONSchema? = nil,
        keepAlive: String? = nil
    ) async throws -> String {
        var message: [String: Any] = ["role": "user", "content": prompt]
        if let imageData {
            message["images"] = [imageData.base64EncodedString()]
        }

        var options: [String: Any] = ["temperature": temperature]
        if let numCtx { options["num_ctx"] = numCtx }
        if let numPredict { options["num_predict"] = numPredict }

        var body: [String: Any] = [
            "model": model,
            "format": "json",
            "messages": [message],
            "options": options,
            "stream": false,  // Ollama's raw HTTP API streams NDJSON by default; we want one shot.
        ]
        if let schema { body["format"] = schema.root }
        if let keepAlive { body["keep_alive"] = keepAlive }

        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 180

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let detail = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw OllamaError.requestFailed("HTTP \(status) \(detail)".trimmingCharacters(in: .whitespaces))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseMessage = json["message"] as? [String: Any],
              let content = responseMessage["content"] as? String else {
            throw OllamaError.badResponseShape
        }
        return content
    }

    func isRunning() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    func installedModels() async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 5
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            return []
        }
        return models.compactMap { $0["name"] as? String }
    }
}
