import Foundation

/// Why a call to the receipts backend failed. `code` is the contract's `detail.code` (e.g. `duplicate_image`).
enum ReceiptsAPIError: Error, LocalizedError, Equatable {
    case http(status: Int, code: String?, message: String?, extra: [String: String])
    case transport(String)
    case invalidResponse(String)
    case notConfigured(String)

    var code: String? { if case .http(_, let c, _, _) = self { return c }; return nil }
    var status: Int? { if case .http(let s, _, _, _) = self { return s }; return nil }
    /// Extra fields of the contract's error detail, e.g. `duplicate_of`.
    var extra: [String: String] { if case .http(_, _, _, let e) = self { return e }; return [:] }

    /// Worth trying again later: the network, the server being busy, or a rate limit. 4xx answers
    /// that name a problem with the request itself are not.
    var isRetryable: Bool {
        switch self {
        case .transport: return true
        case .http(let status, _, _, _): return status >= 500 || status == 429 || status == 408
        case .invalidResponse, .notConfigured: return false
        }
    }

    /// The whole server or the credentials are the problem, so other calls of this run would fail too.
    var isConnectionLevel: Bool {
        switch self {
        case .transport, .notConfigured: return true
        case .http(let status, _, _, _): return status == 401 || status == 429 || status >= 500
        case .invalidResponse: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .transport(let m): return "Server not reachable (\(m))"
        case .invalidResponse(let m): return "Unexpected answer from the server (\(m))"
        case .notConfigured(let m): return m
        case .http(let status, let code, let message, _):
            switch status {
            case 401: return "The server rejected the token (401). Check the receipts token in Settings."
            case 503: return "The server has no receipts token configured (503)."
            case 429: return "Too many wrong tokens from this network (429); try again later."
            default: return message ?? code.map { "Server error \(status) (\($0))" } ?? "Server error \(status)"
            }
        }
    }
}

/// The calls of docs/api/receipts.md the app needs. A protocol so the sync engine can be tested with a
/// fake and shared with the iOS app unchanged.
protocol ReceiptsAPI: Sendable {
    func health() async throws
    func status() async throws -> ServerStatus
    func uploadPhoto(id: String, data: Data, mediaType: String, createdAt: Date?) async throws -> UploadResponse
    func retryExtraction(id: String) async throws
    func push(_ request: PushRequest) async throws -> PushResponse
    func pull(since: String?, limit: Int) async throws -> PullResponse
    func archivePending() async throws -> [ArchivePendingPhoto]
    func downloadPhoto(path: String) async throws -> DownloadedPhoto
    func archiveConfirm(id: String, sha256: String, deviceId: String, acceptFailed: Bool) async throws -> ArchiveConfirmResponse
    func archiveSync(deviceId: String) async throws
}

/// What the user typed as "server URL" -> the receipts API base (`https://host/api/v1/receipts`).
enum ServerURL {
    static let apiPath = "/api/v1/receipts"

    static func apiBase(from input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            let local = text.hasPrefix("localhost") || text.hasPrefix("127.") || text.hasPrefix("[::1]")
            text = (local ? "http://" : "https://") + text
        }
        while text.hasSuffix("/") { text.removeLast() }
        if !text.hasSuffix(apiPath) { text += apiPath }
        guard let url = URL(string: text), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil else { return nil }
        return url
    }

    /// `GET /health` is the one unprefixed route (no token).
    static func healthURL(apiBase: URL) -> URL {
        var text = apiBase.absoluteString
        if text.hasSuffix(apiPath) { text.removeLast(apiPath.count) }
        return URL(string: text + "/health")!
    }

    /// Cursors are global to the server's database: keep one per server.
    static func cursorKey(apiBase: URL) -> String { "cursor:" + apiBase.absoluteString.lowercased() }
}

final class URLSessionReceiptsAPI: ReceiptsAPI, @unchecked Sendable {
    let baseURL: URL
    private let token: String
    private let session: URLSession
    private let encoder = WireCoding.encoder()
    private let decoder = WireCoding.decoder()

    init(baseURL: URL, token: String, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.token = token
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 600
            config.waitsForConnectivity = false
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: Calls

    func health() async throws {
        var request = URLRequest(url: ServerURL.healthURL(apiBase: baseURL))
        request.timeoutInterval = 15
        _ = try await perform(request)
    }

    func status() async throws -> ServerStatus { try decode(try await send("GET", "status")) }

    func uploadPhoto(id: String, data: Data, mediaType: String, createdAt: Date?) async throws -> UploadResponse {
        var query: [URLQueryItem] = []
        if let createdAt { query.append(URLQueryItem(name: "created_at", value: SyncDate.string(from: createdAt))) }
        var request = try makeRequest("PUT", "\(id)/photo", query: query)
        request.setValue(mediaType, forHTTPHeaderField: "Content-Type")
        request.setValue(Sha256.hex(data), forHTTPHeaderField: "X-Content-SHA256")
        let (body, _) = try await perform(request, uploading: data)
        return try decode(body)
    }

    func retryExtraction(id: String) async throws {
        _ = try await send("POST", "\(id)/extraction/retry")
    }

    func push(_ request: PushRequest) async throws -> PushResponse {
        try decode(try await send("POST", "sync/push", body: try encoder.encode(request)))
    }

    func pull(since: String?, limit: Int) async throws -> PullResponse {
        try decode(try await send("GET", "sync/pull", query: [
            URLQueryItem(name: "since", value: since ?? ""), URLQueryItem(name: "limit", value: String(limit)),
        ]))
    }

    func archivePending() async throws -> [ArchivePendingPhoto] {
        let response: ArchivePendingResponse = try decode(try await send("GET", "archive/pending"))
        return response.photos
    }

    func downloadPhoto(path: String) async throws -> DownloadedPhoto {
        // `path` is the server-relative `download` value ("/api/v1/receipts/<id>/photo").
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ReceiptsAPIError.notConfigured("Bad server URL")
        }
        components.path = path
        components.query = nil
        guard let url = components.url else { throw ReceiptsAPIError.invalidResponse("bad download path \(path)") }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await perform(request)
        return DownloadedPhoto(data: data, mediaType: response.value(forHTTPHeaderField: "Content-Type"),
                               headerSHA256: response.value(forHTTPHeaderField: "X-Content-SHA256"))
    }

    func archiveConfirm(id: String, sha256: String, deviceId: String, acceptFailed: Bool) async throws -> ArchiveConfirmResponse {
        let body = ArchiveConfirmRequest(sha256: sha256, deviceId: deviceId, acceptFailed: acceptFailed ? true : nil)
        return try decode(try await send("POST", "\(id)/archive-confirm", body: try encoder.encode(body)))
    }

    func archiveSync(deviceId: String) async throws {
        _ = try await send("POST", "archive/sync", body: try encoder.encode(ArchiveSyncRequest(deviceId: deviceId)))
    }

    // MARK: Plumbing

    private func makeRequest(_ method: String, _ path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw ReceiptsAPIError.notConfigured("Bad server URL")
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw ReceiptsAPIError.notConfigured("Bad server URL") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        var request = try makeRequest(method, path, query: query)
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await perform(request).0
    }

    private func perform(_ request: URLRequest, uploading: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            if let uploading {
                (data, response) = try await session.upload(for: request, from: uploading)
            } else {
                (data, response) = try await session.data(for: request)
            }
        } catch {
            throw ReceiptsAPIError.transport((error as? URLError)?.localizedDescription ?? error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw ReceiptsAPIError.invalidResponse("not an HTTP response") }
        guard (200..<300).contains(http.statusCode) else { throw Self.httpError(http.statusCode, data) }
        return (data, http)
    }

    /// `{"detail": {"code", "message", ...extra}}`, or FastAPI's `detail` list / plain text for 422 and friends.
    static func httpError(_ status: Int, _ data: Data) -> ReceiptsAPIError {
        var code: String?, message: String?
        var extra: [String: String] = [:]
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let detail = object["detail"] as? [String: Any] {
                code = detail["code"] as? String
                message = detail["message"] as? String
                for (k, v) in detail where k != "code" && k != "message" { extra[k] = "\(v)" }
            } else if let detail = object["detail"] as? String {
                message = detail
            } else if let list = object["detail"] as? [[String: Any]] {
                message = list.compactMap { $0["msg"] as? String }.joined(separator: "; ")
            }
        }
        return .http(status: status, code: code, message: message, extra: extra)
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try decoder.decode(T.self, from: data) } catch {
            throw ReceiptsAPIError.invalidResponse("\(T.self): \(error)")
        }
    }
}
