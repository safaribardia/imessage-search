import Foundation

/// Drives OpenAI's GPT through the locally installed Codex CLI (the user's
/// ChatGPT subscription). GPT researches the message archive by shelling out
/// to the bundled `msgtool` helper, and its research steps stream back as
/// agent activities.
enum CodexAgentError: LocalizedError {
    case notInstalled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Codex CLI is not installed or not signed in."
        case .failed(let detail):
            return "Codex failed: \(detail)"
        }
    }
}

struct CodexAccount: Sendable {
    let email: String?
    let plan: String?

    var planDisplayName: String? {
        guard let plan, !plan.isEmpty else {
            return nil
        }
        return "ChatGPT \(plan.capitalized)"
    }
}

struct CodexAgent: Sendable {
    let binary: URL

    /// Signed-in ChatGPT account details, read from Codex's local
    /// credentials (the id_token JWT payload). Nothing leaves the machine.
    static let account: CodexAccount? = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String else {
            return nil
        }
        let segments = idToken.split(separator: ".")
        guard segments.count >= 2 else {
            return nil
        }
        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 {
            payload.append("=")
        }
        guard let payloadData = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: payloadData)
                as? [String: Any] else {
            return nil
        }
        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        let account = CodexAccount(
            email: claims["email"] as? String,
            plan: auth?["chatgpt_plan_type"] as? String
        )
        guard account.email != nil || account.plan != nil else {
            return nil
        }
        return account
    }()

    /// Resolved once per process: the app inherits a minimal PATH when
    /// launched from Finder, so ask a login shell where codex lives.
    private static let resolved: CodexAgent? = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let auth = home.appendingPathComponent(".codex/auth.json")
        guard FileManager.default.fileExists(atPath: auth.path) else {
            return nil
        }

        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-l", "-c", "command -v codex"]
        let pipe = Pipe()
        shell.standardOutput = pipe
        shell.standardError = FileHandle.nullDevice
        guard (try? shell.run()) != nil else {
            return nil
        }
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        shell.waitUntilExit()
        guard !output.isEmpty,
              FileManager.default.isExecutableFile(atPath: output) else {
            return nil
        }
        return CodexAgent(binary: URL(fileURLWithPath: output))
    }()

    /// Available only when the CLI exists and has ChatGPT credentials.
    static func locate() -> CodexAgent? {
        resolved
    }

    /// Runs one research turn, returning the final assistant message and the
    /// activity rows generated along the way. Intermediate events are also
    /// reported live through `onActivity`.
    func run(
        prompt: String,
        environment: [String: String],
        onActivity: @Sendable (AgentActivity) async -> Void
    ) async throws -> (message: String, activities: [AgentActivity]) {
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-answer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: workDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: workDirectory)
        }

        // Captured by the @Sendable cancellation handler purely to terminate.
        nonisolated(unsafe) let process = Process()
        process.executableURL = binary
        process.arguments = [
            "exec",
            "--json",
            "--skip-git-repo-check",
            // Full access so msgtool can read the index database and reach
            // the local Ollama server for query embeddings.
            "--sandbox", "danger-full-access",
            "-C", workDirectory.path,
            prompt,
        ]
        var mergedEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            mergedEnvironment[key] = value
        }
        // npm-installed codex is a Node shim; make sure its sibling `node`
        // binary is findable even when the app was launched from Finder.
        let binaryDirectory = binary.deletingLastPathComponent().path
        let path = mergedEnvironment["PATH"] ?? "/usr/bin:/bin"
        mergedEnvironment["PATH"] = "\(binaryDirectory):\(path)"
        process.environment = mergedEnvironment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        return try await withTaskCancellationHandler {
            var finalMessage = ""
            var activities: [AgentActivity] = []
            for try await line in stdout.fileHandleForReading.bytes.lines {
                try Task.checkCancellation()
                guard let event = try? JSONDecoder().decode(
                    CodexEvent.self,
                    from: Data(line.utf8)
                ) else {
                    continue
                }
                if let activity = Self.activity(for: event) {
                    activities.append(activity)
                    await onActivity(activity)
                }
                if event.type == "item.completed",
                   let item = event.item,
                   item.type == "agent_message",
                   let text = item.text {
                    finalMessage = text
                }
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0, !finalMessage.isEmpty else {
                let detail = String(
                    data: stderr.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                throw CodexAgentError.failed(
                    String(detail.suffix(300))
                )
            }
            return (finalMessage, activities)
        } onCancel: {
            process.terminate()
        }
    }

    /// Maps a Codex stream event to a human-readable activity row, mirroring
    /// the local agent's trace vocabulary.
    private static func activity(for event: CodexEvent) -> AgentActivity? {
        guard event.type == "item.started" || event.type == "item.completed",
              let item = event.item else {
            return nil
        }
        switch item.type {
        case "command_execution":
            guard event.type == "item.started", let command = item.command else {
                return nil
            }
            let (title, detail) = describe(command: command)
            return AgentActivity(
                id: UUID().uuidString,
                toolName: "codex_command",
                title: title,
                detail: detail,
                resultCount: nil,
                createdAt: Date()
            )
        case "agent_message":
            // Intermediate narration ("Let me check the group chat…") makes a
            // nice trace row; the final message is the answer, and it is
            // filtered out by the caller replacing the trace with the answer.
            return nil
        default:
            return nil
        }
    }

    private static func describe(command: String) -> (String, String) {
        guard let range = command.range(of: "msgtool") else {
            return ("Ran a command", String(command.prefix(80)))
        }
        // The helper path is usually shell-quoted, so strip the closing
        // quote and whitespace between the path and the tool name.
        var invocation = String(command[range.upperBound...])
        while let first = invocation.first,
              first == "'" || first == "\"" || first == " " {
            invocation.removeFirst()
        }
        let tool = invocation.prefix(while: { !$0.isWhitespace })
        let quoted = firstQuotedValue(in: invocation)
        switch tool {
        case "search_messages":
            return (quoted.map { "Searched “\($0)”" } ?? "Searched messages", "")
        case "grep_messages":
            return (quoted.map { "Scanned for “\($0)”" } ?? "Scanned messages", "")
        case "recent_messages":
            return ("Read the latest messages", "")
        case "get_conversation_context":
            return ("Read the surrounding conversation", "")
        default:
            return ("Ran a command", String(command.prefix(80)))
        }
    }

    private static func firstQuotedValue(in invocation: String) -> String? {
        for delimiter: Character in ["\"", "'"] {
            let parts = invocation.split(separator: delimiter)
            if parts.count >= 2 {
                // Shell-escaped quotes leave a trailing backslash behind.
                var value = String(parts[1])
                while value.hasSuffix("\\") {
                    value.removeLast()
                }
                if !value.isEmpty, value.count < 80 {
                    return value
                }
            }
        }
        return nil
    }
}

private struct CodexEvent: Decodable {
    let type: String
    let item: CodexItem?
}

private struct CodexItem: Decodable {
    let type: String
    let command: String?
    let text: String?
}
