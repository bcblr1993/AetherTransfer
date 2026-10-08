import AppKit
import SwiftUI
import AetherTransferCore

enum FileViewMode: Sendable, Hashable { case icons, list, columns }

/// Commands observe the active workspace directly, so enabled states follow
/// selection/loading changes as well as switching tabs.
struct WorkspaceFileCommands: Commands {
    @ObservedObject var workspace: Workspace
    @ObservedObject var tabs: BrowserTabs
    @AppStorage(AppLanguage.preferenceKey) private var language = "system"
    var body: some Commands {
        let _ = language
        CommandGroup(after: .newItem) {
            Button(L10n.text("新建标签页")) { tabs.add() }.keyboardShortcut("t")
            Button(L10n.text("选择本地文件夹…")) { workspace.chooseLocal() }.keyboardShortcut("o")
            Button(L10n.text("刷新")) { workspace.refreshLocal(); workspace.refreshRemote() }.keyboardShortcut("r")
            Button(L10n.text("上传所选文件")) { workspace.uploadSelection() }.keyboardShortcut("u", modifiers: [.command, .shift]).disabled(!workspace.canUploadSelection)
            Button(L10n.text("下载所选文件")) { workspace.downloadSelection() }.keyboardShortcut("d", modifiers: [.command, .shift]).disabled(!workspace.canDownloadSelection)
            Button(L10n.text("同步目录…")) { workspace.showSync = true }.keyboardShortcut("s", modifiers: [.command, .shift])
            Button(L10n.text("编辑所选文本…")) { workspace.editSelection() }.keyboardShortcut("e")
            Button(L10n.text("快速查看…")) { workspace.previewSelection() }.keyboardShortcut("y")
            Button(L10n.text("文件信息")) { workspace.showInspector.toggle() }.keyboardShortcut("i")
            Button(L10n.text("编辑权限…")) { workspace.editPermissions() }.disabled(!workspace.canEditPermissions)
            Button(L10n.text("保留的传输…")) { workspace.showRecovery = true }
        }
        CommandGroup(after: .sidebar) {
            Divider()
            Button(L10n.text("图标视图")) { workspace.setViewMode(.icons) }.keyboardShortcut("1")
            Button(L10n.text("列表视图")) { workspace.setViewMode(.list) }.keyboardShortcut("2")
            Button(L10n.text("列视图")) { workspace.setViewMode(.columns) }.keyboardShortcut("3")
            Divider()
            Button(L10n.text("显示 / 隐藏隐藏文件")) { workspace.showHidden.toggle() }.keyboardShortcut(".", modifiers: [.command, .shift])
        }
    }
}

/// Both presentations expose the same file actions and transfer selection.
@MainActor final class FileBrowserActions: NSObject {
    private weak var workspace: Workspace?
    private var remote = false
    private var selection: [FileEntry] = []
    func menu(for entry: FileEntry, selection: [FileEntry], remote: Bool, workspace: Workspace) -> NSMenu {
        self.workspace = workspace; self.remote = remote; self.selection = selection
        let menu = NSMenu()
        func add(_ title: String, _ selector: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self; item.representedObject = entry; item.isEnabled = enabled; menu.addItem(item)
        }
        add(entry.isDirectory ? L10n.text("打开") : (remote ? L10n.text("下载") : L10n.text("打开")), #selector(openItem(_:)))
        if !entry.isDirectory && !entry.isSymbolicLink { add(L10n.text("编辑文本…"), #selector(editItem(_:))) }
        add(L10n.text("快速查看"), #selector(previewItem(_:)), enabled: !entry.isDirectory && !entry.isSymbolicLink)
        add(L10n.text("文件信息"), #selector(informationItem(_:)))
        add(L10n.text("编辑权限…"), #selector(permissionItems), enabled: !workspace.permissionBusy && !selection.isEmpty &&
            !selection.contains(where: \.isSymbolicLink) && (!remote || workspace.connectedProfile?.protocolKind.supportsUnixPermissions == true))
        if !remote { add(L10n.text("上传"), #selector(uploadItems), enabled: workspace.canReceiveUpload) }
        if remote && entry.isDirectory { add(L10n.text("下载"), #selector(downloadItems), enabled: workspace.hasRemoteConnection && !workspace.loadingLocal) }
        menu.addItem(.separator())
        add(L10n.text("重命名…"), #selector(renameItem(_:)), enabled: !remote || !workspace.isS3); add(L10n.text("删除…"), #selector(deleteItem(_:)), enabled: !remote || !workspace.isS3 || !entry.isDirectory)
        menu.autoenablesItems = false
        return menu
    }
    @objc private func openItem(_ sender: NSMenuItem) { if let entry = sender.representedObject as? FileEntry { workspace?.open(entry, remote: remote) } }
    @objc private func renameItem(_ sender: NSMenuItem) { if let entry = sender.representedObject as? FileEntry { workspace?.rename(entry, remote: remote) } }
    @objc private func editItem(_ sender: NSMenuItem) { if let entry = sender.representedObject as? FileEntry { workspace?.edit(entry, remote: remote) } }
    @objc private func previewItem(_ sender: NSMenuItem) { if let entry = sender.representedObject as? FileEntry { workspace?.preview(entry, remote: remote) } }
    @objc private func informationItem(_ sender: NSMenuItem) { workspace?.focusedRemote = remote; workspace?.showInspector = true }
    @objc private func permissionItems() { workspace?.editPermissions(remote: remote) }
    @objc private func deleteItem(_ sender: NSMenuItem) { if let entry = sender.representedObject as? FileEntry { workspace?.delete(entry, remote: remote) } }
    @objc private func uploadItems() { workspace?.upload(selection) }
    @objc private func downloadItems() { workspace?.download(selection) }
}
