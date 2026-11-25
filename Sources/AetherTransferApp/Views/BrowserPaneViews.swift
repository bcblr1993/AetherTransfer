import SwiftUI
import AppKit
import QuickLook
import UniformTypeIdentifiers
import AetherTransferCore

// MARK: - Shared Icon, Transfer Routing & Context Menu Helpers

enum BrowserIconHelper {
    static func symbolName(for entry: FileEntry) -> String {
        if entry.isDirectory { return "folder.fill" }
        switch entry.fileExtension {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp", "svg":
            return "photo"
        case "mp4", "mov", "avi", "mkv":
            return "film"
        case "mp3", "m4a", "flac", "wav":
            return "music.note"
        case "zip", "tar", "gz", "bz2", "xz", "7z", "dmg":
            return "doc.zipper"
        case "swift", "c", "h", "cpp", "py", "sh", "js", "ts", "json", "xml", "html", "css", "md", "yml", "yaml":
            return "chevron.left.forwardslash.chevron.right"
        case "pdf":
            return "doc.richtext"
        default:
            return "doc"
        }
    }
}

struct OppositeTransferSpec {
    let title: String
    let shortTitle: String
    let systemImage: String
    let isEnabled: Bool
    let targetRole: BrowserPaneRole?
    let canMove: Bool
    let perform: ([FileEntry]) -> Void
    let performMove: (([FileEntry]) -> Void)?
}

enum BrowserTransferRouter {
    @MainActor
    static func oppositeAction(
        from role: BrowserPaneRole,
        workspace: Workspace,
        layout: PaneLayoutController
    ) -> OppositeTransferSpec {
        switch role {
        case .leftLocal:
            switch layout.rightPaneSource {
            case .primaryRemote:
                return OppositeTransferSpec(
                    title: L10n.tr("上传至服务器", "Upload to Server"),
                    shortTitle: L10n.tr("上传", "Upload"),
                    systemImage: "arrow.up.circle",
                    isEnabled: workspace.client != nil,
                    targetRole: .primaryRemote,
                    canMove: false,
                    perform: { entries in workspace.upload(entries) },
                    performMove: nil
                )
            case .secondLocal:
                return OppositeTransferSpec(
                    title: L10n.tr("复制到右侧本地", "Copy to Right Local"),
                    shortTitle: L10n.tr("复制 →", "Copy →"),
                    systemImage: "arrow.right.circle",
                    isEnabled: true,
                    targetRole: .secondLocal,
                    canMove: true,
                    perform: { entries in
                        workspace.transferLocalBetweenPanes(
                            entries,
                            toDirectory: layout.secondLocalPath,
                            move: false,
                            sourceRole: .leftLocal,
                            targetRole: .secondLocal,
                            layout: layout
                        )
                    },
                    performMove: { entries in
                        workspace.transferLocalBetweenPanes(
                            entries,
                            toDirectory: layout.secondLocalPath,
                            move: true,
                            sourceRole: .leftLocal,
                            targetRole: .secondLocal,
                            layout: layout
                        )
                    }
                )
            case .secondRemote:
                let secondClient = layout.secondRemoteClient(speedLimit: workspace.speedLimit)
                return OppositeTransferSpec(
                    title: L10n.tr("上传至右侧服务器", "Upload to Right Server"),
                    shortTitle: L10n.tr("上传 →", "Upload →"),
                    systemImage: "arrow.right.circle",
                    isEnabled: secondClient != nil,
                    targetRole: .secondRemote,
                    canMove: false,
                    perform: { entries in
                        guard let secondClient else { return }
                        workspace.transferLocalToRemote(
                            entries,
                            client: secondClient,
                            toRemoteDir: layout.secondRemotePath,
                            targetRole: .secondRemote,
                            layout: layout
                        )
                    },
                    performMove: nil
                )
            }

        case .primaryRemote:
            if layout.leftPaneSource == .primaryRemote {
                switch layout.rightPaneSource {
                case .secondRemote:
                    let secondClient = layout.secondRemoteClient(speedLimit: workspace.speedLimit)
                    return OppositeTransferSpec(
                        title: L10n.tr("传输至右侧服务器", "Transfer to Right Server"),
                        shortTitle: L10n.tr("传至右侧", "To Right"),
                        systemImage: "arrow.right.arrow.left.circle",
                        isEnabled: workspace.client != nil && secondClient != nil,
                        targetRole: .secondRemote,
                        canMove: false,
                        perform: { entries in
                            guard let primary = workspace.client, let secondClient else { return }
                            workspace.transferServerToServer(
                                entries,
                                sourceClient: primary,
                                destinationClient: secondClient,
                                destinationDir: layout.secondRemotePath,
                                targetRole: .secondRemote,
                                layout: layout
                            )
                        },
                        performMove: nil
                    )
                case .secondLocal:
                    return OppositeTransferSpec(
                        title: L10n.tr("下载至右侧本地", "Download to Right Local"),
                        shortTitle: L10n.tr("下载 →", "Download →"),
                        systemImage: "arrow.down.circle",
                        isEnabled: workspace.client != nil,
                        targetRole: .secondLocal,
                        canMove: false,
                        perform: { entries in
                            guard let primary = workspace.client else { return }
                            workspace.transferRemoteToLocal(
                                entries,
                                client: primary,
                                toLocalDir: layout.secondLocalPath,
                                targetLocalRole: .secondLocal,
                                layout: layout
                            )
                        },
                        performMove: nil
                    )
                case .primaryRemote:
                    break
                }
            }
            return OppositeTransferSpec(
                title: L10n.tr("下载至本地", "Download to Local"),
                shortTitle: L10n.tr("下载", "Download"),
                systemImage: "arrow.down.circle",
                isEnabled: workspace.client != nil,
                targetRole: .leftLocal,
                canMove: false,
                perform: { entries in workspace.download(entries) },
                performMove: nil
            )

        case .secondLocal:
            if layout.leftPaneSource == .primaryRemote {
                return OppositeTransferSpec(
                    title: L10n.tr("上传至主服务器", "Upload to Primary Server"),
                    shortTitle: L10n.tr("← 上传", "← Upload"),
                    systemImage: "arrow.up.circle",
                    isEnabled: workspace.client != nil,
                    targetRole: .primaryRemote,
                    canMove: false,
                    perform: { entries in workspace.upload(entries) },
                    performMove: nil
                )
            }
            return OppositeTransferSpec(
                title: L10n.tr("复制到左侧本地", "Copy to Left Local"),
                shortTitle: L10n.tr("← 复制", "← Copy"),
                systemImage: "arrow.left.circle",
                isEnabled: true,
                targetRole: .leftLocal,
                canMove: true,
                perform: { entries in
                    workspace.transferLocalBetweenPanes(
                        entries,
                        toDirectory: workspace.localPath,
                        move: false,
                        sourceRole: .secondLocal,
                        targetRole: .leftLocal,
                        layout: layout
                    )
                },
                performMove: { entries in
                    workspace.transferLocalBetweenPanes(
                        entries,
                        toDirectory: workspace.localPath,
                        move: true,
                        sourceRole: .secondLocal,
                        targetRole: .leftLocal,
                        layout: layout
                    )
                }
            )

        case .secondRemote:
            let secondClient = layout.secondRemoteClient(speedLimit: workspace.speedLimit)
            if layout.leftPaneSource == .primaryRemote {
                return OppositeTransferSpec(
                    title: L10n.tr("传输至主服务器", "Transfer to Primary Server"),
                    shortTitle: L10n.tr("← 传输", "← Transfer"),
                    systemImage: "arrow.right.arrow.left.circle",
                    isEnabled: workspace.client != nil && secondClient != nil,
                    targetRole: .primaryRemote,
                    canMove: false,
                    perform: { entries in
                        guard let secondClient, let primary = workspace.client else { return }
                        workspace.transferServerToServer(
                            entries,
                            sourceClient: secondClient,
                            destinationClient: primary,
                            destinationDir: workspace.remotePath,
                            targetRole: .primaryRemote,
                            layout: layout
                        )
                    },
                    performMove: nil
                )
            }
            return OppositeTransferSpec(
                title: L10n.tr("下载至左侧本地", "Download to Left Local"),
                shortTitle: L10n.tr("← 下载", "← Download"),
                systemImage: "arrow.down.circle",
                isEnabled: secondClient != nil,
                targetRole: .leftLocal,
                canMove: false,
                perform: { entries in
                    guard let secondClient else { return }
                    workspace.transferRemoteToLocal(
                        entries,
                        client: secondClient,
                        toLocalDir: workspace.localPath,
                        targetLocalRole: .leftLocal,
                        layout: layout
                    )
                },
                performMove: nil
            )
        }
    }
}

struct BrowserEntryContextMenu: View {
    let entries: [FileEntry]
    let currentDirectory: String
    let role: BrowserPaneRole
    @ObservedObject var workspace: Workspace
    @ObservedObject var layout: PaneLayoutController

    var body: some View {
        let opposite = BrowserTransferRouter.oppositeAction(from: role, workspace: workspace, layout: layout)

        if entries.count == 1, let entry = entries.first {
            Button(L10n.tr("快速查看 (Quick Look)", "Quick Look")) {
                workspace.previewEntry(entry, in: role, layout: layout)
            }

            Button(entry.isDirectory
                   ? L10n.tr("打开文件夹", "Open Folder")
                   : (role.isRemote ? L10n.tr("下载", "Download") : L10n.tr("在访达中打开", "Open in Finder"))) {
                workspace.openEntry(entry, in: role, layout: layout)
            }

            if !entry.isDirectory && TextFileHelper.isTextFileName(entry.name) {
                Button(L10n.tr("在内置编辑器中查看/修改…", "Edit in Built-in Editor…")) {
                    workspace.openEditorInPane(for: entry, role: role, layout: layout)
                }
            }

            if !entry.isDirectory && (role == .leftLocal || role == .primaryRemote) {
                Button(L10n.tr("在外部编辑器中打开 (保存自动回传)", "Open in External Editor (Auto-Upload on Save)")) {
                    workspace.openInExternalEditor(entry, remote: role == .primaryRemote)
                }
            }

            Button(opposite.title) {
                opposite.perform([entry])
            }
            .disabled(!opposite.isEnabled)

            if opposite.canMove, let moveOp = opposite.performMove {
                Button(L10n.tr("移动到对侧本地", "Move to Opposite Local")) {
                    moveOp([entry])
                }
            }

            if role == .leftLocal {
                Button(L10n.tr("压缩并上传…", "Compress and Upload…")) {
                    workspace.compressAndUpload([entry])
                }
                .disabled(workspace.client == nil)
            }

            Divider()

            if entry.isDirectory {
                Button(L10n.tr("固定到常用位置", "Pin Folder to Places")) {
                    let pid: UUID? = role == .primaryRemote
                        ? workspace.connectedProfile?.id
                        : (role == .secondRemote ? layout.secondRemoteProfile?.id : nil)
                    layout.pinCustomPlace(name: entry.name, path: entry.path, isRemote: role.isRemote, profileId: pid)
                    workspace.flashNotice(L10n.tr("已固定到常用位置：\(entry.name)", "Pinned to Places: \(entry.name)"))
                }
            }

            Button(L10n.tr("新建文件夹…", "New Folder…")) {
                workspace.createFolder(in: role, layout: layout)
            }
            Button(L10n.tr("新建空文件…", "New Empty File…")) {
                workspace.createNewFile(in: role, layout: layout, directoryOverride: currentDirectory)
            }
            if !role.isRemote || workspace.client(for: role, layout: layout)?.profile.protocolKind == .sftp {
                Button(L10n.tr("创建符号链接…", "Create Symbolic Link…")) {
                    workspace.createSymlink(for: entry, in: role, layout: layout)
                }
            }

            Divider()

            if role == .leftLocal || role == .primaryRemote {
                Button(L10n.tr("复制 (Copy)", "Copy")) {
                    workspace.copySelection(remote: role == .primaryRemote, cut: false)
                }
                if workspace.clipboard != nil {
                    Button(L10n.tr("粘贴到此处 (Paste)", "Paste Here")) {
                        workspace.pasteClipboard(toRemote: role == .primaryRemote)
                    }
                }
                Button(L10n.tr("创建副本 (Duplicate)", "Duplicate")) {
                    workspace.duplicateItem(entry, remote: role == .primaryRemote)
                }
                Divider()
            }

            Button(L10n.tr("复制路径", "Copy Path")) {
                if role == .leftLocal || role == .primaryRemote {
                    workspace.copyPathOrURL(entry, remote: role == .primaryRemote, asURL: false)
                } else {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.path, forType: .string)
                }
            }
            if role == .primaryRemote {
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
                workspace.renameEntry(entry, in: role, layout: layout)
            }

            Button(L10n.tr("删除…", "Delete…"), role: .destructive) {
                workspace.deleteEntry(entry, in: role, layout: layout)
            }
        } else if entries.count > 1 {
            Button("\(opposite.title) (\(entries.count))") {
                opposite.perform(entries)
            }
            .disabled(!opposite.isEnabled)

            if role == .leftLocal {
                Button(L10n.tr("压缩并上传所选 \(entries.count) 项…", "Compress & Upload \(entries.count) Items…")) {
                    workspace.compressAndUpload(entries)
                }
                .disabled(workspace.client == nil)
            }

            Divider()

            if role == .leftLocal || role == .primaryRemote {
                Button(L10n.tr("批量重命名…", "Batch Rename…")) {
                    workspace.batchRenameTargetRemote = (role == .primaryRemote)
                    workspace.showBatchRename = true
                }
            }

            Button(L10n.tr("删除所选 \(entries.count) 项", "Delete \(entries.count) Items"), role: .destructive) {
                for file in entries {
                    workspace.deleteEntry(file, in: role, layout: layout)
                }
            }
        } else {
            BrowserBackgroundContextMenu(
                directoryPath: currentDirectory,
                role: role,
                workspace: workspace,
                layout: layout
            )
        }
    }
}

struct BrowserBackgroundContextMenu: View {
    let directoryPath: String
    let role: BrowserPaneRole
    @ObservedObject var workspace: Workspace
    @ObservedObject var layout: PaneLayoutController

    var body: some View {
        Button(L10n.tr("新建文件夹…", "New Folder…")) {
            workspace.createFolder(in: role, layout: layout)
        }
        Button(L10n.tr("新建空文件…", "New Empty File…")) {
            workspace.createNewFile(in: role, layout: layout, directoryOverride: directoryPath)
        }
        if (role == .leftLocal || role == .primaryRemote), workspace.clipboard != nil {
            Button(L10n.tr("粘贴到此处 (Paste)", "Paste Here")) {
                workspace.pasteClipboard(toRemote: role == .primaryRemote)
            }
        }
        Divider()
        Button(L10n.tr("将当前目录固定到常用位置", "Pin Current Folder to Places")) {
            let name = (directoryPath as NSString).lastPathComponent
            let pid: UUID? = role == .primaryRemote
                ? workspace.connectedProfile?.id
                : (role == .secondRemote ? layout.secondRemoteProfile?.id : nil)
            layout.pinCustomPlace(name: name, path: directoryPath, isRemote: role.isRemote, profileId: pid)
        }
        Button(L10n.tr("刷新", "Refresh")) {
            workspace.refreshPane(role: role, layout: layout)
        }
    }
}

// MARK: - Main View

struct MainView: View {
    @ObservedObject var workspace: Workspace
    @StateObject private var appearance = PaneAppearanceState()
    @StateObject private var layout = PaneLayoutController()
    @State private var showConnect = false
    @State private var showActivities = true
    @State private var query = ""

    private var activeLeftRole: BrowserPaneRole {
        (layout.leftPaneSource == .primaryRemote && workspace.connectedProfile != nil)
            ? .primaryRemote
            : .leftLocal
    }

    private var activeRightRole: BrowserPaneRole {
        switch layout.rightPaneSource {
        case .primaryRemote: return .primaryRemote
        case .secondLocal: return .secondLocal
        case .secondRemote: return .secondRemote
        }
    }

    private var focusedPaneRole: BrowserPaneRole {
        switch layout.focusMode {
        case .localOnly: return activeLeftRole
        case .remoteOnly: return activeRightRole
        case .dualPane:
            return layout.activePaneSide == .left ? activeLeftRole : activeRightRole
        }
    }

    private var leftSelectedEntries: [FileEntry] {
        switch activeLeftRole {
        case .leftLocal:
            return workspace.localFiles.filter { workspace.localSelection.contains($0.id) }
        case .primaryRemote:
            return workspace.remoteFiles.filter { workspace.remoteSelection.contains($0.id) }
        default:
            return []
        }
    }

    private var rightSelectedEntries: [FileEntry] {
        switch activeRightRole {
        case .primaryRemote:
            return workspace.remoteFiles.filter { workspace.remoteSelection.contains($0.id) }
        case .secondLocal:
            return layout.secondLocalFiles.filter { layout.secondLocalSelection.contains($0.id) }
        case .secondRemote:
            return layout.secondRemoteFiles.filter { layout.secondRemoteSelection.contains($0.id) }
        default:
            return []
        }
    }

    private var inspectedEntry: FileEntry? {
        if layout.activePaneSide == .right {
            if let entry = rightSelectedEntries.first { return entry }
        }
        if let entry = leftSelectedEntries.first { return entry }
        if let entry = rightSelectedEntries.first { return entry }
        return workspace.selectedEntry
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(workspace: workspace, layout: layout, showConnect: $showConnect)
                .navigationSplitViewColumnWidth(min: 205, ideal: 235, max: 310)
        } detail: {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    TabBarView(workspace: workspace)
                    Divider()

                    paneWorkspaceView
                        .background {
                            // Global pane-aware keyboard shortcuts for Go to Folder (⇧⌘G) & New Empty File (⌥⌘N)
                            Group {
                                Button("") { openFocusedGoToFolder() }
                                    .keyboardShortcut("g", modifiers: [.command, .shift])
                                Button("") { workspace.createNewFile(in: focusedPaneRole, layout: layout) }
                                    .keyboardShortcut("n", modifiers: [.command, .option])
                            }
                            .frame(width: 0, height: 0)
                            .opacity(0.001)
                            .accessibilityHidden(true)
                        }

                    if showActivities {
                        Divider()
                        ActivityQueueDrawer(workspace: workspace)
                            .frame(height: 190)
                    }

                    Divider()
                    StatusBarView(workspace: workspace, layout: layout)
                }

                if workspace.showInspector {
                    Divider()
                    FileInspectorView(entry: inspectedEntry, workspace: workspace)
                        .frame(width: 290)
                        .background(.ultraThinMaterial)
                }
            }
        }
        .navigationTitle("AetherTransfer")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: { workspace.goBackPane(role: focusedPaneRole, layout: layout) }) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!canGoBackFocused)
                .help(L10n.tr("后退 (⌘[)", "Back (⌘[)"))
                .accessibilityLabel(L10n.tr("后退", "Back"))

                Button(action: { workspace.goForwardPane(role: focusedPaneRole, layout: layout) }) {
                    Image(systemName: "chevron.right")
                }
                .disabled(!canGoForwardFocused)
                .help(L10n.tr("前进 (⌘])", "Forward (⌘])"))
                .accessibilityLabel(L10n.tr("前进", "Forward"))
            }

            ToolbarItemGroup(placement: .principal) {
                Picker(L10n.tr("视图", "View"), selection: Binding(
                    get: { appearance.displayMode },
                    set: { appearance.applyDisplayMode($0, to: workspace) }
                )) {
                    ForEach(BrowserDisplayMode.allCases) { mode in
                        Label(mode.localizedTitle, systemImage: mode.systemImage).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 205)

                Picker(L10n.tr("布局", "Layout"), selection: $layout.focusMode) {
                    Image(systemName: "sidebar.left")
                        .help(L10n.tr("仅显示左侧面板", "Left Pane Only"))
                        .tag(WorkspaceFocusMode.localOnly)
                    Image(systemName: "rectangle.split.2x1")
                        .help(L10n.tr("双栏对比布局", "Dual Pane"))
                        .tag(WorkspaceFocusMode.dualPane)
                    Image(systemName: "sidebar.right")
                        .help(L10n.tr("仅显示右侧面板", "Right Pane Only"))
                        .tag(WorkspaceFocusMode.remoteOnly)
                }
                .pickerStyle(.segmented)
                .frame(width: 108)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: {
                    workspace.editingProfile = nil
                    showConnect = true
                }) {
                    Label(L10n.tr("快速连接", "Connect"), systemImage: "plus")
                }
                .accessibilityLabel(L10n.tr("快速连接服务器", "Quick Connect Server"))

                Button(action: {
                    workspace.refreshLocal()
                    workspace.refreshRemote()
                    if layout.rightPaneSource == .secondLocal {
                        layout.refreshSecondLocal(showHidden: workspace.showHidden)
                    } else if layout.rightPaneSource == .secondRemote {
                        layout.refreshSecondRemote(workspace: workspace)
                    }
                }) {
                    Label(L10n.tr("刷新", "Refresh"), systemImage: "arrow.clockwise")
                }

                let leftAction = BrowserTransferRouter.oppositeAction(from: activeLeftRole, workspace: workspace, layout: layout)
                Button(action: { leftAction.perform(leftSelectedEntries) }) {
                    Label(leftAction.shortTitle, systemImage: "arrow.up")
                }
                .disabled(leftSelectedEntries.isEmpty || !leftAction.isEnabled)
                .buttonStyle(.glassProminent)
                .help(leftAction.title)

                let rightAction = BrowserTransferRouter.oppositeAction(from: activeRightRole, workspace: workspace, layout: layout)
                Button(action: { rightAction.perform(rightSelectedEntries) }) {
                    Label(rightAction.shortTitle, systemImage: "arrow.down")
                }
                .disabled(rightSelectedEntries.isEmpty || !rightAction.isEnabled)
                .buttonStyle(.glassProminent)
                .help(rightAction.title)

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
        .sheet(item: $layout.secondRemoteHostChallenge) { challenge in
            SecondRemoteHostChallengeDialog(challenge: challenge, workspace: workspace, layout: layout)
        }
        .sheet(item: $layout.secondRemotePasswordPrompt) { profile in
            SecondRemotePasswordSheet(profile: profile, workspace: workspace, layout: layout)
        }
        .onChange(of: workspace.showHidden) { _, _ in
            workspace.refreshLocal()
            if layout.rightPaneSource == .secondLocal {
                layout.refreshSecondLocal(showHidden: workspace.showHidden)
            }
        }
        .onChange(of: workspace.viewMode) { _, newValue in
            appearance.syncFromWorkspaceViewMode(newValue)
        }
        .onChange(of: layout.rightPaneSource) { _, newSource in
            if newSource == .secondLocal {
                layout.activateSecondLocal(showHidden: workspace.showHidden)
            }
            if newSource == .primaryRemote && layout.leftPaneSource == .primaryRemote {
                layout.leftPaneSource = .local
            }
        }
        .onChange(of: workspace.connectedProfile?.id) { _, newID in
            if newID == nil && layout.leftPaneSource == .primaryRemote {
                layout.leftPaneSource = .local
            }
        }
    }

    private var canGoBackFocused: Bool {
        switch focusedPaneRole {
        case .leftLocal: return workspace.localHistory.canGoBack
        case .primaryRemote: return workspace.remoteHistory.canGoBack
        case .secondLocal: return layout.secondLocalHistory.canGoBack
        case .secondRemote: return layout.secondRemoteHistory.canGoBack
        }
    }

    private var canGoForwardFocused: Bool {
        switch focusedPaneRole {
        case .leftLocal: return workspace.localHistory.canGoForward
        case .primaryRemote: return workspace.remoteHistory.canGoForward
        case .secondLocal: return layout.secondLocalHistory.canGoForward
        case .secondRemote: return layout.secondRemoteHistory.canGoForward
        }
    }

    private func openFocusedGoToFolder() {
        switch layout.focusMode {
        case .localOnly:
            layout.showLeftGoToFolder = true
        case .remoteOnly:
            layout.showRightGoToFolder = true
        case .dualPane:
            if layout.activePaneSide == .left {
                layout.showLeftGoToFolder = true
            } else {
                layout.showRightGoToFolder = true
            }
        }
    }

    @ViewBuilder
    private var paneWorkspaceView: some View {
        switch layout.focusMode {
        case .localOnly:
            leftPaneContent
        case .remoteOnly:
            rightPaneContent
        case .dualPane:
            HSplitView {
                leftPaneContent
                rightPaneContent
            }
        }
    }

    @ViewBuilder
    private var leftPaneContent: some View {
        if layout.leftPaneSource == .primaryRemote, let server = workspace.connectedProfile {
            FilePaneView(
                title: server.name.isEmpty ? server.host : server.name,
                path: $workspace.remotePath,
                files: workspace.sortedRemoteFiles,
                selection: $workspace.remoteSelection,
                loading: workspace.loadingRemote,
                query: query,
                remote: true,
                side: .left,
                role: .primaryRemote,
                showGoToFolder: $layout.showLeftGoToFolder,
                workspace: workspace,
                appearance: appearance,
                layout: layout
            )
        } else {
            FilePaneView(
                title: L10n.tr("本地", "Local"),
                path: $workspace.localPath,
                files: workspace.sortedLocalFiles,
                selection: $workspace.localSelection,
                loading: workspace.loadingLocal,
                query: query,
                remote: false,
                side: .left,
                role: .leftLocal,
                showGoToFolder: $layout.showLeftGoToFolder,
                workspace: workspace,
                appearance: appearance,
                layout: layout
            )
        }
    }

    @ViewBuilder
    private var rightPaneContent: some View {
        switch layout.rightPaneSource {
        case .primaryRemote:
            if let server = workspace.connectedProfile {
                FilePaneView(
                    title: server.name.isEmpty ? server.host : server.name,
                    path: $workspace.remotePath,
                    files: workspace.sortedRemoteFiles,
                    selection: $workspace.remoteSelection,
                    loading: workspace.loadingRemote,
                    query: query,
                    remote: true,
                    side: .right,
                    role: .primaryRemote,
                    showGoToFolder: $layout.showRightGoToFolder,
                    workspace: workspace,
                    appearance: appearance,
                    layout: layout
                )
            } else {
                VStack(spacing: 0) {
                    RightPaneSourceHeaderBar(layout: layout, workspace: workspace)
                    Divider()
                    DisconnectedStateView(showConnect: $showConnect) {
                        workspace.error = L10n.tr("请先连接服务器，再把文件拖到这里上传。",
                                                  "Connect to a server first, then drop files here to upload.")
                    }
                }
            }

        case .secondLocal:
            FilePaneView(
                title: L10n.tr("本地 (右侧)", "Local (Right)"),
                path: $layout.secondLocalPath,
                files: layout.sortedSecondLocalFiles,
                selection: $layout.secondLocalSelection,
                loading: layout.loadingSecondLocal,
                query: query,
                remote: false,
                side: .right,
                role: .secondLocal,
                showGoToFolder: $layout.showRightGoToFolder,
                workspace: workspace,
                appearance: appearance,
                layout: layout
            )

        case .secondRemote:
            if let secondServer = layout.secondRemoteProfile {
                FilePaneView(
                    title: secondServer.name.isEmpty ? secondServer.host : secondServer.name,
                    path: $layout.secondRemotePath,
                    files: layout.sortedSecondRemoteFiles,
                    selection: $layout.secondRemoteSelection,
                    loading: layout.loadingSecondRemote,
                    query: query,
                    remote: true,
                    side: .right,
                    role: .secondRemote,
                    showGoToFolder: $layout.showRightGoToFolder,
                    workspace: workspace,
                    appearance: appearance,
                    layout: layout
                )
            } else {
                VStack(spacing: 0) {
                    RightPaneSourceHeaderBar(layout: layout, workspace: workspace)
                    Divider()
                    SecondRemoteLauncherView(workspace: workspace, layout: layout, showConnect: $showConnect)
                }
            }
        }
    }
}

private struct RightPaneSourceHeaderBar: View {
    @ObservedObject var layout: PaneLayoutController
    @ObservedObject var workspace: Workspace

    var body: some View {
        HStack(spacing: 8) {
            RightPaneSourceMenu(layout: layout, workspace: workspace)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}

private struct RightPaneSourceMenu: View {
    @ObservedObject var layout: PaneLayoutController
    @ObservedObject var workspace: Workspace

    var body: some View {
        Menu {
            ForEach(RightPaneSourceKind.allCases) { source in
                Button {
                    layout.rightPaneSource = source
                } label: {
                    HStack {
                        Text(source.localizedTitle)
                        if layout.rightPaneSource == source {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: sourceIcon)
                    .foregroundStyle(Color.accentColor)
                Text(layout.rightPaneSource.localizedTitle)
                    .font(.caption.weight(.medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
        }
        .menuStyle(.borderlessButton)
        .help(L10n.tr("切换右侧面板来源（主服务器 / 第二个本地 / 第二个服务器）", "Switch right pane source (Primary Remote / Second Local / Second Remote)"))
    }

    private var sourceIcon: String {
        switch layout.rightPaneSource {
        case .primaryRemote: return "network"
        case .secondLocal: return "internaldrive"
        case .secondRemote: return "server.rack"
        }
    }
}

private struct SecondRemoteLauncherView: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var layout: PaneLayoutController
    @Binding var showConnect: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.left.arrow.right.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)

            Text(L10n.tr("服务器 ⇄ 服务器传输", "Server-to-Server Mode"))
                .font(.title3.bold())

            Text(L10n.tr("选择一个已保存的书签作为右侧第二个远程连接，即可在两个服务器之间直接拖放与传输。",
                         "Choose a saved bookmark for the right-hand remote pane to drag and transfer directly between two servers."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            if workspace.profiles.isEmpty {
                Button(L10n.tr("新建服务器连接…", "New Server Connection…")) {
                    workspace.editingProfile = nil
                    showConnect = true
                }
                .buttonStyle(.glassProminent)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(workspace.profiles) { profile in
                            Button {
                                layout.connectSecondRemoteSaved(profile, workspace: workspace)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "server.rack")
                                        .foregroundStyle(Color.accentColor)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(profile.name.isEmpty ? profile.host : profile.name)
                                            .fontWeight(.medium)
                                        Text("\(profile.protocolKind.title) · \(profile.host):\(profile.port)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(L10n.tr("连接", "Connect"))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color.accentColor)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: 360)
                }
                .frame(maxHeight: 220)
            }
        }
        .padding()
        .frame(minWidth: 350, maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SecondRemoteHostChallengeDialog: View {
    let challenge: Workspace.HostChallenge
    @ObservedObject var workspace: Workspace
    @ObservedObject var layout: PaneLayoutController

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(L10n.tr("核对第二服务器指纹", "Verify Second Server Host Key"), systemImage: "lock.shield")
                .font(.title2.bold())
            Text(L10n.tr("首次连接至「\(challenge.profile.host)」，请核对公钥指纹：",
                         "First connection to \"\(challenge.profile.host)\". Verify its public key fingerprint:"))
            Text(RemoteClient.fingerprint(challenge.key))
                .font(.system(.body, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05))
                .cornerRadius(6)
                .textSelection(.enabled)
            HStack {
                Button(L10n.tr("取消", "Cancel")) {
                    layout.secondRemoteHostChallenge = nil
                    layout.disconnectSecondRemote()
                }
                Spacer()
                Button(L10n.tr("信任并连接", "Trust & Connect")) {
                    layout.approveSecondRemoteHostKey(workspace: workspace)
                }
                .buttonStyle(.glassProminent)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

private struct SecondRemotePasswordSheet: View {
    let profile: ServerProfile
    @ObservedObject var workspace: Workspace
    @ObservedObject var layout: PaneLayoutController
    @State private var password = ""
    @State private var remember = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.tr("输入第二服务器密码", "Enter Password for Second Server"))
                .font(.headline)
            Text("\(profile.username)@\(profile.host)")
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField(L10n.tr("密码", "Password"), text: $password)
                .textFieldStyle(.roundedBorder)
            Toggle(L10n.tr("保存到钥匙串", "Remember in Keychain"), isOn: $remember)
            HStack {
                Button(L10n.tr("取消", "Cancel")) {
                    layout.secondRemotePasswordPrompt = nil
                }
                Spacer()
                Button(L10n.tr("连接", "Connect")) {
                    layout.connectSecondRemoteWithPassword(profile, password: password, remember: remember, workspace: workspace)
                }
                .buttonStyle(.glassProminent)
                .disabled(password.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
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
    @ObservedObject var layout: PaneLayoutController
    @Binding var showConnect: Bool
    @State private var isPlacesPinTargeted = false

    var body: some View {
        List(selection: $workspace.selectedServer) {
            Section {
                ForEach(PlaceItem.defaultPlaces()) { place in
                    Button {
                        navigateLocalPlace(place.path)
                    } label: {
                        Label(place.name, systemImage: place.systemImage)
                    }
                    .buttonStyle(.plain)
                    .dropDestination(for: DroppedItem.self) { items, _ in
                        workspace.handleDrop(items, toRemote: false, directory: place.path)
                    }
                }

                ForEach(layout.customPlaces) { custom in
                    Button {
                        openCustomPlace(custom)
                    } label: {
                        HStack(spacing: 6) {
                            Label(custom.name, systemImage: custom.systemImage)
                            Spacer()
                            if custom.isRemote {
                                Text(L10n.tr("远程", "Remote"))
                                    .font(.system(size: 9, weight: .medium))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .dropDestination(for: DroppedItem.self) { items, _ in
                        _ = handleDropOnCustomPlace(items, place: custom)
                        return true
                    }
                    .contextMenu {
                        Button(L10n.tr("打开", "Open")) {
                            openCustomPlace(custom)
                        }
                        Button(L10n.tr("复制路径", "Copy Path")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(custom.path, forType: .string)
                        }
                        Divider()
                        Button(L10n.tr("从常用位置取消固定", "Unpin from Places"), role: .destructive) {
                            layout.unpinCustomPlace(custom)
                        }
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: isPlacesPinTargeted ? "pin.fill" : "pin")
                        .font(.caption2)
                        .foregroundStyle(isPlacesPinTargeted ? Color.accentColor : Color.secondary)
                    Text(L10n.tr("拖放文件夹固定到此处", "Drop folder here to pin"))
                        .font(.caption)
                        .foregroundStyle(isPlacesPinTargeted ? Color.accentColor : Color.secondary)
                }
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isPlacesPinTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
                )
                .dropDestination(for: DroppedItem.self) { items, _ in
                    return layout.pinDroppedItems(
                        items,
                        connectedProfileId: workspace.connectedProfile?.id,
                        secondRemoteProfileId: layout.secondRemoteProfile?.id
                    )
                } isTargeted: { targeted in
                    isPlacesPinTargeted = targeted
                }
            } header: {
                HStack {
                    Text(L10n.tr("常用位置", "Places"))
                    Spacer()
                    Button {
                        let name = (workspace.localPath as NSString).lastPathComponent
                        layout.pinCustomPlace(name: name, path: workspace.localPath, isRemote: false, profileId: nil)
                    } label: {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.tr("固定当前本地文件夹", "Pin Current Local Folder"))
                }
                .dropDestination(for: DroppedItem.self) { items, _ in
                    return layout.pinDroppedItems(
                        items,
                        connectedProfileId: workspace.connectedProfile?.id,
                        secondRemoteProfileId: layout.secondRemoteProfile?.id
                    )
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
                            Button(L10n.tr("在右侧第二窗格连接", "Connect in Right Second Pane")) {
                                layout.rightPaneSource = .secondRemote
                                layout.connectSecondRemoteSaved(profile, workspace: workspace)
                            }
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

    private func navigateLocalPlace(_ path: String) {
        if layout.activePaneSide == .right && layout.rightPaneSource == .secondLocal {
            layout.navigateSecondLocal(to: path, showHidden: workspace.showHidden)
        } else {
            workspace.navigateLocal(to: path)
            layout.recordPathVisit(path, remote: false)
        }
    }

    private func openCustomPlace(_ place: CustomPlaceItem) {
        if !place.isRemote {
            navigateLocalPlace(place.path)
            return
        }
        if let pid = place.profileId {
            if workspace.connectedProfile?.id == pid {
                workspace.navigateRemote(to: place.path)
            } else if layout.secondRemoteProfile?.id == pid {
                layout.navigateSecondRemote(to: place.path, workspace: workspace)
            } else if var profile = workspace.profiles.first(where: { $0.id == pid }) {
                if profile.trustedHostKey != nil || profile.protocolKind != .sftp {
                    profile.initialPath = place.path
                }
                workspace.connectSaved(profile)
            }
        } else if workspace.connectedProfile != nil {
            workspace.navigateRemote(to: place.path)
        }
    }

    private func handleDropOnCustomPlace(_ items: [DroppedItem], place: CustomPlaceItem) -> Bool {
        if !place.isRemote {
            return workspace.handleDrop(items, to: .leftLocal, directory: place.path, layout: layout)
        }
        if let pid = place.profileId, workspace.connectedProfile?.id == pid {
            return workspace.handleDrop(items, to: .primaryRemote, directory: place.path, layout: layout)
        }
        if let pid = place.profileId, layout.secondRemoteProfile?.id == pid {
            return workspace.handleDrop(items, to: .secondRemote, directory: place.path, layout: layout)
        }
        return false
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

// MARK: - Go To Folder Popover (⇧⌘G)

private struct GoToFolderPopover: View {
    let title: String
    let currentPath: String
    let history: [String]
    let remote: Bool
    let onNavigate: (String) -> Void
    @Binding var isPresented: Bool
    @State private var inputPath: String = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "folder.badge.questionmark")
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .font(.headline)
                Spacer()
                Text("⇧⌘G")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                TextField(L10n.tr("输入目标文件夹路径…", "Enter folder path…"), text: $inputPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .focused($isFieldFocused)
                    .onSubmit {
                        commitNavigation()
                    }

                Button(L10n.tr("前往", "Go")) {
                    commitNavigation()
                }
                .buttonStyle(.glassProminent)
                .disabled(inputPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            let suggestions = filteredHistory
            if !suggestions.isEmpty {
                Divider()
                Text(L10n.tr("最近访问路径", "Recent Locations"))
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)

                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(suggestions, id: \.self) { candidate in
                            Button {
                                inputPath = candidate
                                commitNavigation()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: remote ? "network" : "folder")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(candidate)
                                        .font(.system(size: 11, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                    Spacer()
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.04)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 150)
            }
        }
        .padding(14)
        .frame(width: 380)
        .onAppear {
            inputPath = currentPath
            DispatchQueue.main.async {
                isFieldFocused = true
            }
        }
    }

    private var filteredHistory: [String] {
        let trimmed = inputPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let pool = history.filter { $0 != currentPath }
        if trimmed.isEmpty || trimmed == currentPath {
            return Array(pool.prefix(8))
        }
        return Array(pool.filter { $0.localizedCaseInsensitiveContains(trimmed) }.prefix(8))
    }

    private func commitNavigation() {
        let trimmed = inputPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let expanded = (!remote && trimmed.hasPrefix("~"))
            ? NSString(string: trimmed).expandingTildeInPath
            : trimmed
        isPresented = false
        onNavigate(expanded)
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
    let side: PaneSide
    let role: BrowserPaneRole
    @Binding var showGoToFolder: Bool
    @ObservedObject var workspace: Workspace
    @ObservedObject var appearance: PaneAppearanceState
    @ObservedObject var layout: PaneLayoutController

    @State private var isEditingPath = false
    @State private var tempPathText = ""
    @State private var dropTargetID: String?
    @State private var isPaneDropTargeted = false

    var currentSortField: FileSortField {
        switch role {
        case .leftLocal: return workspace.localSortField
        case .primaryRemote: return workspace.remoteSortField
        case .secondLocal: return layout.secondLocalSortField
        case .secondRemote: return layout.secondRemoteSortField
        }
    }

    var currentSortAscending: Bool {
        switch role {
        case .leftLocal: return workspace.localSortAscending
        case .primaryRemote: return workspace.remoteSortAscending
        case .secondLocal: return layout.secondLocalSortAscending
        case .secondRemote: return layout.secondRemoteSortAscending
        }
    }

    var filtered: [FileEntry] {
        files.filter {
            (workspace.showHidden || !$0.name.hasPrefix(".")) &&
            (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            paneHeaderBar
            Divider()
            breadcrumbBar
            Divider()
            paneBodyContent
        }
        .frame(minWidth: 350, maxWidth: .infinity, maxHeight: .infinity)
        .simultaneousGesture(TapGesture().onEnded {
            layout.activePaneSide = side
        })
        .dropDestination(for: DroppedItem.self) { items, _ in
            workspace.handleDrop(items, to: role, directory: nil, layout: layout)
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

    private var paneHeaderBar: some View {
        HStack(spacing: 7) {
            if side == .right {
                RightPaneSourceMenu(layout: layout, workspace: workspace)
            } else if workspace.connectedProfile != nil {
                Menu {
                    ForEach(LeftPaneSourceKind.allCases) { source in
                        Button {
                            layout.leftPaneSource = source
                        } label: {
                            HStack {
                                Text(source.localizedTitle)
                                if layout.leftPaneSource == source {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: remote ? "network" : "internaldrive")
                            .foregroundStyle(Color.accentColor)
                        Text(title)
                            .fontWeight(.semibold)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.borderlessButton)
            } else {
                Image(systemName: remote ? "network" : "internaldrive")
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .fontWeight(.semibold)
            }

            if side == .right && role != .secondLocal {
                Text(title)
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }

            Text("(\(files.count))")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if loading {
                ProgressView().controlSize(.small)
            }

            // Sort & Column Options Menu
            Menu {
                ForEach(FileSortField.allCases) { field in
                    Button {
                        toggleSortForRole(field)
                    } label: {
                        HStack {
                            Text(field.localizedTitle)
                            if currentSortField == field {
                                Image(systemName: currentSortAscending ? "chevron.up" : "chevron.down")
                            }
                        }
                    }
                }
                Divider()
                Toggle(L10n.tr("显示权限列", "Show Permissions Column"), isOn: $appearance.showPermissionsColumn)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up.arrow.down")
                    Text(currentSortField.localizedTitle)
                }
                .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .help(L10n.tr("排序与列选项", "Sort & Column Options"))

            Button(action: { workspace.parentPane(role: role, layout: layout) }) {
                Image(systemName: "arrow.up")
            }
            .help(L10n.tr("上一级文件夹", "Enclosing Folder"))
            .buttonStyle(.borderless)

            Button(action: { workspace.createFolder(in: role, layout: layout) }) {
                Image(systemName: "folder.badge.plus")
            }
            .help(L10n.tr("新建文件夹", "New Folder"))
            .buttonStyle(.borderless)

            Button(action: { workspace.createNewFile(in: role, layout: layout) }) {
                Image(systemName: "doc.badge.plus")
            }
            .help(L10n.tr("新建空文件 (⌥⌘N)", "New Empty File (⌥⌘N)"))
            .buttonStyle(.borderless)

            if !remote {
                Button(action: {
                    if role == .secondLocal { layout.chooseSecondLocal(showHidden: workspace.showHidden) }
                    else { workspace.chooseLocal() }
                }) {
                    Image(systemName: "folder")
                }
                .help(L10n.tr("选取文件夹…", "Choose Folder…"))
                .buttonStyle(.borderless)
            } else if role == .secondRemote {
                Button(action: { layout.disconnectSecondRemote() }) {
                    Image(systemName: "eject")
                }
                .help(L10n.tr("断开第二个服务器", "Disconnect Second Server"))
                .buttonStyle(.borderless)
            }

            if role == .leftLocal || role == .primaryRemote {
                Button(action: { workspace.openTerminal(remote: remote) }) {
                    Image(systemName: "terminal")
                }
                .help(L10n.tr("在终端中打开", "Open in Terminal"))
                .buttonStyle(.borderless)
            }

            Button(action: {
                if let selId = selection.first, let entry = files.first(where: { $0.id == selId }) {
                    workspace.previewEntry(entry, in: role, layout: layout)
                }
            }) {
                Image(systemName: "eye")
            }
            .help(L10n.tr("快速查看 (Quick Look)", "Quick Look"))
            .buttonStyle(.borderless)
            .disabled(selection.isEmpty)

            Button(action: { workspace.refreshPane(role: role, layout: layout) }) {
                Image(systemName: "arrow.clockwise")
            }
            .help(L10n.tr("刷新", "Refresh"))
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var breadcrumbBar: some View {
        HStack(spacing: 4) {
            if isEditingPath {
                TextField(L10n.tr("路径", "Path"), text: $tempPathText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit {
                        isEditingPath = false
                        workspace.navigatePane(to: tempPathText, role: role, layout: layout)
                    }
                Button(L10n.tr("完成", "Done")) {
                    isEditingPath = false
                    workspace.navigatePane(to: tempPathText, role: role, layout: layout)
                }
                .buttonStyle(.glassProminent)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        let crumbs = RemotePath.breadcrumbs(for: path)
                        ForEach(crumbs) { crumb in
                            Button {
                                workspace.navigatePane(to: crumb.path, role: role, layout: layout)
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
                                workspace.handleDrop(items, to: role, directory: crumb.path, layout: layout)
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
                    layout.activePaneSide = side
                    showGoToFolder = true
                } label: {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help(L10n.tr("前往文件夹… (⇧⌘G)", "Go to Folder… (⇧⌘G)"))
                .popover(isPresented: $showGoToFolder) {
                    GoToFolderPopover(
                        title: L10n.tr("前往文件夹", "Go to Folder"),
                        currentPath: path,
                        history: role.isRemote ? layout.remotePathHistory : layout.localPathHistory,
                        remote: role.isRemote,
                        onNavigate: { target in
                            workspace.navigatePane(to: target, role: role, layout: layout)
                        },
                        isPresented: $showGoToFolder
                    )
                }

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
    }

    @ViewBuilder
    private var paneBodyContent: some View {
        switch appearance.displayMode {
        case .list:
            listTableView(entries: filtered)

        case .columns:
            ColumnBrowserView(
                path: path,
                files: filtered,
                selection: $selection,
                remote: remote,
                role: role,
                query: query,
                sortField: currentSortField,
                sortAscending: currentSortAscending,
                workspace: workspace,
                layout: layout
            )
            .dropDestination(for: DroppedItem.self) { items, _ in
                workspace.handleDrop(items, to: role, directory: nil, layout: layout)
            }

        case .icons:
            thumbnailGridView(entries: filtered)

        case .gallery:
            gallerySplitView(entries: filtered)
        }
    }

    @ViewBuilder
    private func listTableView(entries: [FileEntry]) -> some View {
        Table(of: FileEntry.self, selection: $selection) {
            TableColumn(L10n.tr("名称", "Name")) { entry in
                HStack(spacing: 6) {
                    ZStack(alignment: .bottomLeading) {
                        Image(systemName: entry.isDirectory ? "folder.fill" : BrowserIconHelper.symbolName(for: entry))
                            .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                        if entry.isSymbolicLink {
                            Image(systemName: "arrowshape.turn.up.right.fill")
                                .font(.system(size: 7, weight: .bold))
                                .padding(1.5)
                                .background(Circle().fill(.ultraThinMaterial))
                                .foregroundStyle(Color.primary)
                                .offset(x: -3, y: 3)
                        }
                    }
                    .frame(width: 18, height: 18)

                    Text(entry.name)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if entry.isSymbolicLink {
                        Image(systemName: "arrowshape.turn.up.right.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .help(L10n.tr("符号链接", "Symbolic Link"))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    activateEntry(entry)
                }
            }
            .width(min: 160, ideal: 230)

            TableColumn(L10n.tr("大小", "Size")) { entry in
                Text(formattedSize(entry))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(78)

            if appearance.showPermissionsColumn {
                TableColumn(L10n.tr("权限", "Permissions")) { entry in
                    FilePermissionsLabel(entry: entry, remote: remote)
                }
                .width(88)
            }

            TableColumn(L10n.tr("种类", "Kind")) { entry in
                Text(entry.localizedKindDescription)
                    .foregroundStyle(.secondary)
            }
            .width(86)

            TableColumn(L10n.tr("修改日期", "Date Modified")) { entry in
                Text(formattedDate(entry.modified))
                    .foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 135)
        } rows: {
            tableRows(for: entries)
        }
        .dropDestination(for: DroppedItem.self) { items, _ in
            workspace.handleDrop(items, to: role, directory: nil, layout: layout)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            let selected = files.filter { ids.contains($0.id) }
            BrowserEntryContextMenu(
                entries: selected,
                currentDirectory: path,
                role: role,
                workspace: workspace,
                layout: layout
            )
        } primaryAction: { ids in
            if let entry = files.first(where: { ids.contains($0.id) }) {
                activateEntry(entry)
            }
        }
        .overlay {
            if entries.isEmpty && !loading {
                emptyFolderPlaceholder
            }
        }
    }

    @ViewBuilder
    private func thumbnailGridView(entries: [FileEntry]) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                let cellWidth = CGFloat(appearance.gridItemSize)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: cellWidth, maximum: cellWidth + 24), spacing: 12)], spacing: 12) {
                    ForEach(entries) { entry in
                        FileGridCell(
                            entry: entry,
                            remote: remote,
                            cellSize: cellWidth,
                            isSelected: selection.contains(entry.id) || dropTargetID == entry.id
                        )
                        .onDrag { workspace.dragProvider(for: entry, role: role, layout: layout) }
                        .dropDestination(for: DroppedItem.self) { items, _ in
                            workspace.handleDrop(items, to: role, directory: entry.isDirectory ? entry.path : nil, layout: layout)
                        } isTargeted: { targeted in
                            if entry.isDirectory {
                                dropTargetID = targeted ? entry.id : (dropTargetID == entry.id ? nil : dropTargetID)
                            }
                        }
                        .onTapGesture {
                            layout.activePaneSide = side
                            selection = [entry.id]
                        }
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            activateEntry(entry)
                        })
                        .contextMenu {
                            let targetSelection = selection.contains(entry.id) && selection.count > 1
                                ? files.filter { selection.contains($0.id) }
                                : [entry]
                            BrowserEntryContextMenu(
                                entries: targetSelection,
                                currentDirectory: path,
                                role: role,
                                workspace: workspace,
                                layout: layout
                            )
                        }
                    }
                }
                .padding(14)
            }
            .dropDestination(for: DroppedItem.self) { items, _ in
                workspace.handleDrop(items, to: role, directory: nil, layout: layout)
            }
            .contextMenu {
                BrowserBackgroundContextMenu(
                    directoryPath: path,
                    role: role,
                    workspace: workspace,
                    layout: layout
                )
            }
            .overlay {
                if entries.isEmpty && !loading {
                    emptyFolderPlaceholder
                }
            }

            Divider()

            HStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Slider(value: $appearance.gridItemSize, in: 72...160, step: 4)
                    .frame(width: 140)
                    .controlSize(.small)
                Text("\(Int(appearance.gridItemSize)) pt")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial)
        }
    }

    @ViewBuilder
    private func gallerySplitView(entries: [FileEntry]) -> some View {
        let selectedEntry = selection.first.flatMap { id in files.first(where: { $0.id == id }) }
        VStack(spacing: 0) {
            GalleryPreviewCanvas(
                entry: selectedEntry,
                role: role,
                workspace: workspace,
                layout: layout
            )
            .frame(minHeight: 190, maxHeight: 250)

            Divider()

            listTableView(entries: entries)
        }
    }

    private var emptyFolderPlaceholder: some View {
        ContentUnavailableView(
            L10n.tr("没有项目", "No Items"),
            systemImage: "folder",
            description: Text(query.isEmpty
                ? L10n.tr("此文件夹为空。", "This folder is empty.")
                : L10n.tr("未找到匹配的项目。", "No matching items found."))
        )
        .dropDestination(for: DroppedItem.self) { items, _ in
            workspace.handleDrop(items, to: role, directory: nil, layout: layout)
        }
    }

    @TableRowBuilder<FileEntry>
    private func tableRows(for entries: [FileEntry]) -> some TableRowContent<FileEntry> {
        ForEach(entries) { entry in
            if entry.isDirectory {
                TableRow(entry)
                    .itemProvider { workspace.dragProvider(for: entry, role: role, layout: layout) }
                    .dropDestination(for: DroppedItem.self) { items in
                        workspace.handleDrop(items, to: role, directory: entry.path, layout: layout)
                    }
            } else {
                TableRow(entry)
                    .itemProvider { workspace.dragProvider(for: entry, role: role, layout: layout) }
                    .dropDestination(for: DroppedItem.self) { items in
                        workspace.handleDrop(items, to: role, directory: nil, layout: layout)
                    }
            }
        }
    }

    private func activateEntry(_ entry: FileEntry) {
        if !entry.isDirectory && TextFileHelper.isTextFileName(entry.name) {
            workspace.openEditorInPane(for: entry, role: role, layout: layout)
        } else {
            workspace.openEntry(entry, in: role, layout: layout)
        }
    }

    private func toggleSortForRole(_ field: FileSortField) {
        switch role {
        case .leftLocal: workspace.toggleSort(field, remote: false)
        case .primaryRemote: workspace.toggleSort(field, remote: true)
        case .secondLocal: layout.toggleSecondLocalSort(field)
        case .secondRemote: layout.toggleSecondRemoteSort(field)
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
}

// MARK: - Async POSIX Permissions Cell Label

private struct FilePermissionsLabel: View {
    let entry: FileEntry
    let remote: Bool
    @State private var modeText: String = "—"

    var body: some View {
        Text(modeText)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .task(id: "\(entry.id):\(entry.permissions):\(entry.modified?.timeIntervalSince1970 ?? 0)") {
                modeText = await BrowserMediaCache.shared.formattedPermissions(for: entry, remote: remote)
            }
    }
}

// MARK: - Gallery / Preview Split Canvas

private struct GalleryPreviewCanvas: View {
    let entry: FileEntry?
    let role: BrowserPaneRole
    @ObservedObject var workspace: Workspace
    @ObservedObject var layout: PaneLayoutController
    @State private var previewContent: QuickPreviewContent?
    @State private var modeString: String = "—"

    var body: some View {
        VStack(spacing: 0) {
            if let entry {
                ZStack {
                    Color.primary.opacity(0.025)
                    previewVisual(for: entry)
                        .padding(12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(entry.name)
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                            if entry.isSymbolicLink {
                                Label(L10n.tr("符号链接", "Symlink"), systemImage: "arrowshape.turn.up.right.fill")
                                    .font(.caption2)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                            }
                        }
                        HStack(spacing: 8) {
                            Text(entry.localizedKindDescription)
                            if !entry.isDirectory {
                                Text("·")
                                Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                                    .monospacedDigit()
                            }
                            Text("·")
                            Text(modeString)
                                .font(.system(.caption2, design: .monospaced))
                            if let mod = entry.modified {
                                Text("·")
                                Text(mod.formatted(date: .abbreviated, time: .shortened))
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        workspace.previewEntry(entry, in: role, layout: layout)
                    } label: {
                        Label(L10n.tr("快速查看", "Quick Look"), systemImage: "eye")
                    }
                    .controlSize(.small)

                    Button {
                        workspace.openEntry(entry, in: role, layout: layout)
                    } label: {
                        Label(
                            entry.isDirectory ? L10n.tr("打开", "Open") : (role.isRemote ? L10n.tr("下载", "Download") : L10n.tr("打开", "Open")),
                            systemImage: role.isRemote && !entry.isDirectory ? "arrow.down" : "arrow.up.forward.app"
                        )
                    }
                    .controlSize(.small)
                    .buttonStyle(.glassProminent)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .task(id: "\(role):\(entry.id):\(entry.size)") {
                    previewContent = nil
                    modeString = await BrowserMediaCache.shared.formattedPermissions(for: entry, remote: role.isRemote)
                    let client = workspace.client(for: role, layout: layout)
                    previewContent = await BrowserMediaCache.shared.loadPreview(for: entry, remote: role.isRemote, client: client)
                }
            } else {
                ContentUnavailableView(
                    L10n.tr("快速预览", "Quick Preview"),
                    systemImage: "rectangle.split.1x2",
                    description: Text(L10n.tr("在下方列表中选择文件查看图像、文本片段与详细属性", "Select an item below to preview images, text snippets, and metadata"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func previewVisual(for entry: FileEntry) -> some View {
        switch previewContent {
        case .image(let nsImage):
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        case .text(let snippet):
            ScrollView {
                Text(snippet.isEmpty ? L10n.tr("(空文件)", "(Empty File)") : snippet)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxWidth: 620, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor).opacity(0.75)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
        case .icon(let nsImage, _):
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 84, height: 84)
        case nil:
            ProgressView()
        }
    }
}

// MARK: - Thumbnail Grid Cell

struct FileGridCell: View {
    let entry: FileEntry
    let remote: Bool
    let cellSize: CGFloat
    let isSelected: Bool
    @State private var thumbnailImage: NSImage?

    init(entry: FileEntry, remote: Bool = false, cellSize: CGFloat = 104, isSelected: Bool) {
        self.entry = entry
        self.remote = remote
        self.cellSize = cellSize
        self.isSelected = isSelected
    }

    private var iconDimension: CGFloat {
        max(36, cellSize * 0.56)
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let thumbnailImage {
                        Image(nsImage: thumbnailImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    } else {
                        Image(systemName: entry.isDirectory ? "folder.fill" : BrowserIconHelper.symbolName(for: entry))
                            .font(.system(size: iconDimension * 0.72))
                            .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                    }
                }
                .frame(width: iconDimension, height: iconDimension)

                if entry.isSymbolicLink {
                    Image(systemName: "arrowshape.turn.up.right.fill")
                        .font(.system(size: 10, weight: .bold))
                        .padding(3)
                        .background(Circle().fill(.ultraThinMaterial))
                        .foregroundStyle(Color.primary)
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                        .offset(x: 3, y: 3)
                }
            }

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
        .frame(width: cellSize, height: cellSize + 24)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .contentShape(Rectangle())
        .task(id: "\(remote):\(entry.id):\(Int(cellSize)):\(entry.modified?.timeIntervalSince1970 ?? 0)") {
            if remote {
                thumbnailImage = BrowserMediaCache.shared.iconForRemoteEntry(entry)
            } else {
                thumbnailImage = await BrowserMediaCache.shared.thumbnail(
                    forLocalEntry: entry,
                    pixelSize: Int(iconDimension * 2)
                )
            }
        }
    }
}

// MARK: - Status Bar View

struct StatusBarView: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var layout: PaneLayoutController

    private var rightCount: Int {
        switch layout.rightPaneSource {
        case .primaryRemote: return workspace.remoteFiles.count
        case .secondLocal: return layout.secondLocalFiles.count
        case .secondRemote: return layout.secondRemoteFiles.count
        }
    }

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

            if layout.rightPaneSource == .secondRemote, let second = layout.secondRemoteProfile {
                Text("⇄")
                    .foregroundStyle(.tertiary)
                HStack(spacing: 5) {
                    Circle().fill(Color.blue).frame(width: 7, height: 7)
                    Text("\(second.protocolKind.title) · \(second.name.isEmpty ? second.host : second.name)")
                }
            } else if layout.rightPaneSource == .secondLocal {
                Text("·").foregroundStyle(.tertiary)
                Text(L10n.tr("右侧本地双栏模式", "Dual Local Mode"))
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

            Text(L10n.tr("\(workspace.localFiles.count) 个本地项目 · \(rightCount) 个右侧项目",
                         "\(workspace.localFiles.count) left · \(rightCount) right"))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }
}
