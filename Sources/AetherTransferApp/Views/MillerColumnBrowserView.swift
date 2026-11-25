import SwiftUI
import AetherTransferCore

// MARK: - Finder-Style Miller Column Browser View (Transmit Column View Parity)
struct ColumnBrowserView: View {
    let path: String
    let files: [FileEntry]
    @Binding var selection: Set<String>
    let remote: Bool
    @ObservedObject var workspace: Workspace

    var selectedEntry: FileEntry? {
        guard let first = selection.first else { return nil }
        return files.first(where: { $0.id == first })
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 0) {
                // Column 1: Ancestor Path Hierarchy
                let crumbs = RemotePath.breadcrumbs(for: path)
                if crumbs.count > 1 {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(L10n.tr("上级目录层级", "Hierarchy"))
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                        Divider()
                        List(crumbs) { crumb in
                            Button {
                                if remote { workspace.navigateRemote(to: crumb.path) }
                                else { workspace.navigateLocal(to: crumb.path) }
                            } label: {
                                HStack {
                                    Image(systemName: crumb.path == "/" ? "internaldrive" : "folder.fill")
                                        .foregroundStyle(crumb.path == path ? Color.accentColor : Color.secondary)
                                    Text(crumb.name)
                                        .fontWeight(crumb.path == path ? .semibold : .regular)
                                        .lineLimit(1)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .listStyle(.plain)
                    }
                    .frame(width: 175)
                    Divider()
                }

                // Column 2: Active Directory Contents
                VStack(alignment: .leading, spacing: 0) {
                    Text(URL(fileURLWithPath: path).lastPathComponent.isEmpty ? "/" : URL(fileURLWithPath: path).lastPathComponent)
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    Divider()
                    List(files, selection: $selection) { entry in
                        HStack(spacing: 6) {
                            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.text")
                                .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                            Text(entry.name)
                                .lineLimit(1)
                            Spacer()
                            if entry.isDirectory {
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            } else {
                                Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(entry.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            if !entry.isDirectory && TextFileHelper.isTextFileName(entry.name) {
                                workspace.openEditor(for: entry, remote: remote)
                            } else {
                                workspace.open(entry, remote: remote)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
                .frame(width: 250)

                Divider()

                // Column 3: Inspector & Quick Action Preview Column
                VStack(spacing: 12) {
                    if let item = selectedEntry {
                        Spacer()
                        Image(systemName: item.isDirectory ? "folder.fill" : "doc.richtext.fill")
                            .font(.system(size: 46))
                            .foregroundStyle(item.isDirectory ? Color.accentColor : Color.secondary)
                        Text(item.name)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .padding(.horizontal, 10)
                        Text(item.localizedKindDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !item.isDirectory {
                            Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if let mod = item.modified {
                            Text(mod.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        HStack(spacing: 8) {
                            Button(L10n.tr("打开", "Open")) {
                                workspace.open(item, remote: remote)
                            }
                            .controlSize(.small)
                            .buttonStyle(.glassProminent)

                            if !item.isDirectory {
                                Button(L10n.tr("外部编辑", "Edit")) {
                                    workspace.openInExternalEditor(item, remote: remote)
                                }
                                .controlSize(.small)
                            }
                        }
                        Spacer()
                    } else {
                        ContentUnavailableView(
                            L10n.tr("分栏预览", "Column Preview"),
                            systemImage: "sidebar.right",
                            description: Text(L10n.tr("选择左侧项目查看属性与快捷操作", "Select an item to preview metadata & actions"))
                        )
                    }
                }
                .frame(minWidth: 210, maxWidth: .infinity)
            }
        }
    }
}
