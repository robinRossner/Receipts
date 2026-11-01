import Foundation

enum AnthropicAPIError: Error, LocalizedError {
    case missingAPIKey
    case http(status: Int, message: String)
    case refusal
    case truncated
    case noTextContent

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "No Anthropic API key saved. Add one in Settings > AI backend."
        case .http(401, _): return "Anthropic rejected the API key (401). Check or replace it in Settings."
        case .http(403, let m): return "The API key isn't allowed to do this (403): \(m)"
        case .http(404, let m): return "Model not found (404): \(m)"
        case .http(413, _): return "Request too large for the Anthropic API (413) - the receipt image is too big."
        case .http(429, _): return "Anthropic rate limit reached (429). Wait a moment and try again."
        case .http(529, _): return "Anthropic's API is overloaded right now (529). Try again shortly."
        case .http(let s, let m) where s >= 500: return "Anthropic API server error (\(s)): \(m)"
        case .http(let s, let m): return "Anthropic API request failed (\(s)): \(m)"
        case .refusal: return "Claude declined to answer this request (stop_reason: refusal)."
        case .truncated: return "Claude's answer hit the output token limit and was cut off (stop_reason: max_tokens)."
        case .noTextContent: return "The Anthropic API response contained no text block."
        }
    }
}

/// Claude via the Messages API with the user's own API key (Console billing). Uses structured
/// outputs (`output_config.format`, GA - no beta header) so answers match the JSON schema.
struct AnthropicAPIProvider: ReceiptExtractionProvider, ItemClassificationProvider, LLMProviderHealth {
    static let baseURL = URL(string: "https://api.anthropic.com/v1/")!
    static let apiVersion = "2023-06-01"

    let apiKey: String?
    let model: String
    let effort: String

    init(apiKey: String?, model: String = ClaudeModel.id, effort: String = ClaudeModel.effort) {
        self.apiKey = apiKey
        self.model = model
        self.effort = effort
    }

    var id: String { "anthropic-api" }

    // MARK: Request building (pure, so it can be checked without network access)

    static func makeRequestBody(model: String = ClaudeModel.id, effort: String = ClaudeModel.effort, content: [[String: Any]], schema: JSONSchema, maxTokens: Int) -> [String: Any] {
        [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": content]],
            "output_config": [
                "effort": effort,
                "format": ["type": "json_schema", "schema": schema.anthropicCompatible().root] as [String: Any],
            ] as [String: Any],
        ]
    }

    static func imageContent(jpeg: Data, prompt: String) -> [[String: Any]] {
        [
            ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()] as [String: Any]],
            ["type": "text", "text": prompt],
        ]
    }

    static func textContent(_ prompt: String) -> [[String: Any]] {
        [["type": "text", "text": prompt]]
    }

    static func makeURLRequest(path: String, apiKey: String, method: String = "GET", body: [String: Any]? = nil, timeout: TimeInterval) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        request.timeoutInterval = timeout
        return request
    }

    // MARK: Calls

    func extractReceipt(jpeg: Data, prompt: String, schema: JSONSchema, maxOutputTokens: Int) async throws -> LLMResponse {
        // Structured output + a long receipt can exceed the Ollama-sized budget; give Claude room.
        try await send(content: Self.imageContent(jpeg: jpeg, prompt: prompt), schema: schema, maxTokens: max(maxOutputTokens, 8192))
    }

    func classify(prompt: String, schema: JSONSchema, maxOutputTokens: Int) async throws -> LLMResponse {
        try await send(content: Self.textContent(prompt), schema: schema, maxTokens: max(maxOutputTokens, 1024))
    }

    private func send(content: [[String: Any]], schema: JSONSchema, maxTokens: Int) async throws -> LLMResponse {
        guard let apiKey, !apiKey.isEmpty else { throw AnthropicAPIError.missingAPIKey }
        let body = Self.makeRequestBody(model: model, effort: effort, content: content, schema: schema, maxTokens: maxTokens)
        let request = try Self.makeURLRequest(path: "messages", apiKey: apiKey, method: "POST", body: body, timeout: 180)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw AnthropicAPIError.http(status: status, message: Self.errorMessage(from: data))
        }
        return LLMResponse(text: try Self.parseMessageResponse(data), providerId: "\(id)/\(model)")
    }

    static func parseMessageResponse(_ data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnthropicAPIError.noTextContent
        }
        switch json["stop_reason"] as? String {
        case "refusal": throw AnthropicAPIError.refusal
        case "max_tokens": throw AnthropicAPIError.truncated
        default: break
        }
        let blocks = json["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw AnthropicAPIError.noTextContent }
        return text
    }

    static func errorMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return String(data: data.prefix(300), encoding: .utf8) ?? ""
    }

    // MARK: Readiness

    /// Caches the last key check so reopening Settings or relaunching within the TTL doesn't
    /// hit /v1/models again. Keyed by a hash of key + model, never the key itself.
    private actor ReadinessCache {
        static let shared = ReadinessCache()
        private var entries: [Int: (status: ProviderStatus, at: Date)] = [:]
        func get(_ key: Int, ttl: TimeInterval) -> ProviderStatus? {
            guard let entry = entries[key], Date().timeIntervalSince(entry.at) < ttl else { return nil }
            return entry.status
        }
        func set(_ key: Int, _ status: ProviderStatus) { entries[key] = (status, Date()) }
    }

    func readiness() async -> ProviderStatus {
        guard let apiKey, !apiKey.isEmpty else {
            return .warning("No Anthropic API key saved - add one in Settings > AI backend.")
        }
        var hasher = Hasher()
        hasher.combine(apiKey)
        hasher.combine(model)
        let cacheKey = hasher.finalize()
        if let cached = await ReadinessCache.shared.get(cacheKey, ttl: 600) { return cached }

        let status: ProviderStatus
        do {
            let request = try Self.makeURLRequest(path: "models", apiKey: apiKey, timeout: 10)
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            if (200..<300).contains(code) {
                let ids = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]])?
                    .compactMap { $0["id"] as? String } ?? []
                status = ids.isEmpty || ids.contains(model) || ids.contains(where: { $0.hasPrefix(model) })
                    ? .ready
                    : .warning("Model \"\(model)\" isn't available for this API key.")
            } else {
                status = .warning(AnthropicAPIError.http(status: code, message: Self.errorMessage(from: data)).localizedDescription)
            }
        } catch {
            // Network trouble is transient - don't cache it.
            return .warning("Can't reach api.anthropic.com: \(error.localizedDescription)")
        }
        await ReadinessCache.shared.set(cacheKey, status)
        return status
    }
}

extension JSONSchema {
    /// A copy that satisfies Claude structured-output limits: `additionalProperties: false` on
    /// every object, and no numeric/string/array-length constraints (those return a 400).
    func anthropicCompatible() -> JSONSchema {
        let unsupported: Set<String> = ["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf",
                                        "minLength", "maxLength", "maxItems", "minProperties", "maxProperties"]
        func clean(_ value: Any) -> Any {
            if let array = value as? [Any] { return array.map(clean) }
            guard var dict = value as? [String: Any] else { return value }
            for key in unsupported { dict.removeValue(forKey: key) }
            if let minItems = dict["minItems"] as? Int, minItems > 1 { dict.removeValue(forKey: "minItems") }
            let type = dict["type"]
            if type as? String == "object" || (type as? [String])?.contains("object") == true || dict["properties"] != nil {
                dict["additionalProperties"] = false
            }
            for (key, child) in dict {
                switch key {
                case "properties", "$defs", "definitions":
                    // name -> schema maps: clean each schema, never the property names themselves.
                    if let map = child as? [String: Any] { dict[key] = map.mapValues(clean) }
                case "enum", "const", "required", "default", "description":
                    continue
                default:
                    dict[key] = clean(child)
                }
            }
            return dict
        }
        return JSONSchema(name: name, root: clean(root) as? [String: Any] ?? root, keyOrder: keyOrder)
    }
}
