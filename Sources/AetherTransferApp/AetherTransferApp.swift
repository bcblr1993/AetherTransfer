import SwiftUI
import AppKit
import QuickLook
import UniformTypeIdentifiers
import AetherTransferCore

@main struct AetherTransferApp: App {
    @StateObject private var workspace = Workspace()

    var body: some Scene {
        WindowGroup("AetherTransfer") {
            MainView(workspace: workspace)
                .frame(minWidth: 1040, minHeight: 680)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(L10n.tr("检查更新…", "Check for Updates…")) {
                    workspace.openUpdateWindowAndCheck()
                }
                .keyboardShortcut("u", modifiers: [.command])

                Menu(L10n.tr("界面语言 (Language)", "Language")) {
                    ForEach(AppLanguage.allCases) { lang in
                        Button {
                            workspace.appLanguage = lang
                        } label: {
                            HStack {
                                Text(lang.displayName)
                                if workspace.appLanguage == lang {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }

            CommandGroup(after: .newItem) {
                Button(L10n.tr("新建标签页", "New Tab")) { workspace.addNewTab() }.keyboardShortcut("t")
                Button(L10n.tr("关闭标签页", "Close Tab")) {
                    if let tab = workspace.tabManager.activeTab {
                        workspace.closeTab(tab.id)
                    }
                }.keyboardShortcut("w")
                Divider()
                Button(L10n.tr("选择本地文件夹…", "Choose Local Folder…")) { workspace.chooseLocal() }.keyboardShortcut("o")
                Button(L10n.tr("刷新", "Refresh")) { workspace.refreshLocal(); workspace.refreshRemote() }.keyboardShortcut("r")
                Button(L10n.tr("上传所选项目", "Upload Selection")) { workspace.uploadSelection() }.keyboardShortcut("u", modifiers: [.command, .shift])
                Button(L10n.tr("下载所选项目", "Download Selection")) { workspace.downloadSelection() }.keyboardShortcut("d", modifiers: [.command, .shift])
                Divider()
                Button(L10n.tr("文件夹同步…", "Folder Sync…")) { workspace.startSyncAnalysis() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(workspace.connectedProfile == nil)
                Button(L10n.tr("快速查看", "Quick Look")) {
                    if let entry = workspace.selectedEntry {
                        workspace.previewItem(entry, remote: !workspace.remoteSelection.isEmpty)
                    }
                }
                .keyboardShortcut(.space, modifiers: [])
            }
            CommandMenu(L10n.tr("显示", "View")) {
                Toggle(L10n.tr("显示隐藏文件", "Show Hidden Files"), isOn: $workspace.showHidden)
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                Picker(L10n.tr("视图模式", "View Mode"), selection: $workspace.viewMode) {
                    ForEach(FileViewMode.allCases) { mode in
                        Text(mode.localizedTitle).tag(mode)
                    }
                }
                Toggle(L10n.tr("检查器面板", "Inspector"), isOn: $workspace.showInspector)
                    .keyboardShortcut("i")
            }
            CommandMenu(L10n.tr("转到", "Go")) {
                Button(L10n.tr("后退", "Back")) { workspace.goBack(remote: workspace.connectedProfile != nil) }.keyboardShortcut("[")
                Button(L10n.tr("前进", "Forward")) { workspace.goForward(remote: workspace.connectedProfile != nil) }.keyboardShortcut("]")
                Button(L10n.tr("上一级文件夹", "Enclosing Folder")) { workspace.parent(remote: workspace.connectedProfile != nil) }.keyboardShortcut(.upArrow, modifiers: [.command])
                Button(L10n.tr("在终端中打开", "Open in Terminal")) { workspace.openTerminal(remote: workspace.connectedProfile != nil) }
            }
        }

        Settings {
            SettingsView(workspace: workspace)
        }
    }
}

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
                            DisconnectedStateView(showConnect: $showConnect)
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
                    Label(L10n.tr("网格", "Grid"), systemImage: "square.grid.2x2").tag(FileViewMode.icons)
                }
                .pickerStyle(.segmented)
                .frame(width: 110)
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

struct ProtocolBadge: View {
    let protocolKind: TransferProtocol
    var badgeColor: Color {
        switch protocolKind {
        case .sftp: return .blue
        case .ftps: return .green
        case .ftp: return .orange
        }
    }
    var body: some View {
        Text(protocolKind.title)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(badgeColor.opacity(0.15))
            .foregroundStyle(badgeColor)
            .clipShape(RoundedRectangle(cornerRadius: 4))
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
                Table(filtered, selection: $selection) {
                    TableColumn(L10n.tr("名称", "Name")) { entry in
                        Label {
                            Text(entry.name)
                        } icon: {
                            Image(systemName: entry.isDirectory ? "folder.fill" : fileIcon(for: entry))
                                .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                        }
                        .contentShape(Rectangle())
                        .draggable(remote ? "remote://\(entry.path)" : "local://\(entry.path)")
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
                        Text(entry.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
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
                        Text(entry.modified?.formatted(date: .numeric, time: .shortened) ?? "—")
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 100, ideal: 140)
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
                    }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 95, maximum: 120), spacing: 12)], spacing: 12) {
                        ForEach(filtered) { entry in
                            FileGridCell(entry: entry, isSelected: selection.contains(entry.id))
                                .draggable(remote ? "remote://\(entry.path)" : "local://\(entry.path)")
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
                .overlay {
                    if filtered.isEmpty && !loading {
                        ContentUnavailableView(
                            L10n.tr("没有项目", "No Items"),
                            systemImage: "folder",
                            description: Text(query.isEmpty
                                ? L10n.tr("此文件夹为空。", "This folder is empty.")
                                : L10n.tr("未找到匹配的项目。", "No matching items found."))
                        )
                    }
                }
            }
        }
        .frame(minWidth: 350, maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: String.self) { payloads, _ in
            guard !payloads.isEmpty else { return false }
            workspace.handleDroppedItems(payloads, toRemotePane: remote)
            return true
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            if remote {
                workspace.uploadLocalURLs(urls)
            } else {
                workspace.copyLocalURLs(urls, to: path)
            }
            return true
        }
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

// MARK: - File Inspector View
struct FileInspectorView: View {
    let entry: FileEntry?
    @ObservedObject var workspace: Workspace

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(L10n.tr("文件检查器", "File Inspector"))
                    .font(.headline)
                Spacer()
                Button {
                    workspace.showInspector = false
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            Divider()

            if let item = entry {
                ScrollView {
                    VStack(spacing: 14) {
                        Image(systemName: item.isDirectory ? "folder.fill" : "doc.text.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(item.isDirectory ? Color.accentColor : Color.secondary)
                            .padding(.top, 8)

                        Text(item.name)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)

                        Divider()

                        InspectorRow(title: L10n.tr("种类", "Kind"), value: item.localizedKindDescription)
                        InspectorRow(
                            title: L10n.tr("大小", "Size"),
                            value: item.isDirectory
                                ? "—"
                                : "\(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)) (\(item.size) \(L10n.tr("字节", "bytes")))"
                        )
                        if let date = item.modified {
                            InspectorRow(title: L10n.tr("修改时间", "Modified"), value: date.formatted(date: .abbreviated, time: .standard))
                        }
                        InspectorRow(title: L10n.tr("完整路径", "Full Path"), value: item.path)

                        if !item.permissions.isEmpty {
                            Divider()
                            PermissionsEditor(entry: item, workspace: workspace)
                        }
                    }
                    .padding(.horizontal, 14)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text(L10n.tr("选择一个文件以查看详细信息", "Select a file to inspect details"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct InspectorRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Permissions Editor
struct PermissionsEditor: View {
    let entry: FileEntry
    @ObservedObject var workspace: Workspace
    @State private var permissions: POSIXPermissions
    @State private var appliedNotice = false

    init(entry: FileEntry, workspace: Workspace) {
        self.entry = entry
        self.workspace = workspace
        self._permissions = State(initialValue: POSIXPermissions(fromModeString: entry.permissions))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.tr("权限设置 (POSIX)", "Permissions (POSIX)"))
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(permissions.octalString)
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06))
                    .cornerRadius(4)
            }

            VStack(spacing: 6) {
                permissionRow(title: L10n.tr("所有者", "Owner"), triad: $permissions.owner)
                permissionRow(title: L10n.tr("用户组", "Group"), triad: $permissions.group)
                permissionRow(title: L10n.tr("其他人", "Others"), triad: $permissions.others)
            }

            HStack {
                if appliedNotice {
                    Text(L10n.tr("已成功修改", "Applied"))
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
                Spacer()
                Button(L10n.tr("应用修改", "Apply")) {
                    let isRemote = workspace.remoteSelection.contains(entry.id)
                    workspace.applyPermissions(to: entry, permissions: permissions, remote: isRemote)
                    appliedNotice = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        appliedNotice = false
                    }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(8)
    }

    private func permissionRow(title: String, triad: Binding<PermissionTriad>) -> some View {
        HStack {
            Text(title)
                .font(.caption2)
                .frame(width: 50, alignment: .leading)
            Toggle(L10n.tr("读", "R"), isOn: triad.read).toggleStyle(.checkbox).font(.caption2)
            Toggle(L10n.tr("写", "W"), isOn: triad.write).toggleStyle(.checkbox).font(.caption2)
            Toggle(L10n.tr("执", "X"), isOn: triad.execute).toggleStyle(.checkbox).font(.caption2)
        }
    }
}

// MARK: - Batch Rename Sheet
struct BatchRenameSheet: View {
    @ObservedObject var workspace: Workspace
    let items: [FileEntry]
    let isRemote: Bool
    @Environment(\.dismiss) private var dismiss

    @State private var ruleType = 0
    @State private var findText = ""
    @State private var replaceText = ""
    @State private var prefixText = ""
    @State private var suffixText = ""
    @State private var seqFormat = "Item_{N}"
    @State private var seqStart = 1
    @State private var seqPadding = 2

    var currentRule: RenameRule {
        switch ruleType {
        case 0: return .replace(find: findText, replaceWith: replaceText)
        case 1: return .addPrefix(prefixText)
        case 2: return .addSuffix(suffixText)
        case 3: return .sequence(format: seqFormat, start: seqStart, padding: seqPadding)
        default: return .replace(find: "", replaceWith: "")
        }
    }

    var plan: [RenameItemPlan] {
        let renamer = BatchRenamer(rule: currentRule)
        return renamer.plan(for: items.map(\.name))
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Label(L10n.tr("批量重命名 \(items.count) 个项目", "Batch Rename \(items.count) Items"), systemImage: "pencil.and.list.clipboard")
                    .font(.headline)
                Spacer()
            }

            Picker(L10n.tr("规则类型", "Rule"), selection: $ruleType) {
                Text(L10n.tr("替换文本", "Replace Text")).tag(0)
                Text(L10n.tr("添加前缀", "Add Prefix")).tag(1)
                Text(L10n.tr("添加后缀", "Add Suffix")).tag(2)
                Text(L10n.tr("序列编号", "Sequence")).tag(3)
            }
            .pickerStyle(.segmented)

            VStack(spacing: 8) {
                if ruleType == 0 {
                    HStack {
                        TextField(L10n.tr("查找文本", "Find"), text: $findText)
                        TextField(L10n.tr("替换为", "Replace with"), text: $replaceText)
                    }
                } else if ruleType == 1 {
                    TextField(L10n.tr("输入前缀字符串", "Enter prefix"), text: $prefixText)
                } else if ruleType == 2 {
                    TextField(L10n.tr("输入后缀字符串", "Enter suffix"), text: $suffixText)
                } else {
                    HStack {
                        TextField(L10n.tr("格式 (如 Photo_{N})", "Format (e.g. Photo_{N})"), text: $seqFormat)
                        TextField(L10n.tr("起始", "Start"), value: $seqStart, format: .number)
                            .frame(width: 60)
                        TextField(L10n.tr("位数", "Digits"), value: $seqPadding, format: .number)
                            .frame(width: 50)
                    }
                }
            }
            .textFieldStyle(.roundedBorder)

            Text(L10n.tr("效果预览：", "Preview:"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            List(plan) { item in
                HStack {
                    Text(item.originalName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(item.newName)
                        .font(.caption.bold())
                        .foregroundStyle(item.hasError ? .red : .primary)
                    Spacer()
                    if let err = item.errorDescription {
                        Text(err)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
            }
            .frame(height: 170)
            .border(Color.primary.opacity(0.08))

            HStack {
                Button(L10n.tr("取消", "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.tr("执行重命名", "Rename")) {
                    workspace.executeBatchRename(plans: plan, remote: isRemote)
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .disabled(plan.contains { $0.hasError } || plan.allSatisfy { $0.originalName == $0.newName })
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540, height: 440)
    }
}

// MARK: - Quick Text Editor Sheet
struct QuickEditorSheet: View {
    @ObservedObject var workspace: Workspace
    let context: EditingFileContext
    @State private var text: String

    init(workspace: Workspace, context: EditingFileContext) {
        self.workspace = workspace
        self.context = context
        self._text = State(initialValue: context.content)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(context.name, systemImage: "doc.text.fill")
                    .font(.headline)

                Text(context.remote ? L10n.tr("远程服务器文件", "Remote File") : L10n.tr("本地文件", "Local File"))
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15))
                    .foregroundStyle(Color.accentColor)
                    .cornerRadius(4)

                Spacer()

                if context.isSaving {
                    ProgressView().controlSize(.small)
                }

                Button(L10n.tr("关闭", "Close")) {
                    workspace.editingFile = nil
                }
                .keyboardShortcut(.cancelAction)

                Button(L10n.tr("保存更改", "Save Changes")) {
                    workspace.saveEditorContent(text)
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut("s", modifiers: [.command])
            }
            .padding(14)
            .background(.ultraThinMaterial)

            Divider()

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .padding(10)
        }
        .frame(minWidth: 700, minHeight: 520)
    }
}

// MARK: - Activity Queue Drawer
struct ActivityQueueDrawer: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.tr("传输队列", "Activity Queue"))
                    .font(.headline)

                if workspace.activeTransferCount > 0 {
                    Text(L10n.tr("\(workspace.activeTransferCount) 个进行中", "\(workspace.activeTransferCount) Active"))
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .foregroundStyle(Color.accentColor)

                    Text("⚡️ \(workspace.overallTransferSpeed)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Menu {
                    Button(L10n.tr("不限速", "Unlimited")) { workspace.setSpeedLimit(nil) }
                    Divider()
                    Button("500 KB/s") { workspace.setSpeedLimit(500 * 1024) }
                    Button("1 MB/s") { workspace.setSpeedLimit(1024 * 1024) }
                    Button("2 MB/s") { workspace.setSpeedLimit(2 * 1024 * 1024) }
                    Button("5 MB/s") { workspace.setSpeedLimit(5 * 1024 * 1024) }
                    Button("10 MB/s") { workspace.setSpeedLimit(10 * 1024 * 1024) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: workspace.speedLimit == nil ? "gauge.with.needle" : "gauge.with.needle.fill")
                        Text(workspace.speedLimitText)
                    }
                    .font(.caption)
                }
                .menuStyle(.borderlessButton)

                Button(action: { workspace.toggleQueuePause() }) {
                    Label(workspace.isQueuePaused ? L10n.tr("继续", "Resume") : L10n.tr("暂停", "Pause"),
                          systemImage: workspace.isQueuePaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.borderless)
                .disabled(workspace.activeTransferCount == 0 && !workspace.isQueuePaused)
                .help(workspace.isQueuePaused ? L10n.tr("恢复传输队列", "Resume Queue") : L10n.tr("暂停传输队列", "Pause Queue"))

                Button(L10n.tr("清除已完成", "Clear Completed")) {
                    workspace.clearCompletedTransfers()
                }
                .buttonStyle(.borderless)
                .disabled(workspace.transferTasks.allSatisfy { $0.state != .completed })

                Button(L10n.tr("全部取消", "Cancel All")) {
                    workspace.cancelAllTransfers()
                }
                .buttonStyle(.borderless)
                .disabled(workspace.activeTransferCount == 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)

            Divider()

            if workspace.transferTasks.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text(L10n.tr("无传输活动", "No Active Transfers"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(workspace.transferTasks) { item in
                    HStack(spacing: 10) {
                        Image(systemName: item.direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                            .foregroundStyle(item.direction == .upload ? Color.blue : Color.orange)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)

                            if item.state == .inProgress {
                                HStack(spacing: 8) {
                                    ProgressView(value: item.progress)
                                        .frame(maxWidth: 180)
                                    if item.totalBytes > 0 {
                                        Text("\(ByteCountFormatter.string(fromByteCount: item.completedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file))")
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                    if item.speedBytesPerSec > 0 {
                                        Text(TransferQueueManager.formatSpeed(item.speedBytesPerSec))
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }

                            if let err = item.error {
                                Text(err)
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                                    .lineLimit(1)
                            }
                        }

                        Spacer()

                        Text(item.state.localizedTitle)
                            .font(.caption)
                            .foregroundStyle(itemStateColor(item.state))

                        if item.state == .inProgress || item.state == .queued {
                            Button {
                                workspace.cancelTransfer(item.id)
                            } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.borderless)
                            .help(L10n.tr("取消传输", "Cancel Transfer"))
                        } else if item.state == .failed || item.state == .cancelled {
                            Button {
                                workspace.retryTransfer(item.id)
                            } label: {
                                Image(systemName: "arrow.clockwise.circle")
                            }
                            .buttonStyle(.borderless)
                            .help(L10n.tr("重试传输", "Retry Transfer"))
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.plain)
            }
        }
    }

    private func itemStateColor(_ state: TransferState) -> Color {
        switch state {
        case .completed: return .green
        case .failed: return .red
        case .inProgress: return .accentColor
        case .queued: return .secondary
        case .cancelled: return .secondary
        }
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

// MARK: - Disconnected State View
struct DisconnectedStateView: View {
    @Binding var showConnect: Bool

    var body: some View {
        ContentUnavailableView {
            Label(L10n.tr("连接远程服务器", "Connect to Remote Server"), systemImage: "externaldrive.connected.to.line.below")
        } description: {
            Text(L10n.tr("连接到 SFTP / FTP / FTPS 服务器以开始双栏文件浏览与极速传输。",
                         "Connect to an SFTP, FTP, or FTPS server for dual-pane browsing and high-speed file transfers."))
        } actions: {
            Button(L10n.tr("快速连接…", "Quick Connect…"), systemImage: "bolt.fill") {
                showConnect = true
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
        .frame(minWidth: 350, maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.01))
    }
}

// MARK: - Host Challenge Dialog
struct HostChallengeDialog: View {
    let challenge: Workspace.HostChallenge
    @ObservedObject var workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(L10n.tr("核对服务器安全指纹", "Verify Server Host Key Fingerprint"), systemImage: "lock.shield")
                .font(.title2.bold())

            Text(L10n.tr("首次连接至服务器「\(challenge.profile.host)」需要验证其公钥指纹。确认可信后才会建立加密会话：",
                         "First connection to \"\(challenge.profile.host)\". Verify its public key fingerprint before establishing an encrypted session:"))
                .font(.body)

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("SHA-256 指纹：", "SHA-256 Fingerprint:"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(RemoteClient.fingerprint(challenge.key))
                    .font(.system(.body, design: .monospaced))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05))
                    .cornerRadius(6)
                    .textSelection(.enabled)
            }

            HStack {
                Button(L10n.tr("取消", "Cancel")) {
                    workspace.hostChallenge = nil
                    workspace.disconnect()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(L10n.tr("信任并连接", "Trust & Connect")) {
                    workspace.approveHostKey()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 580)
    }
}

// MARK: - Connection View (Add / Edit Bookmark)
struct ConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var workspace: Workspace
    let isEditing: Bool
    @State private var profile: ServerProfile
    @State private var password: String
    @State private var passphrase: String
    @State private var remember: Bool
    @State private var save: Bool
    @State private var error: String?

    init(workspace: Workspace, existingProfile: ServerProfile? = nil) {
        self.workspace = workspace
        if let existing = existingProfile {
            self.isEditing = true
            self._profile = State(initialValue: existing)
            let creds = workspace.loadCredentials(for: existing)
            self._password = State(initialValue: creds.password)
            self._passphrase = State(initialValue: creds.passphrase)
            self._remember = State(initialValue: !creds.password.isEmpty || !creds.passphrase.isEmpty)
            self._save = State(initialValue: true)
        } else {
            self.isEditing = false
            self._profile = State(initialValue: ServerProfile())
            self._password = State(initialValue: "")
            self._passphrase = State(initialValue: "")
            self._remember = State(initialValue: false)
            self._save = State(initialValue: true)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(isEditing ? L10n.tr("编辑服务器书签", "Edit Server Bookmark") : L10n.tr("服务器设置", "Server Settings")) {
                    TextField(L10n.tr("书签名称", "Bookmark Name"), text: $profile.name, prompt: Text(L10n.tr("例如：生产环境 Web 服务器", "e.g. Production Web Server")))
                    TextField(L10n.tr("分组", "Group"), text: $profile.group, prompt: Text(L10n.tr("例如：项目 A、客户…", "e.g. Project A, Clients…")))

                    Picker(L10n.tr("传输协议", "Protocol"), selection: $profile.protocolKind) {
                        ForEach(TransferProtocol.allCases, id: \.self) { Text($0.title).tag($0) }
                    }

                    TextField(L10n.tr("服务器地址 (Host)", "Host"), text: $profile.host)
                    TextField(L10n.tr("端口号", "Port"), value: $profile.port, format: .number.grouping(.never))
                    TextField(L10n.tr("用户名", "Username"), text: $profile.username)
                    SecureField(L10n.tr("登录密码", "Password"), text: $password)
                    TextField(L10n.tr("初始远程路径", "Initial Remote Path"), text: $profile.initialPath)

                    if profile.protocolKind == .sftp {
                        HStack {
                            TextField(L10n.tr("SSH 私钥文件", "SSH Private Key"), text: $profile.privateKeyPath)
                            Button(L10n.tr("选择…", "Choose…")) {
                                let panel = NSOpenPanel()
                                panel.showsHiddenFiles = true
                                if panel.runModal() == .OK { profile.privateKeyPath = panel.url?.path ?? "" }
                            }
                        }
                        SecureField(L10n.tr("私钥解密口令 (Passphrase)", "Private Key Passphrase"), text: $passphrase)
                    }
                }

                Section {
                    Toggle(L10n.tr("保存到书签列表", "Save to Bookmarks"), isOn: $save)
                    Toggle(L10n.tr("将凭据保存到系统钥匙串 (Keychain)", "Save credentials in macOS Keychain"), isOn: $remember)

                    if profile.protocolKind == .ftp {
                        Text(L10n.tr("提示：FTP 会以明文传输凭据和文件内容。生产环境推荐选择 SFTP 或 FTPS。",
                                     "Note: FTP transmits credentials and data in cleartext. Prefer SFTP or FTPS for production."))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    if let error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button(L10n.tr("取消", "Cancel")) {
                    workspace.editingProfile = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if isEditing {
                    Button(L10n.tr("仅保存修改", "Save Only")) {
                        do {
                            let credentials = Credentials(password: password, passphrase: passphrase)
                            try workspace.save(profile, credentials: credentials, remember: remember)
                            workspace.editingProfile = nil
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }

                Button(isEditing ? L10n.tr("保存并连接", "Save & Connect") : L10n.tr("连接", "Connect")) {
                    do {
                        let credentials = Credentials(password: password, passphrase: passphrase)
                        try profile.validate()
                        if save { try workspace.save(profile, credentials: credentials, remember: remember) }
                        workspace.editingProfile = nil
                        workspace.connect(profile, credentials: credentials)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 550, height: 620)
        .onChange(of: profile.protocolKind) { _, kind in
            if !isEditing {
                profile.port = kind.defaultPort
            }
        }
    }
}

// MARK: - Software Update Sheet (In-App Online Update + Download + Immediate Restart)
struct SoftwareUpdateSheet: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 14) {
                Image(systemName: "arrow.down.app.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(LinearGradient(colors: [Color.accentColor, Color.cyan], startPoint: .topLeading, endPoint: .bottomTrailing))

                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("AetherTransfer 软件更新", "AetherTransfer Software Update"))
                        .font(.title3.bold())
                    Text(L10n.tr("当前版本：v\(AutoUpdater.currentAppVersion()) (Build \(AutoUpdater.currentBuildNumber()))",
                                 "Current Version: v\(AutoUpdater.currentAppVersion()) (Build \(AutoUpdater.currentBuildNumber()))"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle(L10n.tr("自动检查更新", "Auto-check for updates"), isOn: $workspace.autoCheckForUpdates)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
            .padding(20)
            .background(.ultraThinMaterial)

            Divider()

            // Main State Content
            VStack(alignment: .leading, spacing: 16) {
                switch workspace.updateState {
                case .idle:
                    updatePlaceholderView(
                        icon: "sparkles",
                        color: .secondary,
                        title: L10n.tr("准备检查新版本", "Ready to Check for Updates"),
                        subtitle: L10n.tr("点击下方「检查更新」获取最新正式版本。", "Click \"Check for Updates\" below to query the latest release.")
                    )

                case .checking:
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text(L10n.tr("正在连接更新服务器检查最新版本…", "Checking update server for new releases…"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .upToDate(let ver):
                    updatePlaceholderView(
                        icon: "checkmark.seal.fill",
                        color: .green,
                        title: L10n.tr("AetherTransfer 已是最新版本 (v\(ver))", "AetherTransfer is up to date (v\(ver))"),
                        subtitle: L10n.tr("您正在运行最新的 Apple Silicon 原生版本。", "You are running the latest native Apple Silicon release.")
                    )

                case .available(let release):
                    releaseDetailView(release: release)

                case .downloading(let release, let completed, let total, let progress):
                    VStack(alignment: .leading, spacing: 14) {
                        releaseDetailView(release: release)
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(L10n.tr("正在下载更新包 v\(release.version)…", "Downloading update v\(release.version)…"))
                                    .font(.caption.bold())
                                Spacer()
                                Text("\(ByteCountFormatter.string(fromByteCount: completed, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) (\(Int(progress * 100))%)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                        }
                    }

                case .verifying(let release):
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text(L10n.tr("正在校验 v\(release.version) 的 SHA-256 指纹与 Apple 代码签名…",
                                     "Verifying SHA-256 digest and code signature for v\(release.version)…"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .readyToInstall(let release, _):
                    VStack(alignment: .leading, spacing: 14) {
                        releaseDetailView(release: release)
                        Divider()
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.shield.fill")
                                .foregroundStyle(.green)
                            Text(L10n.tr("v\(release.version) 下载完成并通过 SHA-256 与代码签名校验，点击「立即重启并更新」即可完成升级。",
                                         "v\(release.version) downloaded and verified (SHA-256 & Code Signature). Click \"Restart & Update Now\" to relaunch."))
                                .font(.caption)
                                .foregroundStyle(.primary)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(8)
                    }

                case .installing(let release):
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text(L10n.tr("正在原子替换应用包并重启至 v\(release.version)…",
                                     "Swapping application bundle and relaunching v\(release.version)…"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .failed(let message):
                    updatePlaceholderView(
                        icon: "exclamationmark.triangle.fill",
                        color: .orange,
                        title: L10n.tr("未能完成更新检查或安装", "Update Check or Installation Failed"),
                        subtitle: message
                    )
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Footer Actions
            HStack {
                Button(L10n.tr("关闭", "Close")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                switch workspace.updateState {
                case .idle, .upToDate, .failed:
                    Button(L10n.tr("检查更新", "Check for Updates")) {
                        workspace.checkForUpdates(silentIfUpToDate: false)
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)

                case .checking, .verifying, .installing:
                    EmptyView()

                case .available(let release):
                    Button(L10n.tr("立即下载更新 (\(ByteCountFormatter.string(fromByteCount: release.sizeBytes, countStyle: .file)))",
                                 "Download Update (\(ByteCountFormatter.string(fromByteCount: release.sizeBytes, countStyle: .file)))")) {
                        workspace.downloadUpdate(release)
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)

                case .downloading:
                    Button(L10n.tr("取消下载", "Cancel Download")) {
                        workspace.cancelUpdateDownload()
                    }

                case .readyToInstall:
                    Button(L10n.tr("立即重启并更新", "Restart & Update Now")) {
                        workspace.installUpdateAndRelaunch()
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .background(.ultraThinMaterial)
        }
        .frame(width: 560, height: 420)
    }

    @ViewBuilder
    private func updatePlaceholderView(icon: String, color: Color, title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(color)
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func releaseDetailView(release: UpdateRelease) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(L10n.tr("发现新版本 v\(release.version)", "New Version v\(release.version) Available"), systemImage: "sparkles")
                    .font(.headline)
                    .foregroundStyle(Color.accentColor)
                Spacer()
                Text(release.publishedAt)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(L10n.tr("更新说明：", "Release Notes:"))
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            ScrollView {
                Text(release.localizedReleaseNotes)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color.primary.opacity(0.04))
            .cornerRadius(8)

            HStack(spacing: 12) {
                Text("SHA-256: \(release.sha256.prefix(16))…")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(L10n.tr("安装包大小: \(ByteCountFormatter.string(fromByteCount: release.sizeBytes, countStyle: .file))",
                             "Size: \(ByteCountFormatter.string(fromByteCount: release.sizeBytes, countStyle: .file))"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Directory Synchronization Sheet (Liquid Glass)
struct SyncSheet: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(LinearGradient(colors: [Color.accentColor, Color.cyan], startPoint: .topLeading, endPoint: .bottomTrailing))

                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.tr("文件夹同步 (Folder Sync)", "Folder Synchronization"))
                        .font(.title3.bold())

                    Text("\(L10n.tr("本地", "Local")): \(workspace.localPath)  ⇄  \(L10n.tr("远程", "Remote")): \(workspace.remotePath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(18)
            .background(.ultraThinMaterial)

            Divider()

            // Configuration Bar
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    Picker(L10n.tr("同步方向", "Direction"), selection: $workspace.syncDirection) {
                        ForEach(SyncDirection.allCases, id: \.self) { dir in
                            Text(dir.localizedTitle).tag(dir)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: workspace.syncDirection) { workspace.recalculateSyncPlan() }

                    Picker(L10n.tr("比较规则", "Compare By"), selection: $workspace.syncRule) {
                        Text(SyncComparisonRule.sizeAndDate.localizedTitle).tag(SyncComparisonRule.sizeAndDate)
                        Text(SyncComparisonRule.sizeOnly.localizedTitle).tag(SyncComparisonRule.sizeOnly)
                    }
                    .pickerStyle(.menu)
                    .onChange(of: workspace.syncRule) { workspace.recalculateSyncPlan() }

                    Spacer()

                    Button {
                        workspace.startSyncAnalysis()
                    } label: {
                        Label(L10n.tr("重新比对", "Re-analyze"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                }

                HStack {
                    Toggle(L10n.tr("删除目标位置的多余文件 (慎用，默认关闭)", "Delete orphan files on target (Use with caution, off by default)"), isOn: $workspace.syncDeleteOrphans)
                        .toggleStyle(.checkbox)
                        .onChange(of: workspace.syncDeleteOrphans) { workspace.recalculateSyncPlan() }

                    Spacer()

                    Text(L10n.tr("🛡️ 遵循安全性原则，默认不删除任何远程文件", "🛡️ Safe by default: remote files are never deleted unless explicitly checked"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color.primary.opacity(0.02))

            Divider()

            // Summary Stats Pill Bar
            if let plan = workspace.syncPlan {
                HStack(spacing: 14) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundStyle(.blue)
                        Text(L10n.tr("上传: \(plan.uploadItems.count) 项", "Upload: \(plan.uploadItems.count)"))
                            .font(.caption.bold())
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.1))
                    .clipShape(Capsule())

                    HStack(spacing: 5) {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(.green)
                        Text(L10n.tr("下载: \(plan.downloadItems.count) 项", "Download: \(plan.downloadItems.count)"))
                            .font(.caption.bold())
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.1))
                    .clipShape(Capsule())

                    HStack(spacing: 5) {
                        Image(systemName: "trash.circle.fill")
                            .foregroundStyle(.red)
                        Text(L10n.tr("删除: \(plan.deleteItems.count) 项", "Delete: \(plan.deleteItems.count)"))
                            .font(.caption.bold())
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.1))
                    .clipShape(Capsule())

                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                        Text(L10n.tr("跳过: \(plan.skipItems.count) 项", "Skip: \(plan.skipItems.count)"))
                            .font(.caption)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(Capsule())

                    Spacer()

                    Text(L10n.tr("计划传输: \(ByteCountFormatter.string(fromByteCount: plan.totalTransferBytes, countStyle: .file))",
                                 "Total: \(ByteCountFormatter.string(fromByteCount: plan.totalTransferBytes, countStyle: .file))"))
                        .font(.caption.monospacedDigit().bold())
                        .foregroundStyle(Color.accentColor)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)

                Divider()

                // Items Table
                List {
                    ForEach(plan.items.indices, id: \.self) { idx in
                        let item = plan.items[idx]
                        HStack(spacing: 10) {
                            Toggle("", isOn: Binding(
                                get: { workspace.syncPlan?.items[idx].isEnabled ?? false },
                                set: { workspace.syncPlan?.items[idx].isEnabled = $0 }
                            ))
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                            .disabled(item.actionType == .skipIdentical)

                            Image(systemName: item.actionType.iconName)
                                .foregroundStyle(colorForAction(item.actionType))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.relativePath)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)

                                HStack(spacing: 8) {
                                    Text(item.actionType.localizedTitle)
                                        .font(.caption2)
                                        .foregroundStyle(colorForAction(item.actionType))

                                    if item.size > 0 {
                                        Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }

                                    if let d1 = item.sourceDate {
                                        Text("\(L10n.tr("源", "Src")): \(d1.formatted(date: .numeric, time: .shortened))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }

                                    if let d2 = item.targetDate {
                                        Text("\(L10n.tr("目标", "Dst")): \(d2.formatted(date: .numeric, time: .shortened))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }

                            Spacer()
                        }
                        .padding(.vertical, 3)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(L10n.tr("正在生成同步计划…", "Generating sync plan…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            // Footer
            HStack {
                Button(L10n.tr("取消", "Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if let plan = workspace.syncPlan {
                    Button(L10n.tr("执行同步 (\(plan.activeItems.count) 项)", "Synchronize (\(plan.activeItems.count) Items)")) {
                        workspace.executeSyncPlan()
                        dismiss()
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(plan.activeItems.isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .background(.ultraThinMaterial)
        }
        .frame(width: 720, height: 560)
    }

    private func colorForAction(_ action: SyncActionType) -> Color {
        switch action {
        case .upload: return .blue
        case .download: return .green
        case .deleteRemote, .deleteLocal: return .red
        case .skipIdentical: return .secondary
        }
    }
}

// MARK: - Native Settings View (⌘,)
struct SettingsView: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        TabView {
            Form {
                Section(L10n.tr("通用与语言", "General & Language")) {
                    Picker(L10n.tr("界面语言", "Interface Language"), selection: $workspace.appLanguage) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }

                    HStack {
                        TextField(L10n.tr("默认本地起始文件夹", "Default Local Folder"), text: $workspace.defaultLocalPath)
                        Button(L10n.tr("选择…", "Choose…")) {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            if panel.runModal() == .OK, let url = panel.url {
                                workspace.defaultLocalPath = url.path
                            }
                        }
                    }

                    Toggle(L10n.tr("默认显示隐藏文件 (以 . 开头)", "Show hidden files by default"), isOn: $workspace.showHidden)
                }

                Section(L10n.tr("传输与冲突处理", "Transfers & Conflict Resolution")) {
                    Stepper(
                        value: $workspace.maxConcurrentTransfers,
                        in: 1...10
                    ) {
                        HStack {
                            Text(L10n.tr("最大并发传输任务数", "Max Concurrent Transfers"))
                            Spacer()
                            Text("\(workspace.maxConcurrentTransfers)")
                                .font(.body.monospacedDigit().bold())
                        }
                    }

                    Picker(L10n.tr("遇到同名文件冲突时", "When File Conflict Occurs"), selection: $workspace.defaultConflictPreference) {
                        ForEach(DefaultConflictPreference.allCases) { pref in
                            Text(pref.localizedTitle).tag(pref)
                        }
                    }
                }

                Section(L10n.tr("软件在线更新", "Software Updates")) {
                    Toggle(L10n.tr("启动时自动在后台检查更新", "Automatically check for updates on launch"), isOn: $workspace.autoCheckForUpdates)

                    HStack {
                        Text(L10n.tr("当前版本：v\(AutoUpdater.currentAppVersion()) (Build \(AutoUpdater.currentBuildNumber()))",
                                     "Current Version: v\(AutoUpdater.currentAppVersion()) (Build \(AutoUpdater.currentBuildNumber()))"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(L10n.tr("立即检查更新…", "Check for Updates Now…")) {
                            workspace.openUpdateWindowAndCheck()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label(L10n.tr("通用与传输", "General & Transfers"), systemImage: "gearshape")
            }
        }
        .frame(width: 520, height: 390)
    }
}
