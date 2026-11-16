import SwiftUI

/// 二级面板：上下文管理。
///
/// 三块内容：
///   1. 缓存池配置（轮数上限 / 字符预算 / 自动裁剪），决定每轮会带多少历史给模型；
///   2. 实时用量（轮数、字符、估算 token、预算占比）；
///   3. 会话回溯（历史会话列表，可切回继续、可删除、可清空当前上下文）。
struct ContextView: View {
    @Bindable var vm: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    bootstrapSection
                    usageSection
                    budgetSection
                    sessionsSection
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            Divider()
            footer
        }
        .navigationTitle("上下文管理")
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("上下文缓存池")
                    .font(.headline)
                Text("像聊天一样保留历史记录，并控制在每轮任务里带多少上下文给模型。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                vm.clearContext()
            } label: {
                Label("清空上下文", systemImage: "eraser")
            }
            .disabled(vm.isRunning || vm.transcript.isEmpty)
            .help("清空当前会话的聊天记录与执行日志")

            Button {
                vm.startNewSession()
            } label: {
                Label("新建会话", systemImage: "square.and.pencil")
            }
            .disabled(vm.isRunning)
            .help("归档当前会话并开启一个新的上下文")
        }
        .padding(16)
        .background(.bar)
    }

    // MARK: - 会话启动装载

    private var bootstrapSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("会话启动装载", symbol: "shippingbox")

            Text("每次发送任务前，客户端都会按这里的装载结果把记忆、技能与上下文交给模型。")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Label("记忆", systemImage: "brain")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Text(vm.loadedMemoryFiles.isEmpty ? "未装载" : "\(vm.loadedMemoryFiles.count) 个文件")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Button("打开全局记忆") { vm.openGlobalMemory() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }

                if vm.loadedMemoryFiles.isEmpty {
                    Text("还没有记忆文件。全局位置：\(vm.globalMemoryPath)；项目内可放 AGENTS.md 或 .hawk/memory.md。")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                } else {
                    ForEach(vm.loadedMemoryFiles) { file in
                        Button {
                            vm.revealMemory(file)
                        } label: {
                            HStack(spacing: 8) {
                                Text(file.title)
                                    .font(.system(size: 11, weight: .medium))
                                Text(file.path)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                Divider()

                HStack(spacing: 8) {
                    Label("技能", systemImage: "sparkles.rectangle.stack")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Text("\(vm.availableSkills.count) 个已挂载")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Divider()

                HStack(spacing: 8) {
                    Label("上下文", systemImage: "text.bubble")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Text("\(vm.contextUsage.activeTurns) / \(vm.contextUsage.totalTurns) 轮带入模型")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        }
    }

    // MARK: - 用量

    private var usageSection: some View {
        let usage = vm.contextUsage

        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle("当前用量", symbol: "gauge.with.dots.needle.33percent")

            HStack(spacing: 24) {
                metric(title: "历史轮次", value: "\(usage.totalTurns)")
                metric(title: "带入模型", value: "\(usage.activeTurns)")
                metric(title: "字符数", value: "\(usage.characters)")
                metric(title: "估算 token", value: "≈ \(usage.estimatedTokens)")
                metric(title: "已裁剪", value: "\(usage.trimmedTurns)")
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("预算占用")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(usage.characters) / \(usage.charBudget) 字符")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: usage.usageRatio)
                    .tint(usage.usageRatio > 0.9 ? .orange : .accentColor)
            }

            if usage.trimmedTurns > 0 {
                Label(
                    "有 \(usage.trimmedTurns) 轮较早的历史因超出预算未带入模型。",
                    systemImage: "scissors"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 缓存池配置

    private var budgetSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("缓存池配置", symbol: "slider.horizontal.3")

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("最多带入的历史轮数")
                            .font(.callout)
                        Spacer()
                        Text(vm.contextTurnLimit == 0 ? "不限制" : "\(vm.contextTurnLimit) 轮")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Stepper(
                        "",
                        value: $vm.contextTurnLimit,
                        in: 0...50
                    )
                    .labelsHidden()
                    .help("0 表示不限制轮数，仅受字符预算约束")
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("历史字符预算")
                            .font(.callout)
                        Spacer()
                        Text("\(vm.contextCharBudget) 字符")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(vm.contextCharBudget) },
                            set: { vm.contextCharBudget = Int($0.rounded()) }
                        ),
                        in: 2000...64000,
                        step: 1000
                    )
                    .help("超出预算时按最早的对话开始裁剪")
                }

                Toggle("超出预算时自动裁剪更早的历史", isOn: $vm.autoTrimContext)
                    .toggleStyle(.switch)
                    .font(.callout)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        }
    }

    // MARK: - 会话回溯

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("会话记录", symbol: "clock.arrow.trianglehead.counterclockwise.rotate.90")

            let sessions = vm.allSessions
            if sessions.isEmpty {
                Text("还没有会话记录。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { offset, session in
                        if offset > 0 { Divider() }
                        sessionRow(session, isCurrent: session.id == vm.session.id)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
            }
        }
    }

    private func sessionRow(_ session: ConversationSession, isCurrent: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: isCurrent ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(session.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if isCurrent {
                        Text("当前")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text("\(session.turnCount) 轮 · \(session.characterCount) 字符 · \(formatted(session.updatedAt))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !isCurrent {
                Button {
                    vm.loadSession(session)
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                }
                .buttonStyle(.borderless)
                .disabled(vm.isRunning)
                .help("切换到这个会话继续")

                Button {
                    vm.deleteSession(session)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .disabled(vm.isRunning)
                .help("删除这个会话")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - 底部

    private var footer: some View {
        Text("会话存储位置：\(vm.sessionsRoot)")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
    }

    // MARK: - 小组件

    private func sectionTitle(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func metric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 72, alignment: .leading)
    }

    private func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
