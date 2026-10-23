import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var vm = AppViewModel()
    @State private var showingSettings = false
    @State private var showingLogs = false
    @State private var showingSkills = false

    var body: some View {
        NavigationSplitView {
            SidebarView(
                vm: vm,
                onOpenSettings: { showingSettings = true },
                onOpenLogs: { showingLogs = true },
                onOpenSkills: { showingSkills = true }
            )
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 320)
        } detail: {
            mainColumn
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView(vm: vm)
                    .frame(minWidth: 560, minHeight: 620)
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button("完成") { showingSettings = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showingLogs) {
            NavigationStack {
                LogCenterView(vm: vm)
                    .frame(minWidth: 760, minHeight: 620)
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button("完成") { showingLogs = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showingSkills) {
            NavigationStack {
                SkillsView(vm: vm)
                    .frame(minWidth: 860, minHeight: 620)
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button("完成") { showingSkills = false }
                        }
                    }
            }
        }
        .onChange(of: vm.settings) { _, _ in vm.saveSettings() }
        .onAppear {
            vm.refreshModels()
            vm.refreshSkills()
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    vm.newSession()
                } label: {
                    Label("新建会话", systemImage: "square.and.pencil")
                }
                .disabled(vm.isRunning)
                .help("清空当前转录，开始新任务")

                if vm.isRunning {
                    Button {
                        vm.stop()
                    } label: {
                        Label("停止", systemImage: "stop.fill")
                    }
                    .keyboardShortcut(".", modifiers: .command)
                    .help("中止当前任务（⌘.）")
                }

                Button {
                    vm.refreshModels()
                } label: {
                    Label("刷新模型", systemImage: "arrow.clockwise")
                }
                .disabled(vm.isRefreshingModels)
                .help("重新读取 /v1/models")
            }
        }
    }

    private var mainColumn: some View {
        VStack(spacing: 0) {
            RunHeader(vm: vm)
            Divider()
            TranscriptView(vm: vm)
            Divider()
            Composer(vm: vm)
        }
        .navigationTitle("本地模型客户端")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 顶部状态条

private struct RunHeader: View {
    @Bindable var vm: AppViewModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: vm.isRunning ? "brain" : "brain.head.profile")
                .foregroundStyle(vm.isRunning ? Color.accentColor : Color.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(vm.model)
                    .font(.system(size: 12, weight: .semibold))
                Text(vm.workspacePath.isEmpty ? "未选择工作区" : (vm.workspacePath as NSString).lastPathComponent)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if vm.isRunning {
                Text("第 \(max(vm.stepIndex, 1)) / \(vm.stepTotal) 步")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                ProgressView()
                    .controlSize(.small)
            }

            Text(vm.statusMessage)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

// MARK: - 输入区

private struct Composer: View {
    @Bindable var vm: AppViewModel
    @State private var isDropTargeted = false

    private var canRun: Bool {
        !vm.isRunning
            && !vm.taskInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !vm.workspacePath.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            attachmentBar

            TextEditor(text: $vm.taskInput)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 64, maxHeight: 160)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isDropTargeted ? Color.accentColor.opacity(0.75) : Color.primary.opacity(0.12), lineWidth: isDropTargeted ? 2 : 1)
                )
                .overlay(alignment: .topLeading) {
                    if vm.taskInput.isEmpty {
                        Text("输入你的需求，例如：修复 calc.py 里除以零会导致崩溃的问题，并跑通测试")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 14)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if isDropTargeted {
                        Label("松手即可附加文件并授权模型访问", systemImage: "paperclip.circle.fill")
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                            .padding(10)
                    }
                }
                .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
                    vm.handleDroppedFileProviders(providers)
                }

            HStack(spacing: 10) {
                if vm.workspacePath.isEmpty {
                    Label("先选择工作区", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Text("支持拖拽文件到输入框")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Spacer()

                Text("⌘↩ 发送")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if vm.isRunning {
                    Button("停止") { vm.stop() }
                        .buttonStyle(.bordered)
                }

                Button("发送") { vm.start() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canRun)
            }
        }
        .padding(12)
        .background(.bar)
    }

    private var attachmentBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    vm.chooseAttachments()
                } label: {
                    Label("选择文件", systemImage: "paperclip")
                }
                .buttonStyle(.bordered)
                .disabled(vm.isRunning)

                Text(vm.fileAccessSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()
            }

            if !vm.authorizedItems.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(vm.authorizedItems) { item in
                            HStack(spacing: 6) {
                                Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                                    .foregroundStyle(item.isDirectory ? .orange : .blue)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.name)
                                        .font(.caption.weight(.medium))
                                        .lineLimit(1)
                                    Text(item.path)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Button {
                                    vm.removeAuthorizedItem(id: item.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                                .disabled(vm.isRunning)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                            )
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 侧边栏

private struct SidebarView: View {
    @Bindable var vm: AppViewModel
    let onOpenSettings: () -> Void
    let onOpenLogs: () -> Void
    let onOpenSkills: () -> Void

    var body: some View {
        List {
            Section("工作区") {
                if vm.workspacePath.isEmpty {
                    Text("尚未选择")
                        .foregroundStyle(.secondary)
                } else {
                    Text(vm.workspacePath)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Button {
                    vm.chooseWorkspace()
                } label: {
                    Label("选择文件夹…", systemImage: "folder")
                }
            }

            Section("当前环境") {
                Label(vm.model, systemImage: "cpu")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label(vm.providerID.uppercased(), systemImage: "network")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label(vm.fileAccessSummary, systemImage: "paperclip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Skills") {
                Button(action: onOpenSkills) {
                    Label("打开技能中心", systemImage: "sparkles.rectangle.stack")
                }
                .buttonStyle(.plain)

                Label(vm.skillsSummary, systemImage: "shippingbox")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("更多") {
                Button(action: onOpenLogs) {
                    Label("查看日志", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.plain)

                Button(action: onOpenSettings) {
                    Label("打开设置", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.plain)

                Label("代码改动和命令执行会直接继续处理", systemImage: "bolt.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
    }
}

// MARK: - 人工审批

private struct ApprovalSheet: View {
    let request: ApprovalRequest
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: request.tool.symbolName)
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.title)
                        .font(.headline)
                    Text(request.tool.displayName + (request.summary.isEmpty ? "" : " · \(request.summary)"))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch request.action {
                    case .command(let command):
                        Label("将执行以下命令", systemImage: "terminal")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(command)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))

                    case .write:
                        if let change = request.change {
                            DiffView(change: change)
                        }
                    }
                }
                .padding(16)
            }

            Divider()

            HStack {
                Text("拒绝后模型会收到拒绝结果并尝试其他方案。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("拒绝", role: .cancel) { onDeny() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("允许并执行") { onApprove() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])
            }
            .padding(16)
        }
        .frame(minWidth: 660, minHeight: 460)
        .interactiveDismissDisabled()
    }
}
