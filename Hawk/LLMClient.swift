import Foundation

/// 流式增量。
enum StreamDelta: Sendable {
    case text(String)
    case toolCall(index: Int, id: String?, name: String?, argumentsFragment: String?)
}

/// 任意 OpenAI 兼容服务的客户端。
///
/// 只依赖 `/v1/chat/completions` 与 `/v1/models` 两个事实标准接口，
/// 因此换 Ollama / LM Studio / llama.cpp / vLLM / 云端 API 都只是改一个地址。
struct LLMClient: Sendable {
    var baseURL: String
    var apiKey: String
    var model: String
    var timeout: TimeInterval = 300
    var temperature: Double = 0.1

    private var normalizedBase: String {
        var text = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    // MARK: - 模型列表

    func listModels() async throws -> [String] {
        guard let url = URL(string: normalizedBase + "/models") else {
            throw AgentError.badURL(baseURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = min(timeout, 20)
        authorize(&request)

        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw AgentError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        if let entries = root["data"] as? [[String: Any]] {
            return entries.compactMap { $0["id"] as? String }.sorted()
        }
        // 少数服务用 models[].name
        if let entries = root["models"] as? [[String: Any]] {
            return entries.compactMap { $0["name"] as? String ?? $0["id"] as? String }.sorted()
        }
        return []
    }

    // MARK: - 流式对话

    func streamChat(messages: [ChatMessage], tools: [[String: Any]]?) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await performStream(messages: messages, tools: tools, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func performStream(
        messages: [ChatMessage],
        tools: [[String: Any]]?,
        continuation: AsyncThrowingStream<StreamDelta, Error>.Continuation
    ) async throws {
        guard let url = URL(string: normalizedBase + "/chat/completions") else {
            throw AgentError.badURL(baseURL)
        }

        var body: [String: Any] = [
            "model": model,
            "messages": messages.map(\.wireValue),
            "temperature": temperature,
            "stream": true,
        ]
        if let tools, !tools.isEmpty {
            body["tools"] = tools
            body["tool_choice"] = "auto"
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        authorize(&request)

        let (bytes, response) = try await openStream(request)

        guard let http = response as? HTTPURLResponse else {
            throw AgentError.transport("响应不是 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            var text = ""
            for try await line in bytes.lines {
                text += line
                if text.count > 800 { break }
            }
            throw AgentError.http(status: http.statusCode, body: text)
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }

            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty { continue }
            if payload == "[DONE]" { break }

            guard let data = payload.data(using: .utf8),
                  let envelope = try? JSONDecoder().decode(ChunkEnvelope.self, from: data),
                  let delta = envelope.choices?.first?.delta else {
                continue
            }

            if let content = delta.content, !content.isEmpty {
                continuation.yield(.text(content))
            }

            for call in delta.toolCalls ?? [] {
                continuation.yield(
                    .toolCall(
                        index: call.index ?? 0,
                        id: call.id,
                        name: call.function?.name,
                        argumentsFragment: call.function?.arguments
                    )
                )
            }
        }
    }

    // MARK: - 底层

    private func authorize(_ request: inout URLRequest) {
        guard !apiKey.isEmpty else { return }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            throw AgentError.transport(error.localizedDescription)
        }
    }

    /// 单独抽出来是为了把连接阶段的 URLError 统一翻译成可读提示。
    private func openStream(_ request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        do {
            return try await URLSession.shared.bytes(for: request)
        } catch let error as URLError {
            throw AgentError.transport(error.localizedDescription)
        }
    }
}

// MARK: - SSE 报文

private struct ChunkEnvelope: Decodable {
    struct Choice: Decodable {
        let delta: Delta?
    }

    struct Delta: Decodable {
        let content: String?
        let toolCalls: [ToolCallDelta]?

        enum CodingKeys: String, CodingKey {
            case content
            case toolCalls = "tool_calls"
        }
    }

    struct ToolCallDelta: Decodable {
        let index: Int?
        let id: String?
        let function: FunctionDelta?
    }

    struct FunctionDelta: Decodable {
        let name: String?
        let arguments: String?
    }

    let choices: [Choice]?
}
