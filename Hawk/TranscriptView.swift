import SwiftUI

// MARK: - 转录列表

/// 中间栏主体：把 `TranscriptItem` 序列渲染成对话流。
struct TranscriptView: View {
    @Bindable var vm: AppViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if vm.transcript.isEmpty && !vm.isRunning {
                        EmptyHint()
                    }
                    ForEach(vm.transcript) { item in
                        row(item).id(item.id)
                    }
                    if vm.isRunning {
                        ProgressStatusCard(title: vm.runPhaseTitle, detail: vm.runPhaseDetail)
                            .id("running-status")
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: vm.scrollTick) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    if vm.isRunning {
                        proxy.scrollTo("running-status", anchor: .bottom)
                    } else if let last = vm.transcript.last?.id {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private func row(_ item: TranscriptItem) -> some View {
        switch item.kind {
        case .user(let text):
            MessageBubble(text: text, roleTitle: "你", symbol: "person.fill", tint: .accentColor, alignTrailing: true)
        case .assistant(let text):
            MessageBubble(text: text, roleTitle: "模型", symbol: "cpu", tint: .secondary, alignTrailing: false)
        case .thinking:
            EmptyView()
        case .tool:
            EmptyView()
        case .notice:
            EmptyView()
        case .error(let text):
            ResultCard(title: "执行失败", text: text, tint: .red, isError: true)
        case .summary(let text):
            ResultCard(title: "执行结果", text: text, tint: .green, isError: false)
        }
    }
}

private struct EmptyHint: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("本地模型客户端", systemImage: "sparkles")
                .font(.title3.weight(.semibold))
            Text("在左侧选择工作区，必要时打开设置，然后直接发送你的需求。")
                .foregroundStyle(.secondary)
            Text("执行过程中不会刷出内部工具细节，只展示当前状态和最后的结果。涉及写文件或执行命令时，仍然会向你确认。")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 32)
    }
}

// MARK: - 气泡

private struct MessageBubble: View {
    let text: String
    let roleTitle: String
    let symbol: String
    let tint: Color
    let alignTrailing: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if alignTrailing { Spacer(minLength: 60) }

            if alignTrailing {
                content
            } else {
                avatar
                content
                Spacer(minLength: 60)
            }

            if alignTrailing { avatar }
        }
    }

    private var avatar: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 24, height: 24)
            .background(Circle().fill(tint.opacity(0.12)))
    }

    private var content: some View {
        VStack(alignment: alignTrailing ? .trailing : .leading, spacing: 4) {
            Text(roleTitle)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(tint.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(tint.opacity(0.22), lineWidth: 1)
                )
        }
    }
}

private struct NoticeRow: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.08)))
    }
}

private struct ProgressStatusCard: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ProgressView()
                .controlSize(.small)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 1)
        )
    }
}

private struct ResultCard: View {
    let title: String
    let text: String
    let tint: Color
    let isError: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: isError ? "xmark.octagon.fill" : "checkmark.seal.fill")
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
            }

            ForEach(ResultBlock.parse(text)) { block in
                switch block.kind {
                case .text(let content):
                    textBlock(content)
                case .code(let content, let language):
                    codeBlock(content, language: language)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.22), lineWidth: 1))
    }

    @ViewBuilder
    private func textBlock(_ content: String) -> some View {
        let paragraphs = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                if isBullet(paragraph) {
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(tint)
                            .frame(width: 5, height: 5)
                            .padding(.top, 6)
                        Text(cleanBullet(paragraph))
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text(paragraph)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func codeBlock(_ content: String, language: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(language?.isEmpty == false ? language! : "代码片段", systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            ScrollView(.horizontal) {
                Text(content)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        }
    }

    private func isBullet(_ text: String) -> Bool {
        text.hasPrefix("- ") || text.hasPrefix("* ") || text.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil
    }

    private func cleanBullet(_ text: String) -> String {
        if text.hasPrefix("- ") || text.hasPrefix("* ") {
            return String(text.dropFirst(2))
        }
        return text.replacingOccurrences(of: #"^\d+\.\s+"#, with: "", options: .regularExpression)
    }
}

private struct ResultBlock: Identifiable {
    enum Kind {
        case text(String)
        case code(String, language: String?)
    }

    let id = UUID()
    let kind: Kind

    static func parse(_ text: String) -> [ResultBlock] {
        let parts = text.components(separatedBy: "```")
        guard parts.count > 1 else {
            return [.init(kind: .text(text.trimmingCharacters(in: .whitespacesAndNewlines)))]
        }

        var blocks: [ResultBlock] = []
        for (index, part) in parts.enumerated() {
            if index.isMultiple(of: 2) {
                let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    blocks.append(.init(kind: .text(trimmed)))
                }
            } else {
                let lines = part.components(separatedBy: "\n")
                let language = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines)
                let body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty {
                    blocks.append(.init(kind: .code(body, language: language)))
                }
            }
        }
        return blocks.isEmpty ? [.init(kind: .text(text))] : blocks
    }
}

// MARK: - 工具调用卡片

struct ToolCard: View {
    let run: ToolRun
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if expanded { detail }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(borderColor, lineWidth: 1)
        )
    }

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .foregroundStyle(.tertiary)

                Image(systemName: run.tool.symbolName)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                Text(run.tool.displayName)
                    .font(.system(size: 12, weight: .semibold))

                Text(run.summary.isEmpty ? run.argumentsText : run.summary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                if let change = run.change, change.addedLines > 0 || change.removedLines > 0 {
                    Text("+\(change.addedLines)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.green)
                    Text("-\(change.removedLines)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.red)
                }

                statusBadge
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            if run.status == .running || run.status == .waitingApproval {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: run.status.symbolName)
            }
            Text(run.status.label)
                .font(.caption2)
        }
        .foregroundStyle(statusColor)
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let change = run.change {
                DiffView(change: change)
            }
            if !run.output.isEmpty {
                ScrollView {
                    Text(run.output)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 220)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            }
        }
    }

    private var statusColor: Color {
        switch run.status {
        case .running: return .secondary
        case .waitingApproval: return .orange
        case .succeeded: return .green
        case .failed: return .red
        case .denied: return .orange
        }
    }

    private var borderColor: Color {
        switch run.status {
        case .waitingApproval: return .orange.opacity(0.45)
        case .failed: return .red.opacity(0.35)
        default: return Color.primary.opacity(0.10)
        }
    }
}

// MARK: - Diff

/// 行级差异视图：绿色新增、红色删除、灰色上下文。
struct DiffView: View {
    let change: FileChange

    var body: some View {
        let lines = change.diffLines
        let added = lines.filter { $0.kind == .inserted }.count
        let removed = lines.filter { $0.kind == .removed }.count

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(.secondary)
                Text(change.path)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                if change.isNewFile {
                    Text("新文件")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.green.opacity(0.16)))
                }
                Spacer(minLength: 8)
                Text("+\(added)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.green)
                Text("-\(removed)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.red)
            }

            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        row(line)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .textSelection(.enabled)
        }
    }

    private func row(_ line: DiffLine) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(line.oldNumber.map(String.init) ?? "")
                .frame(width: 36, alignment: .trailing)
                .foregroundStyle(.tertiary)
            Text(line.newNumber.map(String.init) ?? "")
                .frame(width: 36, alignment: .trailing)
                .foregroundStyle(.tertiary)

            Text(marker(line.kind))
                .frame(width: 14)
                .foregroundStyle(markerColor(line.kind))

            Text(line.text.isEmpty ? " " : line.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.primary)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.vertical, 1)
        .padding(.horizontal, 6)
        .background(background(line.kind))
    }

    private func marker(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .inserted: return "+"
        case .removed: return "-"
        case .context: return " "
        }
    }

    private func markerColor(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .inserted: return .green
        case .removed: return .red
        case .context: return .secondary
        }
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .inserted: return .green.opacity(0.13)
        case .removed: return .red.opacity(0.13)
        case .context: return .clear
        }
    }
}
