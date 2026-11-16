import Foundation

/// 写入类动作的落盘计划：在真正写之前先把「要发生什么」算清楚，这样才能给出 diff 并等待确认。
enum WritePlan: Sendable {
    case createFile(path: String, content: String)
    case overwriteFile(path: String, before: String, after: String)
    case editFile(path: String, before: String, after: String)

    var absolutePath: String {
        switch self {
        case .createFile(let path, _),
             .overwriteFile(let path, _, _),
             .editFile(let path, _, _):
            return path
        }
    }

    func change(guard safety: SafetyGuard) -> FileChange {
        switch self {
        case .createFile(let path, let content):
            return FileChange(
                path: safety.relativePath(path),
                before: "",
                after: content,
                isNewFile: true
            )
        case .overwriteFile(let path, let before, let after),
             .editFile(let path, let before, let after):
            return FileChange(
                path: safety.relativePath(path),
                before: before,
                after: after,
                isNewFile: false
            )
        }
    }
}

/// 写入前的计划被拒绝的原因。`Result` 的 Failure 必须是 Error，故单独包一层。
///
/// 支持字符串字面量写法，这样调用处可以继续写 `.failure("ERROR: ... \(path)")`。
struct PlanRejection: Error, ExpressibleByStringInterpolation {
    var message: String

    init(stringLiteral value: String) { self.message = value }

    init(stringInterpolation: DefaultStringInterpolation) {
        self.message = String(stringInterpolation: stringInterpolation)
    }
}

/// 待确认的动作。
enum PendingAction: Sendable {
    case write(WritePlan)
    case command(command: String, workingDirectory: String?, displayText: String)
}

/// 工具执行前的判定结果。
enum ToolPlan: Sendable {
    /// 可以直接完成（只读工具，或参数/权限错误）
    case ready(ToolExecutionResult)
    /// 会改变磁盘状态，可能需要先征求用户同意
    case pending(PendingAction, FileChange?)
}

/// 工具层：agent 能调用的动作集合。
///
/// 每个工具 = 一个执行函数 + 一份 JSON Schema（让模型知道什么时候该用它）。
/// 所有文件操作都经过 `SafetyGuard`，只能作用在 workspace 内。
struct AgentTools: Sendable {
    static let maxOutputChars = 6000
    private static let maxScannedFiles = 5000
    private static let skipDirectories: Set<String> = [
        ".git", "node_modules", "__pycache__", ".venv", "venv",
        "build", "dist", "DerivedData", "Pods", ".build", ".idea",
    ]

    let safety: SafetyGuard
    let workspace: String

    var validToolNames: Set<String> { Set(AgentTool.allCases.map(\.rawValue)) }

    // MARK: - 判定

    func plan(_ invocation: ToolInvocation) -> ToolPlan {
        let arguments = invocation.arguments

        switch invocation.tool {
        case .listDir:
            return .ready(listDirectory(path: arguments["path"]?.stringValue ?? "."))

        case .readFile:
            return .ready(
                readFile(
                    path: arguments["path"]?.stringValue ?? "",
                    offset: arguments["offset"]?.intValue ?? 1,
                    limit: arguments["limit"]?.intValue ?? 200
                )
            )

        case .search:
            return .ready(
                search(
                    pattern: arguments["pattern"]?.stringValue ?? "",
                    path: arguments["path"]?.stringValue ?? ".",
                    maxResults: arguments["max_results"]?.intValue ?? 50
                )
            )

        case .writeFile:
            let outcome = planWriteFile(
                path: arguments["path"]?.stringValue ?? "",
                content: arguments["content"]?.stringValue ?? ""
            )
            return wrap(outcome)

        case .editFile:
            let outcome = planEditFile(
                path: arguments["path"]?.stringValue ?? "",
                oldString: arguments["old_string"]?.stringValue ?? "",
                newString: arguments["new_string"]?.stringValue ?? ""
            )
            return wrap(outcome)

        case .runCommand:
            let rawCommand = arguments["command"]?.stringValue ?? ""
            let prepared = prepareCommand(rawCommand)
            switch prepared {
            case .failure(let rejection):
                return .ready(.failure(rejection.message))
            case .success(let plan):
                let verdict = safety.checkCommand(plan.command)
                guard verdict.allowed else {
                    return .ready(.failure("DENIED: \(verdict.reason)"))
                }
                return .pending(
                    .command(
                        command: plan.command,
                        workingDirectory: plan.workingDirectory,
                        displayText: plan.displayText
                    ),
                    nil
                )
            }
        }
    }

    private func wrap(_ outcome: Result<WritePlan, PlanRejection>) -> ToolPlan {
        switch outcome {
        case .success(let plan):
            return .pending(.write(plan), plan.change(guard: safety))
        case .failure(let rejection):
            return .ready(.failure(rejection.message))
        }
    }

    // MARK: - 落盘

    func commit(_ action: PendingAction) -> ToolExecutionResult {
        switch action {
        case .write(let plan):
            return commitWrite(plan)
        case .command(let command, let workingDirectory, _):
            return runCommand(command, workingDirectory: workingDirectory)
        }
    }

    func overrideCommandAction(from rawCommand: String) -> Result<PendingAction, PlanRejection> {
        let prepared = prepareCommand(rawCommand)
        switch prepared {
        case .failure(let rejection):
            return .failure(rejection)
        case .success(let plan):
            let verdict = safety.checkCommand(plan.command)
            if verdict.allowed {
                return .success(
                    .command(
                        command: plan.command,
                        workingDirectory: plan.workingDirectory,
                        displayText: plan.displayText
                    )
                )
            }

            if verdict.reason.contains("危险命令规则") || verdict.reason.contains("管道、重定向") {
                return .failure("DENIED: \(verdict.reason)")
            }

            return .success(
                .command(
                    command: plan.command,
                    workingDirectory: plan.workingDirectory,
                    displayText: plan.displayText
                )
            )
        }
    }

    private struct PreparedCommand: Sendable {
        var command: String
        var workingDirectory: String?
        var displayText: String
    }

    private func prepareCommand(_ rawCommand: String) -> Result<PreparedCommand, PlanRejection> {
        let trimmed = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure("ERROR: 空命令") }

        let marker = "&&"
        if trimmed.hasPrefix("cd "), let range = trimmed.range(of: marker) {
            let left = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let right = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

            let rawPath = left.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
            let path = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !path.isEmpty, !right.isEmpty else {
                return .failure("ERROR: 命令解析失败: \(rawCommand)")
            }

            do {
                let workingDirectory = try safety.resolvePath(path)
                let displayText = "工作目录：\(workingDirectory)\n命令：\(right)"
                return .success(
                    PreparedCommand(
                        command: right,
                        workingDirectory: workingDirectory,
                        displayText: displayText
                    )
                )
            } catch {
                return .failure("DENIED: \(error.localizedDescription)")
            }
        }

        return .success(
            PreparedCommand(
                command: trimmed,
                workingDirectory: nil,
                displayText: trimmed
            )
        )
    }

    private func commitWrite(_ plan: WritePlan) -> ToolExecutionResult {
        let change = plan.change(guard: safety)
        let target = plan.absolutePath

        do {
            let directory = (target as NSString).deletingLastPathComponent
            if !directory.isEmpty {
                try FileManager.default.createDirectory(
                    atPath: directory,
                    withIntermediateDirectories: true
                )
            }

            let content: String
            switch plan {
            case .createFile(_, let text): content = text
            case .overwriteFile(_, _, let text): content = text
            case .editFile(_, _, let text): content = text
            }

            try content.write(toFile: target, atomically: true, encoding: .utf8)

            guard FileManager.default.fileExists(atPath: target) else {
                return .failure("ERROR: 写入后未找到文件：\(target)")
            }

            let byteCount = content.lengthOfBytes(using: .utf8)
            let verb = change.isNewFile ? "已写入" : "已修改"
            return .ok(
                """
                OK: \(verb) \(change.path)（\(byteCount) 字节）
                absolute_path: \(target)
                verified: true
                """,
                change: change
            )
        } catch {
            return .failure("ERROR: 写入失败 \(change.path)：\(error.localizedDescription)")
        }
    }

    // MARK: - 只读工具

    private func readFile(path: String, offset: Int, limit: Int) -> ToolExecutionResult {
        let target: String
        do {
            target = try safety.resolvePath(path)
        } catch {
            return .failure("DENIED: \(error.localizedDescription)")
        }

        guard FileManager.default.fileExists(atPath: target) else {
            return .failure("ERROR: 文件不存在: \(path)")
        }
        guard let text = readText(target) else {
            return .failure("ERROR: 无法读取文件: \(path)")
        }

        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }

        let total = lines.count
        let start = max(1, offset) - 1
        let end = min(start + max(1, limit), total)
        guard start < total else {
            return .ok("[\(path)] 共 \(total) 行，起始行 \(offset) 超出范围")
        }

        let body = (start..<end)
            .map { String(format: "%4d| %@", $0 + 1, lines[$0]) }
            .joined(separator: "\n")

        let header = "[\(path)] 共 \(total) 行，本次显示第 \(start + 1)-\(end) 行\n"
        return .ok(truncate(header + body))
    }

    private func listDirectory(path: String) -> ToolExecutionResult {
        let target: String
        do {
            target = try safety.resolvePath(path)
        } catch {
            return .failure("DENIED: \(error.localizedDescription)")
        }

        guard let names = try? FileManager.default.contentsOfDirectory(atPath: target) else {
            return .failure("ERROR: 目录不存在: \(path)")
        }

        let entries = names
            .filter { !$0.hasPrefix(".") && !Self.skipDirectories.contains($0) }
            .sorted()
            .map { name -> String in
                let full = target + "/" + name
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory)
                return name + (isDirectory.boolValue ? "/" : "")
            }

        let body = entries.isEmpty ? "(空目录)" : entries.joined(separator: "\n")
        return .ok("[\(path)]\n\(body)")
    }

    private func search(pattern: String, path: String, maxResults: Int) -> ToolExecutionResult {
        let root: String
        do {
            root = try safety.resolvePath(path)
        } catch {
            return .failure("DENIED: \(error.localizedDescription)")
        }

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return .failure("ERROR: 正则表达式无效: \(pattern)")
        }

        var hits: [String] = []
        var scanned = 0

        guard let enumerator = FileManager.default.enumerator(atPath: root) else {
            return .failure("ERROR: 无法遍历目录: \(path)")
        }

        while let relative = enumerator.nextObject() as? String {
            let components = relative.split(separator: "/").map(String.init)
            if components.contains(where: { Self.skipDirectories.contains($0) || $0.hasPrefix(".") }) {
                enumerator.skipDescendants()
                continue
            }

            let full = root + "/" + relative
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  let text = readText(full) else {
                continue
            }

            scanned += 1
            if scanned > Self.maxScannedFiles { break }

            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                guard regex.firstMatch(in: line, range: range) != nil else { continue }

                let snippet = line.count > 200 ? String(line.prefix(200)) : line
                hits.append("\(safety.relativePath(full)):\(index + 1): \(snippet)")
                if hits.count >= maxResults {
                    return .ok(hits.joined(separator: "\n") + "\n... [已达结果上限 \(maxResults)]")
                }
            }
        }

        return .ok(hits.isEmpty ? "未找到匹配：\(pattern)" : hits.joined(separator: "\n"))
    }

    // MARK: - 写入前的计划

    private func planWriteFile(path: String, content: String) -> Result<WritePlan, PlanRejection> {
        let target: String
        do {
            target = try safety.resolvePath(path, forWrite: true)
        } catch {
            return .failure("DENIED: \(error.localizedDescription)")
        }

        if FileManager.default.fileExists(atPath: target) {
            let before = readText(target) ?? ""
            return .success(.overwriteFile(path: target, before: before, after: content))
        }
        return .success(.createFile(path: target, content: content))
    }

    private func planEditFile(path: String, oldString: String, newString: String) -> Result<WritePlan, PlanRejection> {
        let target: String
        do {
            target = try safety.resolvePath(path, forWrite: true)
        } catch {
            return .failure("DENIED: \(error.localizedDescription)")
        }

        guard FileManager.default.fileExists(atPath: target) else {
            return .failure("ERROR: 文件不存在: \(path)（新建文件请用 write_file）")
        }
        guard !oldString.isEmpty else {
            return .failure("ERROR: old_string 不能为空")
        }
        guard let text = readText(target) else {
            return .failure("ERROR: 无法读取文件: \(path)")
        }

        let occurrences = text.components(separatedBy: oldString).count - 1
        if occurrences == 0 {
            return .failure("ERROR: 未找到要替换的内容。请先用 read_file 查看原文（注意缩进与空行需完全一致）。")
        }
        if occurrences > 1 {
            return .failure("ERROR: 匹配到 \(occurrences) 处，内容不唯一。请提供更长的上下文以确保唯一。")
        }

        guard let range = text.range(of: oldString) else {
            return .failure("ERROR: 未找到要替换的内容。")
        }

        var updated = text
        updated.replaceSubrange(range, with: newString)
        return .success(.editFile(path: target, before: text, after: updated))
    }

    // MARK: - 执行命令

    private func runCommand(_ command: String, workingDirectory: String?) -> ToolExecutionResult {
        guard let argv = SafetyGuard.shellSplit(command), !argv.isEmpty else {
            return .failure("ERROR: 命令解析失败: \(command)")
        }

        let cwd = workingDirectory ?? workspace
        let outcome = Self.runProcess(argv: argv, cwd: cwd, timeout: 180)
        if outcome.timedOut {
            return .failure("ERROR: 命令执行超时（180s）")
        }
        if outcome.launchFailed {
            return .failure("ERROR: 找不到可执行文件: \(argv[0])")
        }

        let output = outcome.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = "exit=\(outcome.status)\n\(output.isEmpty ? "(无输出)" : truncate(output))"
        if outcome.status == 0 {
            return .ok(body)
        }
        return .failure(body)
    }

    struct ProcessOutcome {
        var status: Int32
        var output: String
        var timedOut: Bool
        var launchFailed: Bool
    }

    /// 同步执行子进程。
    ///
    /// 三个坑都在这儿处理掉了：stdout/stderr 必须在后台队列并发读取（否则管道写满会死锁）、
    /// 超时要用信号量而不是 `waitUntilExit`（否则卡死主流程）、PATH 要补上 Homebrew 目录
    /// （GUI 启动的 App 拿不到登录 shell 的 PATH）。
    static func runProcess(argv: [String], cwd: String, timeout: TimeInterval) -> ProcessOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)

        var environment = ProcessInfo.processInfo.environment
        let extraPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = (environment["PATH"].map { $0 + ":" } ?? "") + extraPath
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let lock = NSLock()
        var outputData = Data()
        var errorData = Data()

        let group = DispatchGroup()
        for (pipe, isError) in [(outputPipe, false), (errorPipe, true)] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? nil
                lock.lock()
                if isError { errorData = data ?? Data() } else { outputData = data ?? Data() }
                lock.unlock()
                group.leave()
            }
        }

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }

        do {
            try process.run()
        } catch {
            return ProcessOutcome(status: -1, output: error.localizedDescription, timedOut: false, launchFailed: true)
        }

        var timedOut = false
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if semaphore.wait(timeout: .now() + 3) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
        }

        group.wait()

        lock.lock()
        let merged = outputData + errorData
        lock.unlock()

        let text = String(data: merged, encoding: .utf8) ?? ""
        return ProcessOutcome(
            status: process.terminationStatus,
            output: text,
            timedOut: timedOut,
            launchFailed: false
        )
    }

    // MARK: - 工具

    private func readText(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        // 优先按 UTF-8 解，失败再退到 Latin-1，保证任何文件都能读出内容而不是报错
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private func truncate(_ text: String) -> String {
        guard text.count > Self.maxOutputChars else { return text }
        let half = Self.maxOutputChars / 2
        let omitted = text.count - Self.maxOutputChars
        return "\(text.prefix(half))\n... [输出过长，已省略 \(omitted) 字符] ...\n\(text.suffix(half))"
    }

    // MARK: - Schema

    static var schemas: [[String: Any]] {
        [
            function(
                name: AgentTool.readFile.rawValue,
                description: "读取 workspace 内文件，或用户已授权附件文件的带行号内容。改动文件前必须先读。",
                properties: [
                    "path": ["type": "string", "description": "workspace 内相对路径，或用户已授权的绝对路径"],
                    "offset": ["type": "integer", "description": "起始行号，从 1 开始，默认 1"],
                    "limit": ["type": "integer", "description": "读取行数，默认 200"],
                ],
                required: ["path"]
            ),
            function(
                name: AgentTool.writeFile.rawValue,
                description: "新建文件或整体覆盖写入。修改已有文件请优先用 edit_file。",
                properties: [
                    "path": ["type": "string", "description": "workspace 内相对路径，或用户已授权的绝对路径/目录下路径"],
                    "content": ["type": "string", "description": "完整文件内容"],
                ],
                required: ["path", "content"]
            ),
            function(
                name: AgentTool.editFile.rawValue,
                description: "对已有文件做定点替换。old_string 必须与原文完全一致（含缩进）且唯一。这是首选的改文件方式。",
                properties: [
                    "path": ["type": "string", "description": "workspace 内相对路径，或用户已授权的绝对路径"],
                    "old_string": ["type": "string", "description": "要被替换的原文片段"],
                    "new_string": ["type": "string", "description": "替换后的新片段"],
                ],
                required: ["path", "old_string", "new_string"]
            ),
            function(
                name: AgentTool.listDir.rawValue,
                description: "列出目录内容。第一步通常应该先调用它了解项目结构。",
                properties: [
                    "path": ["type": "string", "description": "相对 workspace 的目录，默认当前目录"],
                ],
                required: []
            ),
            function(
                name: AgentTool.search.rawValue,
                description: "按正则搜索文件内容，返回 文件:行号:内容。用于定位符号或字符串。",
                properties: [
                    "pattern": ["type": "string", "description": "正则表达式"],
                    "path": ["type": "string", "description": "搜索根目录，默认当前目录"],
                    "max_results": ["type": "integer", "description": "最大返回条数，默认 50"],
                ],
                required: ["pattern"]
            ),
            function(
                name: AgentTool.runCommand.rawValue,
                description: "执行单条命令，用于跑测试、跑 lint、查看文件。默认在 workspace 根目录执行；如果确实要切目录，只允许 `cd 目录 && 命令` 这一种形式，不能再拼接别的 shell 语法。",
                properties: [
                    "command": ["type": "string", "description": "完整命令，例如 python3 test_calc.py；若需切目录，只写 `cd 子目录 && ./gradlew test` 这种单次切换"],
                ],
                required: ["command"]
            ),
        ]
    }

    private static func function(
        name: String,
        description: String,
        properties: [String: [String: Any]],
        required: [String]
    ) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": required,
                ],
            ],
        ]
    }
}
