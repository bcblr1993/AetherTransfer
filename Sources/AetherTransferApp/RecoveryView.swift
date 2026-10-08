import SwiftUI
import AppKit
import AetherTransferCore

struct RecoveryView: View {
    @Environment(\.locale) private var interfaceLocale
    @ObservedObject var workspace: Workspace
    @ObservedObject var tabs: BrowserTabs
    @Environment(\.dismiss) private var dismiss
    @State private var records: [ResumeTransferRecord] = []
    @State private var s3Records: [S3MultipartCleanup] = []
    @State private var busyS3: String?
    @State private var loading = true
    @State private var busy: UUID?
    @State private var error: String?
    private var displayed: [ResumeTransferRecord] {
        let active = Set(tabs.tabs.flatMap { $0.workspace.resumeIDs })
        return records.filter { !active.contains($0.id) }
    }
    var body: some View {
        let _ = interfaceLocale
        VStack(spacing: 0) {
            HStack {
                SheetHeader(title: L10n.text("保留的传输"),
                            subtitle: L10n.text("连接对应服务器后继续。活动列表中的任务仍在原标签页处理。"),
                            symbol: "clock.arrow.circlepath")
                Button(L10n.text("刷新"), systemImage: "arrow.clockwise") { Task { await load() } }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(busy != nil || busyS3 != nil)
                    .padding(.trailing, InterfaceStyle.pageInset)
            }
            Divider()
            if loading {
                ProgressView(L10n.text("读取保留进度…")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if displayed.isEmpty && s3Records.isEmpty {
                ContentUnavailableView(L10n.text("没有保留的传输"), systemImage: "checkmark.circle", description: Text(L10n.text("单个文件传输中选择“保留进度”，即可稍后恢复。")))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(displayed) { record in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Label(record.name, systemImage: record.direction == .upload ? "arrow.up.circle" : "arrow.down.circle").font(.headline).lineLimit(1)
                                    Spacer()
                                    Text(record.discardPending ? L10n.text("待清理") : L10n.text("已保留")).font(.caption).foregroundStyle(.secondary)
                                }
                                Text("\(record.endpoint.protocolKind.title) · \(record.endpoint.host):\(String(record.endpoint.port)) · \(record.endpoint.username)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Text(record.localPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                Text(record.remotePath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                HStack {
                                    Text("\(DisplayFormat.bytes(record.retainedBytes)) / \(DisplayFormat.bytes(record.expectedSize))").font(.caption).monospacedDigit()
                                    Spacer()
                                    if busy == record.id { ProgressView().controlSize(.small) }
                                    Button(L10n.text("丢弃进度"), role: .destructive) { discard(record) }
                                        .disabled(busy != nil || busyS3 != nil || (record.direction == .upload && !matches(record)))
                                    if !record.discardPending {
                                        Button(requiresRestart(record) ? L10n.text("从头上传") : L10n.text("继续传输")) { recover(record) }
                                            .buttonStyle(.glassProminent).disabled(busy != nil || busyS3 != nil || !matches(record))
                                    }
                                }
                                if !matches(record) { Text(L10n.text("请先连接此服务器，并完成认证与主机指纹核对。")).font(.caption).foregroundStyle(.secondary) }
                                else if requiresRestart(record) { Text(L10n.text("此服务器使用普通 WebDAV PUT；重新上传会从文件开头开始。")).font(.caption).foregroundStyle(.secondary) }
                            }.padding(.vertical, 12).accessibilityElement(children: .contain)
                            Divider()
                        }
                        ForEach(s3Records, id: \.id) { record in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Label(L10n.text("S3 分片待清理"), systemImage: "exclamationmark.arrow.circlepath").font(.headline)
                                    Spacer()
                                    if busyS3 == record.id { ProgressView().controlSize(.small) }
                                }
                                Text("\(record.endpoint.host):\(record.endpoint.port) · \(record.endpoint.bucket)").font(.caption).foregroundStyle(.secondary)
                                Text(record.key).font(.caption).lineLimit(1).truncationMode(.middle)
                                HStack {
                                    Text(matchesS3(record) ? L10n.text("只清理此任务的 upload ID；不删除已提交对象。") : L10n.text("请先连接同一端点 / 存储桶并重新认证。"))
                                        .font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Button(L10n.text("重试清理")) { cleanupS3(record) }
                                        .disabled(busy != nil || busyS3 != nil || !matchesS3(record))
                                }
                            }.padding(.vertical, 12).accessibilityElement(children: .contain)
                            Divider()
                        }
                    }.padding(.horizontal, 20)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal, 20).padding(.vertical, 10) }
            Divider()
            HStack {
                Text(L10n.text("保留的数据会占用磁盘空间；丢弃进度会清理此任务的部分文件。")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("完成")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy != nil || busyS3 != nil)
            }.padding(20)
        }.frame(width: 760, height: 520)
        .task { await load() }
        .interactiveDismissDisabled(busy != nil || busyS3 != nil)
    }
    private func matchesS3(_ record: S3MultipartCleanup) -> Bool {
        !workspace.connecting && !workspace.loadingRemote && workspace.s3Client?.endpoint == record.endpoint
    }
    private func cleanupS3(_ record: S3MultipartCleanup) {
        guard matchesS3(record), let client = workspace.s3Client else { return }
        busyS3 = record.id; error = nil
        Task {
            do { try await client.abort(record); try await S3CleanupStore.shared.remove(record); await load() }
            catch { self.error = error.localizedDescription }
            busyS3 = nil
        }
    }
    private func matches(_ record: ResumeTransferRecord) -> Bool {
        guard !workspace.connecting, !workspace.loadingRemote, workspace.hostChallenge == nil,
              let client = workspace.client else { return false }
        return ResumeEndpoint(client.profile) == record.endpoint
    }
    private func requiresRestart(_ record: ResumeTransferRecord) -> Bool { record.direction == .upload && record.endpoint.protocolKind.isWebDAV }
    private func load() async {
        loading = true; error = nil
        do { records = try await ResumeTransferStore().records(); s3Records = try await S3CleanupStore.shared.records() }
        catch { self.error = error.localizedDescription }
        loading = false
    }
    private func recover(_ record: ResumeTransferRecord) {
        busy = record.id; error = nil
        Task {
            do { try await workspace.recover(record, restart: requiresRestart(record)); dismiss() }
            catch { self.error = error.localizedDescription }
            busy = nil
        }
    }
    private func discard(_ record: ResumeTransferRecord) {
        let alert = NSAlert(); alert.messageText = L10n.format("丢弃“%@”的保留进度？", String(describing: record.name))
        alert.informativeText = L10n.text("将清理此任务的部分文件。原始文件和原有目标文件会保留。")
        alert.addButton(withTitle: L10n.text("丢弃进度")); alert.addButton(withTitle: L10n.text("返回"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        busy = record.id; error = nil
        let client = workspace.client
        Task {
            do { try await ResumableTransfer(restoring: record).discard(client: client); await load() }
            catch { self.error = error.localizedDescription }
            busy = nil
        }
    }
}
