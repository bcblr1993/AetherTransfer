import AppKit
import AetherTransferCore

enum FileViewMode: Hashable { case icons, list }

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
        add(entry.isDirectory ? "打开" : (remote ? "下载" : "打开"), #selector(openItem(_:)))
        if !entry.isDirectory && !entry.isSymbolicLink { add("编辑文本…", #selector(editItem(_:)), enabled: !remote || !workspace.isS3) }
        add("快速查看", #selector(previewItem(_:)), enabled: !entry.isDirectory && !entry.isSymbolicLink && (!remote || !workspace.isS3))
        add("文件信息", #selector(informationItem(_:)))
        if !remote { add("上传", #selector(uploadItems), enabled: workspace.hasRemoteConnection) }
        menu.addItem(.separator())
        add("重命名…", #selector(renameItem(_:)), enabled: !remote || !workspace.isS3); add("删除…", #selector(deleteItem(_:)), enabled: !remote || !workspace.isS3 || !entry.isDirectory)
        menu.autoenablesItems = false
        return menu
    }
    @objc private func openItem(_ sender: NSMenuItem) { if let entry = sender.representedObject as? FileEntry { workspace?.open(entry, remote: remote) } }
    @objc private func renameItem(_ sender: NSMenuItem) { if let entry = sender.representedObject as? FileEntry { workspace?.rename(entry, remote: remote) } }
    @objc private func editItem(_ sender: NSMenuItem) { if let entry = sender.representedObject as? FileEntry { workspace?.edit(entry, remote: remote) } }
    @objc private func previewItem(_ sender: NSMenuItem) { if let entry = sender.representedObject as? FileEntry { workspace?.preview(entry, remote: remote) } }
    @objc private func informationItem(_ sender: NSMenuItem) { workspace?.focusedRemote = remote; workspace?.showInspector = true }
    @objc private func deleteItem(_ sender: NSMenuItem) { if let entry = sender.representedObject as? FileEntry { workspace?.delete(entry, remote: remote) } }
    @objc private func uploadItems() { workspace?.upload(selection) }
}
