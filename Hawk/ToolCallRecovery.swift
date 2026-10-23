import Foundation

/// 工具调用解析兜底。
///
/// 背景：本地模型经常不产生结构化 `tool_calls`，而是把调用写成纯文本：
///
///     {"name": "list_dir", "arguments": {"path": "."}}
///     ```json
///     {"name": "read_file", "arguments": {"path": "calc.py"}}
///     ```
///     <tool_call>{"name": "run_cmd", "arguments": {"command": "ls"}}</tool_call>
///     list_dir(path=".")
///
/// 这层解析器把这些退化输出还原成标准工具调用，让主循环不必依赖模型是否「听话」。
/// 这也是真实本地 agent 项目普遍采用的策略：不指望模型守规矩，而是自己容错。
enum ToolCallRecovery {
    struct Recovered: Equatable, Sendable {
        var tool: AgentTool
        var arguments: JSONValue
    }

    private static let nameKeys = ["name", "tool", "tool_name", "function"]
    private static let argumentKeys = ["arguments", "parameters", "args", "input", "params"]

    static func extract(from content: String, validTools: Set<String>) -> [Recovered] {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        // 1) 优先看代码围栏里的内容，模型很爱把调用包在 ```json 里
        for block in fencedBlocks(in: text) {
            let calls = scan(block, validTools: validTools)
            if !calls.isEmpty { return calls }
        }

        // 2) 再扫全文
        let calls = scan(text, validTools: validTools)
        if !calls.isEmpty { return calls }

        // 3) 最后尝试 `tool_name(key=value)` 这种函数调用写法
        return keywordCalls(in: text, validTools: validTools)
    }

    // MARK: - 花括号配平扫描

    private static func scan(_ text: String, validTools: Set<String>) -> [Recovered] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 整段就是一个 JSON 对象 / 数组
        if let whole = JSONValue.parse(trimmed) {
            let found = collect(whole, validTools: validTools)
            if !found.isEmpty { return found }
        }

        for candidate in balancedObjects(in: text) {
            guard let parsed = JSONValue.parse(candidate) else { continue }
            let found = collect(parsed, validTools: validTools)
            if !found.isEmpty { return found }
        }

        return []
    }

    private static func balancedObjects(in text: String) -> [String] {
        var results: [String] = []
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false

        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]

            if inString {
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                }
                index = text.index(after: index)
                continue
            }

            if char == "\"" {
                inString = true
            } else if char == "{" {
                if depth == 0 { start = index }
                depth += 1
            } else if char == "}" {
                if depth > 0 {
                    depth -= 1
                    if depth == 0, let begin = start {
                        results.append(String(text[begin...index]))
                        start = nil
                    }
                }
            }
            index = text.index(after: index)
        }

        return results
    }

    // MARK: - 归一化

    private static func collect(_ value: JSONValue, validTools: Set<String>) -> [Recovered] {
        if case .array(let items) = value {
            return items.compactMap { normalize($0, validTools: validTools) }
        }
        if let single = normalize(value, validTools: validTools) {
            return [single]
        }
        return []
    }

    private static func normalize(_ value: JSONValue, validTools: Set<String>) -> Recovered? {
        guard case .object(let dict) = value else { return nil }

        var rawName: String?
        for key in nameKeys {
            if let candidate = dict[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !candidate.isEmpty {
                rawName = candidate
                break
            }
        }

        guard let name = rawName, validTools.contains(name), let tool = AgentTool(rawValue: name) else {
            return nil
        }

        var arguments: JSONValue?
        for key in argumentKeys {
            if let candidate = dict[key] {
                arguments = candidate
                break
            }
        }

        var resolved = arguments ?? .object([:])
        if case .string(let text) = resolved {
            resolved = JSONValue.parse(text) ?? .object([:])
        }
        guard case .object = resolved else { return nil }

        return Recovered(tool: tool, arguments: resolved)
    }

    // MARK: - 函数调用写法

    private static func keywordCalls(in text: String, validTools: Set<String>) -> [Recovered] {
        let pattern = "\\b([A-Za-z_][A-Za-z0-9_]*)\\s*\\(([^()]*)\\)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var results: [Recovered] = []

        for match in regex.matches(in: text, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: text),
                  let argsRange = Range(match.range(at: 2), in: text) else { continue }

            let name = String(text[nameRange])
            guard validTools.contains(name), let tool = AgentTool(rawValue: name) else { continue }

            let rawArguments = String(text[argsRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if rawArguments.isEmpty {
                results.append(Recovered(tool: tool, arguments: .object([:])))
                continue
            }

            guard let arguments = parseKeywordArguments(rawArguments) else { continue }
            results.append(Recovered(tool: tool, arguments: .object(arguments)))
        }

        return results
    }

    /// 解析 `path=".", limit=50` 这种参数列表。
    private static func parseKeywordArguments(_ text: String) -> [String: JSONValue]? {
        var arguments: [String: JSONValue] = [:]

        for part in splitTopLevel(text) {
            guard let separator = firstTopLevelEquals(part) else { return nil }
            let key = String(part[part.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(part[part.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, let value = parseLiteral(rawValue) else { return nil }
            arguments[key] = value
        }

        return arguments
    }

    private static func splitTopLevel(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?

        for char in text {
            if let active = quote {
                current.append(char)
                if char == active { quote = nil }
                continue
            }
            switch char {
            case "\"", "'":
                quote = char
                current.append(char)
            case "(", "[", "{":
                depth += 1
                current.append(char)
            case ")", "]", "}":
                depth -= 1
                current.append(char)
            case "," where depth == 0:
                parts.append(current)
                current = ""
            default:
                current.append(char)
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private static func firstTopLevelEquals(_ text: String) -> String.Index? {
        var depth = 0
        var quote: Character?

        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if let active = quote {
                if char == active { quote = nil }
            } else {
                switch char {
                case "\"", "'": quote = char
                case "(", "[", "{": depth += 1
                case ")", "]", "}": depth -= 1
                case "=" where depth == 0: return index
                default: break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func parseLiteral(_ text: String) -> JSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("\"") || trimmed.hasPrefix("'") {
            return .string(unquote(trimmed))
        }
        switch trimmed {
        case "True", "true": return .bool(true)
        case "False", "false": return .bool(false)
        case "None", "null", "Null": return .null
        default: break
        }
        if trimmed.hasPrefix("[") || trimmed.hasPrefix("{"),
           let parsed = JSONValue.parse(trimmed) {
            return parsed
        }
        if let number = Double(trimmed) { return .number(number) }
        return nil
    }

    private static func unquote(_ text: String) -> String {
        guard text.count >= 2 else { return text }
        var body = String(text.dropFirst().dropLast())
        body = body.replacingOccurrences(of: "\\n", with: "\n")
        body = body.replacingOccurrences(of: "\\t", with: "\t")
        body = body.replacingOccurrences(of: "\\\"", with: "\"")
        body = body.replacingOccurrences(of: "\\'", with: "'")
        body = body.replacingOccurrences(of: "\\\\", with: "\\")
        return body
    }

    // MARK: - 代码围栏

    private static func fencedBlocks(in text: String) -> [String] {
        let pattern = "```(?:json|python|javascript|swift)?\\s*(.*?)```"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let inner = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[inner])
        }
    }
}
