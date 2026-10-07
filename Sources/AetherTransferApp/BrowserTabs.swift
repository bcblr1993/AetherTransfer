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
    var current: Workspace { tabs.first(where: { $0.id == selected })!.workspace }
    init() {
        let queue = TransferQueue(limit: 2)
        self.queue = queue
        let tab = Tab(id: UUID(), workspace: Workspace(queue: queue))
        tabs = [tab]; selected = tab.id
    }
    func add() {
        let tab = Tab(id: UUID(), workspace: Workspace(queue: queue))
        tabs.append(tab); selected = tab.id
    }
    func close(_ id: UUID) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let workspace = tabs[index].workspace
        // Active file operations must remain visible until the user cancels or finishes them.
        if workspace.activities.contains(where: { $0.state == "传输中" || $0.state == "等待中" }) {
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
    var body: some View {
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
        .background(tabs.selected == id ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }
}
