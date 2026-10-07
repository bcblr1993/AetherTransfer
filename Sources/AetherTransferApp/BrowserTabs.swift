import SwiftUI
import AetherTransferCore

@MainActor final class BrowserTabs: ObservableObject {
    struct Tab: Identifiable {
        let id: UUID
        let workspace: Workspace
    }
    @Published var tabs: [Tab]
    @Published var selected: UUID
    private let queue: TransferQueue
    let editors = FileEditorManager()
    var current: Workspace { tabs.first(where: { $0.id == selected })!.workspace }
    init() {
        let savedLimit = UserDefaults.standard.integer(forKey: "maxConcurrentTransfers")
        let queue = TransferQueue(limit: savedLimit == 0 ? 2 : savedLimit)
        self.queue = queue
        let tab = Tab(id: UUID(), workspace: Workspace(queue: queue, editors: editors))
        tabs = [tab]; selected = tab.id
    }
    func setConcurrency(_ value: Int) { Task { await queue.setLimit(value) } }
    func add() {
        let tab = Tab(id: UUID(), workspace: Workspace(queue: queue, editors: editors))
        tabs.append(tab); selected = tab.id
    }
    func close(_ id: UUID) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let workspace = tabs[index].workspace
        // Active file operations must remain visible until the user cancels or finishes them.
        if workspace.activities.contains(where: { $0.state == "传输中" || $0.state == "等待中" || $0.state == "已暂停" }) {
            workspace.error = "此标签页仍有传输任务，请先完成或取消任务。"
            return
        }
        workspace.disconnect(); tabs.remove(at: index)
        if selected == id { selected = tabs[min(index, tabs.count - 1)].id }
    }
}

struct BrowserTabItem: View {
    let id: UUID
    @ObservedObject var workspace: Workspace
    @ObservedObject var tabs: BrowserTabs
    let namespace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewBuilder var body: some View {
        if tabs.selected == id {
            content.glassEffect(.regular.tint(.accentColor.opacity(0.08)), in: Capsule())
                .glassEffectID("selected-tab", in: namespace)
                .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
                .accessibilityAddTraits(.isSelected)
        } else { content }
    }
    private var content: some View {
        HStack(spacing: 8) {
            Button { tabs.selected = id } label: {
                Label(workspace.connectedProfile.map { $0.name.isEmpty ? $0.host : $0.name } ?? "新连接", systemImage: workspace.connectedProfile == nil ? "folder" : "network")
                    .lineLimit(1).frame(maxWidth: 180)
            }.buttonStyle(.plain)
            if tabs.tabs.count > 1 {
                Button("关闭标签页", systemImage: "xmark") { tabs.close(id) }.labelStyle(.iconOnly).buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}
