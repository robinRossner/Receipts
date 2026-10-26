import Foundation

/// Ensures Ollama is up before the pipeline needs it - replaces the `ollama serve` launch +
/// retry loop in start.sh. Never kills Ollama on quit: it's a shared background service (this
/// machine has several other unrelated models pulled), so leaving it running after the app
/// closes matches what a user who started it manually would expect.
enum OllamaProcessManager {
    /// Returns a human-readable warning to surface in the UI, or nil if everything's ready.
    /// Only starts `ollama serve` when the endpoint is local - a remote server is reported, not launched.
    static func ensureReady(client: OllamaClient, requiredModels: [String], logDirectory: URL) async -> String? {
        if await client.isRunning() {
            return await missingModelsMessage(client: client, requiredModels: requiredModels)
        }

        guard client.isLocal else {
            return "Can't reach the Ollama server at \(client.baseURL.absoluteString). Check the endpoint in Settings."
        }

        guard let ollamaPath = findOllamaBinary() else {
            return "Could not find the `ollama` command. Install Ollama from https://ollama.com and make sure it's on your PATH, then relaunch."
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ollamaPath)
        process.arguments = ["serve"]

        let logFile = logDirectory.appendingPathComponent("ollama.log")
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        if let handle = FileHandle(forWritingAtPath: logFile.path) {
            process.standardOutput = handle
            process.standardError = handle
        }

        do {
            try process.run()
        } catch {
            return "Could not start Ollama: \(error.localizedDescription)"
        }

        // Same intent as start.sh's retry loop: give it a few seconds to come up.
        for _ in 0..<20 {
            if await client.isRunning() { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        guard await client.isRunning() else {
            return "Ollama didn't start in time. Check \(logFile.path)."
        }
        return await missingModelsMessage(client: client, requiredModels: requiredModels)
    }

    private static func missingModelsMessage(client: OllamaClient, requiredModels: [String]) async -> String? {
        guard let installed = try? await client.installedModels() else { return nil }
        // `ollama list` shows untagged models as "name:latest"; accept either spelling.
        let missing = requiredModels.filter { !installed.contains($0) && !installed.contains("\($0):latest") }
        guard !missing.isEmpty else { return nil }
        let commands = missing.map { "  ollama pull \($0)" }.joined(separator: "\n")
        return "Missing required Ollama model(s). Run:\n\(commands)"
    }

    private static func findOllamaBinary() -> String? {
        for path in ["/usr/local/bin/ollama", "/opt/homebrew/bin/ollama"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}
