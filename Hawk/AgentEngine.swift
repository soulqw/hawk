import Foundation

/// Agent 主循环。
///
/// 每轮四步：
///     1. 把 任务 + 历史消息 + 工具清单 发给模型
///     2. 模型要么直接回话（结束），要么发起工具调用
///     3. 本地执行工具，把结果回灌
///     4. 压缩上下文，回到第 1 步
struct AgentEngine: Sendable {
    static let maxToolOutput = 6000
    static let maxEmptyRetries = 3
    /// 同一个工具调用累计重复这么多次，就认为模型卡住了，强制进入总结。
    static let maxRepeatCalls = 3
    /// 文本方言下，工具结果以 user 消息回灌，用这个前缀标记以便压缩时识别。
    static let resultPrefix = "[工具结果] "

    static let finishPrompt = """
    任务已经完成。请不要再调用任何工具，直接用中文给出简短总结：你做了哪些修改、验证结果如何。只输出总结文字。
    """

    static let systemPrompt = """
    你是一个在本地运行的编码代理（coding agent），通过调用工具来修改代码。

    可用工具：list_dir、read_file、edit_file、write_file、search、run_cmd。

    调用工具时，只输出一行 JSON，不要有多余文字，例如：
    {"name": "read_file", "arguments": {"path": "calc.py"}}

    工作方式要求：
    1. 先观察再动手：第一步用 list_dir 了解项目结构，不要凭空猜测文件内容。
    2. 改文件前必须先 read_file 看到原文，edit_file 的 old_string 必须与原文逐字符一致。
    3. 一次只做一件小事，做完立刻用 run_cmd 验证（例如 python3 test_calc.py）。
    4. 如果工具返回 ERROR 或 DENIED，不要重复同样的调用，要根据错误信息调整做法。若是目录权限不足，客户端会申请权限并自动继续当前步骤。
    5. 如果用户明确给出了文件路径、文件名或目标目录，必须严格使用该路径/名称，不要自行改名，也不要省略路径。
    6. 如果用户给的是目录，创建或修改文件时要把文件放进那个目录里；不要因为 workspace 可写就回退写到 workspace 根目录。
    7. 全部完成后再用自然语言给出简短总结，不要提前宣称完成。

    约束：
    - 所有文件操作都被限制在当前 workspace 目录内，越界会被拒绝。
    - 用户额外授权的附件文件/目录可以直接用绝对路径访问；未授权的绝对路径不能碰。若工具碰到未授权目录，客户端会申请该目录权限后续跑。
    - run_cmd 只执行单条命令。默认已在 workspace 根目录运行，不要写 `cd xxx && ...`；只有确实要切到子目录时，才允许这种单次切目录形式，不能再叠加别的命令拼接。
    - 只能执行白名单内的命令，不支持管道与重定向。
    - 总结里必须写出实际创建/修改的文件路径；如果写入失败，要明确说明失败原因。
    - 用中文回复。
    """

    let client: LLMClient
    let tools: AgentTools
    let config: AgentRunConfig

    /// 执行一次工具调用。由界面层注入，以便在真正落盘前插入「人工确认」。
    typealias Executor = @Sendable (ToolInvocation, UUID) async -> ToolExecutionResult

    func run(
        task: String,
        history: [ChatMessage] = [],
        bootstrap: String = "",
        executor: @escaping Executor
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream<AgentEvent, Error> { continuation in
            let work = Task {
                do {
                    try await loop(
                        task: task,
                        history: history,
                        bootstrap: bootstrap,
                        executor: executor,
                        emit: { continuation.yield($0) }
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.yield(.failed(error.localizedDescription))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    // MARK: - 主循环

    private func loop(
        task: String,
        history: [ChatMessage],
        bootstrap: String,
        executor: @escaping Executor,
        emit: @escaping @Sendable (AgentEvent) -> Void
    ) async throws {
        // 消息顺序：系统提示词 → 本次会话装载（记忆 / 技能） → 历史轮次 → 本轮提问。
        // 装载块单独作为一条 system 消息，压缩阶段不会破坏它，也不会占用 tool_call 配对。
        var messages: [ChatMessage] = [.system(Self.systemPrompt)]
        if !bootstrap.isEmpty {
            messages.append(.system(bootstrap))
        }
        messages += history
        messages.append(.user(task))
        var emptyRetries = 0
        var repeatCounts: [String: Int] = [:]

        for step in 1...max(1, config.maxSteps) {
            try Task.checkCancellation()
            emit(.stepStarted(index: step, total: config.maxSteps))

            let reply = try await requestModel(messages: messages, emit: emit)

            let pending = resolveCalls(from: reply)

            // 没有工具调用：要么正常收尾，要么是空响应（本地模型常见退化）
            guard !pending.isEmpty else {
                if !reply.text.isEmpty {
                    emit(.finished(reply.text))
                    return
                }

                emptyRetries += 1
                guard emptyRetries <= Self.maxEmptyRetries else {
                    throw AgentError.emptyResponse
                }
                emit(.notice("模型返回空响应，第 \(emptyRetries) 次重试"))
                messages.append(.user("你的上一条回复为空。请继续推进任务：输出工具调用，或给出最终总结。"))
                continue
            }

            emptyRetries = 0

            // 循环检测：本地小模型常常反复调用同一个工具却不肯收尾
            let signature = pending.map { "\($0.name)#\($0.argumentsText)" }.joined(separator: "&&")
            repeatCounts[signature, default: 0] += 1
            if repeatCounts[signature, default: 0] >= Self.maxRepeatCalls {
                try await forceFinish(messages: messages, emit: emit)
                return
            }

            if reply.usedNativeToolCalls {
                messages.append(
                    .assistant(reply.text, toolCalls: pending.compactMap(\.record))
                )
            } else {
                // 文本方言：保留模型自己的原文，不引入它不认识的 tool_calls 字段
                messages.append(.assistant(reply.text))
            }

            var textResults: [String] = []

            for call in pending {
                try Task.checkCancellation()

                guard let tool = call.tool else {
                    let message = "ERROR: 未知工具 \(call.name)（可用：\(tools.validToolNames.sorted().joined(separator: ", "))）"
                    emit(.notice(message))
                    if reply.usedNativeToolCalls {
                        messages.append(.toolResult(message, callID: call.callID))
                    } else {
                        textResults.append("\(Self.resultPrefix)\(call.name) 的执行结果：\n\(message)")
                    }
                    continue
                }

                var run = ToolRun(
                    tool: tool,
                    argumentsText: call.argumentsText,
                    summary: call.arguments?.objectValue.map { object in
                        ToolInvocation(id: call.callID, tool: tool, arguments: .object(object)).summary
                    } ?? ""
                )

                guard let arguments = call.arguments else {
                    let message = "ERROR: 工具参数不是合法 JSON，请重新生成。"
                    run.status = .failed
                    run.output = message
                    emit(.toolStarted(run))
                    emit(.toolFinished(runID: run.id, output: message, status: .failed, change: nil))
                    if reply.usedNativeToolCalls {
                        messages.append(.toolResult(message, callID: call.callID))
                    } else {
                        textResults.append("\(Self.resultPrefix)\(tool.rawValue) 的执行结果：\n\(message)")
                    }
                    continue
                }

                let invocation = ToolInvocation(id: call.callID, tool: tool, arguments: arguments)
                emit(.toolStarted(run))

                let result = await executor(invocation, run.id)

                emit(.toolFinished(runID: run.id, output: result.output, status: result.status, change: result.change))

                if reply.usedNativeToolCalls {
                    messages.append(.toolResult(String(result.output.prefix(Self.maxToolOutput)), callID: call.callID))
                } else {
                    let header = "\(Self.resultPrefix)\(tool.rawValue)(\(call.argumentsText)) 的执行结果：\n"
                    textResults.append(header + result.output)
                }
            }

            if !reply.usedNativeToolCalls, !textResults.isEmpty {
                let joined = textResults.joined(separator: "\n\n")
                messages.append(.user(String(joined.prefix(Self.maxToolOutput)) + "\n\n请继续下一步。"))
            }

            compact(&messages)
        }

        throw AgentError.maxStepsReached(config.maxSteps)
    }

    // MARK: - 与模型交互

    /// 从这一轮的回复里取出真正要执行的调用。
    ///
    /// native 方言用结构化调用；文本方言用兜底解析出来的调用。两者都由 `requestModel` 判定过，
    /// 这里只负责按方言挑选，避免把两种来源混在一起重复执行。
    private func resolveCalls(from reply: ModelReply) -> [PendingCall] {
        reply.usedNativeToolCalls ? reply.toolCalls : reply.recovered
    }

    private struct ModelReply: Sendable {
        var text: String
        var toolCalls: [PendingCall]
        var recovered: [PendingCall]
        var usedNativeToolCalls: Bool
    }

    private func requestModel(
        messages: [ChatMessage],
        emit: @escaping @Sendable (AgentEvent) -> Void
    ) async throws -> ModelReply {
        var text = ""
        var accumulators: [Int: Accumulator] = [:]
        var announcedStreaming = false

        for try await delta in client.streamChat(messages: messages, tools: AgentTools.schemas) {
            try Task.checkCancellation()

            switch delta {
            case .text(let chunk):
                text += chunk
                if !announcedStreaming {
                    announcedStreaming = true
                }
                emit(.assistantDelta(chunk))

            case .toolCall(let index, let id, let name, let fragment):
                var accumulator = accumulators[index] ?? Accumulator()
                if let id, !id.isEmpty { accumulator.id = id }
                // OpenAI 只在第一个分片里给出完整函数名，后续分片为 null
                if let name, !name.isEmpty, accumulator.name == nil { accumulator.name = name }
                if let fragment { accumulator.arguments += fragment }
                accumulators[index] = accumulator
            }
        }

        let native = accumulators.keys.sorted().compactMap { key -> PendingCall? in
            guard let accumulator = accumulators[key], let name = accumulator.name else { return nil }
            return PendingCall(
                name: name,
                tool: AgentTool(rawValue: name),
                arguments: accumulationArguments(accumulator.arguments),
                argumentsText: accumulator.arguments,
                callID: accumulator.id ?? "call_\(key)"
            )
        }

        var recovered: [PendingCall] = []
        if native.isEmpty, !text.isEmpty {
            recovered = ToolCallRecovery
                .extract(from: text, validTools: tools.validToolNames)
                .enumerated()
                .map { index, item in
                    PendingCall(
                        name: item.tool.rawValue,
                        tool: item.tool,
                        arguments: item.arguments,
                        argumentsText: item.arguments.compactText,
                        callID: "call_\(index)"
                    )
                }
        }

        let resolved = pickDialect(
            hasNative: !native.isEmpty,
            hasRecovered: !recovered.isEmpty,
            emit: emit
        )

        let calls = resolved.dialect == .native ? native : recovered

        return ModelReply(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            toolCalls: native,
            recovered: recovered,
            usedNativeToolCalls: resolved.dialect == .native && !calls.isEmpty
        )
    }

    /// 累积的参数文本可能为空（模型没给参数），此时按空对象处理。
    private func accumulationArguments(_ text: String) -> JSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .object([:]) }
        guard let value = JSONValue.parse(trimmed), case .object = value else { return nil }
        return value
    }

    private struct Accumulator {
        var id: String?
        var name: String?
        var arguments = ""
    }

    /// 决定这一轮用哪种方言回灌。
    @discardableResult
    private func pickDialect(
        hasNative: Bool,
        hasRecovered: Bool,
        emit: @escaping @Sendable (AgentEvent) -> Void
    ) -> (dialect: ToolDialect, notified: Bool) {
        switch config.dialect {
        case .text:
            if hasRecovered { return (.text, true) }
            if hasNative {
                emit(.notice("方言设为纯文本，但模型返回了结构化调用，已按 native 处理"))
                return (.native, true)
            }
        case .native:
            if hasNative { return (.native, true) }
            if hasRecovered {
                emit(.notice("方言设为 native，但模型以文本描述调用，已按 text 处理"))
                return (.text, true)
            }
        case .auto:
            if hasNative { return (.native, true) }
            if hasRecovered {
                emit(.notice("模型以文本描述调用，已解析出调用"))
                return (.text, true)
            }
        }
        return (.auto, false)
    }

    /// 禁用工具，强制模型给出文本总结，保证循环一定能终止。
    private func forceFinish(
        messages: [ChatMessage],
        emit: @escaping @Sendable (AgentEvent) -> Void
    ) async throws {
        emit(.notice("检测到重复调用，强制进入总结模式"))

        var summary = ""
        for try await delta in client.streamChat(
            messages: messages + [.user(Self.finishPrompt)],
            tools: nil
        ) {
            if case .text(let chunk) = delta { summary += chunk }
        }

        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        emit(.finished(trimmed.isEmpty ? "(模型未返回总结)" : trimmed))
    }

    // MARK: - 上下文压缩

    /// 把较早的工具输出替换成占位符，避免上下文被历史输出撑爆。
    ///
    /// 只替换 content、不动消息结构，因此不会破坏 tool_call_id 的配对关系。
    private func compact(_ messages: inout [ChatMessage], keepRecent: Int = 10) {
        guard messages.count > keepRecent + 2 else { return }

        let cutoff = messages.count - keepRecent
        // 从 1 开始：保留 system 提示词，其余（含历史轮次）都允许被裁剪。
        for index in 1..<cutoff {
            let text = messages[index].content
            guard text.count > 120 else { continue }

            if messages[index].role == "tool" {
                messages[index].content = "[较早的工具输出已省略]"
            } else if messages[index].role == "user", text.hasPrefix(Self.resultPrefix) {
                messages[index].content = Self.resultPrefix + "较早的输出已省略]"
            }
        }
    }
}

// MARK: - 待执行的调用

struct PendingCall: Sendable {
    var name: String
    var tool: AgentTool?
    var arguments: JSONValue?
    var argumentsText: String
    var callID: String

    var record: ToolCallRecord? {
        guard let tool else { return nil }
        return ToolCallRecord(id: callID, name: tool.rawValue, argumentsJSON: argumentsText)
    }
}
