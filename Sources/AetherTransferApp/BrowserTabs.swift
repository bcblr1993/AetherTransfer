import SwiftUI
import Combine
import AetherTransferCore

@MainActor final class BrowserTabs: ObservableObject {
    struct Tab: Identifiable {
        let id: UUID
        let workspace: Workspace
    }
    @Published var tabs: [Tab]
    @Published var selected: UUID
    @Published private(set) var activeResumeIDs: Set<UUID> = []
    private var resumeObservations: [UUID: AnyCancellable] = [:]
    private var resumeIDsByWorkspace: [UUID: Set<UUID>] = [:]
    private let queue: TransferQueue
    let editors = FileEditorManager()
    let previews = FilePreviewManager()
    private let dock = TransferDock()
    var current: Workspace { tabs.first(where: { $0.id == selected })!.workspace }
    init() {
        let savedLimit = UserDefaults.standard.integer(forKey: "maxConcurrentTransfers")
        let queue = TransferQueue(limit: savedLimit == 0 ? 2 : savedLimit)
        self.queue = queue
        let tab = Tab(id: UUID(), workspace: Workspace(queue: queue, editors: editors, previews: previews))
        tabs = [tab]; selected = tab.id
        observe(tab.workspace)
    }
    func setConcurrency(_ value: Int) { Task { await queue.setLimit(value) } }
    func add() {
        let tab = Tab(id: UUID(), workspace: Workspace(queue: queue, editors: editors, previews: previews))
        tabs.append(tab); selected = tab.id
        observe(tab.workspace)
    }
    private func observe(_ workspace: Workspace) {
        workspace.activityObserver = { [weak self] item in self?.dock.receive(item) }
        let id = workspace.id
        resumeObservations[id] = workspace.activityStore.$resumeIDs.sink { [weak self] value in
            guard let self else { return }
            // Published emits before assignment. Aggregate the supplied value,
            // rather than reading the previous set back from the workspace.
            self.resumeIDsByWorkspace[id] = value
            self.refreshResumeIDs()
        }
    }
    private func refreshResumeIDs() {
        let value = resumeIDsByWorkspace.values.reduce(into: Set<UUID>()) { $0.formUnion($1) }
        if activeResumeIDs != value { activeResumeIDs = value }
    }
    func close(_ id: UUID) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let workspace = tabs[index].workspace
        guard !workspace.permissionBusy else { workspace.error = L10n.text("请先完成或停止权限操作。"); return }
        // Active file operations must remain visible until the user cancels or finishes them.
        if workspace.activities.contains(where: { ["传输中", "等待中", "已暂停", "保留中", "清理中"].contains($0.state) }) {
            workspace.error = L10n.text("此标签页仍有传输任务，请先完成或取消任务。")
            return
        }
        workspace.disconnect(); tabs.remove(at: index)
        resumeObservations[workspace.id] = nil
        resumeIDsByWorkspace[workspace.id] = nil
        refreshResumeIDs()
        if selected == id { selected = tabs[min(index, tabs.count - 1)].id }
    }
}

struct BrowserTabBar: View {
    @Environment(\.locale) private var interfaceLocale
    @ObservedObject var tabs: BrowserTabs
    var body: some View {
        let _ = interfaceLocale
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(tabs.tabs) { tab in
                        BrowserTabItem(id: tab.id, workspace: tab.workspace, tabs: tabs)
                    }
                    Button(L10n.text("新建标签页"), systemImage: "plus") { tabs.add() }
                        .labelStyle(.iconOnly).buttonStyle(.borderless).padding(.horizontal, 8)
                }.padding(.horizontal, 10).padding(.vertical, 7)
            }
        }.scrollIndicators(.hidden)
    }
}

struct BrowserTabItem: View {
    @Environment(\.locale) private var interfaceLocale
    let id: UUID
    @ObservedObject var workspace: Workspace
    @ObservedObject var tabs: BrowserTabs
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let _ = interfaceLocale
        // The content and modifier stay structurally stable. Only the glass
        // material changes; labels and file panes never inherit its animation.
        content.transaction { $0.animation = nil }
            .glassEffect(tabs.selected == id ? .regular.tint(.accentColor.opacity(0.08)) : .identity, in: Capsule())
            .animation(reduceMotion ? nil : .smooth(duration: InterfaceStyle.tabTransition), value: tabs.selected == id)
            .accessibilityAddTraits(tabs.selected == id ? .isSelected : [])
    }
    private var content: some View {
        HStack(spacing: 8) {
            Button { tabs.selected = id } label: {
                Label(workspace.connectedProfile.map { $0.name.isEmpty ? $0.host : $0.name } ?? L10n.text("新连接"), systemImage: workspace.connectedProfile == nil ? "folder" : "network")
                    .lineLimit(1).frame(maxWidth: 180)
            }.buttonStyle(.plain)
            Button(L10n.text("关闭标签页"), systemImage: "xmark") { tabs.close(id) }
                .labelStyle(.iconOnly).buttonStyle(.plain)
                .opacity(tabs.tabs.count > 1 ? 1 : 0)
                .disabled(tabs.tabs.count < 2)
                .accessibilityHidden(tabs.tabs.count < 2)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}
