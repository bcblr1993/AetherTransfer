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
                Button(L10n.tr("新建标签页", "New Tab")) { workspace.addNewTab() }.keyboardShortcut("t")
                Button(L10n.tr("关闭标签页", "Close Tab")) {
                    if let tab = workspace.tabManager.activeTab {
                        workspace.closeTab(tab.id)
                    }
                }.keyboardShortcut("w")
                Button(L10n.tr("新建空文件…", "New Empty File…")) {
                    workspace.requestNewEmptyFile()
                }
                .keyboardShortcut("n", modifiers: [.command, .option])
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
                Button(L10n.tr("SSH 密钥管理器…", "SSH Key Manager…")) {
                    workspace.showSSHKeyManager = true
                }
                Button(L10n.tr("从 ~/.ssh/config 导入主机", "Import Hosts from ~/.ssh/config")) {
                    _ = workspace.importSSHConfigHosts()
                }
                Button(L10n.tr("零知识加密书签同步 (.aethersync)…", "Encrypted Bookmark Sync (.aethersync)…")) {
                    workspace.showEncryptedSyncSheet = true
                }
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
            CommandGroup(after: .sidebar) {
                Toggle(L10n.tr("显示隐藏文件", "Show Hidden Files"), isOn: $workspace.showHidden)
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                Picker(L10n.tr("视图模式", "View Mode"), selection: $workspace.viewMode) {
                    ForEach(FileViewMode.allCases) { mode in
                        Text(mode.localizedTitle).tag(mode)
                    }
                }
                Toggle(L10n.tr("检查器面板", "Inspector"), isOn: $workspace.showInspector)
                    .keyboardShortcut("i")
                Toggle(
                    L10n.tr("传输日志", "Transcript"),
                    isOn: Binding(
                        get: { workspace.rulesAndTranscriptStore.isTranscriptVisible },
                        set: { workspace.rulesAndTranscriptStore.setTranscriptVisible($0) }
                    )
                )
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
            CommandMenu(L10n.tr("转到", "Go")) {
                Button(L10n.tr("后退", "Back")) { workspace.goBack(remote: workspace.connectedProfile != nil) }.keyboardShortcut("[")
                Button(L10n.tr("前进", "Forward")) { workspace.goForward(remote: workspace.connectedProfile != nil) }.keyboardShortcut("]")
                Button(L10n.tr("上一级文件夹", "Enclosing Folder")) { workspace.parent(remote: workspace.connectedProfile != nil) }.keyboardShortcut(.upArrow, modifiers: [.command])
                Button(L10n.tr("前往文件夹…", "Go to Folder…")) { workspace.requestGoToFolder() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Divider()
                Button(L10n.tr("在终端中打开", "Open in Terminal")) { workspace.openTerminal(remote: workspace.connectedProfile != nil) }
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
