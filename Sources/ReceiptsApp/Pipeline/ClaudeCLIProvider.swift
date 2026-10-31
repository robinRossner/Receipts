import Foundation

enum ClaudeCLIError: Error, LocalizedError {
    case binaryNotFound
    case missingToken
    case timedOut(Int)
    case launchFailed(String)
    case failed(exitCode: Int32, detail: String)
    case badOutput(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound: return "Claude CLI not found - install Claude Code or set its path in Settings."
        case .missingToken: return "No Claude subscription token saved - run `claude setup-token` and paste the token in Settings."
        case .timedOut(let s): return "Claude CLI didn't answer within \(s)s and was stopped."
        case .launchFailed(let m): return "Could not start the Claude CLI: \(m)"
        case .failed(let code, let detail): return "Claude CLI failed (exit \(code)): \(detail)"
        case .badOutput(let m): return "Claude CLI returned unexpected output: \(m)"
        }
    }
}

/// Finds the user's `claude` binary. GUI apps don't inherit the shell PATH, so check the usual
/// install locations. Deliberately NOT the copies under ~/Library/Application Support/Claude
/// (the desktop app's internal runtime).
enum ClaudeCLILocator {
    static var candidates: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
        ]
    }

    static func detect() -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The configured path if set (with ~ expanded), else auto-detect.
    static func resolve(configured: String) -> String? {
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return detect() }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return FileManager.default.isExecutableFile(atPath: expanded) ? expanded : nil
    }
}

/// Claude through the user's installed Claude Code CLI in headless print mode (`claude -p`).
/// Two auth modes: the CLI's existing login, or a `claude setup-token` token passed ONLY via
/// the CLAUDE_CODE_OAUTH_TOKEN environment variable (never argv). The subscription token is
/// never sent to the Messages API directly - that's what the CLI is for.
struct ClaudeCLIProvider: ReceiptExtractionProvider, ItemClassificationProvider, LLMProviderHealth {
    enum AuthMode: Sendable {
        case existingLogin
        case oauthToken
    }

    static let timeoutSeconds = 180

    /// Replaces Claude Code's coding-agent system prompt for these one-shot JSON tasks.
    static let systemPrompt = "You are a data extraction and classification engine inside a receipts app. Follow the user's instructions exactly and answer only with the requested JSON. You have no tools."

    let authMode: AuthMode
    /// Resolved executable path, or nil if none was found.
    let binaryPath: String?
    let model: String
    let oauthToken: String?

    var id: String {
        switch authMode {
        case .existingLogin: return "claude-cli"
        case .oauthToken: return "claude-cli-token"
        }
    }

    // MARK: Invocation building (pure, so it can be checked without running anything)

    struct Invocation {
        let executable: String
        let arguments: [String]
        let environment: [String: String]
        let stdin: Data
    }

    /// Headless flags (see code.claude.com/docs/en/cli-reference and /headless):
    /// - no `--bare`: bare mode reads neither the OAuth login nor CLAUDE_CODE_OAUTH_TOKEN.
    /// - `--setting-sources ""`, `--strict-mcp-config`, `--disable-slash-commands`, `--tools ""`:
    ///   keep the user's hooks, plugins, MCP servers and skills out of these calls.
    /// - `--max-turns 3`: `--json-schema` answers via an internal StructuredOutput tool call
    ///   and re-prompts on a schema mismatch, so one turn can be too few.
    static func arguments(model: String, schema: JSONSchema, imageInput: Bool) -> [String] {
        var args = [
            "-p",
            "--model", model,
            // `--input-format stream-json` (image calls) is only accepted with stream-json output,
            // which in turn needs `--verbose`; text-only calls keep the single JSON object.
            "--output-format", imageInput ? "stream-json" : "json",
            "--json-schema", schema.anthropicCompatible().jsonString,
            "--max-turns", "3",
            "--tools", "",
            "--strict-mcp-config",
            "--setting-sources", "",
            "--disable-slash-commands",
            "--no-session-persistence",
            "--permission-mode", "dontAsk",
            "--system-prompt", systemPrompt,
        ]
        if imageInput { args += ["--input-format", "stream-json", "--verbose"] }
        return args
    }

    /// One stream-json user message with the image block first, then the prompt text.
    static func streamJSONMessage(jpeg: Data, prompt: String) throws -> Data {
        let message: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": AnthropicAPIProvider.imageContent(jpeg: jpeg, prompt: prompt),
            ] as [String: Any],
        ]
        var line = try JSONSerialization.data(withJSONObject: message)
        line.append(0x0A)
        return line
    }

    static func environment(binaryPath: String, authMode: AuthMode, token: String?) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // npm installs are `#!/usr/bin/env node` scripts: give the child a PATH that can find node.
        let extraPath = [(binaryPath as NSString).deletingLastPathComponent, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        env["PATH"] = (extraPath + [env["PATH"] ?? ""]).filter { !$0.isEmpty }.joined(separator: ":")
        if authMode == .oauthToken {
            // These outrank CLAUDE_CODE_OAUTH_TOKEN in Claude Code's auth precedence.
            env.removeValue(forKey: "ANTHROPIC_API_KEY")
            env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
            if let token { env["CLAUDE_CODE_OAUTH_TOKEN"] = token }
        }
        return env
    }

    func makeInvocation(prompt: String, jpeg: Data?, schema: JSONSchema) throws -> Invocation {
        guard let binaryPath else { throw ClaudeCLIError.binaryNotFound }
        if authMode == .oauthToken, (oauthToken ?? "").isEmpty { throw ClaudeCLIError.missingToken }
        let stdin = try jpeg.map { try Self.streamJSONMessage(jpeg: $0, prompt: prompt) } ?? Data(prompt.utf8)
        return Invocation(
            executable: binaryPath,
            arguments: Self.arguments(model: model, schema: schema, imageInput: jpeg != nil),
            environment: Self.environment(binaryPath: binaryPath, authMode: authMode, token: oauthToken),
            stdin: stdin
        )
    }

    // MARK: Calls

    func extractReceipt(jpeg: Data, prompt: String, schema: JSONSchema, maxOutputTokens: Int) async throws -> LLMResponse {
        try await run(try makeInvocation(prompt: prompt, jpeg: jpeg, schema: schema))
    }

    func classify(prompt: String, schema: JSONSchema, maxOutputTokens: Int) async throws -> LLMResponse {
        try await run(try makeInvocation(prompt: prompt, jpeg: nil, schema: schema))
    }

    private func run(_ invocation: Invocation) async throws -> LLMResponse {
        let output = try await ProcessRunner.run(invocation, timeoutSeconds: Self.timeoutSeconds)
        return LLMResponse(text: try Self.parseResult(stdout: output.stdout, stderr: output.stderr, exitCode: output.exitCode), providerId: "\(id)/\(model)")
    }

    /// The final `result` message of the CLI output: `--output-format json` prints one object (or a
    /// list of messages), `stream-json --verbose` prints NDJSON (system init, assistant, user,
    /// rate_limit_event, ..., result). Lines that do not parse (a truncated tail, stray noise) are
    /// skipped; the last `result` event wins; nil if there is none.
    static func resultEnvelope(stdout: Data) -> [String: Any]? {
        func lastResult(_ items: [Any]) -> [String: Any]? {
            items.reversed().compactMap { $0 as? [String: Any] }.first { $0["type"] as? String == "result" }
        }
        if let whole = try? JSONSerialization.jsonObject(with: stdout) {
            if let object = whole as? [String: Any] {
                // A single object is the result itself (older `json` output has type "result" too).
                return object["type"] == nil || object["type"] as? String == "result" ? object : nil
            }
            if let list = whole as? [Any] { return lastResult(list) }
        }
        let lines = stdout.split(separator: 0x0A).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) }
        return lastResult(lines)
    }

    /// Prefer `structured_output`; fall back to the `result` text (JSONUtil scrapes the object out of
    /// it downstream). `is_error: true` is a failure whatever the `subtype` says (a bad model comes
    /// back as `subtype: "success"`, `is_error: true`).
    static func parseResult(stdout: Data, stderr: Data, exitCode: Int32) throws -> String {
        let errText = String(data: stderr.suffix(2000), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let json = resultEnvelope(stdout: stdout)
        let resultText = json?["result"] as? String

        if exitCode != 0 || json?["is_error"] as? Bool == true {
            var parts: [String] = []
            if let resultText { parts.append(resultText) }
            if let errors = json?["errors"] as? [Any] { parts += errors.map { "\($0)" } }
            if let status = json?["api_error_status"] as? Int { parts.append("HTTP \(status)") }
            if parts.isEmpty, let subtype = json?["subtype"] as? String, subtype != "success" { parts.append(subtype) }
            parts.append(errText)
            let detail = parts.filter { !$0.isEmpty }.joined(separator: " | ")
            throw ClaudeCLIError.failed(exitCode: exitCode, detail: detail.isEmpty ? "no output" : String(detail.prefix(800)))
        }
        guard let json else {
            throw ClaudeCLIError.badOutput(String(data: stdout.prefix(300), encoding: .utf8) ?? "<binary>")
        }
        if let structured = json["structured_output"], !(structured is NSNull),
           JSONSerialization.isValidJSONObject(structured),
           let data = try? JSONSerialization.data(withJSONObject: structured),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let resultText, !resultText.isEmpty { return resultText }
        throw ClaudeCLIError.badOutput("no structured_output or result (subtype: \(json["subtype"] as? String ?? "?"))")
    }

    // MARK: Readiness

    func readiness() async -> ProviderStatus {
        guard let binaryPath else {
            return .warning("Claude CLI not found - install Claude Code or set its path in Settings.")
        }
        if authMode == .oauthToken, (oauthToken ?? "").isEmpty {
            return .warning("No Claude subscription token saved - run `claude setup-token` in Terminal and paste it in Settings.")
        }
        let invocation = Invocation(
            executable: binaryPath, arguments: ["--version"],
            environment: Self.environment(binaryPath: binaryPath, authMode: authMode, token: oauthToken), stdin: Data()
        )
        do {
            let output = try await ProcessRunner.run(invocation, timeoutSeconds: 20)
            guard output.exitCode == 0 else {
                let err = String(data: output.stderr.prefix(300), encoding: .utf8) ?? ""
                return .warning("`claude --version` failed (exit \(output.exitCode)) - check the CLI path in Settings. \(err)")
            }
            return .ready
        } catch {
            return .warning("Couldn't run the Claude CLI at \(binaryPath): \(error.localizedDescription)")
        }
    }
}

/// Runs a child process in a fresh empty temp directory, feeds stdin, collects stdout/stderr,
/// and kills it after a timeout.
enum ProcessRunner {
    struct Output {
        let stdout: Data
        let stderr: Data
        let exitCode: Int32
    }

    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
        var value: Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var set = false
        /// Returns true the first time only.
        func trip() -> Bool { lock.lock(); defer { lock.unlock() }; if set { return false }; set = true; return true }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return set }
    }

    static func run(_ invocation: ClaudeCLIProvider.Invocation, timeoutSeconds: Int) async throws -> Output {
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("receipts-claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        process.environment = invocation.environment
        process.currentDirectoryURL = workDir

        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let out = Buffer(), err = Buffer(), timedOut = Flag(), finished = Flag()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in out.append(handle.availableData) }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in err.append(handle.availableData) }

        let exitCode: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                guard finished.trip() else { return }
                continuation.resume(returning: proc.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                guard finished.trip() else { return }
                continuation.resume(throwing: ClaudeCLIError.launchFailed(error.localizedDescription))
                return
            }
            let stdinData = invocation.stdin
            DispatchQueue.global(qos: .userInitiated).async {
                let writer = stdinPipe.fileHandleForWriting
                try? writer.write(contentsOf: stdinData)
                try? writer.close()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeoutSeconds)) {
                guard process.isRunning else { return }
                _ = timedOut.trip()
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        // Drain whatever arrived between the last handler call and exit.
        out.append((try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data())
        err.append((try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data())

        if timedOut.isSet { throw ClaudeCLIError.timedOut(timeoutSeconds) }
        return Output(stdout: out.value, stderr: err.value, exitCode: exitCode)
    }
}
