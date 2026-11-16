import AppKit
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
                .textSelection(.enabled)
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
        case .assistant:
            // 模型中间过程属于内部细节，只在日志中心可见。
            EmptyView()
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
            Text("执行过程中只展示当前状态，结束后给出结果摘要；完整过程可在「查看日志」里回溯。")
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
            HStack(spacing: 6) {
                if alignTrailing { CopyButton(text: text) }
                Text(roleTitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                if !alignTrailing { CopyButton(text: text) }
            }
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
                CopyButton(text: text)
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
                if let fileResult = parseFileResult(paragraph) {
                    FileResultRow(action: fileResult.action, path: fileResult.path, tint: tint)
                } else if isSectionTitle(paragraph) {
                    Text(paragraph)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if isBullet(paragraph) {
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
        CodeBlockView(content: content, language: language)
    }

    private func isSectionTitle(_ text: String) -> Bool {
        text.hasSuffix("：") && !isBullet(text)
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

    private func parseFileResult(_ text: String) -> (action: String, path: String)? {
        let cleaned = cleanBullet(text)
        let patterns = ["已创建", "已修改"]
        for pattern in patterns {
            let prefix = "\(pattern)："
            if cleaned.hasPrefix(prefix) {
                let path = String(cleaned.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard path.hasPrefix("/") else { return nil }
                return (pattern, path)
            }
        }
        return nil
    }

}

private struct FileResultRow: View {
    let action: String
    let path: String
    let tint: Color

    private var fileName: String { URL(fileURLWithPath: path).lastPathComponent }

    var body: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "doc.text.fill")
                    .foregroundStyle(tint)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text("\(action)：\(fileName)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(2)
                }

                Text("定位")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(tint.opacity(0.14), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("在 Finder 中定位这个文件")
    }
}

/// 一键复制：整段内容进剪贴板，避免只能逐块选中。
struct CopyButton: View {
    let text: String
    var title: String = "复制"
    var helpText: String = "复制全部内容"
    @State private var copied = false

    var body: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                copied = false
            }
        } label: {
            Label(copied ? "已复制" : title, systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.caption2)
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.plain)
        .foregroundStyle(copied ? Color.green : Color.secondary)
        .help(helpText)
    }
}

private struct CodeBlockView: View {
    let content: String
    let language: String?

    private var displayedLanguage: String {
        let trimmed = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "代码片段" : trimmed
    }

    private var highlightedText: AttributedString {
        CodeSyntaxHighlighter.highlight(content, language: language)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(displayedLanguage, systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                CopyButton(text: content, title: "复制代码", helpText: "复制这段代码")
            }

            ScrollView(.horizontal) {
                Text(highlightedText)
                    .textSelection(.enabled)
                    .font(.system(size: 12, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        }
    }
}

private enum CodeSyntaxHighlighter {
    static func highlight(_ code: String, language: String?) -> AttributedString {
        let ns = NSMutableAttributedString(string: code)
        let fullRange = NSRange(location: 0, length: ns.length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.12

        ns.addAttributes([
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ], range: fullRange)

        if inferredLanguage(language, code: code) == "xml" {
            applyXMLHighlights(to: ns, code: code)
        } else {
            applyGenericHighlights(to: ns, code: code, language: inferredLanguage(language, code: code))
        }

        return AttributedString(ns)
    }

    private static func inferredLanguage(_ language: String?, code: String) -> String {
        let trimmed = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if !trimmed.isEmpty { return trimmed }

        let sample = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if sample.hasPrefix("<?xml") || sample.hasPrefix("<") { return "xml" }
        if sample.contains("import SwiftUI") || sample.contains("let ") || sample.contains("var ") { return "swift" }
        if sample.contains("public class ") || sample.contains("System.out.println") { return "java" }
        if sample.contains("fun ") || sample.contains("val ") { return "kotlin" }
        if sample.contains("def ") || sample.contains("print(") { return "python" }
        if sample.hasPrefix("{") || sample.hasPrefix("[") { return "json" }
        return "plain"
    }

    private static func applyGenericHighlights(to text: NSMutableAttributedString, code: String, language: String) {
        let keywordSets: [String: [String]] = [
            "swift": ["import", "struct", "class", "enum", "protocol", "extension", "func", "let", "var", "if", "else", "guard", "return", "for", "in", "while", "switch", "case", "default", "private", "fileprivate", "internal", "public", "open", "static", "async", "await", "throw", "throws", "try", "nil", "true", "false"],
            "java": ["package", "import", "public", "private", "protected", "class", "interface", "enum", "static", "final", "void", "int", "long", "float", "double", "boolean", "char", "new", "return", "if", "else", "for", "while", "switch", "case", "break", "continue", "try", "catch", "throws", "throw", "null", "true", "false", "this"],
            "kotlin": ["package", "import", "class", "interface", "object", "data", "fun", "val", "var", "if", "else", "when", "for", "while", "return", "null", "true", "false", "private", "public", "internal", "protected", "override", "suspend", "try", "catch", "throw", "this"],
            "python": ["import", "from", "class", "def", "return", "if", "elif", "else", "for", "while", "in", "is", "not", "and", "or", "None", "True", "False", "try", "except", "finally", "with", "as", "pass", "break", "continue"],
            "json": [],
            "plain": []
        ]

        let keywords = keywordSets[language] ?? []
        if !keywords.isEmpty {
            let pattern = "\\b(" + keywords.joined(separator: "|") + ")\\b"
            apply(pattern: pattern, in: code, to: text, color: .systemPurple)
        }

        apply(pattern: #"(?<!\w)[A-Z][A-Za-z0-9_]*"#, in: code, to: text, color: .systemTeal)
        apply(pattern: #"\b\d+(\.\d+)?\b"#, in: code, to: text, color: .systemOrange)
        apply(pattern: #""(?:\\.|[^"\\])*""#, in: code, to: text, color: .systemRed)
        apply(pattern: #"'(?:\\.|[^'\\])*'"#, in: code, to: text, color: .systemRed)
        apply(pattern: #"@[A-Za-z_][A-Za-z0-9_]*"#, in: code, to: text, color: .systemBlue)

        switch language {
        case "python":
            apply(pattern: #"(?m)#.*$"#, in: code, to: text, color: .systemGreen)
        default:
            apply(pattern: #"(?m)//.*$"#, in: code, to: text, color: .systemGreen)
            apply(pattern: #"/\*[\s\S]*?\*/"#, in: code, to: text, color: .systemGreen)
        }
    }

    private static func applyXMLHighlights(to text: NSMutableAttributedString, code: String) {
        apply(pattern: #"<!--[\s\S]*?-->"#, in: code, to: text, color: .systemGreen)
        apply(pattern: #"</?[A-Za-z_:][A-Za-z0-9_.:-]*"#, in: code, to: text, color: .systemBlue)
        apply(pattern: #"\s[A-Za-z_:][A-Za-z0-9_.:-]*(?=\=)"#, in: code, to: text, color: .systemPurple)
        apply(pattern: #""[^"]*""#, in: code, to: text, color: .systemRed)
    }

    private static func apply(pattern: String, in code: String, to text: NSMutableAttributedString, color: NSColor) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        for match in regex.matches(in: code, options: [], range: range) {
            text.addAttribute(.foregroundColor, value: color, range: match.range)
        }
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
