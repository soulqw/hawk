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

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
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

                    Button {
                        vm.chooseCustomSkill()
                    } label: {
                        Label("添加 Skill", systemImage: "plus")
                    }
                }
            }
            .overlay {
                if vm.availableSkills.isEmpty && !vm.isRefreshingSkills {
                    ContentUnavailableView(
                        "还没有可展示的 Skill",
                        systemImage: "sparkles.rectangle.stack",
                        description: Text("你可以先点击右上角添加，或选择工作区后刷新列表。")
                    )
                }
            }
        } detail: {
            if let skill = selectedSkill {
                ScrollView {
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
                    .padding(20)
                }
                .navigationTitle(skill.name)
            } else {
                ContentUnavailableView(
                    "请选择一个 Skill",
                    systemImage: "sparkles.rectangle.stack",
                    description: Text("左侧会列出当前客户端已经发现的技能。")
                )
            }
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
}
