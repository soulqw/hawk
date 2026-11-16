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
    /// Skill 上传目录：导入/更新的 Skill 会复制到这里。
    var skillsLibraryPath: String = ""
    /// 上下文缓存池：最多带入多少轮历史对话。
    var contextTurnLimit: Int = 6
    /// 上下文缓存池：历史对话的总字符预算。
    var contextCharBudget: Int = 16000
    /// 超预算时是否自动裁剪更早的历史。
    var autoTrimContext: Bool = true
}

// MARK: - 待确认的动作

struct ApprovalRequest: Identifiable, Sendable {
    enum Intent: Sendable {
        case execute(PendingAction)
        case authorizePath(String)
    }

    var id: UUID
    var tool: AgentTool
    var title: String
    var summary: String
    var detail: String
    var confirmTitle: String
    var intent: Intent
    var change: FileChange?
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

struct SkillMountStatus: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let source: String
    let path: String
    let count: Int
    let isWorkspaceScoped: Bool
    let isCurrentUploadTarget: Bool

    init(
        title: String,
        source: String,
        path: String,
        count: Int,
        isWorkspaceScoped: Bool,
        isCurrentUploadTarget: Bool
    ) {
        self.id = path
        self.title = title
        self.source = source
        self.path = path
        self.count = count
        self.isWorkspaceScoped = isWorkspaceScoped
        self.isCurrentUploadTarget = isCurrentUploadTarget
    }
}

// MARK: - 记忆

/// 一个可装载的记忆文件（全局或项目内）。
struct MemoryFile: Identifiable, Equatable, Sendable {
    let title: String
    let path: String

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

// MARK: - 上下文用量

/// 上下文缓存池的实时用量，供「上下文管理」面板展示。
struct ContextUsage: Equatable, Sendable {
    /// 全部历史轮数（含未进入模型的部分）
    var totalTurns = 0
    /// 实际会带进模型的轮数
    var activeTurns = 0
    /// 带进模型的字符数
    var characters = 0
    /// 字符预算
    var charBudget = 0
    /// 粗略 token 估算（按 1 token ≈ 3 字符）
    var estimatedTokens = 0
    /// 因预算被裁掉的轮数
    var trimmedTurns = 0

    var usageRatio: Double {
        guard charBudget > 0 else { return 0 }
        return min(1, Double(characters) / Double(charBudget))
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
    var skillsLibraryPath: String = ""
    var contextTurnLimit: Int = 6
    var contextCharBudget: Int = 16000
    var autoTrimContext: Bool = true

    // MARK: 会话

    /// 当前会话的完整记录（聊天 + 执行日志），会随任务推进实时落盘。
    var session = ConversationSession()
    /// 历史会话（不含当前会话），按更新时间倒序。
    var archivedSessions: [ConversationSession] = []
    /// 本轮任务在 `session.items` 中的起始下标，用于把「结果摘要」限定在本轮。
    private var currentTurnStart = 0

    // MARK: 私有

    private static let defaultsKey = "MyApp.settings.v1"
    private static let currentSessionKey = "MyApp.currentSessionID"

    private var runTask: Task<Void, Never>?
    private var approvalContinuations: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var streamingItemID: UUID?
    private var activeAuthorizedItems: [AuthorizedItem] = []
    /// 本轮用户显式附加的目标路径（不含技能目录等运行时权限）。
    private var userTaskAuthorizedItems: [AuthorizedItem] = []

    init() {
        apply(AppViewModel.loadStoredSettings())

        let identifier = UserDefaults.standard.string(forKey: Self.currentSessionKey)
            .flatMap(UUID.init(uuidString:))
        let sessions = AppViewModel.loadSessions()
        if let identifier, let existing = sessions.first(where: { $0.id == identifier }) {
            session = existing
            if workspacePath.isEmpty { workspacePath = existing.workspacePath }
        } else {
            session = ConversationSession(workspacePath: workspacePath)
        }
        archivedSessions = sessions.filter { $0.id != session.id }
        transcript = session.items
    }

    private static func loadStoredSettings() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return saved
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
            customSkillPaths: customSkillPaths,
            skillsLibraryPath: skillsLibraryPath,
            contextTurnLimit: contextTurnLimit,
            contextCharBudget: contextCharBudget,
            autoTrimContext: autoTrimContext
        )
    }

    func loadSettings() {
        apply(AppViewModel.loadStoredSettings())
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
        skillsLibraryPath = saved.skillsLibraryPath
        contextTurnLimit = saved.contextTurnLimit
        contextCharBudget = saved.contextCharBudget
        autoTrimContext = saved.autoTrimContext
    }

    func resetToDefaults() {
        apply(AppSettings())
    }

    // MARK: - 会话与上下文

    var sessionsRoot: String {
        (AppViewModel.applicationSupportRoot as NSString).appendingPathComponent("Hawk/Sessions")
    }

    private static var applicationSupportRoot: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.path
    }

    private static func loadSessions() -> [ConversationSession] {
        let root = (applicationSupportRoot as NSString).appendingPathComponent("Hawk/Sessions")
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root) else { return [] }

        var sessions: [ConversationSession] = []
        for name in names where name.hasSuffix(".json") {
            let path = (root as NSString).appendingPathComponent(name)
            guard let data = fm.contents(atPath: path),
                  let session = try? JSONDecoder().decode(ConversationSession.self, from: data) else { continue }
            sessions.append(session)
        }
        return sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func writeSessionToDisk(_ value: ConversationSession) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: sessionsRoot, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(value) else { return }
        let path = (sessionsRoot as NSString).appendingPathComponent("\(value.id.uuidString).json")
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// 把当前会话写回磁盘。每轮结束后调用，退出 App 也不会丢聊天记录。
    func persistSession() {
        session.items = transcript
        session.updatedAt = Date()
        if session.workspacePath.isEmpty { session.workspacePath = workspacePath }
        if session.title == "新会话" {
            if let first = transcript.first(where: { $0.dialogueText != nil && isUserItem($0) }),
               let text = first.dialogueText {
                session.title = String(text.prefix(24))
            }
        }

        UserDefaults.standard.set(session.id.uuidString, forKey: Self.currentSessionKey)
        writeSessionToDisk(session)
    }

    private func isUserItem(_ item: TranscriptItem) -> Bool {
        if case .user(_) = item.kind { return true }
        return false
    }

    /// 已完成的历史轮次：只有拿到了结论的轮次才算，正在跑的这一轮不会进历史。
    private func completedTurns() -> [(user: String, assistant: String)] {
        var pairs: [(String, String)] = []
        var pendingUser: String?

        for item in transcript {
            switch item.kind {
            case .user(let text):
                pendingUser = text
            case .summary(let text), .error(let text):
                if let user = pendingUser {
                    pairs.append((user, text))
                    pendingUser = nil
                }
            default:
                break
            }
        }
        return pairs
    }

    /// 按「轮数上限 + 字符预算」裁剪后的上下文缓存池。
    var contextHistory: [ChatMessage] {
        var pairs = completedTurns()
        if contextTurnLimit > 0, pairs.count > contextTurnLimit {
            pairs = Array(pairs.suffix(contextTurnLimit))
        }

        var messages: [ChatMessage] = []
        for pair in pairs {
            messages.append(.user(pair.user))
            if !pair.assistant.isEmpty {
                messages.append(.assistant(pair.assistant))
            }
        }

        if autoTrimContext, contextCharBudget > 0 {
            while messages.count > 2, Self.characterCount(of: messages) > contextCharBudget {
                messages.removeFirst(min(2, messages.count))
            }
        }
        return messages
    }

    var contextUsage: ContextUsage {
        let all = completedTurns()
        let history = contextHistory
        let characters = Self.characterCount(of: history)

        return ContextUsage(
            totalTurns: all.count,
            activeTurns: history.filter { $0.role == "user" }.count,
            characters: characters,
            charBudget: max(contextCharBudget, 0),
            estimatedTokens: characters / 3,
            trimmedTurns: max(0, all.count - history.filter { $0.role == "user" }.count)
        )
    }

    private static func characterCount(of messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + $1.content.count }
    }

    /// 清空当前会话的缓存池（聊天记录与执行日志一并清掉）。
    func clearContext() {
        guard !isRunning else { return }
        transcript = []
        session.items = []
        session.title = "新会话"
        streamingItemID = nil
        stepIndex = 0
        statusMessage = "上下文已清空"
        runPhaseTitle = "等待开始"
        runPhaseDetail = "上下文缓存池已清空，可以开始新的任务。"
        persistSession()
        touch()
    }

    /// 归档当前会话并开启一个新的上下文。
    func startNewSession() {
        guard !isRunning else { return }
        persistSession()

        if !transcript.isEmpty {
            session.updatedAt = Date()
            archivedSessions.insert(session, at: 0)
            writeSessionToDisk(session)
        }

        session = ConversationSession(workspacePath: workspacePath)
        transcript = []
        currentTurnStart = 0
        UserDefaults.standard.set(session.id.uuidString, forKey: Self.currentSessionKey)
        streamingItemID = nil
        stepIndex = 0
        taskInput = ""
        authorizedItems = []
        statusMessage = "新会话"
        runPhaseTitle = "等待开始"
        runPhaseDetail = workspacePath.isEmpty ? "选择工作区后，输入你的任务并发送。" : "准备就绪，随时可以发送新任务。"
        touch()
    }

    /// 把某个历史会话调回主界面继续（同时成为当前会话）。
    func loadSession(_ target: ConversationSession) {
        guard !isRunning else { return }
        guard target.id != session.id else { return }
        persistSession()

        if !transcript.isEmpty {
            archivedSessions.insert(session, at: 0)
        }
        archivedSessions.removeAll { $0.id == target.id }

        session = target
        transcript = target.items
        currentTurnStart = transcript.count
        if !target.workspacePath.isEmpty { workspacePath = target.workspacePath }
        UserDefaults.standard.set(session.id.uuidString, forKey: Self.currentSessionKey)
        streamingItemID = nil
        stepIndex = 0
        taskInput = ""
        authorizedItems = []
        runPhaseTitle = "等待开始"
        runPhaseDetail = target.items.isEmpty ? "这个会话还没有记录，直接发送任务即可。" : "已切回该会话，历史记录可继续回溯。"
        statusMessage = "已切换到「\(target.title)」"
        // 会话所属工作区可能不同，技能索引要跟着重新装载。
        refreshSkills()
        touch()
    }

    func deleteSession(_ target: ConversationSession) {
        guard !isRunning else { return }
        guard target.id != session.id else { return }
        archivedSessions.removeAll { $0.id == target.id }
        let path = (sessionsRoot as NSString).appendingPathComponent("\(target.id.uuidString).json")
        try? FileManager.default.removeItem(atPath: path)
        statusMessage = "已删除会话「\(target.title)」"
        touch()
    }

    func renameSession(_ target: ConversationSession) {
        guard !isRunning else { return }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "重命名会话"
        alert.informativeText = "给这个会话设置一个更清晰的名称。"

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = target.title == "新会话" ? "" : target.title
        field.placeholderString = "输入会话名称"
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if target.id == session.id {
            session.title = trimmed
            persistSession()
        } else if let index = archivedSessions.firstIndex(where: { $0.id == target.id }) {
            archivedSessions[index].title = trimmed
            archivedSessions[index].updatedAt = Date()
            writeSessionToDisk(archivedSessions[index])
            archivedSessions.sort { $0.updatedAt > $1.updatedAt }
        }

        statusMessage = "已重命名为「\(trimmed)」"
        touch()
    }

    /// 当前会话 + 历史会话，供上下文面板展示。
    var allSessions: [ConversationSession] {
        [session] + archivedSessions
    }

    // MARK: - 会话启动装载（记忆 / 技能 / 上下文）

    /// 全局记忆文件：跨项目通用的长期偏好与约束。
    var globalMemoryPath: String {
        (AppViewModel.applicationSupportRoot as NSString).appendingPathComponent("Hawk/Memory.md")
    }

    /// 记忆候选位置：全局 + 项目内约定文件。只有真实存在的才会被装载。
    var memoryCandidates: [MemoryFile] {
        var items: [MemoryFile] = [MemoryFile(title: "全局记忆", path: globalMemoryPath)]

        let workspace = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !workspace.isEmpty {
            items.append(MemoryFile(title: "项目记忆", path: (workspace as NSString).appendingPathComponent("AGENTS.md")))
            items.append(MemoryFile(title: "项目记忆", path: (workspace as NSString).appendingPathComponent(".hawk/memory.md")))
        }
        return items
    }

    /// 实际存在的记忆文件，装载与界面展示共用同一份判断。
    var loadedMemoryFiles: [MemoryFile] {
        memoryCandidates.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 单个记忆文件的字符上限，避免一个超大文件把上下文挤爆。
    private static let memoryFileCharLimit = 4000

    private func loadMemoryBlock() -> String {
        var blocks: [String] = []

        for item in loadedMemoryFiles {
            guard let text = try? String(contentsOfFile: item.path, encoding: .utf8) else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let body = trimmed.count > Self.memoryFileCharLimit
                ? String(trimmed.prefix(Self.memoryFileCharLimit)) + "\n…（内容过长已截断）"
                : trimmed
            blocks.append("[\(item.title) · \(item.path)]\n\(body)")
        }
        return blocks.joined(separator: "\n\n")
    }

    /// 技能索引：只给名称、说明和路径。细节让模型按需 read_file，避免一次性灌满上下文。
    private func loadSkillIndexBlock() -> String {
        guard !availableSkills.isEmpty else { return "" }

        let lines = availableSkills.prefix(40).map { skill -> String in
            let summary = skill.summary.count > 120
                ? String(skill.summary.prefix(120)) + "…"
                : skill.summary
            let skillFile = (skill.path as NSString).appendingPathComponent("SKILL.md")
            return "- \(skill.name)：\(summary)\n  路径：\(skillFile)"
        }

        return """
        [可用 Skill 索引]
        下面是当前会话已挂载的专家流程。当任务与某个 Skill 相关时，先用 read_file 读取它的 SKILL.md，再按其中步骤执行。
        \(lines.joined(separator: "\n"))
        """
    }

    /// 会话启动装载块：记忆 + 技能索引。上下文（历史轮次）走独立通道。
    private func buildBootstrap() -> String {
        var sections: [String] = []

        let memory = loadMemoryBlock()
        if !memory.isEmpty {
            sections.append(
                """
                [记忆]
                以下是本项目 / 全局的长期约束与偏好，在不与用户当前指令冲突的前提下遵守。

                \(memory)
                """
            )
        }

        let skills = loadSkillIndexBlock()
        if !skills.isEmpty { sections.append(skills) }

        return sections.joined(separator: "\n\n")
    }

    /// 启动装载概览，供顶栏状态与上下文面板展示。
    var bootstrapSummary: String {
        let turns = contextHistory.filter { $0.role == "user" }.count
        return "记忆 \(loadedMemoryFiles.count) 项 · 技能 \(availableSkills.count) 个 · 上下文 \(turns) 轮"
    }

    /// 工作区之外的技能目录需要显式授权，模型才能 read_file 到 SKILL.md。
    private var skillReadableRoots: [String] {
        var roots = [resolvedSkillsLibraryPath]
        roots.append(contentsOf: customSkillPaths)
        return roots.filter { FileManager.default.fileExists(atPath: $0) }
    }

    private static let memoryTemplate = """
    # Hawk 全局记忆

    这里写跨项目通用的长期约束与偏好，每次任务启动都会自动装载。例如：

    - 回复与代码注释统一使用中文。
    - 改文件前必须先读原文，不要凭猜测修改。
    - 技术方案优先本地可运行、零额外依赖。
    """

    /// 打开全局记忆文件；不存在时先落一份模板，方便直接填写。
    func openGlobalMemory() {
        let path = globalMemoryPath
        let fm = FileManager.default

        if !fm.fileExists(atPath: path) {
            try? fm.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try? Self.memoryTemplate.write(toFile: path, atomically: true, encoding: .utf8)
        }

        NSWorkspace.shared.open(URL(fileURLWithPath: path))
        statusMessage = "已打开全局记忆文件"
    }

    /// 在 Finder 中定位某个记忆文件。
    func revealMemory(_ file: MemoryFile) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
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

    /// 客户端技能库默认位置：上传的 Skill 会被复制到这里，不再依赖原始路径。
    var defaultSkillsLibraryPath: String {
        (AppViewModel.applicationSupportRoot as NSString).appendingPathComponent("Hawk/Skills")
    }

    /// 实际生效的技能上传目录。留空则用默认位置，否则用用户指定路径（支持 ~ 展开）。
    var resolvedSkillsLibraryPath: String {
        let trimmed = skillsLibraryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultSkillsLibraryPath }
        return (trimmed as NSString).expandingTildeInPath
    }

    /// 项目内技能目录：`{workspace}/.hawk/skills`，随项目一起版本管理。
    var projectSkillsPath: String? {
        let workspace = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspace.isEmpty else { return nil }
        return (workspace as NSString).appendingPathComponent(".hawk/skills")
    }

    func useProjectSkillsLibrary() {
        guard let project = projectSkillsPath else {
            presentAlert(title: "还没有选择工作区", message: "先选择工作区，才能把技能目录指到项目内。")
            return
        }
        skillsLibraryPath = project
        try? FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        refreshSkills()
        statusMessage = "技能目录已指向项目内：\(project)"
    }

    func useDefaultSkillsLibrary() {
        skillsLibraryPath = ""
        refreshSkills()
        statusMessage = "技能目录已恢复为默认位置"
    }

    func chooseSkillsLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.message = "选择 Skill 上传目录，上传与更新的技能都会放到这里。"
        panel.directoryURL = URL(fileURLWithPath: (resolvedSkillsLibraryPath as NSString).deletingLastPathComponent)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        skillsLibraryPath = url.path
        refreshSkills()
        statusMessage = "技能目录已设置为：\(url.path)"
    }

    func revealSkillsLibrary() {
        let path = resolvedSkillsLibraryPath
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func uploadSkills() {
        importSkills(
            into: resolvedSkillsLibraryPath,
            prompt: "上传",
            statusPrefix: "Skill 上传完成"
        )
    }

    func uploadSkillsToWorkspace() {
        guard let projectRoot = prepareProjectSkillsDirectory() else { return }
        skillsLibraryPath = projectRoot
        importSkills(
            into: projectRoot,
            prompt: "挂载",
            statusPrefix: "已挂到当前工作空间"
        )
    }

    private func prepareProjectSkillsDirectory() -> String? {
        guard let project = projectSkillsPath else {
            presentAlert(title: "还没有选择工作区", message: "先选择工作区，才能把 Skill 挂到当前工作空间。")
            return nil
        }

        do {
            try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
            return project
        } catch {
            presentAlert(title: "无法创建项目 Skill 目录", message: error.localizedDescription)
            return nil
        }
    }

    /// 上传 Skill 到指定目录。同名技能会被直接更新，方便迭代。
    private func importSkills(
        into root: String,
        prompt: String,
        statusPrefix: String
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = prompt
        panel.message = "选择 skill 文件夹（需含 SKILL.md）或 SKILL.md / .md 文件；会复制到目标目录，同名会被更新。"
        guard panel.runModal() == .OK else { return }

        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        } catch {
            presentAlert(title: "无法创建技能目录", message: error.localizedDescription)
            return
        }

        var created: [String] = []
        var updated: [String] = []
        var failures: [String] = []

        for url in panel.urls {
            let name = skillName(for: url)
            let destination = (root as NSString).appendingPathComponent(name)
            let existed = fm.fileExists(atPath: destination)
            do {
                if existed { try fm.removeItem(atPath: destination) }
                try copySkill(from: url, to: destination)
                if existed { updated.append(name) } else { created.append(name) }
            } catch {
                failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }

        refreshSkills()

        if created.isEmpty && updated.isEmpty {
            let detail = failures.isEmpty ? "没有可上传的内容。" : failures.joined(separator: "\n")
            presentAlert(title: "上传未完成", message: detail)
            return
        }

        var parts: [String] = []
        if !created.isEmpty { parts.append("新增 \(created.count) 个：\(created.joined(separator: "、"))") }
        if !updated.isEmpty { parts.append("更新 \(updated.count) 个：\(updated.joined(separator: "、"))") }
        statusMessage = statusPrefix + " · " + parts.joined(separator: "；")

        if !failures.isEmpty {
            presentAlert(
                title: "部分内容未上传",
                message: parts.joined(separator: "\n") + "\n\n失败：\n" + failures.joined(separator: "\n")
            )
        }
    }

    /// 目录用目录名；SKILL.md 用所在目录名；其他 .md 用文件名。
    private func skillName(for url: URL) -> String {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if exists, isDirectory.boolValue { return url.lastPathComponent }

        let base = url.deletingPathExtension().lastPathComponent
        if base.uppercased() == "SKILL" {
            let parent = url.deletingLastPathComponent().lastPathComponent
            return parent.isEmpty ? "Skill" : parent
        }
        return base.isEmpty ? "Skill" : base
    }

    private func copySkill(from url: URL, to destination: String) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = fm.fileExists(atPath: url.path, isDirectory: &isDirectory)

        if exists, isDirectory.boolValue {
            let skillFile = (url.path as NSString).appendingPathComponent("SKILL.md")
            guard fm.fileExists(atPath: skillFile) else {
                throw NSError(
                    domain: "Hawk",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "文件夹里没有 SKILL.md"]
                )
            }
            try fm.copyItem(at: url, to: URL(fileURLWithPath: destination))
            return
        }

        try fm.createDirectory(atPath: destination, withIntermediateDirectories: true)
        try fm.copyItem(at: url, to: URL(fileURLWithPath: (destination as NSString).appendingPathComponent("SKILL.md")))
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
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

    var skillMountStatuses: [SkillMountStatus] {
        var statuses: [SkillMountStatus] = []
        var seen = Set<String>()

        for (path, source) in defaultSkillRoots() {
            appendSkillMountStatus(
                path: path,
                source: source,
                title: source == "技能库" ? "当前上传目录" : source,
                into: &statuses,
                seen: &seen
            )
        }

        for path in customSkillPaths {
            appendSkillMountStatus(
                path: path,
                source: "自定义引用",
                title: "自定义引用",
                into: &statuses,
                seen: &seen
            )
        }

        return statuses.sorted { lhs, rhs in
            if lhs.isWorkspaceScoped != rhs.isWorkspaceScoped {
                return lhs.isWorkspaceScoped && !rhs.isWorkspaceScoped
            }
            if lhs.isCurrentUploadTarget != rhs.isCurrentUploadTarget {
                return lhs.isCurrentUploadTarget && !rhs.isCurrentUploadTarget
            }
            if lhs.count != rhs.count {
                return lhs.count > rhs.count
            }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
    }

    var workspaceMountedSkillCount: Int {
        skillMountStatuses
            .filter(\.isWorkspaceScoped)
            .reduce(0) { $0 + $1.count }
    }

    var currentUploadTargetSkillCount: Int {
        skillMountStatuses.first(where: \.isCurrentUploadTarget)?.count ?? 0
    }

    private func appendSkillMountStatus(
        path: String,
        source: String,
        title: String,
        into statuses: inout [SkillMountStatus],
        seen: inout Set<String>
    ) {
        let normalized = SafetyGuard.normalize(path)
        guard !normalized.isEmpty, seen.insert(normalized).inserted else { return }

        let count = discoverSkills(in: path, source: source).count
        let workspaceScoped = isWorkspaceScopedSkillPath(normalized)
        let currentUploadTarget = normalized == SafetyGuard.normalize(resolvedSkillsLibraryPath)

        let exists = FileManager.default.fileExists(atPath: path)
        guard exists || count > 0 || currentUploadTarget || workspaceScoped else { return }

        statuses.append(
            SkillMountStatus(
                title: title,
                source: source,
                path: path,
                count: count,
                isWorkspaceScoped: workspaceScoped,
                isCurrentUploadTarget: currentUploadTarget
            )
        )
    }

    private func isWorkspaceScopedSkillPath(_ normalizedPath: String) -> Bool {
        let workspace = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspace.isEmpty else { return false }
        let normalizedWorkspace = SafetyGuard.normalize(workspace)
        return normalizedPath == normalizedWorkspace || normalizedPath.hasPrefix(normalizedWorkspace + "/")
    }

    private func normalizedSkillPath(from url: URL) -> String {
        let path = url.path
        if url.lastPathComponent == "SKILL.md" {
            return (path as NSString).deletingLastPathComponent
        }
        return path
    }

    private func buildTaskForModel(_ task: String) -> String {
        guard !userTaskAuthorizedItems.isEmpty else { return task }

        let lines = userTaskAuthorizedItems.map { item in
            let kind = item.isDirectory ? "目录（可读写，可在其中新建文件）" : "文件"
            return "- \(kind)：\(item.path)"
        }.joined(separator: "\n")

        return """
        \(task)

        [用户指定的目标路径，已授权可直接读写]
        \(lines)

        使用要求：
        - 上面这些绝对路径就是用户指定的工作位置，必须原样使用，不要改写、不要省略目录部分。
        - 需要在目录里新建或修改文件时，直接用「目录路径 + 文件名」拼出的绝对路径，不要退化成相对 workspace 的路径。
        - 只有上面这些路径与当前 workspace 可以直接访问；确实需要别的绝对路径时，先发起工具调用，客户端会在权限不足时申请授权并自动续跑。
        """
    }

    /// 把用户选择的路径加入授权列表。
    ///
    /// 附件是单个文件时，会把「文件所在目录」一并授权：模型改这个文件、
    /// 或在它旁边新建文件都属于同一个工作位置，否则第一步就会因权限被拒。
    private func expandForAuthorization(_ path: String) -> [AuthorizedItem] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = fm.fileExists(atPath: path, isDirectory: &isDirectory)
        let isDir = exists && isDirectory.boolValue

        var items = [AuthorizedItem(path: path, isDirectory: isDir)]

        // 路径还不存在（例如要新建的文件）时，按目录处理它的父级。
        if !exists || !isDir {
            let parent = (path as NSString).deletingLastPathComponent
            if !parent.isEmpty, parent != "/" {
                items.append(AuthorizedItem(path: parent, isDirectory: true))
            }
        }
        return items
    }

    private func addAuthorizedURLs(_ urls: [URL]) {
        var merged = authorizedItems

        for url in urls {
            let path = SafetyGuard.normalize(url.path)
            guard !path.isEmpty, path != "." else { continue }

            for item in expandForAuthorization(path) where !merged.contains(item) {
                merged.append(item)
            }
        }

        authorizedItems = merged.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        statusMessage = authorizedItems.isEmpty ? "未附加额外文件" : "已授权 \(authorizedItems.count) 个附件路径"
    }

    private func addRuntimeAuthorizedURLs(_ urls: [URL]) {
        var merged = activeAuthorizedItems

        for url in urls {
            let path = SafetyGuard.normalize(url.path)
            guard !path.isEmpty, path != "." else { continue }

            for item in expandForAuthorization(path) where !merged.contains(item) {
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
            (resolvedSkillsLibraryPath, "技能库"),
        ]

        let workspace = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !workspace.isEmpty {
            roots.append(((workspace as NSString).appendingPathComponent(".hawk/skills"), "项目"))
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

        // 用户附件是「任务目标路径」，与运行时权限快照分开记录，避免把技能目录误当成用户指定路径。
        userTaskAuthorizedItems = authorizedItems
        var runtimeItems = authorizedItems
        for root in skillReadableRoots {
            for item in expandForAuthorization(root) where !runtimeItems.contains(item) {
                runtimeItems.append(item)
            }
        }
        activeAuthorizedItems = runtimeItems.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }

        // 历史上下文要在写入本轮消息之前算好，避免把本轮提问也当成历史。
        let history = contextHistory
        // 会话启动装载：记忆 + 技能索引（上下文走 history 通道）。
        let bootstrap = buildBootstrap()

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

        // 像聊天一样累积：不重置转录，只在末尾追加本轮提问。
        currentTurnStart = transcript.count
        transcript.append(.notice("会话启动装载：\(bootstrapSummary)"))
        transcript.append(.user(task))
        persistSession()

        taskInput = ""
        authorizedItems = []
        streamingItemID = nil
        stepIndex = 0
        stepTotal = maxSteps
        isRunning = true
        statusMessage = "运行中 · \(model)"
        runPhaseTitle = "正在理解你的需求"
        runPhaseDetail = "已装载 \(bootstrapSummary)，正在规划执行步骤"
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
                for try await event in engine.run(
                    task: effectiveTask,
                    history: history,
                    bootstrap: bootstrap,
                    executor: executor
                ) {
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
        persistSession()
        touch()
    }

    func newSession() {
        startNewSession()
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
        persistSession()
        touch()
    }

    // MARK: - 工具执行（含人工审批）

    private func perform(
        _ invocation: ToolInvocation,
        runID: UUID,
        tools: AgentTools
    ) async -> ToolExecutionResult {
        var promptedPaths = Set<String>()

        while true {
            let currentTools = makeRuntimeTools(fallback: tools)
            let plan = await Task.detached(priority: .userInitiated) {
                currentTools.plan(invocation)
            }.value

            switch plan {
            case .ready(let result):
                if let path = authorizationPathIfNeeded(
                    result: result,
                    invocation: invocation,
                    promptedPaths: promptedPaths
                ) {
                    promptedPaths.insert(path)
                    let granted = await requestAuthorizationIfNeeded(for: path, tool: invocation.tool)
                    if granted {
                        continue
                    }
                    return result
                }

                if let request = commandApprovalIfNeeded(
                    result: result,
                    invocation: invocation,
                    tools: currentTools
                ) {
                    let approved = await requestApproval(request)
                    guard approved else { return result }

                    if case .execute(let action) = request.intent {
                        runPhaseTitle = actionTitle(for: invocation.tool)
                        runPhaseDetail = "已按你的选择继续执行当前命令"
                        return await Task.detached(priority: .userInitiated) {
                            currentTools.commit(action)
                        }.value
                    }
                    return result
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

    /// 只输出用户关心的事实：真正落盘的路径、关键验证结论、以及需要注意的问题。
    /// 内部校验命令与模型过程放到日志中心，不挤到主结果卡片。
    private func buildGroundedSummary(modelText: String) -> String {
        var results: [String] = []
        var extraNotes: [String] = []
        var warnings: [String] = []
        var seenPaths = Set<String>()
        var seenWarningKeys = Set<String>()

        // 只统计本轮任务产生的工具结果；历史轮次的结论已经各自成为独立卡片。
        let start = min(currentTurnStart, transcript.count)
        for item in transcript[start...] {
            guard case .tool(let run) = item.kind else { continue }

            switch run.status {
            case .succeeded:
                if let change = run.change {
                    let absolutePath = extractValue(for: "absolute_path:", in: run.output) ?? resolvedAbsolutePath(for: change.path)
                    guard seenPaths.insert(absolutePath).inserted else { continue }
                    let verb = change.isNewFile ? "已创建" : "已修改"
                    results.append("- \(verb)：\(absolutePath)")
                } else if run.tool == .runCommand, shouldIncludeCommandInSummary(run) {
                    let command = brief(run.summary.isEmpty ? run.argumentsText : run.summary, limit: 80)
                    let output = brief(run.output, limit: 80)
                    extraNotes.append(output.isEmpty ? "- 已执行：\(command)" : "- 已执行：\(command) → \(output)")
                }
            case .failed:
                let name = brief(run.summary.isEmpty ? run.tool.displayName : run.summary, limit: 80)
                let reason = brief(run.output, limit: 90)
                let warningKey = "\(run.tool.rawValue)|\(name)|\(reason)"
                guard seenWarningKeys.insert(warningKey).inserted else { continue }
                warnings.append("- 未完成：\(name)（\(reason)）")
            case .running, .waitingApproval, .denied:
                continue
            }
        }

        var sections: [String] = []
        if !results.isEmpty {
            sections.append("执行结果：\n" + results.joined(separator: "\n"))
        }
        if !extraNotes.isEmpty {
            sections.append("额外补充：\n" + extraNotes.joined(separator: "\n"))
        }
        if !warnings.isEmpty {
            sections.append("需要注意：\n" + warnings.joined(separator: "\n"))
        }

        guard sections.isEmpty else { return sections.joined(separator: "\n\n") }

        // 没有工具结果时，保留模型最终答复；若是纯代码则自动包成代码块，避免裸文本预览。
        let trimmed = modelText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "本次没有采集到可确认的执行结果。" : formattedFallbackSummary(trimmed)
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

    private func shouldIncludeCommandInSummary(_ run: ToolRun) -> Bool {
        let command = (run.summary.isEmpty ? run.argumentsText : run.summary)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !command.isEmpty else { return false }

        let internalPrefixes = [
            "cat ", "ls ", "pwd", "sed ", "head ", "tail ", "rg ", "grep ",
            "find ", "wc ", "stat ", "file ", "which ", "echo "
        ]
        if internalPrefixes.contains(where: { command.hasPrefix($0) }) {
            return false
        }
        return true
    }

    private func formattedFallbackSummary(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        if text.contains("```") { return text }
        guard let language = likelyCodeLanguage(in: text) else { return text }
        return "```\(language)\n\(text)\n```"
    }

    private func likelyCodeLanguage(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("<?xml") || trimmed.hasPrefix("<") {
            return "xml"
        }
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return "json"
        }
        if trimmed.contains("import SwiftUI") || trimmed.contains("struct ") || trimmed.contains("func ") {
            return "swift"
        }
        if trimmed.contains("fun ") || trimmed.contains("val ") || trimmed.contains("android:") {
            return "kotlin"
        }
        if trimmed.contains("def ") || trimmed.contains("import ") {
            return "python"
        }
        return nil
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

    private func authorizationPathIfNeeded(
        result: ToolExecutionResult,
        invocation: ToolInvocation,
        promptedPaths: Set<String>
    ) -> String? {
        guard result.status == .failed else { return nil }

        let output = result.output.lowercased()
        let isPermissionIssue =
            output.contains("denied:") ||
            output.contains("路径越界") ||
            output.contains("拒绝访问") ||
            output.contains("operation not permitted") ||
            output.contains("permission denied")
        guard isPermissionIssue else { return nil }
        guard let rawPath = requestedPath(from: invocation) else { return nil }

        let normalized = SafetyGuard.normalize(rawPath)
        guard normalized.hasPrefix("/") else { return nil }
        guard !promptedPaths.contains(normalized) else { return nil }
        return normalized
    }

    private func commandApprovalIfNeeded(
        result: ToolExecutionResult,
        invocation: ToolInvocation,
        tools: AgentTools
    ) -> ApprovalRequest? {
        guard invocation.tool == .runCommand else { return nil }
        guard result.status == .failed else { return nil }
        guard result.output.hasPrefix("DENIED:") else { return nil }
        guard let rawCommand = invocation.arguments["command"]?.stringValue else { return nil }

        let override = tools.overrideCommandAction(from: rawCommand)
        guard case .success(let action) = override else { return nil }

        return ApprovalRequest(
            id: UUID(),
            tool: invocation.tool,
            title: "命令被执行策略拦截",
            summary: rawCommand,
            detail: """
当前命令没有自动执行，原因：
\(result.output)

如果你确认这是本次任务必须执行的命令，可以选择继续。客户端只会放行这一次，不会永久修改安全规则。
""",
            confirmTitle: "继续执行这一次",
            intent: .execute(action),
            change: nil
        )
    }

    private func requestAuthorizationIfNeeded(for normalizedPath: String, tool: AgentTool) async -> Bool {
        runPhaseTitle = "等待你处理权限"
        runPhaseDetail = "目标路径当前无权限，需要你授权后我再继续当前步骤"
        touch()

        let request = ApprovalRequest(
            id: UUID(),
            tool: tool,
            title: "需要你授权目标目录",
            summary: normalizedPath,
            detail: """
当前步骤需要访问这个绝对路径，但它不在当前工作区或已授权范围内。

继续后会打开系统目录选择面板。你选中对应目录并授权后，客户端会自动续跑当前步骤。
""",
            confirmTitle: "继续授权",
            intent: .authorizePath(normalizedPath),
            change: nil
        )

        let approved = await requestApproval(request)
        guard approved else { return false }

        let granted = requestAuthorization(for: normalizedPath)
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
        let targetDirectory: String
        if exists, isDirectory.boolValue {
            targetDirectory = path
        } else {
            targetDirectory = (path as NSString).deletingLastPathComponent
        }

        let panel = NSOpenPanel()
        panel.prompt = "授权"
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = "请选择要授予读写权限的目标目录。授权后会自动续跑当前步骤。"
        panel.directoryURL = URL(fileURLWithPath: targetDirectory)

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
