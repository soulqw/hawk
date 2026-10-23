import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

// MARK: - 可持久化的设置

/// 界面上所有可调参数。整体以 JSON 存进 UserDefaults，换机器时导出这一份即可。
struct AppSettings: Codable, Equatable, Sendable {
    var providerID: String = "ollama"
    var baseURL: String = ""
    var apiKey: String = ""
    var model: String = "qwen2.5-coder:14b"
    var dialect: String = ToolDialect.auto.rawValue
    var workspacePath: String = ""
    var allowWrite: Bool = true
    var requireApproval: Bool = false
    var maxSteps: Int = 25
    var temperature: Double = 0.1
    var timeout: Double = 300
    /// 每行一条，设置面板里用多行文本编辑，比数组绑定清爽。
    var extraAllowedText: String = ""
    var extraDangerousText: String = ""
    var customSkillPaths: [String] = []
}

// MARK: - 待确认的动作

struct ApprovalRequest: Identifiable, Sendable {
    var id: UUID
    var tool: AgentTool
    var summary: String
    var action: PendingAction
    var change: FileChange?

    var title: String {
        switch action {
        case .command: return "请求执行命令"
        case .write: return change?.isNewFile == true ? "请求新建文件" : "请求修改文件"
        }
    }
}

struct AuthorizedItem: Identifiable, Equatable, Sendable {
    let id: String
    let path: String
    let isDirectory: Bool

    init(path: String, isDirectory: Bool) {
        self.path = path
        self.isDirectory = isDirectory
        self.id = path
    }

    var name: String { (path as NSString).lastPathComponent }
}

struct RegisteredSkill: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let path: String
    let source: String
    let summary: String
    let content: String

    init(name: String, path: String, source: String, summary: String, content: String) {
        self.name = name
        self.path = path
        self.source = source
        self.summary = summary
        self.content = content
        self.id = path
    }
}

// MARK: - 视图模型

/// App 的状态机：持有设置、转录、待审批动作，并把 `AgentEngine` 的事件流翻译成界面状态。
@MainActor
@Observable
final class AppViewModel {

    // MARK: 设置项

    var providerID: String = "ollama"
    var baseURL: String = ""
    var apiKey: String = ""
    var model: String = "qwen2.5-coder:14b"
    var dialect: ToolDialect = .auto
    var workspacePath: String = ""
    var allowWrite: Bool = true
    var requireApproval: Bool = false
    var maxSteps: Int = 25
    var temperature: Double = 0.1
    var timeout: Double = 300
    var extraAllowedText: String = ""
    var extraDangerousText: String = ""

    // MARK: 运行状态

    var transcript: [TranscriptItem] = []
    var taskInput: String = ""
    var isRunning = false
    var stepIndex = 0
    var stepTotal = 0
    var scrollTick = 0
    var statusMessage = "就绪"
    var runPhaseTitle = "等待开始"
    var runPhaseDetail = "选择工作区后，输入你的任务并发送。"
    var availableModels: [String] = []
    var isRefreshingModels = false
    var pendingApproval: ApprovalRequest?
    var authorizedItems: [AuthorizedItem] = []
    var availableSkills: [RegisteredSkill] = []
    var isRefreshingSkills = false
    var customSkillPaths: [String] = []

    // MARK: 私有

    private static let defaultsKey = "MyApp.settings.v1"

    private var runTask: Task<Void, Never>?
    private var approvalContinuations: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var streamingItemID: UUID?
    private var activeAuthorizedItems: [AuthorizedItem] = []

    init() {
        loadSettings()
    }

    // MARK: - 派生值

    var resolvedBaseURL: String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return ProviderPreset.preset(for: providerID).baseURL
    }

    var resolvedAPIKey: String {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return ProviderPreset.preset(for: providerID).apiKey
    }

    var extraAllowedCommands: [String] { splitLines(extraAllowedText) }
    var extraDangerousPatterns: [String] { splitLines(extraDangerousText) }

    private func splitLines(_ text: String) -> [String] {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 供界面监听并自动落盘（`onChange(of: vm.settings)`）。
    var settings: AppSettings {
        AppSettings(
            providerID: providerID,
            baseURL: baseURL,
            apiKey: apiKey,
            model: model,
            dialect: dialect.rawValue,
            workspacePath: workspacePath,
            allowWrite: allowWrite,
            requireApproval: requireApproval,
            maxSteps: maxSteps,
            temperature: temperature,
            timeout: timeout,
            extraAllowedText: extraAllowedText,
            extraDangerousText: extraDangerousText,
            customSkillPaths: customSkillPaths
        )
    }

    func loadSettings() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let saved = try? JSONDecoder().decode(AppSettings.self, from: data) else { return }
        apply(saved)
    }

    func saveSettings() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private func apply(_ saved: AppSettings) {
        providerID = saved.providerID
        baseURL = saved.baseURL
        apiKey = saved.apiKey
        model = saved.model
        dialect = ToolDialect(rawValue: saved.dialect) ?? .auto
        workspacePath = saved.workspacePath
        allowWrite = saved.allowWrite
        requireApproval = saved.requireApproval
        maxSteps = saved.maxSteps
        temperature = saved.temperature
        timeout = saved.timeout
        extraAllowedText = saved.extraAllowedText
        extraDangerousText = saved.extraDangerousText
        customSkillPaths = saved.customSkillPaths
    }

    func resetToDefaults() {
        apply(AppSettings())
    }

    // MARK: - 工作区与模型

    func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.message = "选择 Agent 可以读写的项目目录"
        if !workspacePath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: workspacePath)
        }
        if panel.runModal() == .OK, let url = panel.url {
            workspacePath = url.path
            statusMessage = "工作区：\(url.lastPathComponent)"
            runPhaseDetail = "当前工作区：\(url.lastPathComponent)"
            refreshSkills()
        }
    }

    func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = "添加"
        panel.message = "选择要附加到输入框的文件或目录，模型将获得这些路径的读写权限。"
        if !workspacePath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: workspacePath)
        }
        if panel.runModal() == .OK {
            addAuthorizedURLs(panel.urls)
        }
    }

    func removeAuthorizedItem(id: String) {
        authorizedItems.removeAll { $0.id == id }
        statusMessage = authorizedItems.isEmpty ? "已移除附件" : "已授权 \(authorizedItems.count) 个附件路径"
    }

    func refreshSkills() {
        guard !isRefreshingSkills else { return }
        isRefreshingSkills = true

        let discovered = scanSkills()
        availableSkills = discovered.sorted {
            if $0.source == $1.source {
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return $0.source.localizedStandardCompare($1.source) == .orderedAscending
        }
        isRefreshingSkills = false
    }

    func chooseCustomSkill() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = "添加"
        panel.message = "选择 skill 文件夹或 SKILL.md 文件，加入当前客户端的技能列表。"
        if panel.runModal() == .OK {
            for url in panel.urls {
                let normalized = normalizedSkillPath(from: url)
                if !customSkillPaths.contains(normalized) {
                    customSkillPaths.append(normalized)
                }
            }
            customSkillPaths.sort { $0.localizedStandardCompare($1) == .orderedAscending }
            refreshSkills()
        }
    }

    func handleDroppedFileProviders(_ providers: [NSItemProvider]) -> Bool {
        let matched = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !matched.isEmpty else { return false }

        for provider in matched {
            provider.loadObject(ofClass: NSURL.self) { [weak self] item, _ in
                guard let self else { return }
                guard let fileURL = item as? URL, fileURL.isFileURL else { return }
                Task { @MainActor in
                    self.addAuthorizedURLs([fileURL])
                }
            }
        }
        return true
    }

    var fileAccessSummary: String {
        guard !authorizedItems.isEmpty else { return "未附加额外文件" }
        return "已附加 \(authorizedItems.count) 个路径"
    }

    var skillsSummary: String {
        availableSkills.isEmpty ? "未发现 Skill" : "已发现 \(availableSkills.count) 个 Skill"
    }

    private func normalizedSkillPath(from url: URL) -> String {
        let path = url.path
        if url.lastPathComponent == "SKILL.md" {
            return (path as NSString).deletingLastPathComponent
        }
        return path
    }

    private func buildTaskForModel(_ task: String) -> String {
        guard !activeAuthorizedItems.isEmpty else { return task }

        let lines = activeAuthorizedItems.map { item in
            let kind = item.isDirectory ? "目录" : "文件"
            return "- \(kind)：\(item.path)"
        }.joined(separator: "\n")

        return """
        \(task)

        [用户已明确授权或指定的目标路径]
        以下路径允许直接读写；如果用户已经明确给了目标目录/文件，你必须优先在这些路径里完成工作。
        不要把文件回退写到 workspace 根目录，也不要自行改成 workspace 相对路径：
        \(lines)
        """
    }

    private func inferredAuthorizedURLs(from task: String) -> [URL] {
        let pattern = #"/[^\s，。；、,!?！？“”"'`()\[\]{}<>]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let fullRange = NSRange(task.startIndex..., in: task)
        let fm = FileManager.default
        var results: [URL] = []
        var seen = Set<String>()

        for match in regex.matches(in: task, range: fullRange) {
            guard let range = Range(match.range, in: task) else { continue }
            let raw = String(task[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,，。；;!?！？\"'“”‘’"))
            let normalized = SafetyGuard.normalize(raw)
            guard normalized.hasPrefix("/") else { continue }

            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: normalized, isDirectory: &isDirectory) {
                if seen.insert(normalized).inserted {
                    results.append(URL(fileURLWithPath: normalized))
                }
                continue
            }

            let parent = (normalized as NSString).deletingLastPathComponent
            guard parent != normalized else { continue }
            guard fm.fileExists(atPath: parent, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            if seen.insert(parent).inserted {
                results.append(URL(fileURLWithPath: parent))
            }
        }

        return results
    }

    private func prepareRuntimeAuthorizedItems(for task: String) {
        activeAuthorizedItems = authorizedItems
        let inferred = inferredAuthorizedURLs(from: task)
        if !inferred.isEmpty {
            addRuntimeAuthorizedURLs(inferred)
            statusMessage = "已识别 \(inferred.count) 个目标路径"
        }
    }

    private func addAuthorizedURLs(_ urls: [URL]) {
        var merged = authorizedItems
        let fm = FileManager.default

        for url in urls {
            let path = SafetyGuard.normalize(url.path)
            guard !path.isEmpty, path != "." else { continue }

            var isDirectory: ObjCBool = false
            let exists = fm.fileExists(atPath: path, isDirectory: &isDirectory)
            let item = AuthorizedItem(path: path, isDirectory: exists && isDirectory.boolValue)
            if !merged.contains(item) {
                merged.append(item)
            }
        }

        authorizedItems = merged.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        statusMessage = authorizedItems.isEmpty ? "未附加额外文件" : "已授权 \(authorizedItems.count) 个附件路径"
    }

    private func addRuntimeAuthorizedURLs(_ urls: [URL]) {
        var merged = activeAuthorizedItems
        let fm = FileManager.default

        for url in urls {
            let path = SafetyGuard.normalize(url.path)
            guard !path.isEmpty, path != "." else { continue }

            var isDirectory: ObjCBool = false
            let exists = fm.fileExists(atPath: path, isDirectory: &isDirectory)
            let item = AuthorizedItem(path: path, isDirectory: exists && isDirectory.boolValue)
            if !merged.contains(item) {
                merged.append(item)
            }
        }

        activeAuthorizedItems = merged.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func scanSkills() -> [RegisteredSkill] {
        let roots = defaultSkillRoots()
        var items: [RegisteredSkill] = []
        var seen = Set<String>()

        for (path, source) in roots {
            for skill in discoverSkills(in: path, source: source) where seen.insert(skill.path).inserted {
                items.append(skill)
            }
        }

        for path in customSkillPaths {
            for skill in discoverSkills(in: path, source: "自定义") where seen.insert(skill.path).inserted {
                items.append(skill)
            }
        }

        return items
    }

    private func defaultSkillRoots() -> [(String, String)] {
        var roots: [(String, String)] = [
            ("/Users/george/.trae/builtin/scopes/a96d0c21/f3d4aadb/trae/default/skills", "内置"),
            ("/Users/george/.trae/builtin_skills", "Trae"),
            ("/Users/george/.trae/skills", "用户"),
        ]

        let workspace = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !workspace.isEmpty {
            roots.append(((workspace as NSString).appendingPathComponent(".trae/skills"), "项目"))
        }
        return roots
    }

    private func discoverSkills(in root: String, source: String) -> [RegisteredSkill] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else { return [] }

        var candidates: [String] = []
        let rootSkill = (root as NSString).appendingPathComponent("SKILL.md")
        if fm.fileExists(atPath: rootSkill) {
            candidates.append(root)
        }

        guard let children = try? fm.contentsOfDirectory(atPath: root) else {
            return candidates.compactMap { loadSkill(at: $0, source: source) }
        }

        for child in children {
            let childPath = (root as NSString).appendingPathComponent(child)
            var childIsDirectory: ObjCBool = false
            guard fm.fileExists(atPath: childPath, isDirectory: &childIsDirectory), childIsDirectory.boolValue else { continue }
            if fm.fileExists(atPath: (childPath as NSString).appendingPathComponent("SKILL.md")) {
                candidates.append(childPath)
            }
        }

        return candidates.compactMap { loadSkill(at: $0, source: source) }
    }

    private func loadSkill(at directoryPath: String, source: String) -> RegisteredSkill? {
        let filePath = (directoryPath as NSString).appendingPathComponent("SKILL.md")
        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else { return nil }

        let lines = content.components(separatedBy: .newlines)
        let titleLine = lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") })
        let title = titleLine?
            .replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = lines.first {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "暂无说明"

        return RegisteredSkill(
            name: title?.isEmpty == false ? title! : (directoryPath as NSString).lastPathComponent,
            path: directoryPath,
            source: source,
            summary: summary,
            content: content
        )
    }

    func refreshModels() {
        guard !isRefreshingModels else { return }
        isRefreshingModels = true
        statusMessage = "正在连接 \(resolvedBaseURL) …"

        let client = LLMClient(
            baseURL: resolvedBaseURL,
            apiKey: resolvedAPIKey,
            model: model,
            timeout: 20,
            temperature: temperature
        )

        Task { [weak self] in
            guard let self else { return }
            do {
                let models = try await client.listModels()
                self.availableModels = models
                self.statusMessage = models.isEmpty
                    ? "服务已连通，但未返回模型列表"
                    : "已连接 · 发现 \(models.count) 个模型"
            } catch {
                self.availableModels = []
                self.statusMessage = error.localizedDescription
            }
            self.isRefreshingModels = false
        }
    }

    // MARK: - 运行

    func start() {
        guard !isRunning else { return }

        let task = taskInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return }

        let workspace = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspace.isEmpty else {
            transcript.append(.error(AgentError.missingWorkspace.localizedDescription))
            touch()
            return
        }

        prepareRuntimeAuthorizedItems(for: task)

        let safety = SafetyGuard(
            rootPath: workspace,
            allowWrite: allowWrite,
            extraAllowed: extraAllowedCommands,
            extraDangerous: extraDangerousPatterns,
            authorizedPaths: activeAuthorizedItems.map(\.path)
        )
        let tools = AgentTools(safety: safety, workspace: safety.root)
        let client = LLMClient(
            baseURL: resolvedBaseURL,
            apiKey: resolvedAPIKey,
            model: model,
            timeout: timeout,
            temperature: temperature
        )
        let config = AgentRunConfig(
            workspacePath: safety.root,
            dialect: dialect,
            maxSteps: maxSteps,
            temperature: temperature,
            timeout: timeout,
            allowWrite: allowWrite,
            requireApproval: false,
            extraAllowedCommands: extraAllowedCommands,
            extraDangerousPatterns: extraDangerousPatterns
        )
        let engine = AgentEngine(client: client, tools: tools, config: config)

        let effectiveTask = buildTaskForModel(task)

        transcript = [.user(task)]
        taskInput = ""
        authorizedItems = []
        streamingItemID = nil
        stepIndex = 0
        stepTotal = maxSteps
        isRunning = true
        statusMessage = "运行中 · \(model)"
        runPhaseTitle = "正在理解你的需求"
        runPhaseDetail = "准备分析项目并规划执行步骤"
        touch()

        let executor: AgentEngine.Executor = { [weak self] invocation, runID in
            guard let self else {
                return .failure("会话已结束")
            }
            return await self.perform(invocation, runID: runID, tools: tools)
        }

        // 放到 detached 上跑：SSE 解析与工具调度都不占主线程，界面在流式输出时依然顺滑。
        runTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                for try await event in engine.run(task: effectiveTask, executor: executor) {
                    await self.apply(event)
                }
            } catch is CancellationError {
                await self.apply(.notice("已停止"))
            } catch {
                await self.apply(.failed(error.localizedDescription))
            }
            await self.finishRun()
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        denyAllPending()
        isRunning = false
        statusMessage = "已停止"
        runPhaseTitle = "任务已停止"
        runPhaseDetail = "你可以修改需求后重新发送。"
        touch()
    }

    func newSession() {
        guard !isRunning else { return }
        transcript = []
        streamingItemID = nil
        stepIndex = 0
        statusMessage = "就绪"
        runPhaseTitle = "等待开始"
        runPhaseDetail = workspacePath.isEmpty ? "选择工作区后，输入你的任务并发送。" : "准备就绪，随时可以发送新任务。"
        touch()
    }

    private func finishRun() {
        isRunning = false
        runTask = nil
        streamingItemID = nil
        activeAuthorizedItems = []
        if case .some = pendingApproval { pendingApproval = nil }
        denyAllPending()
        statusMessage = "就绪"
        runPhaseTitle = "等待开始"
        runPhaseDetail = workspacePath.isEmpty ? "选择工作区后，输入你的任务并发送。" : "准备就绪，随时可以发送新任务。"
        touch()
    }

    // MARK: - 工具执行（含人工审批）

    private func perform(
        _ invocation: ToolInvocation,
        runID: UUID,
        tools: AgentTools
    ) async -> ToolExecutionResult {
        for attempt in 0..<2 {
            let currentTools = makeRuntimeTools(fallback: tools)
            let plan = await Task.detached(priority: .userInitiated) {
                currentTools.plan(invocation)
            }.value

            switch plan {
            case .ready(let result):
                if attempt == 0, await handleUnauthorizedPathIfNeeded(result: result, invocation: invocation) {
                    continue
                }
                return result

            case .pending(let action, let change):
                runPhaseTitle = actionTitle(for: invocation.tool)
                if let change {
                    runPhaseDetail = "直接执行改动：\(change.path)"
                } else {
                    runPhaseDetail = actionDetail(for: invocation.tool, summary: invocation.summary)
                }
                return await Task.detached(priority: .userInitiated) {
                    currentTools.commit(action)
                }.value
            }
        }

        return .failure("ERROR: 权限申请后仍无法继续执行。")
    }

    private func requestApproval(_ request: ApprovalRequest) async -> Bool {
        await withCheckedContinuation { continuation in
            approvalContinuations[request.id] = continuation
            pendingApproval = request
        }
    }

    func approvePending() {
        resolvePending(approved: true)
    }

    func denyPending() {
        resolvePending(approved: false)
    }

    private func resolvePending(approved: Bool) {
        guard let request = pendingApproval else { return }
        pendingApproval = nil
        approvalContinuations.removeValue(forKey: request.id)?.resume(returning: approved)
    }

    private func denyAllPending() {
        let waiting = approvalContinuations
        approvalContinuations.removeAll()
        pendingApproval = nil
        for (_, continuation) in waiting {
            continuation.resume(returning: false)
        }
    }

    // MARK: - 事件 → 界面状态

    private func apply(_ event: AgentEvent) {
        switch event {
        case .stepStarted(let index, let total):
            stepIndex = index
            stepTotal = total
            statusMessage = "处理中 · 第 \(index)/\(total) 步"
            if runPhaseTitle == "等待开始" || runPhaseTitle == "正在理解你的需求" {
                runPhaseTitle = "正在处理任务"
            }
            runPhaseDetail = "第 \(index) / \(total) 步"

        case .assistantDelta(let chunk):
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                runPhaseTitle = "正在整理结果"
                runPhaseDetail = "把执行结果整理成更易读的回复"
            }

        case .assistantMessage(let text):
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                transcript.append(.assistant(text))
                runPhaseTitle = "正在整理结果"
                runPhaseDetail = "正在生成最终回复"
            }

        case .notice(let text):
            transcript.append(.notice(text))
            applyNotice(text)

        case .toolStarted(let run):
            transcript.append(.tool(run))
            runPhaseTitle = actionTitle(for: run.tool)
            runPhaseDetail = actionDetail(for: run.tool, summary: run.summary)

        case .toolFinished(let runID, let output, let status, let change):
            finishTool(runID: runID, output: output, status: status, change: change)
            switch status {
            case .succeeded:
                if let change {
                    runPhaseTitle = "代码已更新"
                    runPhaseDetail = "\(change.path) 变更 +\(change.addedLines) / -\(change.removedLines)"
                } else {
                    runPhaseTitle = "当前步骤已完成"
                    runPhaseDetail = brief(output)
                }
            case .failed:
                runPhaseTitle = "遇到一点问题，正在调整"
                runPhaseDetail = brief(output)
            case .denied:
                runPhaseTitle = "操作已取消"
                runPhaseDetail = "我会基于你的选择继续调整方案"
            case .waitingApproval:
                runPhaseTitle = "等待你的确认"
            case .running:
                break
            }

        case .finished(let text):
            transcript.append(.summary(buildGroundedSummary(modelText: text)))
            streamingItemID = nil
            statusMessage = "执行完成"
            runPhaseTitle = "任务已完成"
            runPhaseDetail = "最终结果已经整理好了。"

        case .failed(let text):
            transcript.append(.error(text))
            streamingItemID = nil
            statusMessage = "执行失败"
            runPhaseTitle = "执行失败"
            runPhaseDetail = brief(text)
        }
        touch()
    }

    private func approvalDetail(for invocation: ToolInvocation, change: FileChange?) -> String {
        switch invocation.tool {
        case .runCommand:
            return invocation.summary.isEmpty ? "准备执行命令，等待你确认。" : "准备执行命令：\(invocation.summary)"
        case .editFile, .writeFile:
            if let change {
                return "准备修改 \(change.path)，请确认这次改动。"
            }
            return invocation.summary.isEmpty ? "准备写入文件，请确认这次改动。" : "准备修改 \(invocation.summary)，请确认这次改动。"
        case .listDir, .readFile, .search:
            return actionDetail(for: invocation.tool, summary: invocation.summary)
        }
    }

    private func actionTitle(for tool: AgentTool) -> String {
        switch tool {
        case .listDir:
            return "正在查看项目结构"
        case .readFile:
            return "正在阅读相关文件"
        case .editFile, .writeFile:
            return "正在处理代码改动"
        case .search:
            return "正在搜索相关内容"
        case .runCommand:
            return "正在执行验证命令"
        }
    }

    private func actionDetail(for tool: AgentTool, summary: String) -> String {
        let text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        switch tool {
        case .listDir:
            return text.isEmpty ? "先了解项目目录和文件结构" : "查看目录：\(text)"
        case .readFile:
            return text.isEmpty ? "读取代码上下文，确认真实内容" : "读取文件：\(text)"
        case .editFile, .writeFile:
            return text.isEmpty ? "准备落地这次代码调整" : "处理文件：\(text)"
        case .search:
            return text.isEmpty ? "检索相关代码与关键字" : "搜索：\(text)"
        case .runCommand:
            return text.isEmpty ? "运行命令验证结果" : "执行：\(text)"
        }
    }

    private func applyNotice(_ text: String) {
        if text.contains("空响应") {
            runPhaseTitle = "模型暂无有效输出"
            runPhaseDetail = "正在自动重试，继续推进任务"
            return
        }
        if text.contains("解析出调用") {
            runPhaseTitle = "已识别执行动作"
            runPhaseDetail = "模型用了文本描述调用，我已经自动接上继续执行"
            return
        }
        if text.contains("重复调用") {
            runPhaseTitle = "正在收束结果"
            runPhaseDetail = "检测到重复动作，已切换到总结模式"
            return
        }
        runPhaseDetail = brief(text)
    }

    private func brief(_ text: String, limit: Int = 72) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard oneLine.count > limit else { return oneLine }
        return String(oneLine.prefix(limit)) + "..."
    }

    private func touch() { scrollTick &+= 1 }

    private func appendAssistantDelta(_ chunk: String) {
        if let id = streamingItemID, let index = transcript.firstIndex(where: { $0.id == id }) {
            if case .assistant(let text) = transcript[index].kind {
                transcript[index].kind = .assistant(text + chunk)
            }
        } else {
            let item = TranscriptItem.assistant(chunk)
            streamingItemID = item.id
            transcript.append(item)
        }
        touch()
    }

    private func setRunStatus(_ runID: UUID, _ status: ToolRun.Status) {
        for index in transcript.indices {
            if case .tool(var run) = transcript[index].kind, run.id == runID {
                run.status = status
                transcript[index].kind = .tool(run)
                touch()
                return
            }
        }
    }

    private func buildGroundedSummary(modelText: String) -> String {
        var changedFiles: [String] = []
        var commandResults: [String] = []
        var failedSteps: [String] = []

        for item in transcript {
            guard case .tool(let run) = item.kind else { continue }

            switch run.status {
            case .succeeded:
                if let change = run.change {
                    let absolutePath = extractValue(for: "absolute_path:", in: run.output) ?? resolvedAbsolutePath(for: change.path)
                    let verb = change.isNewFile ? "已创建" : "已修改"
                    changedFiles.append("- \(verb)：\(change.path)\n  实际路径：\(absolutePath)")
                } else if run.tool == .runCommand {
                    commandResults.append("- \(run.summary.isEmpty ? run.argumentsText : run.summary)\n  \(brief(run.output, limit: 120))")
                }
            case .failed:
                let name = run.summary.isEmpty ? run.tool.displayName : run.summary
                failedSteps.append("- \(name)\n  \(brief(run.output, limit: 120))")
            case .running, .waitingApproval, .denied:
                continue
            }
        }

        var sections: [String] = []

        if !changedFiles.isEmpty {
            sections.append("实际落盘结果：\n" + changedFiles.joined(separator: "\n"))
        }
        if !commandResults.isEmpty {
            sections.append("验证结果：\n" + commandResults.joined(separator: "\n"))
        }
        if !failedSteps.isEmpty {
            sections.append("失败步骤：\n" + failedSteps.joined(separator: "\n"))
        }

        let trimmed = modelText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            sections.append("模型总结：\n" + trimmed)
        }

        return sections.isEmpty ? "本次没有采集到可确认的执行结果。" : sections.joined(separator: "\n\n")
    }

    private func extractValue(for prefix: String, in text: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix(prefix) {
                return trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private func resolvedAbsolutePath(for relativePath: String) -> String {
        let base = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty || relativePath == "." { return relativePath }
        if relativePath.hasPrefix("/") { return relativePath }
        return (base as NSString).appendingPathComponent(relativePath)
    }

    private func makeRuntimeTools(fallback: AgentTools) -> AgentTools {
        let workspace = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspace.isEmpty else { return fallback }

        let safety = SafetyGuard(
            rootPath: workspace,
            allowWrite: allowWrite,
            extraAllowed: extraAllowedCommands,
            extraDangerous: extraDangerousPatterns,
            authorizedPaths: activeAuthorizedItems.map(\.path)
        )
        return AgentTools(safety: safety, workspace: safety.root)
    }

    private func handleUnauthorizedPathIfNeeded(
        result: ToolExecutionResult,
        invocation: ToolInvocation
    ) async -> Bool {
        guard result.status == .failed else { return false }
        guard result.output.contains("路径越界") || result.output.contains("拒绝访问") else { return false }
        guard let rawPath = requestedPath(from: invocation) else { return false }

        let normalized = SafetyGuard.normalize(rawPath)
        guard normalized.hasPrefix("/") else { return false }

        runPhaseTitle = "正在申请文件权限"
        runPhaseDetail = "目标路径未授权，准备请求你授予访问权限"
        touch()

        let granted = requestAuthorization(for: normalized)
        if granted {
            runPhaseTitle = "权限已授予，继续执行"
            runPhaseDetail = "已拿到目标路径权限，正在继续未完成的工作"
            touch()
        } else {
            runPhaseTitle = "未授予目标路径权限"
            runPhaseDetail = "当前工具无法访问该路径，模型会看到真实失败原因"
            touch()
        }
        return granted
    }

    private func requestedPath(from invocation: ToolInvocation) -> String? {
        switch invocation.tool {
        case .readFile, .writeFile, .editFile, .listDir:
            return invocation.arguments["path"]?.stringValue
        case .search:
            return invocation.arguments["path"]?.stringValue ?? "."
        case .runCommand:
            return nil
        }
    }

    private func requestAuthorization(for path: String) -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = fm.fileExists(atPath: path, isDirectory: &isDirectory)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "需要访问新的路径"
        alert.informativeText = exists
            ? "模型正在访问这个\(isDirectory.boolValue ? "目录" : "文件")：\n\(path)\n\n授予后会自动继续刚才未完成的操作。"
            : "模型准备写入的目标路径当前未授权：\n\(path)\n\n请授权该文件的父目录，授予后会自动继续刚才未完成的操作。"
        alert.addButton(withTitle: "继续授权")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        let panel = NSOpenPanel()
        panel.prompt = "授权"
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        if exists {
            panel.message = "请选择这个文件，或它所在的父目录。"
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.directoryURL = isDirectory.boolValue
                ? URL(fileURLWithPath: path)
                : URL(fileURLWithPath: (path as NSString).deletingLastPathComponent)
        } else {
            panel.message = "目标文件尚不存在，请选择要授权的父目录。"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.directoryURL = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent)
        }

        guard panel.runModal() == .OK, let url = panel.url else { return false }
        addRuntimeAuthorizedURLs([url])
        return true
    }

    private func finishTool(runID: UUID, output: String, status: ToolRun.Status, change: FileChange?) {
        for index in transcript.indices {
            if case .tool(var run) = transcript[index].kind, run.id == runID {
                run.status = status
                run.output = output
                if let change { run.change = change }
                transcript[index].kind = .tool(run)
                return
            }
        }
        // 理论上不会走到这里：toolStarted 一定先于 toolFinished。
    }
}
