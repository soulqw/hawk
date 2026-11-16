import SwiftUI

struct SkillsView: View {
    @Bindable var vm: AppViewModel
    @State private var selection: RegisteredSkill.ID?

    private var selectedSkill: RegisteredSkill? {
        guard let selection else { return vm.availableSkills.first }
        return vm.availableSkills.first(where: { $0.id == selection }) ?? vm.availableSkills.first
    }

    private var groupedSkills: [(key: String, value: [RegisteredSkill])] {
        Dictionary(grouping: vm.availableSkills, by: \.source)
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
    }

    private var mountStatuses: [SkillMountStatus] {
        vm.skillMountStatuses
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("当前工作空间") {
                    infoRow(
                        title: "当前可用 Skill",
                        value: "\(vm.availableSkills.count) 个",
                        symbol: "sparkles.rectangle.stack"
                    )
                    infoRow(
                        title: "项目内已挂载",
                        value: "\(vm.workspaceMountedSkillCount) 个",
                        symbol: "folder.badge.gearshape"
                    )
                    infoRow(
                        title: "当前上传目录",
                        value: "\(vm.currentUploadTargetSkillCount) 个",
                        symbol: "square.and.arrow.up"
                    )

                    if let projectPath = vm.projectSkillsPath {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("项目 Skill 目录")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(projectPath)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    }
                }

                Section("挂载操作") {
                    Button {
                        vm.useProjectSkillsLibrary()
                    } label: {
                        Label("把上传目录切到当前工作空间", systemImage: "scope")
                    }

                    Button {
                        vm.uploadSkillsToWorkspace()
                    } label: {
                        Label("导入 Skill 到当前工作空间", systemImage: "square.and.arrow.down.on.square")
                    }

                    Button {
                        vm.uploadSkills()
                    } label: {
                        Label("上传到当前目录", systemImage: "square.and.arrow.up")
                    }

                    Button {
                        vm.chooseCustomSkill()
                    } label: {
                        Label("引用外部目录（全局）", systemImage: "link.badge.plus")
                    }

                    Menu {
                        Button("指定上传目录…") { vm.chooseSkillsLibrary() }
                        Button("恢复默认位置") { vm.useDefaultSkillsLibrary() }
                        Button("打开当前目录") { vm.revealSkillsLibrary() }
                    } label: {
                        Label("管理上传目录", systemImage: "folder.badge.gearshape")
                    }
                }

                if !mountStatuses.isEmpty {
                    Section("已挂载来源") {
                        ForEach(mountStatuses) { status in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(status.title)
                                        .font(.caption.weight(.semibold))
                                    Text("\(status.count) 个")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if status.isWorkspaceScoped {
                                        badge("工作空间")
                                    }
                                    if status.isCurrentUploadTarget {
                                        badge("当前目录")
                                    }
                                }
                                Text(status.path)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                ForEach(groupedSkills, id: \.key) { group in
                    Section(group.key) {
                        ForEach(group.value) { skill in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(skill.name)
                                    .font(.body.weight(.medium))
                                Text(skill.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .tag(skill.id)
                        }
                    }
                }
            }
            .navigationTitle("Skills")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        vm.refreshSkills()
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .help("重新扫描所有已挂载的 Skill 来源")
                }
            }
            .overlay {
                if vm.availableSkills.isEmpty && !vm.isRefreshingSkills {
                    ContentUnavailableView(
                        "当前没有发现 Skill",
                        systemImage: "sparkles.rectangle.stack",
                        description: Text("先决定要把 Skill 挂到当前工作空间，还是只做全局引用；上面「挂载操作」里的按钮就是入口。")
                    )
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 10))
                    Text(vm.resolvedSkillsLibraryPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button("打开") { vm.revealSkillsLibrary() }
                        .buttonStyle(.link)
                        .font(.system(size: 10))
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
            }
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    mountOverview

                    Divider()

                    if let skill = selectedSkill {
                        skillDetail(skill)
                    } else {
                        ContentUnavailableView(
                            "请选择一个 Skill",
                            systemImage: "sparkles.rectangle.stack",
                            description: Text("左边会按来源列出当前工作空间实际能用到的 Skill。")
                        )
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(selectedSkill?.name ?? "Skill 详情")
        }
        .onAppear {
            if selection == nil {
                selection = vm.availableSkills.first?.id
            }
        }
        .onChange(of: vm.availableSkills) { _, newValue in
            if selection == nil || !newValue.contains(where: { $0.id == selection }) {
                selection = newValue.first?.id
            }
        }
    }

    private var mountOverview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("当前挂载概览")
                .font(.title3.weight(.semibold))

            Text("这里显示的是当前工作空间实际会参与加载的 Skill 来源，不只是文件浏览。")
                .foregroundStyle(.secondary)

            HStack(spacing: 24) {
                metric(title: "当前可用", value: "\(vm.availableSkills.count)")
                metric(title: "项目挂载", value: "\(vm.workspaceMountedSkillCount)")
                metric(title: "当前目录", value: "\(vm.currentUploadTargetSkillCount)")
            }

            if mountStatuses.isEmpty {
                Text("还没有挂载来源。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(mountStatuses) { status in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: status.isWorkspaceScoped ? "scope" : "shippingbox")
                                        .foregroundStyle(status.isWorkspaceScoped ? Color.accentColor : Color.secondary)
                                .frame(width: 18)

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(status.title)
                                        .font(.callout.weight(.medium))
                                    Text("\(status.count) 个 Skill")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if status.isWorkspaceScoped {
                                        badge("工作空间")
                                    }
                                    if status.isCurrentUploadTarget {
                                        badge("当前上传目录")
                                    }
                                }
                                Text(status.path)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }

                            Spacer()
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                    }
                }
            }
        }
    }

    private func skillDetail(_ skill: RegisteredSkill) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(skill.name)
                    .font(.title2.weight(.semibold))
                Text(skill.summary)
                    .foregroundStyle(.secondary)
                LabeledContent("来源", value: skill.source)
                LabeledContent("路径", value: skill.path)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
            }

            Divider()

            Text(skill.content)
                .font(.system(size: 13, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func infoRow(title: String, value: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(title)
                .font(.caption)
            Spacer()
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
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

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            .foregroundStyle(Color.accentColor)
    }
}
