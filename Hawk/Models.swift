import Foundation

// MARK: - 任意 JSON 值

/// 工具参数是模型自由生成的 JSON，用这个枚举承载，避免 `Any` 带来的并发与类型问题。
///
/// 刻意不走 `Codable` 的自动合成：Swift 的 `JSONDecoder` 在 Bool / Number 之间存在桥接歧义
/// （`true` 与 `1` 都可能被解成同一个 NSNumber），这里统一经 `JSONSerialization` 处理。
enum JSONValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: 解析

    static func parse(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return from(object)
    }

    static func from(_ any: Any) -> JSONValue {
        switch any {
        case is NSNull:
            return .null
        case let value as String:
            return .string(value)
        case let value as NSNumber:
            // 必须用 CFTypeID 区分，否则布尔值会被当成数字
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            return .number(value.doubleValue)
        case let value as [Any]:
            return .array(value.map(JSONValue.from))
        case let value as [String: Any]:
            return .object(value.mapValues(JSONValue.from))
        default:
            return .null
        }
    }

    // MARK: 访问

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .number(let value): return Int(value)
        case .string(let value): return Int(value)
        default: return nil
        }
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    // MARK: 输出

    /// 转回 `Any`，供 `JSONSerialization` 编码请求体使用。
    var anyValue: Any {
        switch self {
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .null: return NSNull()
        case .array(let value): return value.map(\.anyValue)
        case .object(let value): return value.mapValues(\.anyValue)
        }
    }

    /// 紧凑的单行 JSON，用于展示与回灌。
    var compactText: String {
        guard let data = try? JSONSerialization.data(withJSONObject: anyValue, options: [.sortedKeys, .fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    /// 展开的多行 JSON，用于详情面板。
    var prettyText: String {
        guard let data = try? JSONSerialization.data(withJSONObject: anyValue, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else {
            return compactText
        }
        return text
    }
}

// MARK: - 工具调用方言

/// 本地模型分两类，必须用不同「方言」回灌历史，否则模型会退化甚至返回空响应。
enum ToolDialect: String, CaseIterable, Sendable, Identifiable {
    case auto
    case native
    case text

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "自动识别"
        case .native: return "结构化 (native)"
        case .text: return "纯文本 (text)"
        }
    }

    var explanation: String {
        switch self {
        case .auto:
            return "按模型每轮的实际返回自动选择方言，兼容性最好。"
        case .native:
            return "模型返回结构化 tool_calls，用 role=tool 回灌。绝大多数新模型属于这类。"
        case .text:
            return "模型把调用写成 JSON 文本，保留 assistant 原文并用 role=user 回灌结果。"
        }
    }
}

// MARK: - 工具定义

enum AgentTool: String, CaseIterable, Sendable, Identifiable {
    case listDir = "list_dir"
    case readFile = "read_file"
    case editFile = "edit_file"
    case writeFile = "write_file"
    case search = "search"
    case runCommand = "run_cmd"

    var id: String { rawValue }

    /// 会改变磁盘状态的工具，需要走审批与 diff 预览。
    var isMutating: Bool {
        switch self {
        case .writeFile, .editFile, .runCommand: return true
        case .listDir, .readFile, .search: return false
        }
    }

    var displayName: String {
        switch self {
        case .listDir: return "列目录"
        case .readFile: return "读文件"
        case .editFile: return "改动代码"
        case .writeFile: return "写入文件"
        case .search: return "搜索"
        case .runCommand: return "执行命令"
        }
    }

    var symbolName: String {
        switch self {
        case .listDir: return "folder"
        case .readFile: return "doc.text"
        case .editFile: return "pencil.and.outline"
        case .writeFile: return "square.and.arrow.down"
        case .search: return "magnifyingglass"
        case .runCommand: return "terminal"
        }
    }
}

/// 一次工具调用（模型发起）。
struct ToolInvocation: Identifiable, Equatable, Sendable {
    var id: String
    var tool: AgentTool
    var arguments: JSONValue

    var argumentsText: String { arguments.compactText }

    /// 一行摘要，给卡片标题用。
    var summary: String {
        switch tool {
        case .readFile, .writeFile, .editFile:
            return arguments["path"]?.stringValue ?? ""
        case .listDir:
            return arguments["path"]?.stringValue ?? "."
        case .search:
            return arguments["pattern"]?.stringValue ?? ""
        case .runCommand:
            return arguments["command"]?.stringValue ?? ""
        }
    }
}

/// 一次工具调用的执行记录（用于展示）。
struct ToolRun: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case running
        case waitingApproval
        case succeeded
        case failed
        case denied

        var label: String {
            switch self {
            case .running: return "执行中"
            case .waitingApproval: return "等待确认"
            case .succeeded: return "完成"
            case .failed: return "失败"
            case .denied: return "被拒绝"
            }
        }

        var symbolName: String {
            switch self {
            case .running: return "arrow.triangle.2.circlepath"
            case .waitingApproval: return "hand.raised"
            case .succeeded: return "checkmark.circle.fill"
            case .failed: return "xmark.octagon.fill"
            case .denied: return "shield.lefthalf.filled"
            }
        }
    }

    var id: UUID = UUID()
    var tool: AgentTool
    var argumentsText: String
    var summary: String
    var status: Status = .running
    var output: String = ""
    var change: FileChange?
}

/// 一次文件改动的前后对照，用于 diff 预览。
struct FileChange: Equatable, Sendable {
    var path: String
    var before: String
    var after: String
    var isNewFile: Bool

    /// 简单的逐行变更统计，给卡片显示 +n / -n。
    var addedLines: Int { diffLines.filter { $0.kind == .inserted }.count }
    var removedLines: Int { diffLines.filter { $0.kind == .removed }.count }

    var diffLines: [DiffLine] { DiffEngine.lines(before: before, after: after) }
}

struct DiffLine: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case context, inserted, removed }
    let id = UUID()
    var kind: Kind
    var text: String
    var oldNumber: Int?
    var newNumber: Int?
}

// MARK: - 对话记录

/// 发给模型的 assistant 侧工具调用。
struct ToolCallRecord: Equatable, Sendable {
    var id: String
    var name: String
    var argumentsJSON: String
}

/// 一条会话消息，既用于展示也用于构造请求体。
struct ChatMessage: Equatable, Sendable {
    var role: String
    var content: String
    var toolCalls: [ToolCallRecord] = []
    var toolCallID: String?

    static func system(_ text: String) -> ChatMessage { ChatMessage(role: "system", content: text) }
    static func user(_ text: String) -> ChatMessage { ChatMessage(role: "user", content: text) }
    static func assistant(_ text: String, toolCalls: [ToolCallRecord] = []) -> ChatMessage {
        ChatMessage(role: "assistant", content: text, toolCalls: toolCalls)
    }
    static func toolResult(_ text: String, callID: String) -> ChatMessage {
        ChatMessage(role: "tool", content: text, toolCallID: callID)
    }

    var wireValue: [String: Any] {
        var value: [String: Any] = ["role": role, "content": content]
        if !toolCalls.isEmpty {
            value["tool_calls"] = toolCalls.map { call -> [String: Any] in
                [
                    "id": call.id,
                    "type": "function",
                    "function": ["name": call.name, "arguments": call.argumentsJSON],
                ]
            }
        }
        if let toolCallID {
            value["tool_call_id"] = toolCallID
        }
        return value
    }
}

// MARK: - 展示用转录

/// 界面上的一行记录。
struct TranscriptItem: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case user(String)
        case assistant(String)
        case thinking(String)
        case tool(ToolRun)
        case notice(String)
        case error(String)
        case summary(String)
    }

    var id = UUID()
    var kind: Kind

    static func user(_ text: String) -> TranscriptItem { TranscriptItem(kind: .user(text)) }
    static func assistant(_ text: String) -> TranscriptItem { TranscriptItem(kind: .assistant(text)) }
    static func notice(_ text: String) -> TranscriptItem { TranscriptItem(kind: .notice(text)) }
    static func error(_ text: String) -> TranscriptItem { TranscriptItem(kind: .error(text)) }
    static func summary(_ text: String) -> TranscriptItem { TranscriptItem(kind: .summary(text)) }
    static func tool(_ run: ToolRun) -> TranscriptItem { TranscriptItem(kind: .tool(run)) }
}

// MARK: - Agent 事件

/// Agent 主循环向外抛出的事件流。
enum AgentEvent: Sendable {
    case stepStarted(index: Int, total: Int)
    case assistantDelta(String)
    case assistantMessage(String)
    case notice(String)
    case toolStarted(ToolRun)
    case toolFinished(runID: UUID, output: String, status: ToolRun.Status, change: FileChange?)
    case finished(String)
    case failed(String)
}

/// 工具执行结果。
struct ToolExecutionResult: Sendable {
    var output: String
    var status: ToolRun.Status
    var change: FileChange?

    static func ok(_ output: String, change: FileChange? = nil) -> ToolExecutionResult {
        ToolExecutionResult(output: output, status: .succeeded, change: change)
    }

    static let denied = ToolExecutionResult(output: "", status: .denied, change: nil)

    static func failure(_ output: String) -> ToolExecutionResult {
        ToolExecutionResult(output: output, status: .failed, change: nil)
    }
}

/// 一次运行用到的全部参数快照（不可变，可安全跨线程传递）。
struct AgentRunConfig: Sendable {
    var workspacePath: String
    var dialect: ToolDialect = .auto
    var maxSteps: Int = 25
    var temperature: Double = 0.1
    var timeout: TimeInterval = 300
    var allowWrite: Bool = true
    var requireApproval: Bool = true
    var extraAllowedCommands: [String] = []
    var extraDangerousPatterns: [String] = []
}

// MARK: - 推理服务预设

struct ProviderPreset: Identifiable, Sendable, Hashable {
    var id: String
    var name: String
    var baseURL: String
    var apiKey: String

    static let all: [ProviderPreset] = [
        ProviderPreset(id: "ollama", name: "Ollama", baseURL: "http://localhost:11434/v1", apiKey: "ollama"),
        ProviderPreset(id: "lmstudio", name: "LM Studio", baseURL: "http://localhost:1234/v1", apiKey: "lm-studio"),
        ProviderPreset(id: "llamacpp", name: "llama.cpp", baseURL: "http://localhost:8080/v1", apiKey: "none"),
        ProviderPreset(id: "vllm", name: "vLLM", baseURL: "http://localhost:8000/v1", apiKey: "none"),
        ProviderPreset(id: "custom", name: "自定义 / 云端", baseURL: "http://localhost:11434/v1", apiKey: "none"),
    ]

    static func preset(for id: String) -> ProviderPreset {
        all.first { $0.id == id } ?? all[4]
    }
}

// MARK: - 错误

enum AgentError: LocalizedError {
    case missingWorkspace
    case badURL(String)
    case http(status: Int, body: String)
    case transport(String)
    case emptyResponse
    case maxStepsReached(Int)

    var errorDescription: String? {
        switch self {
        case .missingWorkspace:
            return "还没有选择工作区文件夹"
        case .badURL(let url):
            return "服务地址无效：\(url)"
        case .http(let status, let body):
            return "模型服务返回 HTTP \(status)：\(body)"
        case .transport(let message):
            return "无法连接模型服务：\(message)"
        case .emptyResponse:
            return "模型连续返回空响应"
        case .maxStepsReached(let steps):
            return "已达到最大步数 \(steps)，任务中止"
        }
    }
}
