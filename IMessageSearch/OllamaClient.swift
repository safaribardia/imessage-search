import Foundation

enum OllamaError: LocalizedError {
    case unavailable
    case missingModels([String])
    case invalidResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Ollama is not running. Install Ollama and start it before building the index."
        case .missingModels(let models):
            "Missing Ollama models: \(models.joined(separator: ", "))."
        case .invalidResponse:
            "Ollama returned an invalid response."
        case .requestFailed(let message):
            "Ollama error: \(message)"
        }
    }
}

enum JSONValue: Codable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var stringValue: String? {
        guard case .string(let value) = self else {
            return nil
        }
        return value
    }

    var intValue: Int? {
        guard case .number(let value) = self,
              value.rounded() == value else {
            return nil
        }
        return Int(value)
    }
}

struct OllamaToolCall: Codable, Sendable {
    let function: OllamaToolFunctionCall
}

struct OllamaToolFunctionCall: Codable, Sendable {
    let name: String
    let arguments: [String: JSONValue]
}

struct OllamaToolDefinition: Encodable, Sendable {
    let type = "function"
    let function: OllamaFunctionDefinition
}

struct OllamaFunctionDefinition: Encodable, Sendable {
    let name: String
    let description: String
    let parameters: JSONValue
}

struct OllamaChatMessage: Codable, Sendable {
    let role: String
    let content: String
    let toolCalls: [OllamaToolCall]?
    let toolName: String?

    init(
        role: String,
        content: String,
        toolCalls: [OllamaToolCall]? = nil,
        toolName: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolName = toolName
    }

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
        case toolName = "tool_name"
    }
}

struct OllamaClient: Sendable {
    private let baseURL = URL(string: "http://127.0.0.1:11434")!

    func verify(modelNames requiredModels: [String]) async throws {
        let url = baseURL.appendingPathComponent("api/tags")
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                throw OllamaError.unavailable
            }

            let tags = try JSONDecoder().decode(TagsResponse.self, from: data)
            let available = Set(tags.models.flatMap { [$0.name, $0.model] })
            let missing = requiredModels.filter { !available.contains($0) }
            if !missing.isEmpty {
                throw OllamaError.missingModels(missing)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as OllamaError {
            throw error
        } catch {
            throw OllamaError.unavailable
        }
    }

    /// Downloads a model through Ollama's streaming pull API.
    func pull(
        modelName: String,
        onProgress: @Sendable (Double?, String) async -> Void
    ) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/pull"))
        request.httpMethod = "POST"
        request.timeoutInterval = 3_600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            PullRequest(model: modelName, stream: true)
        )

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                throw OllamaError.invalidResponse
            }

            var succeeded = false
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard !line.isEmpty,
                      let data = line.data(using: .utf8) else {
                    continue
                }
                let event = try JSONDecoder().decode(PullStatusEvent.self, from: data)
                if let error = event.error {
                    throw OllamaError.requestFailed(error)
                }
                let fraction: Double?
                if let total = event.total,
                   total > 0,
                   let completed = event.completed {
                    fraction = min(1, Double(completed) / Double(total))
                } else {
                    fraction = nil
                }
                await onProgress(fraction, event.status)
                if event.status == "success" {
                    succeeded = true
                }
            }
            guard succeeded else {
                throw OllamaError.invalidResponse
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as OllamaError {
            throw error
        } catch let error as URLError where error.code == .cannotConnectToHost {
            throw OllamaError.unavailable
        } catch {
            throw OllamaError.requestFailed(error.localizedDescription)
        }
    }

    func embed(_ input: [String], model: EmbeddingModel) async throws -> [[Float]] {
        guard !input.isEmpty else {
            return []
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("api/embed"))
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            EmbedRequest(model: model.rawValue, input: input)
        )

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw OllamaError.invalidResponse
            }
            guard httpResponse.statusCode == 200 else {
                let message = (try? JSONDecoder().decode(
                    ErrorResponse.self,
                    from: data
                ).error) ?? "HTTP \(httpResponse.statusCode)"
                throw OllamaError.requestFailed(message)
            }

            let result = try JSONDecoder().decode(EmbedResponse.self, from: data)
            guard result.embeddings.count == input.count else {
                throw OllamaError.invalidResponse
            }
            return result.embeddings
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as OllamaError {
            throw error
        } catch let error as URLError where error.code == .cannotConnectToHost {
            throw OllamaError.unavailable
        } catch {
            throw OllamaError.requestFailed(error.localizedDescription)
        }
    }

    func completeChat(
        messages: [OllamaChatMessage],
        model: String,
        json: Bool = false,
        maxTokens: Int? = nil
    ) async throws -> String {
        let request = try chatRequest(
            messages: messages,
            model: model,
            stream: false,
            format: json ? "json" : nil,
            maxTokens: maxTokens
        )
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response: response, data: data)
            let result = try JSONDecoder().decode(ChatChunk.self, from: data)
            guard let content = result.message?.content else {
                throw OllamaError.invalidResponse
            }
            return content
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as OllamaError {
            throw error
        } catch {
            throw OllamaError.requestFailed(error.localizedDescription)
        }
    }

    func agentTurn(
        messages: [OllamaChatMessage],
        model: String,
        tools: [OllamaToolDefinition]
    ) async throws -> OllamaChatMessage {
        let request = try chatRequest(
            messages: messages,
            model: model,
            stream: false,
            format: nil,
            tools: tools
        )
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response: response, data: data)
            let result = try JSONDecoder().decode(ChatChunk.self, from: data)
            guard let message = result.message else {
                throw OllamaError.invalidResponse
            }
            return message
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as OllamaError {
            throw error
        } catch {
            throw OllamaError.requestFailed(error.localizedDescription)
        }
    }

    func streamChat(
        messages: [OllamaChatMessage],
        model: String,
        onToken: @Sendable (String) async -> Void
    ) async throws -> String {
        let request = try chatRequest(
            messages: messages,
            model: model,
            stream: true,
            format: nil
        )
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                throw OllamaError.invalidResponse
            }

            var output = ""
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard !line.isEmpty,
                      let data = line.data(using: .utf8) else {
                    continue
                }
                let chunk = try JSONDecoder().decode(ChatChunk.self, from: data)
                if let error = chunk.error {
                    throw OllamaError.requestFailed(error)
                }
                if let content = chunk.message?.content, !content.isEmpty {
                    output += content
                    await onToken(content)
                }
            }
            return output
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as OllamaError {
            throw error
        } catch {
            throw OllamaError.requestFailed(error.localizedDescription)
        }
    }

    private func chatRequest(
        messages: [OllamaChatMessage],
        model: String,
        stream: Bool,
        format: String?,
        tools: [OllamaToolDefinition]? = nil,
        maxTokens: Int? = nil
    ) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // gpt-oss models always reason and reject `think: false`; medium
        // effort balances research diligence against latency.
        let think: JSONValue = model.hasPrefix("gpt-oss")
            ? .string("medium")
            : .bool(false)
        request.httpBody = try JSONEncoder().encode(
            ChatRequest(
                model: model,
                messages: messages,
                stream: stream,
                think: think,
                keepAlive: "15m",
                format: format,
                options: ChatOptions(temperature: 0, numPredict: maxTokens),
                tools: tools
            )
        )
        return request
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            let message = (try? JSONDecoder().decode(
                ErrorResponse.self,
                from: data
            ).error) ?? "HTTP \(httpResponse.statusCode)"
            throw OllamaError.requestFailed(message)
        }
    }
}

private struct EmbedRequest: Encodable {
    let model: String
    let input: [String]
}

private struct PullRequest: Encodable {
    let model: String
    let stream: Bool
}

private struct PullStatusEvent: Decodable {
    let status: String
    let digest: String?
    let total: Int64?
    let completed: Int64?
    let error: String?
}

private struct EmbedResponse: Decodable {
    let embeddings: [[Float]]
}

private struct ChatRequest: Encodable {
    let model: String
    let messages: [OllamaChatMessage]
    let stream: Bool
    let think: JSONValue
    let keepAlive: String
    let format: String?
    let options: ChatOptions
    let tools: [OllamaToolDefinition]?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case stream
        case think
        case keepAlive = "keep_alive"
        case format
        case options
        case tools
    }
}

private struct ChatOptions: Encodable {
    let temperature: Double
    let numPredict: Int?

    enum CodingKeys: String, CodingKey {
        case temperature
        case numPredict = "num_predict"
    }
}

private struct ChatChunk: Decodable {
    let message: OllamaChatMessage?
    let error: String?
}

private struct TagsResponse: Decodable {
    let models: [OllamaModel]
}

private struct OllamaModel: Decodable {
    let name: String
    let model: String
}

private struct ErrorResponse: Decodable {
    let error: String
}
