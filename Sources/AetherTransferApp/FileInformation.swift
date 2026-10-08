import SwiftUI
import UniformTypeIdentifiers
import AetherTransferCore

struct FileInformationView: View {
    @Environment(\.locale) private var interfaceLocale
    @ObservedObject var workspace: Workspace
    private var entries: [FileEntry] {
        let files = workspace.focusedRemote ? workspace.remoteFiles : workspace.localFiles
        let selected = workspace.focusedRemote ? workspace.remoteSelection : workspace.localSelection
        return files.filter { selected.contains($0.id) }
    }
    var body: some View {
        let _ = interfaceLocale
        let selection = entries
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(L10n.text("文件信息")).font(.headline)
                    Spacer()
                    Button(L10n.text("关闭文件信息"), systemImage: "xmark") { workspace.showInspector = false }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
                if let entry = selection.first, selection.count == 1 {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                            .font(.system(size: 42)).foregroundStyle(.tint).accessibilityHidden(true)
                        Text(entry.name).font(.title3.weight(.semibold)).textSelection(.enabled)
                        Text(kind(entry)).foregroundStyle(.secondary)
                    }
                    Divider()
                    field(L10n.text("位置"), entry.path)
                    field(L10n.text("来源"), workspace.focusedRemote ? (workspace.connectedProfile?.protocolKind.title ?? L10n.text("远程")) : L10n.text("本地"))
                    field(L10n.text("大小"), entry.isDirectory ? "—" : DisplayFormat.bytes(entry.size))
                    field(L10n.text("修改时间"), entry.modified.map { $0.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(interfaceLocale)) } ?? "—")
                    field(L10n.text("权限"), entry.permissions.isEmpty ? "—" : entry.permissions)
                    Button(L10n.text("编辑权限…"), systemImage: "lock.open") { workspace.editPermissions() }
                        .buttonStyle(.glass).disabled(!workspace.canEditPermissions)
                    if !entry.isDirectory && !entry.isSymbolicLink {
                        Button(L10n.text("快速查看"), systemImage: "eye") { workspace.preview(entry, remote: workspace.focusedRemote) }
                            .buttonStyle(.glass).frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if selection.count > 1 {
                    Text(L10n.format("已选择 %@ 个项目", String(describing: selection.count))).font(.title3.weight(.semibold))
                    Text(L10n.format("%@ 个目录 · %@ 个文件", String(describing: selection.filter(\.isDirectory).count), String(describing: selection.filter { !$0.isDirectory }.count)))
                        .foregroundStyle(.secondary)
                    // Directory sizes are not recursive totals; never invent a folder size.
                    let bytes = selection.filter { !$0.isDirectory }.reduce((value: Int64(0), overflow: false)) { result, entry in
                        let sum = result.value.addingReportingOverflow(max(0, entry.size))
                        return (sum.partialValue, result.overflow || sum.overflow || entry.size < 0)
                    }
                    field(L10n.text("所选文件大小"), bytes.overflow ? "—" : DisplayFormat.bytes(bytes.value))
                    Button(L10n.text("编辑权限…"), systemImage: "lock.open") { workspace.editPermissions() }
                        .buttonStyle(.glass).disabled(!workspace.canEditPermissions)
                } else {
                    ContentUnavailableView(L10n.text("选择文件"), systemImage: "info.circle", description: Text(L10n.text("查看大小、路径和修改时间。")))
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }
    }
    private func kind(_ entry: FileEntry) -> String {
        if entry.isSymbolicLink { return L10n.text("符号链接") }
        if entry.isDirectory { return L10n.text("文件夹") }
        return UTType(filenameExtension: URL(fileURLWithPath: entry.name).pathExtension)?.localizedDescription ?? L10n.text("文件")
    }
    private func field(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
