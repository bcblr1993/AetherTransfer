import Foundation

public struct TabSession: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var localPath: String
    public var remotePath: String
    public var connectedProfileId: UUID?
    public var connectedProfileName: String?

    public init(id: UUID = UUID(), title: String = "新建标签页", localPath: String, remotePath: String = "/",
                connectedProfileId: UUID? = nil, connectedProfileName: String? = nil) {
        self.id = id
        self.title = title
        self.localPath = localPath
        self.remotePath = remotePath
        self.connectedProfileId = connectedProfileId
        self.connectedProfileName = connectedProfileName
    }
}

public struct TabSessionManager: Sendable {
    public private(set) var tabs: [TabSession] = []
    public var activeTabId: UUID

    public var activeTab: TabSession? {
        tabs.first(where: { $0.id == activeTabId })
    }

    public init(initialLocalPath: String) {
        let firstTab = TabSession(title: "主工作区", localPath: initialLocalPath, remotePath: "/")
        self.tabs = [firstTab]
        self.activeTabId = firstTab.id
    }

    @discardableResult
    public mutating func createTab(title: String = "新建标签页", localPath: String, remotePath: String = "/",
                                   connectedProfileId: UUID? = nil, connectedProfileName: String? = nil) -> UUID {
        let tab = TabSession(title: title, localPath: localPath, remotePath: remotePath,
                             connectedProfileId: connectedProfileId, connectedProfileName: connectedProfileName)
        tabs.append(tab)
        activeTabId = tab.id
        return tab.id
    }

    public mutating func selectTab(_ id: UUID) {
        if tabs.contains(where: { $0.id == id }) {
            activeTabId = id
        }
    }

    public mutating func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if tabs.count <= 1 {
            // Keep at least one tab, just reset it
            let fallback = TabSession(title: "主工作区", localPath: tabs[0].localPath, remotePath: "/")
            tabs = [fallback]
            activeTabId = fallback.id
            return
        }

        tabs.remove(at: index)
        if activeTabId == id {
            let nextIndex = min(index, tabs.count - 1)
            activeTabId = tabs[nextIndex].id
        }
    }

    public mutating func updateActiveTab(localPath: String? = nil, remotePath: String? = nil,
                                        profileId: UUID? = nil, profileName: String? = nil, title: String? = nil) {
        guard let index = tabs.firstIndex(where: { $0.id == activeTabId }) else { return }
        if let local = localPath { tabs[index].localPath = local }
        if let remote = remotePath { tabs[index].remotePath = remote }
        if let pid = profileId { tabs[index].connectedProfileId = pid }
        if let pname = profileName { tabs[index].connectedProfileName = pname }
        if let t = title { tabs[index].title = t }
    }

    public mutating func clearActiveConnection(fallbackTitle: String) {
        guard let index = tabs.firstIndex(where: { $0.id == activeTabId }) else { return }
        tabs[index].connectedProfileId = nil
        tabs[index].connectedProfileName = nil
        tabs[index].title = fallbackTitle
    }
}
