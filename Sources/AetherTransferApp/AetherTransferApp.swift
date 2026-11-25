import SwiftUI
import AetherTransferCore

@main struct AetherTransferApp: App {
    @StateObject private var workspace = Workspace()

    var body: some Scene {
        WindowGroup("AetherTransfer") {
            MainView(workspace: workspace)
                .frame(minWidth: 1040, minHeight: 680)
                .onOpenURL { url in
                    workspace.handleIncomingURL(url)
                }
        }
        .handlesExternalEvents(matching: ["*"])
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
                Button(L10n.tr("新建标签页", "New Tab")) { workspace.addNewTab() }
                    .keyboardShortcut("t", modifiers: [.command])
                Button(L10n.tr("关闭标签页", "Close Tab")) {
                    if let tab = workspace.tabManager.activeTab {
                        workspace.closeTab(tab.id)
                    }
                }
                .keyboardShortcut("w", modifiers: [.command])
                Button(L10n.tr("新建文件夹…", "New Folder…")) {
                    workspace.requestNewFolder()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                Button(L10n.tr("新建空文件…", "New Empty File…")) {
                    workspace.requestNewEmptyFile()
                }
                .keyboardShortcut("n", modifiers: [.command, .option])

                Divider()

                Button(L10n.tr("快速查看", "Quick Look")) {
                    if let entry = workspace.selectedEntry {
                        workspace.previewItem(entry, remote: !workspace.remoteSelection.isEmpty)
                    }
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(workspace.selectedEntry == nil)

                Button(L10n.tr("在内置编辑器中打开…", "Edit in Built-in Editor…")) {
                    if let entry = workspace.selectedEntry, !entry.isDirectory {
                        workspace.openEditor(for: entry, remote: !workspace.remoteSelection.isEmpty)
                    }
                }
                .disabled(workspace.selectedEntry == nil || workspace.selectedEntry?.isDirectory == true)

                Button(L10n.tr("在外部编辑器中打开", "Edit in External Editor")) {
                    workspace.requestExternalEdit()
                }
                .keyboardShortcut("e", modifiers: [.command])
                .disabled(workspace.selectedEntry == nil || workspace.selectedEntry?.isDirectory == true)

                Divider()

                Button(L10n.tr("复制所选项目", "Copy Selection")) {
                    workspace.copySelection(remote: !workspace.remoteSelection.isEmpty)
                }
                .keyboardShortcut("c", modifiers: [.command, .option])

                Button(L10n.tr("粘贴到当前面板", "Paste Here")) {
                    workspace.pasteClipboard(toRemote: workspace.connectedProfile != nil && !workspace.remoteSelection.isEmpty)
                }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(workspace.clipboard == nil)

                Button(L10n.tr("创建副本 (Duplicate)", "Duplicate")) {
                    if let entry = workspace.selectedEntry {
                        workspace.duplicateItem(entry, remote: !workspace.remoteSelection.isEmpty)
                    }
                }
                .keyboardShortcut("d", modifiers: [.command])
                .disabled(workspace.selectedEntry == nil)

                Divider()

                Button(L10n.tr("选择本地文件夹…", "Choose Local Folder…")) {
                    workspace.chooseLocal()
                }
                .keyboardShortcut("o", modifiers: [.command])
                Button(L10n.tr("刷新", "Refresh")) {
                    workspace.refreshLocal()
                    workspace.refreshRemote()
                }
                .keyboardShortcut("r", modifiers: [.command])

                Divider()

                Button(L10n.tr("导入服务器书签向导…", "Import Servers…")) {
                    workspace.v3UIStore.showImportServersSheet = true
                }
                Button(L10n.tr("从 ~/.ssh/config 导入主机", "Import Hosts from ~/.ssh/config")) {
                    _ = workspace.importSSHConfigHosts()
                }
                Button(L10n.tr("SSH 密钥管理器…", "SSH Key Manager…")) {
                    workspace.showSSHKeyManager = true
                }
                Button(L10n.tr("零知识加密书签同步 (.aethersync)…", "Encrypted Bookmark Sync (.aethersync)…")) {
                    workspace.showEncryptedSyncSheet = true
                }
            }

            CommandGroup(after: .sidebar) {
                Button {
                    workspace.v3UIStore.displayMode = .list
                } label: {
                    Label(BrowserDisplayMode.list.localizedTitle, systemImage: workspace.v3UIStore.displayMode == .list ? "checkmark" : BrowserDisplayMode.list.systemImage)
                }
                .keyboardShortcut("1", modifiers: [.command])

                Button {
                    workspace.v3UIStore.displayMode = .columns
                } label: {
                    Label(BrowserDisplayMode.columns.localizedTitle, systemImage: workspace.v3UIStore.displayMode == .columns ? "checkmark" : BrowserDisplayMode.columns.systemImage)
                }
                .keyboardShortcut("2", modifiers: [.command])

                Button {
                    workspace.v3UIStore.displayMode = .icons
                } label: {
                    Label(BrowserDisplayMode.icons.localizedTitle, systemImage: workspace.v3UIStore.displayMode == .icons ? "checkmark" : BrowserDisplayMode.icons.systemImage)
                }
                .keyboardShortcut("3", modifiers: [.command])

                Button {
                    workspace.v3UIStore.displayMode = .gallery
                } label: {
                    Label(BrowserDisplayMode.gallery.localizedTitle, systemImage: workspace.v3UIStore.displayMode == .gallery ? "checkmark" : BrowserDisplayMode.gallery.systemImage)
                }
                .keyboardShortcut("4", modifiers: [.command])

                Divider()

                Toggle(L10n.tr("显示隐藏文件", "Show Hidden Files"), isOn: $workspace.showHidden)
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                Toggle(L10n.tr("检查器面板", "Inspector"), isOn: $workspace.showInspector)
                    .keyboardShortcut("i", modifiers: [.command])
                Toggle(
                    L10n.tr("传输日志", "Transcript"),
                    isOn: Binding(
                        get: { workspace.rulesAndTranscriptStore.isTranscriptVisible },
                        set: { workspace.rulesAndTranscriptStore.setTranscriptVisible($0) }
                    )
                )
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Button(L10n.tr("显示选项…", "View Options…")) {
                    workspace.requestViewOptions()
                }
                .keyboardShortcut("b", modifiers: [.command, .option])

                Divider()

                Button(L10n.tr("上一个标签页", "Previous Tab")) {
                    workspace.selectPreviousTab()
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(workspace.tabManager.tabs.count <= 1)

                Button(L10n.tr("下一个标签页", "Next Tab")) {
                    workspace.selectNextTab()
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(workspace.tabManager.tabs.count <= 1)
            }

            CommandMenu(L10n.tr("转到", "Go")) {
                Button(L10n.tr("后退", "Back")) {
                    workspace.goBack(remote: workspace.connectedProfile != nil)
                }
                .keyboardShortcut("[", modifiers: [.command])
                Button(L10n.tr("前进", "Forward")) {
                    workspace.goForward(remote: workspace.connectedProfile != nil)
                }
                .keyboardShortcut("]", modifiers: [.command])
                Button(L10n.tr("上一级文件夹", "Enclosing Folder")) {
                    workspace.parent(remote: workspace.connectedProfile != nil)
                }
                .keyboardShortcut(.upArrow, modifiers: [.command])
                Button(L10n.tr("前往文件夹…", "Go to Folder…")) {
                    workspace.requestGoToFolder()
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])

                Divider()

                Button(L10n.tr("在终端中打开", "Open in Terminal")) {
                    workspace.openTerminal(remote: workspace.connectedProfile != nil)
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Button(L10n.tr(
                    workspace.isSyncBrowsingEnabled ? "关闭同步浏览" : "开启同步浏览",
                    workspace.isSyncBrowsingEnabled ? "Disable Synchronized Browsing" : "Enable Synchronized Browsing"
                )) {
                    workspace.toggleSyncBrowsing()
                }
                .disabled(workspace.connectedProfile == nil)
            }

            CommandMenu(L10n.tr("传输", "Transfer")) {
                Button(L10n.tr("上传所选项目", "Upload Selection")) {
                    workspace.uploadSelection()
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(workspace.connectedProfile == nil || workspace.localSelection.isEmpty)

                Button(L10n.tr("下载所选项目", "Download Selection")) {
                    workspace.downloadSelection()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(workspace.connectedProfile == nil || workspace.remoteSelection.isEmpty)

                Button(L10n.tr("文件夹同步…", "Folder Sync…")) {
                    workspace.startSyncAnalysis()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(workspace.connectedProfile == nil)

                Divider()

                Menu(L10n.tr("传输模式", "Transfer Mode")) {
                    ForEach(TransferMode.allCases) { mode in
                        Button {
                            workspace.setActiveTransferMode(mode)
                        } label: {
                            HStack {
                                Text(mode.localizedTitle)
                                if workspace.v3UIStore.activeTransferMode == mode {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }

                Button(workspace.isQueuePaused
                       ? L10n.tr("恢复传输队列", "Resume Queue")
                       : L10n.tr("暂停传输队列", "Pause Queue")) {
                    workspace.toggleQueuePause()
                }

                Button(L10n.tr("清除已完成任务", "Clear Completed")) {
                    workspace.clearCompletedTransfers()
                }

                Button(L10n.tr("取消所有传输", "Cancel All Transfers")) {
                    workspace.cancelAllTransfers()
                }
                .disabled(workspace.activeTransferCount == 0)
            }

            CommandMenu(L10n.tr("服务器", "Server")) {
                Button(L10n.tr("快速连接 / 服务器…", "Quick Connect / Servers…")) {
                    workspace.requestQuickConnect()
                }
                .keyboardShortcut("k", modifiers: [.command])

                Button(L10n.tr("断开当前连接", "Disconnect")) {
                    workspace.disconnect()
                }
                .disabled(workspace.connectedProfile == nil)

                Divider()

                Button(L10n.tr("发送原始服务器命令…", "Send Raw Server Command…")) {
                    workspace.v3UIStore.showRawCommandSheet = true
                }
                .disabled(workspace.connectedProfile == nil)

                Button(L10n.tr("列举 S3 存储桶…", "Browse S3 Buckets…")) {
                    if let profile = workspace.connectedProfile, profile.protocolKind == .s3 {
                        workspace.browseS3Buckets(for: profile, credentials: workspace.loadCredentials(for: profile))
                    }
                }
                .disabled(workspace.connectedProfile?.protocolKind != .s3)

                Button(L10n.tr("导入服务器书签…", "Import Servers…")) {
                    workspace.v3UIStore.showImportServersSheet = true
                }

                if !workspace.profiles.isEmpty {
                    Divider()
                    Menu(L10n.tr("连接已保存书签", "Connect to Bookmark")) {
                        ForEach(workspace.profiles) { profile in
                            Button(profile.name.isEmpty ? profile.host : profile.name) {
                                workspace.connectSaved(profile)
                            }
                        }
                    }
                }
            }
        }

        Settings {
            SettingsView(workspace: workspace)
        }

        MenuBarExtra("AetherTransfer", systemImage: "arrow.up.arrow.down.circle.fill") {
            MenuBarDropletView(workspace: workspace)
        }
        .menuBarExtraStyle(.window)
    }
}
