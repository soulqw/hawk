import SwiftUI

/// 二级日志面板：主界面保持简洁，这里专门用于回溯模型与工具的执行过程。
struct LogCenterView: View {
    @Bindable var vm: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .navigationTitle("运行日志")
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("回溯模型与工具的执行过程")
                    .font(.headline)
                Text("这里会保留当前会话中的提示、工具调用、验证输出和最终结果。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if vm.isRunning {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(vm.runPhaseTitle)
                            .font(.caption.weight(.semibold))
                        Text(vm.runPhaseDetail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .background(.bar)
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if vm.transcript.isEmpty {
                    emptyState
                } else {
                    ForEach(Array(vm.transcript.enumerated()), id: \.element.id) { offset, item in
                        LogRow(index: offset + 1, item: item)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("当前还没有日志", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                .font(.title3.weight(.semibold))
            Text("等你发送任务后，这里会显示模型回复、工具调用、命令执行和最终结果。")
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 24)
    }
}

private struct LogRow: View {
    let index: Int
    let item: TranscriptItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(String(format: "%02d", index))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 28, alignment: .trailing)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 8) {
                switch item.kind {
                case .user(let text):
                    logCard(
                        title: "用户输入",
                        symbol: "person.fill",
                        tint: .accentColor,
                        text: text,
                        monospaced: false
                    )
                case .assistant(let text):
                    logCard(
                        title: "模型回复",
                        symbol: "cpu",
                        tint: .secondary,
                        text: text,
                        monospaced: false
                    )
                case .thinking(let text):
                    logCard(
                        title: "思考",
                        symbol: "brain",
                        tint: .secondary,
                        text: text,
                        monospaced: false
                    )
                case .notice(let text):
                    logCard(
                        title: "系统提示",
                        symbol: "info.circle",
                        tint: .orange,
                        text: text,
                        monospaced: false
                    )
                case .error(let text):
                    logCard(
                        title: "错误",
                        symbol: "exclamationmark.triangle.fill",
                        tint: .red,
                        text: text,
                        monospaced: false
                    )
                case .summary(let text):
                    logCard(
                        title: "最终结果",
                        symbol: "checkmark.seal.fill",
                        tint: .green,
                        text: text,
                        monospaced: false
                    )
                case .tool(let run):
                    VStack(alignment: .leading, spacing: 6) {
                        Text("工具调用")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ToolCard(run: run)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func logCard(
        title: String,
        symbol: String,
        tint: Color,
        text: String,
        monospaced: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)

            Text(text)
                .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(tint.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(tint.opacity(0.18), lineWidth: 1)
                )
        }
    }
}
