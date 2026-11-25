import SwiftUI
import AppKit
import QuickLook
import UniformTypeIdentifiers
import AetherTransferCore

// MARK: - Main View
struct MainView: View {
    @ObservedObject var workspace: Workspace
    @State private var showConnect = false
    @State private var showActivities = true
    @State private var query = ""

    var body: some View {
        NavigationSplitView {
            SidebarView(workspace: workspace, showConnect: $showConnect)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    TabBarView(workspace: workspace)
                    Divider()

                    HSplitView {
                        FilePaneView(
                            title: L10n.tr("本地", "Local"),
                            path: $workspace.localPath,
                            files: workspace.sortedLocalFiles,
                            selection: $workspace.localSelection,
                            loading: workspace.loadingLocal,
                            query: query,
                            remote: false,
                            workspace: workspace
                        )

                        if workspace.connectedProfile != nil {
                            FilePaneView(
                                title: workspace.connectedProfile?.name.isEmpty == false
                                    ? workspace.connectedProfile!.name
                                    : L10n.tr("远程服务器", "Remote Server"),
                                path: $workspace.remotePath,
                                files: workspace.sortedRemoteFiles,
                                selection: $workspace.remoteSelection,
                                loading: workspace.loadingRemote,
                                query: query,
                                remote: true,
                                workspace: workspace
                            )
                        } else {
                            DisconnectedStateView(showConnect: $showConnect) {
                                workspace.error = L10n.tr("请先连接服务器，再把文件拖到这里上传。",
                                                          "Connect to a server first, then drop files here to upload.")
                            }
                        }
                    }

                    if showActivities {
                        Divider()
                        ActivityQueueDrawer(workspace: workspace)
                            .frame(height: 190)
                    }

                    Divider()
                    StatusBarView(workspace: workspace)
                }

                if workspace.showInspector {
                    Divider()
                    FileInspectorView(entry: workspace.selectedEntry, workspace: workspace)
                        .frame(width: 290)
                        .background(.ultraThinMaterial)
                }
            }
        }
        .navigationTitle("AetherTransfer")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: { workspace.goBack(remote: false) }) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!workspace.localHistory.canGoBack)
                .help(L10n.tr("后退 (⌘[)", "Back (⌘[)"))
                .accessibilityLabel(L10n.tr("后退", "Back"))

                Button(action: { workspace.goForward(remote: false) }) {
                    Image(systemName: "chevron.right")
                }
                .disabled(!workspace.localHistory.canGoForward)
                .help(L10n.tr("前进 (⌘])", "Forward (⌘])"))
                .accessibilityLabel(L10n.tr("前进", "Forward"))
            }

            ToolbarItemGroup(placement: .principal) {
                Picker(L10n.tr("视图", "View"), selection: $workspace.viewMode) {
                    Label(L10n.tr("列表", "List"), systemImage: "list.bullet").tag(FileViewMode.list)
                    Label(L10n.tr("分栏", "Columns"), systemImage: "rectangle.split.3x1").tag(FileViewMode.columns)
                    Label(L10n.tr("网格", "Grid"), systemImage: "square.grid.2x2").tag(FileViewMode.icons)
                }
                .pickerStyle(.segmented)
                .frame(width: 155)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: {
                    workspace.editingProfile = nil
                    showConnect = true
                }) {
                    Label(L10n.tr("快速连接", "Connect"), systemImage: "plus")
                }
                .accessibilityLabel(L10n.tr("快速连接服务器", "Quick Connect Server"))

                Button(action: { workspace.refreshLocal(); workspace.refreshRemote() }) {
                    Label(L10n.tr("刷新", "Refresh"), systemImage: "arrow.clockwise")
                }

                Button(action: { workspace.uploadSelection() }) {
                    Label(L10n.tr("上传", "Upload"), systemImage: "arrow.up")
                }
                .disabled(workspace.localSelection.isEmpty || workspace.client == nil)
                .buttonStyle(.glassProminent)

                Button(action: { workspace.downloadSelection() }) {
                    Label(L10n.tr("下载", "Download"), systemImage: "arrow.down")
                }
                .disabled(workspace.remoteSelection.isEmpty)
                .buttonStyle(.glassProminent)

                Button(action: { workspace.startSyncAnalysis() }) {
                    Label(L10n.tr("同步", "Sync"), systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(workspace.connectedProfile == nil || workspace.isAnalyzingSync)
                .help(L10n.tr("文件夹双向/单向同步… (⇧⌘S)", "Folder Synchronization… (⇧⌘S)"))

                Button(action: { workspace.toggleSyncBrowsing() }) {
                    Label(L10n.tr("同步浏览", "Sync Browse"), systemImage: workspace.isSyncBrowsingEnabled ? "link.circle.fill" : "link.circle")
                }
                .disabled(workspace.connectedProfile == nil)
                .help(L10n.tr("同步导航：保持两端同步浏览对应文件夹", "Synchronized Browsing: Mirror directory navigation between panes"))

                Button(action: { workspace.showInspector.toggle() }) {
                    Label(L10n.tr("检查器", "Inspector"), systemImage: "info.circle")
                }
                .help(L10n.tr("显示文件检查器 (⌘I)", "Toggle File Inspector (⌘I)"))

                Button(action: { showActivities.toggle() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "list.bullet.rectangle")
                        if workspace.activeTransferCount > 0 {
                            Text("\(workspace.activeTransferCount)")
                                .font(.caption2.bold())
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .help(L10n.tr("传输队列", "Activity Queue"))

                Button(action: { workspace.openUpdateWindowAndCheck() }) {
                    HStack(spacing: 4) {
                        Image(systemName: workspace.hasAvailableUpdate ? "arrow.down.app.fill" : "arrow.triangle.2.circlepath.doc.on.clipboard")
                            .foregroundStyle(workspace.hasAvailableUpdate ? Color.green : Color.primary)
                        if workspace.hasAvailableUpdate {
                            Text("NEW")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.green))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .help(L10n.tr("软件在线更新 (⌘U)", "Software Update (⌘U)"))

                if workspace.connectedProfile != nil {
                    Button(action: { workspace.disconnect() }) {
                        Label(L10n.tr("断开", "Disconnect"), systemImage: "eject.fill")
                    }
                    .help(L10n.tr("断开远程连接", "Disconnect Remote Server"))
                }
            }
        }
        .searchable(text: $query, prompt: L10n.tr("在当前目录搜索", "Search current folder"))
        .sheet(isPresented: $showConnect) {
            ConnectionView(workspace: workspace, existingProfile: workspace.editingProfile)
        }
        .sheet(item: $workspace.editingFile) { ctx in
            QuickEditorSheet(workspace: workspace, context: ctx)
        }
        .sheet(isPresented: $workspace.showBatchRename) {
            let isRemote = workspace.batchRenameTargetRemote
            let files = isRemote ? workspace.remoteFiles : workspace.localFiles
            let selection = isRemote ? workspace.remoteSelection : workspace.localSelection
            let targetFiles = files.filter { selection.contains($0.id) }
            BatchRenameSheet(workspace: workspace, items: targetFiles, isRemote: isRemote)
        }
        .sheet(isPresented: $workspace.showSyncSheet) {
            SyncSheet(workspace: workspace)
        }
        .sheet(isPresented: $workspace.showUpdateSheet) {
            SoftwareUpdateSheet(workspace: workspace)
        }
        .sheet(isPresented: $workspace.showSSHKeyManager) {
            SSHKeyManagerSheet(workspace: workspace)
        }
        .sheet(isPresented: $workspace.showEncryptedSyncSheet) {
            EncryptedSyncVaultSheet(workspace: workspace)
        }
        .quickLookPreview($workspace.previewURL)
        .overlay {
            if workspace.isAnalyzingSync {
                ZStack {
                    Color.black.opacity(0.35)
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text(L10n.tr("正在递归比对本地与远程目录差异…", "Comparing local and remote directories recursively…"))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    .padding(24)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .transition(.opacity)
            }
        }
        .alert(L10n.tr("操作失败", "Operation Failed"), isPresented: Binding(get: { workspace.error != nil }, set: { if !$0 { workspace.error = nil } })) {
            Button(L10n.tr("确定", "OK")) { workspace.error = nil }
        } message: { Text(workspace.error ?? "") }
        .sheet(item: $workspace.hostChallenge) { challenge in
            HostChallengeDialog(challenge: challenge, workspace: workspace)
        }
        .sheet(item: $workspace.passwordPrompt) { profile in
            PasswordPromptSheet(profile: profile, workspace: workspace)
        }
        .onChange(of: workspace.showHidden) { workspace.refreshLocal() }
    }
}

// MARK: - Tab Bar View
struct TabBarView: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(workspace.tabManager.tabs) { tab in
                        let isActive = tab.id == workspace.tabManager.activeTabId
                        HStack(spacing: 6) {
                            Image(systemName: tab.connectedProfileId != nil ? "server.rack" : "internaldrive")
                                .font(.system(size: 11))
                                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)

                            Text(tab.title)
                                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                                .lineLimit(1)

                            if workspace.tabManager.tabs.count > 1 {
                                Button {
                                    workspace.closeTab(tab.id)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(L10n.tr("关闭标签页", "Close Tab"))
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isActive ? Color.primary.opacity(0.1) : Color.primary.opacity(0.03))
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            workspace.selectTab(tab.id)
                        }
                    }
                }
            }

            Button {
                workspace.addNewTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11))
                    .padding(5)
            }
            .buttonStyle(.borderless)
            .help(L10n.tr("新建标签页 (⌘T)", "New Tab (⌘T)"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Sidebar View
struct SidebarView: View {
    @ObservedObject var workspace: Workspace
    @Binding var showConnect: Bool

    var body: some View {
        List(selection: $workspace.selectedServer) {
            Section(L10n.tr("常用位置", "Places")) {
                ForEach(PlaceItem.defaultPlaces()) { place in
                    Button {
                        workspace.navigateLocal(to: place.path)
                    } label: {
                        Label(place.name, systemImage: place.systemImage)
                    }
                    .buttonStyle(.plain)
                    .dropDestination(for: DroppedItem.self) { items, _ in
                        workspace.handleDrop(items, toRemote: false, directory: place.path)
                    }
                }
            }

            let groups = ServerProfile.grouped(workspace.profiles)
            ForEach(groups) { group in
                let displayGroup = group.groupName == "未分组" ? L10n.tr("未分组", "Ungrouped") : group.groupName
                Section(displayGroup) {
                    ForEach(group.profiles) { profile in
                        HStack(spacing: 8) {
                            Image(systemName: "server.rack")
                                .foregroundStyle(workspace.connectedProfile?.id == profile.id ? Color.accentColor : Color.secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name.isEmpty ? profile.host : profile.name)
                                    .fontWeight(workspace.connectedProfile?.id == profile.id ? .semibold : .regular)
                                Text("\(profile.protocolKind.title) · \(profile.host):\(profile.port)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            ProtocolBadge(protocolKind: profile.protocolKind)
                        }
                        .contentShape(Rectangle())
                        .tag(profile.id)
                        .onTapGesture(count: 2) { workspace.connectSaved(profile) }
                        .contextMenu {
                            Button(L10n.tr("连接", "Connect")) { workspace.connectSaved(profile) }
                            Button(L10n.tr("编辑书签…", "Edit Bookmark…")) {
                                workspace.editingProfile = profile
                                showConnect = true
                            }
                            Button(L10n.tr("创建副本", "Duplicate")) { workspace.duplicateProfile(profile) }
                            Divider()
                            Button(L10n.tr("删除", "Delete"), role: .destructive) { workspace.deleteProfile(profile) }
                        }
                    }
                }
            }

            Section {
                Button {
                    workspace.editingProfile = nil
                    showConnect = true
                } label: {
                    Label(L10n.tr("添加新服务器…", "Add New Server…"), systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
            }

            Section(L10n.tr("书签与更新", "Bookmarks & Updates")) {
                Button {
                    workspace.showEncryptedSyncSheet = true
                } label: {
                    Label(L10n.tr("加密书签同步 (.aethersync)…", "Encrypted Sync (.aethersync)…"), systemImage: "lock.icloud")
                }
                .buttonStyle(.plain)

                Button {
                    workspace.showSSHKeyManager = true
                } label: {
                    Label(L10n.tr("SSH 密钥管理器…", "SSH Key Manager…"), systemImage: "key.horizontal")
                }
                .buttonStyle(.plain)

                Button {
                    _ = workspace.importSSHConfigHosts()
                } label: {
                    Label(L10n.tr("导入 ~/.ssh/config 主机", "Import ~/.ssh/config"), systemImage: "terminal")
                }
                .buttonStyle(.plain)

                Button {
                    exportBookmarks()
                } label: {
                    Label(L10n.tr("导出书签 (JSON)…", "Export Bookmarks (JSON)…"), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.plain)

                Button {
                    importBookmarks()
                } label: {
                    Label(L10n.tr("导入书签 (JSON)…", "Import Bookmarks (JSON)…"), systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.plain)

                Button {
                    workspace.openUpdateWindowAndCheck()
                } label: {
                    HStack {
                        Label(L10n.tr("检查软件更新…", "Check for Updates…"), systemImage: "arrow.down.app")
                        if workspace.hasAvailableUpdate {
                            Spacer()
                            Circle().fill(Color.green).frame(width: 8, height: 8)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func exportBookmarks() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "AetherBookmarks.json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url, let data = workspace.exportBookmarksJSON() {
            do {
                try data.write(to: url)
            } catch {
                workspace.error = L10n.tr("导出书签失败: \(error.localizedDescription)", "Failed to export bookmarks: \(error.localizedDescription)")
            }
        }
    }

    private func importBookmarks() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try Data(contentsOf: url)
                try workspace.importBookmarksJSON(data)
            } catch {
                workspace.error = L10n.tr("导入书签失败: \(error.localizedDescription)", "Failed to import bookmarks: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - File Pane View
struct FilePaneView: View {
    let title: String
    @Binding var path: String
    let files: [FileEntry]
    @Binding var selection: Set<String>
    let loading: Bool
    let query: String
    let remote: Bool
    @ObservedObject var workspace: Workspace
    @State private var isEditingPath = false
    @State private var tempPathText = ""
    @State private var dropTargetID: String?
    @State private var isPaneDropTargeted = false

    var currentSortField: FileSortField {
        remote ? workspace.remoteSortField : workspace.localSortField
    }

    var currentSortAscending: Bool {
        remote ? workspace.remoteSortAscending : workspace.localSortAscending
    }

    var filtered: [FileEntry] {
        files.filter {
            (workspace.showHidden || !$0.name.hasPrefix(".")) &&
            (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Pane Header
            HStack(spacing: 8) {
                Image(systemName: remote ? "network" : "internaldrive")
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .fontWeight(.semibold)

                Text("(\(files.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if loading {
                    ProgressView().controlSize(.small)
                }

                // Sort Picker Menu
                Menu {
                    ForEach(FileSortField.allCases) { field in
                        Button {
                            workspace.toggleSort(field, remote: remote)
                        } label: {
                            HStack {
                                Text(field.localizedTitle)
                                if currentSortField == field {
                                    Image(systemName: currentSortAscending ? "chevron.up" : "chevron.down")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.arrow.down")
                        Text(currentSortField.localizedTitle)
                    }
                    .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .help(L10n.tr("排序方式", "Sort By"))

                Button(action: { workspace.parent(remote: remote) }) {
                    Image(systemName: "arrow.up")
                }
                .help(L10n.tr("上一级文件夹", "Enclosing Folder"))
                .buttonStyle(.borderless)

                Button(action: { workspace.createFolder(remote: remote) }) {
                    Image(systemName: "folder.badge.plus")
                }
                .help(L10n.tr("新建文件夹", "New Folder"))
                .buttonStyle(.borderless)

                if !remote {
                    Button(action: { workspace.chooseLocal() }) {
                        Image(systemName: "folder")
                    }
                    .help(L10n.tr("选取文件夹…", "Choose Folder…"))
                    .buttonStyle(.borderless)
                }

                Button(action: { workspace.openTerminal(remote: remote) }) {
                    Image(systemName: "terminal")
                }
                .help(L10n.tr("在终端中打开", "Open in Terminal"))
                .buttonStyle(.borderless)

                Button(action: {
                    if let selId = selection.first, let entry = files.first(where: { $0.id == selId }) {
                        workspace.previewItem(entry, remote: remote)
                    }
                }) {
                    Image(systemName: "eye")
                }
                .help(L10n.tr("快速查看 (Quick Look)", "Quick Look"))
                .buttonStyle(.borderless)
                .disabled(selection.isEmpty)

                Button(action: { if remote { workspace.refreshRemote() } else { workspace.refreshLocal() } }) {
                    Image(systemName: "arrow.clockwise")
                }
                .help(L10n.tr("刷新", "Refresh"))
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)

            Divider()

            // Breadcrumb Navigation Bar
            HStack(spacing: 4) {
                if isEditingPath {
                    TextField(L10n.tr("路径", "Path"), text: $tempPathText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit {
                            isEditingPath = false
                            if remote { workspace.navigateRemote(to: tempPathText) }
                            else { workspace.navigateLocal(to: tempPathText) }
                        }
                    Button(L10n.tr("完成", "Done")) {
                        isEditingPath = false
                        if remote { workspace.navigateRemote(to: tempPathText) }
                        else { workspace.navigateLocal(to: tempPathText) }
                    }
                    .buttonStyle(.glassProminent)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            let crumbs = RemotePath.breadcrumbs(for: path)
                            ForEach(crumbs) { crumb in
                                Button {
                                    if remote { workspace.navigateRemote(to: crumb.path) }
                                    else { workspace.navigateLocal(to: crumb.path) }
                                } label: {
                                    Text(crumb.name)
                                        .font(.system(size: 12, weight: crumb.path == path ? .semibold : .regular))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(crumb.path == path ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05))
                                        .cornerRadius(4)
                                }
                                .buttonStyle(.plain)
                                .dropDestination(for: DroppedItem.self) { items, _ in
                                    workspace.handleDrop(items, toRemote: remote, directory: crumb.path)
                                }

                                if crumb.path != crumbs.last?.path {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }

                    Spacer()

                    Button {
                        tempPathText = path
                        isEditingPath = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.tr("手动输入路径", "Edit Path"))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.02))

            Divider()

            // Content: Table or Grid
            if workspace.viewMode == .list {
                Table(of: FileEntry.self, selection: $selection) {
                    TableColumn(L10n.tr("名称", "Name")) { entry in
                        Label {
                            Text(entry.name)
                        } icon: {
                            Image(systemName: entry.isDirectory ? "folder.fill" : fileIcon(for: entry))
                                .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            if !entry.isDirectory && TextFileHelper.isTextFileName(entry.name) {
                                workspace.openEditor(for: entry, remote: remote)
                            } else {
                                workspace.open(entry, remote: remote)
                            }
                        }
                    }
                    .width(min: 160, ideal: 240)

                    TableColumn(L10n.tr("大小", "Size")) { entry in
                        Text(formattedSize(entry))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .width(80)

                    TableColumn(L10n.tr("种类", "Kind")) { entry in
                        Text(entry.localizedKindDescription)
                            .foregroundStyle(.secondary)
                    }
                    .width(90)

                    TableColumn(L10n.tr("修改日期", "Date Modified")) { entry in
                        Text(formattedDate(entry.modified))
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 100, ideal: 140)
                } rows: {
                    tableRows
                }
                .dropDestination(for: DroppedItem.self) { items, _ in
                    workspace.handleDrop(items, toRemote: remote, directory: nil)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    paneContextMenu(ids: ids)
                } primaryAction: { ids in
                    if let entry = files.first(where: { ids.contains($0.id) }) {
                        if !entry.isDirectory && TextFileHelper.isTextFileName(entry.name) {
                            workspace.openEditor(for: entry, remote: remote)
                        } else {
                            workspace.open(entry, remote: remote)
                        }
                    }
                }
                .overlay {
                    if filtered.isEmpty && !loading {
                        ContentUnavailableView(
                            L10n.tr("没有项目", "No Items"),
                            systemImage: "folder",
                            description: Text(query.isEmpty
                                ? L10n.tr("此文件夹为空。", "This folder is empty.")
                                : L10n.tr("未找到匹配的项目。", "No matching items found."))
                        )
                        .dropDestination(for: DroppedItem.self) { items, _ in
                            workspace.handleDrop(items, toRemote: remote, directory: nil)
                        }
                    }
                }
            } else if workspace.viewMode == .columns {
                ColumnBrowserView(
                    path: path,
                    files: filtered,
                    selection: $selection,
                    remote: remote,
                    workspace: workspace
                )
                .dropDestination(for: DroppedItem.self) { items, _ in
                    workspace.handleDrop(items, toRemote: remote, directory: nil)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 95, maximum: 120), spacing: 12)], spacing: 12) {
                        ForEach(filtered) { entry in
                            FileGridCell(entry: entry, isSelected: selection.contains(entry.id) || dropTargetID == entry.id)
                                .onDrag { workspace.dragProvider(for: entry, remote: remote) }
                                .dropDestination(for: DroppedItem.self) { items, _ in
                                    workspace.handleDrop(items, toRemote: remote, directory: entry.isDirectory ? entry.path : nil)
                                } isTargeted: { targeted in
                                    if entry.isDirectory { dropTargetID = targeted ? entry.id : (dropTargetID == entry.id ? nil : dropTargetID) }
                                }
                                .onTapGesture {
                                    selection = [entry.id]
                                }
                                .simultaneousGesture(TapGesture(count: 2).onEnded {
                                    if !entry.isDirectory && TextFileHelper.isTextFileName(entry.name) {
                                        workspace.openEditor(for: entry, remote: remote)
                                    } else {
                                        workspace.open(entry, remote: remote)
                                    }
                                })
                        }
                    }
                    .padding(14)
                }
                .dropDestination(for: DroppedItem.self) { items, _ in
                    workspace.handleDrop(items, toRemote: remote, directory: nil)
                }
                .overlay {
                    if filtered.isEmpty && !loading {
                        ContentUnavailableView(
                            L10n.tr("没有项目", "No Items"),
                            systemImage: "folder",
                            description: Text(query.isEmpty
                                ? L10n.tr("此文件夹为空。", "This folder is empty.")
                                : L10n.tr("未找到匹配的项目。", "No matching items found."))
                        )
                        .dropDestination(for: DroppedItem.self) { items, _ in
                            workspace.handleDrop(items, toRemote: remote, directory: nil)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 350, maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: DroppedItem.self) { items, _ in
            workspace.handleDrop(items, toRemote: remote, directory: nil)
        } isTargeted: { targeted in
            isPaneDropTargeted = targeted
        }
        .overlay {
            if isPaneDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(2)
                    .allowsHitTesting(false)
            }
        }
    }

    @TableRowBuilder<FileEntry>
    private var tableRows: some TableRowContent<FileEntry> {
        ForEach(filtered) { entry in
            if entry.isDirectory {
                TableRow(entry)
                    .itemProvider { workspace.dragProvider(for: entry, remote: remote) }
                    .dropDestination(for: DroppedItem.self) { items in
                        workspace.handleDrop(items, toRemote: remote, directory: entry.path)
                    }
            } else {
                TableRow(entry)
                    .itemProvider { workspace.dragProvider(for: entry, remote: remote) }
                    .dropDestination(for: DroppedItem.self) { items in
                        workspace.handleDrop(items, toRemote: remote, directory: nil)
                    }
            }
        }
    }

    private func formattedDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .numeric, time: .shortened)
    }

    private func formattedSize(_ entry: FileEntry) -> String {
        if entry.isDirectory { return "—" }
        return ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
    }

    @ViewBuilder
    private func paneContextMenu(ids: Set<String>) -> some View {
        let selectedFiles = files.filter { ids.contains($0.id) }
        if selectedFiles.count == 1, let entry = selectedFiles.first {
            Button(L10n.tr("快速查看 (Quick Look)", "Quick Look")) {
                workspace.previewItem(entry, remote: remote)
            }

            Button(entry.isDirectory
                   ? L10n.tr("打开文件夹", "Open Folder")
                   : (remote ? L10n.tr("下载", "Download") : L10n.tr("在访达中打开", "Open in Finder"))) {
                workspace.open(entry, remote: remote)
            }

            if !entry.isDirectory && TextFileHelper.isTextFileName(entry.name) {
                Button(L10n.tr("在内置编辑器中查看/修改…", "Edit in Built-in Editor…")) {
                    workspace.openEditor(for: entry, remote: remote)
                }
            }

            if !entry.isDirectory {
                Button(L10n.tr("在外部编辑器中打开 (保存自动回传)", "Open in External Editor (Auto-Upload on Save)")) {
                    workspace.openInExternalEditor(entry, remote: remote)
                }
            }

            if !remote {
                Button(L10n.tr("上传至服务器", "Upload to Server")) {
                    workspace.upload([entry])
                }
                .disabled(workspace.client == nil)

                Button(L10n.tr("压缩并上传…", "Compress and Upload…")) {
                    workspace.compressAndUpload([entry])
                }
                .disabled(workspace.client == nil)
            } else {
                Button(L10n.tr("下载至本地", "Download to Local")) {
                    workspace.download([entry])
                }
            }

            Divider()

            Button(L10n.tr("复制 (Copy)", "Copy")) {
                workspace.copySelection(remote: remote, cut: false)
            }
            if workspace.clipboard != nil {
                Button(L10n.tr("粘贴到此处 (Paste)", "Paste Here")) {
                    workspace.pasteClipboard(toRemote: remote)
                }
            }
            Button(L10n.tr("创建副本 (Duplicate)", "Duplicate")) {
                workspace.duplicateItem(entry, remote: remote)
            }

            Divider()

            Button(L10n.tr("复制路径", "Copy Path")) {
                workspace.copyPathOrURL(entry, remote: remote, asURL: false)
            }
            if remote {
                Button(L10n.tr("复制服务器 URL", "Copy Server URL")) {
                    workspace.copyPathOrURL(entry, remote: true, asURL: true)
                }
                if workspace.connectedProfile?.protocolKind == .s3 && !entry.isDirectory {
                    Button(L10n.tr("复制 S3 临时签名链接 (1小时有效)", "Copy S3 Presigned URL (1h)")) {
                        workspace.copyPathOrURL(entry, remote: true, asURL: true, presignedS3: true)
                    }
                }
            }

            Divider()

            Button(L10n.tr("重命名…", "Rename…")) {
                workspace.rename(entry, remote: remote)
            }

            Button(L10n.tr("删除…", "Delete…"), role: .destructive) {
                workspace.delete(entry, remote: remote)
            }
        } else if selectedFiles.count > 1 {
            if !remote {
                Button(L10n.tr("上传所选 \(selectedFiles.count) 项", "Upload \(selectedFiles.count) Selected Items")) {
                    workspace.upload(selectedFiles)
                }
                .disabled(workspace.client == nil)

                Button(L10n.tr("压缩并上传所选 \(selectedFiles.count) 项…", "Compress & Upload \(selectedFiles.count) Items…")) {
                    workspace.compressAndUpload(selectedFiles)
                }
                .disabled(workspace.client == nil)
            } else {
                Button(L10n.tr("下载所选 \(selectedFiles.count) 项", "Download \(selectedFiles.count) Selected Items")) {
                    workspace.download(selectedFiles)
                }
            }

            Divider()

            Button(L10n.tr("批量重命名…", "Batch Rename…")) {
                workspace.batchRenameTargetRemote = remote
                workspace.showBatchRename = true
            }

            Button(L10n.tr("删除所选 \(selectedFiles.count) 项", "Delete \(selectedFiles.count) Items"), role: .destructive) {
                for file in selectedFiles {
                    workspace.delete(file, remote: remote)
                }
            }
        }
    }

    private func fileIcon(for entry: FileEntry) -> String {
        switch entry.fileExtension {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "svg": return "photo"
        case "mp4", "mov", "avi", "mkv": return "film"
        case "mp3", "m4a", "flac", "wav": return "music.note"
        case "zip", "tar", "gz", "bz2", "xz", "7z", "dmg": return "doc.zipper"
        case "swift", "c", "h", "cpp", "py", "sh", "js", "ts", "json", "xml", "html", "css": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }
}

// MARK: - Grid Cell
struct FileGridCell: View {
    let entry: FileEntry
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                .font(.system(size: 38))
                .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)

            Text(entry.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(isSelected ? Color.white : Color.primary)

            if !entry.isDirectory {
                Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
            }
        }
        .padding(8)
        .frame(width: 95, height: 105)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Status Bar View
struct StatusBarView: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        HStack {
            if let server = workspace.connectedProfile {
                HStack(spacing: 6) {
                    Circle().fill(Color.green).frame(width: 8, height: 8)
                    Text("\(server.protocolKind.title) · \(server.name.isEmpty ? server.host : server.name)")
                }
            } else {
                HStack(spacing: 6) {
                    Circle().fill(Color.secondary).frame(width: 8, height: 8)
                    Text(L10n.tr("未连接", "Disconnected"))
                }
            }

            Spacer()

            if let notice = workspace.statusNotice {
                Text("✨ \(notice)")
                    .foregroundStyle(Color.accentColor)
                    .fontWeight(.medium)
                Text("·").foregroundStyle(.tertiary)
            }

            if !workspace.activeExternalEditSessions.isEmpty {
                Text(L10n.tr("外部监听: \(workspace.activeExternalEditSessions.count)",
                             "Live Edit: \(workspace.activeExternalEditSessions.count)"))
                    .foregroundStyle(.orange)
                Text("·").foregroundStyle(.tertiary)
            }

            Text("v\(AutoUpdater.currentAppVersion())")
                .foregroundStyle(.tertiary)

            Text("·")
                .foregroundStyle(.tertiary)

            Text(L10n.tr("\(workspace.localFiles.count) 个本地项目 · \(workspace.remoteFiles.count) 个远程项目",
                         "\(workspace.localFiles.count) local · \(workspace.remoteFiles.count) remote"))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }
}
