import SwiftUI
import UniformTypeIdentifiers
import AetherTransferCore

struct FileInformationView: View {
    @ObservedObject var workspace: Workspace
    private var entries: [FileEntry] {
        let files = workspace.focusedRemote ? workspace.remoteFiles : workspace.localFiles
        let selected = workspace.focusedRemote ? workspace.remoteSelection : workspace.localSelection
        return files.filter { selected.contains($0.id) }
    }
    var body: some View {
        let selection = entries
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("文件信息").font(.headline)
                    Spacer()
                    Button("关闭文件信息", systemImage: "xmark") { workspace.showInspector = false }
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
                    field("位置", entry.path)
                    field("来源", workspace.focusedRemote ? (workspace.connectedProfile?.protocolKind.title ?? "远程") : "本地")
                    field("大小", entry.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                    field("修改时间", entry.modified.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "—")
                    field("权限", entry.permissions.isEmpty ? "—" : entry.permissions)
                    if !entry.isDirectory && !entry.isSymbolicLink {
                        Button("快速查看", systemImage: "eye") { workspace.preview(entry, remote: workspace.focusedRemote) }
                            .buttonStyle(.glass).frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if selection.count > 1 {
                    Text("已选择 \(selection.count) 个项目").font(.title3.weight(.semibold))
                    Text("\(selection.filter(\.isDirectory).count) 个目录 · \(selection.filter { !$0.isDirectory }.count) 个文件")
                        .foregroundStyle(.secondary)
                    // Directory sizes are not recursive totals; never invent a folder size.
                    let bytes = selection.filter { !$0.isDirectory }.reduce((value: Int64(0), overflow: false)) { result, entry in
                        let sum = result.value.addingReportingOverflow(max(0, entry.size))
                        return (sum.partialValue, result.overflow || sum.overflow || entry.size < 0)
                    }
                    field("所选文件大小", bytes.overflow ? "—" : ByteCountFormatter.string(fromByteCount: bytes.value, countStyle: .file))
                } else {
                    ContentUnavailableView("选择文件", systemImage: "info.circle", description: Text("查看大小、路径和修改时间。"))
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }
    }
    private func kind(_ entry: FileEntry) -> String {
        if entry.isSymbolicLink { return "符号链接" }
        if entry.isDirectory { return "文件夹" }
        return UTType(filenameExtension: URL(fileURLWithPath: entry.name).pathExtension)?.localizedDescription ?? "文件"
    }
    private func field(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
