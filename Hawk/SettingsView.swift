import SwiftUI

/// 右侧检视器：所有可调参数集中在这里。
struct SettingsView: View {
    @Bindable var vm: AppViewModel

    var body: some View {
        Form {
            serviceSection
            runSection
            workspaceSection
            safetySection
        }
        .formStyle(.grouped)
        .navigationTitle("设置")
    }

    // MARK: - 推理服务

    private var serviceSection: some View {
        Section("推理服务") {
            Picker("预设", selection: $vm.providerID) {
                ForEach(ProviderPreset.all) { preset in
                    Text(preset.name).tag(preset.id)
                }
            }
            .onChange(of: vm.providerID) { _, newValue in
                let preset = ProviderPreset.preset(for: newValue)
                if vm.baseURL.isEmpty || ProviderPreset.all.contains(where: { $0.baseURL == vm.baseURL }) {
                    vm.baseURL = preset.baseURL
                    vm.apiKey = preset.apiKey
                }
            }

            TextField("服务地址", text: $vm.baseURL, prompt: Text(ProviderPreset.preset(for: vm.providerID).baseURL))
                .font(.system(size: 12, design: .monospaced))
            Text("留空则使用预设地址。必须兼容 OpenAI 的 /v1/chat/completions。")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("API Key", text: $vm.apiKey, prompt: Text(ProviderPreset.preset(for: vm.providerID).apiKey))
                .font(.system(size: 12, design: .monospaced))

            HStack {
                TextField("模型", text: $vm.model)
                    .font(.system(size: 12, design: .monospaced))
                Menu {
                    if vm.availableModels.isEmpty {
                        Text("点「刷新」获取模型列表")
                    } else {
                        ForEach(vm.availableModels, id: \.self) { name in
                            Button(name) { vm.model = name }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button {
                    vm.refreshModels()
                } label: {
                    if vm.isRefreshingModels {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(vm.isRefreshingModels)
            }

            Text(vm.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 运行参数

    private var runSection: some View {
        Section("运行参数") {
            Picker("工具调用方言", selection: $vm.dialect) {
                ForEach(ToolDialect.allCases) { item in
                    Text(item.label).tag(item)
                }
            }
            Text(vm.dialect.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)

            Stepper(value: $vm.maxSteps, in: 1...100) {
                Text("最大步数：\(vm.maxSteps)")
            }
            Text("模型连续调用工具的轮数上限，防止死循环。")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading) {
                HStack {
                    Text("温度")
                    Spacer()
                    Text(String(format: "%.1f", vm.temperature))
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12, design: .monospaced))
                }
                Slider(value: $vm.temperature, in: 0...1.5, step: 0.1)
            }

            Stepper(value: $vm.timeout, in: 30...1800, step: 30) {
                Text("请求超时：\(Int(vm.timeout)) 秒")
            }
        }
    }

    // MARK: - 工作区

    private var workspaceSection: some View {
        Section("工作区") {
            if vm.workspacePath.isEmpty {
                Text("尚未选择")
                    .foregroundStyle(.secondary)
            } else {
                Text(vm.workspacePath)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
            }
            Button {
                vm.chooseWorkspace()
            } label: {
                Label("选择文件夹…", systemImage: "folder")
            }
            Text("Agent 的全部读写都被限制在这个目录内，越界会被拒绝。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 安全

    private var safetySection: some View {
        Section("安全") {
            Toggle("允许写入文件", isOn: $vm.allowWrite)
            Text("关闭写入即进入只读模式；开启写入后，改文件与跑命令会直接执行。")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("追加放行的命令（每行一条）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $vm.extraAllowedText)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 64)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
                Text("例如：gradlew、adb、./gradlew")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("追加的危险命令正则（每行一条）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $vm.extraDangerousText)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 64)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
            }

            Button("恢复默认设置") { vm.resetToDefaults() }
        }
    }
}
