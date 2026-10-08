import SwiftUI
import AppKit
import AetherTransferCore

@main struct AetherTransferApp: App {
    @StateObject private var tabs = BrowserTabs()
    @NSApplicationDelegateAdaptor(TransferAppDelegate.self) private var appDelegate
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage(AppLanguage.preferenceKey) private var language = "system"
    var body: some Scene {
        WindowGroup("AetherTransfer") {
            MainView(workspace: tabs.current, tabs: tabs).frame(minWidth: 1000, minHeight: 640)
                .environment(\.locale, (AppLanguage(rawValue: language) ?? .system).locale)
                .preferredColorScheme(appearance == "dark" ? .dark : (appearance == "light" ? .light : nil))
                .onAppear { appDelegate.editors = tabs.editors; appDelegate.tabs = tabs }
        }
        .defaultSize(width: 1240, height: 800)
        .commands {
            WorkspaceFileCommands(workspace: tabs.current, tabs: tabs)
            CommandGroup(after: .textEditing) {
                Button(L10n.text("查找…")) {
                    let sender = NSMenuItem(); sender.tag = NSTextFinder.Action.showFindInterface.rawValue
                    NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)), to: nil, from: sender)
                }.keyboardShortcut("f")
            }
        }
        Settings { TransferSettingsView(tabs: tabs).modifier(AppPresentation()) }
    }
}

struct TransferSettingsView: View {
    @Environment(\.locale) private var interfaceLocale
    @ObservedObject var tabs: BrowserTabs
    @AppStorage("maxConcurrentTransfers") private var concurrency = 2
    @AppStorage("transferRateKiB") private var rate = 0
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage(AppLanguage.preferenceKey) private var language = "system"
    var body: some View {
        let _ = interfaceLocale
        Form {
            Section(L10n.text("外观")) {
                Picker(L10n.text("语言"), selection: $language) {
                    Text(L10n.text("跟随系统")).tag("system")
                    Text("简体中文").tag("zh-Hans")
                    Text("English").tag("en")
                }
                Text(L10n.text("选择显示语言。文件名、路径和服务器名称保持原样。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker(L10n.text("主题"), selection: $appearance) {
                    Text(L10n.text("跟随系统")).tag("system")
                    Text(L10n.text("浅色")).tag("light")
                    Text(L10n.text("深色")).tag("dark")
                }
                Text(L10n.text("动效遵循系统“减少动态效果”设置。")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.text("传输")) {
                Picker(L10n.text("同时进行的任务"), selection: $concurrency) {
                    ForEach(1...8, id: \.self) { Text("\($0)").tag($0) }
                }
                Picker(L10n.text("每个任务的速度上限"), selection: $rate) {
                    Text(L10n.text("不限速")).tag(0)
                    Text("256 KiB/s").tag(256)
                    Text("1 MiB/s").tag(1024)
                    Text("5 MiB/s").tag(5120)
                    Text("20 MiB/s").tag(20480)
                }
                Text(L10n.text("速度上限对新任务生效。降低并发数时，已开始的任务会继续运行。")).font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).frame(width: 560, height: 470)
        .background { InterfaceWindowTitle(title: L10n.text("AetherTransfer 设置")).frame(width: 0, height: 0).accessibilityHidden(true) }
        .preferredColorScheme(appearance == "dark" ? .dark : (appearance == "light" ? .light : nil))
        .onChange(of: concurrency) { _, value in tabs.setConcurrency(value) }
    }
}

struct MainView: View {
    @Environment(\.locale) private var interfaceLocale
    @ObservedObject var workspace: Workspace
    @ObservedObject var tabs: BrowserTabs
    @State private var showConnect = false
    @State private var showActivities = false
    @State private var query = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editingProfile: ServerProfile?
    private var groups: [String] { Set(workspace.profiles.map(\.group)).sorted() }
    var body: some View {
        let _ = interfaceLocale
        NavigationSplitView {
            List(selection: $workspace.selectedServer) {
                Section(L10n.text("位置")) {
                    Button { workspace.localPath = FileManager.default.homeDirectoryForCurrentUser.path; workspace.refreshLocal() } label: { Label(L10n.text("个人文件夹"), systemImage: "house") }.buttonStyle(.plain)
                    Button { workspace.localPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path; workspace.refreshLocal() } label: { Label(L10n.text("下载"), systemImage: "arrow.down.circle") }.buttonStyle(.plain)
                }
                Section(L10n.text("服务器")) {
                    ForEach(groups, id: \.self) { group in
                        if !group.isEmpty { Text(group).font(.caption).foregroundStyle(.secondary) }
                        ForEach(workspace.profiles.filter { $0.group == group }) { profile in
                            VStack(alignment: .leading, spacing: 3) {
                                Label(profile.name.isEmpty ? profile.host : profile.name, systemImage: "server.rack")
                                Text(profile.protocolKind.title).font(.caption).foregroundStyle(.secondary)
                            }.tag(profile.id).onTapGesture(count: 2) { workspace.connectSaved(profile) }
                            .contextMenu {
                                Button(L10n.text("连接")) { workspace.connectSaved(profile) }
                                Button(L10n.text("编辑…")) { editingProfile = profile }
                                Divider()
                                Button(L10n.text("移除收藏…"), role: .destructive) { workspace.removeProfile(profile) }
                            }
                        }
                    }
                    Button { showConnect = true } label: { Label(L10n.text("添加服务器"), systemImage: "plus") }.buttonStyle(.plain)
                    Menu {
                        Button(L10n.text("导入收藏…")) { workspace.importProfiles() }
                        Button(L10n.text("导出收藏…")) { workspace.exportProfiles() }.disabled(workspace.profiles.isEmpty)
                    } label: {
                        Label {
                            Text(L10n.text("管理收藏"))
                        } icon: {
                            Image(systemName: "ellipsis.circle").foregroundStyle(.tint)
                        }
                    }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    BrowserTabBar(tabs: tabs)
                    Divider()
                    HSplitView {
                        FilePane(title: L10n.text("本地"), path: $workspace.localPath, files: workspace.localFiles,
                                 selection: $workspace.localSelection, loading: workspace.loadingLocal,
                                 query: query, remote: false, workspace: workspace)
                        if workspace.connectedProfile != nil {
                            FilePane(title: workspace.connectedProfile?.name.isEmpty == false ? workspace.connectedProfile!.name : L10n.text("远程"),
                                     path: $workspace.remotePath, files: workspace.remoteFiles, selection: $workspace.remoteSelection,
                                     loading: workspace.loadingRemote, query: query, remote: true, workspace: workspace)
                        } else {
                            ConnectionWelcomeView { showConnect = true }
                                .frame(minWidth: 350, maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }.transaction { $0.animation = nil }
                    Divider()
                    ActivityView(workspace: workspace, expanded: $showActivities).frame(height: showActivities ? 170 : 44)
                        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: showActivities)
                    Divider()
                    HStack {
                        Text(workspace.connectedProfile.map { "\($0.protocolKind.title) · \($0.name.isEmpty ? $0.host : $0.name)" } ?? L10n.text("未连接"))
                        Spacer()
                        Text(L10n.format("%@ 个本地项目 · %@ 个远程项目", String(describing: workspace.localFiles.count), String(describing: workspace.remoteFiles.count)))
                    }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if workspace.showInspector {
                    Divider()
                    FileInformationView(workspace: workspace).frame(width: 280)
                        .background(.bar)
                }
            }
        }
        .navigationTitle("AetherTransfer")
        .toolbar {
            ToolbarItemGroup {
                Button(L10n.text("连接"), systemImage: "plus") { showConnect = true }
                Button(L10n.text("刷新"), systemImage: "arrow.clockwise") { workspace.refreshLocal(); workspace.refreshRemote() }
                Button(L10n.text("上传"), systemImage: "arrow.up") { workspace.uploadSelection() }.disabled(!workspace.canUploadSelection)
                Button(L10n.text("下载"), systemImage: "arrow.down") { workspace.downloadSelection() }.disabled(!workspace.canDownloadSelection)
            }
            ToolbarItem { Button(L10n.text("活动"), systemImage: "list.bullet.rectangle") { showActivities.toggle() } }
            ToolbarItem { Button(L10n.text("文件信息"), systemImage: "info.circle") { workspace.showInspector.toggle() } }
            ToolbarItem { Button(L10n.text("同步"), systemImage: "arrow.triangle.2.circlepath") { workspace.showSync = true } }
            ToolbarItem { Button(L10n.text("断开"), systemImage: "eject") { workspace.disconnect() }.disabled(!workspace.hasRemoteConnection) }
        }
        .searchable(text: $query, prompt: L10n.text("筛选当前目录"))
        .sheet(isPresented: $showConnect) { ConnectionView(workspace: workspace) }
        .sheet(isPresented: $workspace.showSync) { SyncReviewView(workspace: workspace, tabs: tabs) }
        .sheet(isPresented: $workspace.showRecovery) { RecoveryView(workspace: workspace, tabs: tabs) }
        .sheet(item: $workspace.permissionRequest) { request in PermissionEditorView(request: request, workspace: workspace) }
        .sheet(item: $editingProfile) { profile in ConnectionView(workspace: workspace, initial: profile, editing: true) }
        .sheet(item: $workspace.connectionPrompt) { profile in ConnectionView(workspace: workspace, initial: profile, loadSaved: true) }
        .alert(L10n.text("操作失败"), isPresented: Binding(get: { workspace.error != nil }, set: { if !$0 { workspace.error = nil } })) {
            Button(L10n.text("确定")) { workspace.error = nil }
        } message: { Text(workspace.error ?? "") }
        .sheet(item: $workspace.hostChallenge) { challenge in
            VStack(alignment: .leading, spacing: InterfaceStyle.sectionGap) {
                SheetHeader(title: L10n.text("核对服务器指纹"),
                            subtitle: L10n.text("请通过可信渠道核对服务器的 SHA-256 指纹。确认后才会进行认证和文件操作。"),
                            symbol: "lock.shield", inset: 0)
                Text(RemoteClient.fingerprint(challenge.key)).font(.system(.body, design: .monospaced))
                    .textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Button(L10n.text("取消")) { workspace.hostChallenge = nil; workspace.disconnect() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(L10n.text("信任并连接")) { workspace.approveHostKey() }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                }
            }.padding(InterfaceStyle.pageInset).frame(width: InterfaceStyle.connectionWidth)
        }
        .onChange(of: tabs.selected) { workspace.reloadProfiles() }
        .onChange(of: workspace.activities.count) { old, new in if new > old { showActivities = true } }
        .onReceive(NotificationCenter.default.publisher(for: .init("AetherTransferEditedFile"))) { _ in
            workspace.refreshLocal(); workspace.refreshRemote()
        }
        .onAppear { workspace.reloadProfiles() }
    }
}

private struct ConnectionWelcomeView: View {
    @Environment(\.locale) private var interfaceLocale
    let connect: () -> Void
    var body: some View {
        let _ = interfaceLocale
        VStack(spacing: 18) {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 30, weight: .medium)).foregroundStyle(.blue.gradient)
                .frame(width: 76, height: 76).background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 23))
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(L10n.text("文件，自由往来")).font(.title2.weight(.semibold))
                Text(L10n.text("连接服务器，让本地与远程并肩工作。"))
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            HStack(spacing: 8) {
                ForEach(["SFTP", "FTP", "FTPS", "WebDAV", "S3"], id: \.self) { name in
                    Text(name).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.quaternary, in: Capsule())
                }
            }
            Button(L10n.text("连接服务器"), systemImage: "plus") { connect() }.buttonStyle(.glassProminent).controlSize(.large)
                .padding(.top, 4)
            Text(L10n.text("密码可保存在系统钥匙串")).font(.caption).foregroundStyle(.secondary)
        }.padding(32)
    }
}

struct FilePane: View {
    @Environment(\.locale) private var interfaceLocale
    let title: String
    @Binding var path: String
    let files: [FileEntry]
    @Binding var selection: Set<String>
    let loading: Bool
    let query: String
    let remote: Bool
    @ObservedObject var workspace: Workspace
    @State private var sortField: FileSortField = .name
    @State private var descending = false
    @State private var presentationRevision = UUID()
    @State private var filtered: [FileEntry] = []
    @State private var columnHistory = FileColumnHistory()
    @State private var columns: [FileColumnContent] = []
    @State private var presenting = true
    private struct PresentationRequest: Hashable {
        let revision: UUID
        let query: String
        let hidden: Bool
        let field: FileSortField
        let descending: Bool
        let mode: FileViewMode
        let workspace: UUID
        let namespace: UUID
    }
    @State private var presentedRequest: PresentationRequest?
    // A reused native pane is immediately inert while its new workspace's
    // snapshot is being prepared. Old rows must never act on a new connection.
    private var presentationPending: Bool { presenting || presentedRequest != request }
    private var request: PresentationRequest {
        PresentationRequest(revision: remote ? workspace.remoteRevision : workspace.localRevision,
                            query: query, hidden: workspace.showHidden, field: sortField, descending: descending,
                            mode: viewMode.wrappedValue, workspace: workspace.id,
                            namespace: remote ? workspace.connectionRevision : workspace.id)
    }
    private var viewMode: Binding<FileViewMode> {
        remote ? $workspace.remoteViewMode : $workspace.localViewMode
    }

    var body: some View {
        let _ = interfaceLocale
        VStack(spacing: 0) {
            HStack {
                Image(systemName: remote ? "network" : "internaldrive").foregroundStyle(.secondary)
                Text(title).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Spacer()
                if loading || presentationPending { ProgressView().controlSize(.small) }
                Picker(L10n.format("%@视图", String(describing: title)), selection: viewMode) {
                    Image(systemName: "square.grid.2x2").accessibilityLabel(L10n.text("图标视图")).tag(FileViewMode.icons)
                    Image(systemName: "list.bullet").accessibilityLabel(L10n.text("列表视图")).tag(FileViewMode.list)
                    Image(systemName: "rectangle.split.3x1").accessibilityLabel(L10n.text("列视图")).tag(FileViewMode.columns)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 112)
                if viewMode.wrappedValue != .list {
                    Menu(L10n.text("排序"), systemImage: "arrow.up.arrow.down") {
                        Picker(L10n.text("排序依据"), selection: $sortField) {
                            Text(L10n.text("名称")).tag(FileSortField.name); Text(L10n.text("大小")).tag(FileSortField.size); Text(L10n.text("修改日期")).tag(FileSortField.modified)
                        }
                        Divider()
                        Button(descending ? L10n.text("升序") : L10n.text("降序")) { descending.toggle() }
                    }.labelStyle(.iconOnly).menuStyle(.borderlessButton)
                }
                Button(L10n.text("上一级"), systemImage: "arrow.up") { workspace.parent(remote: remote) }.labelStyle(.iconOnly)
                Button(L10n.text("新建文件夹"), systemImage: "folder.badge.plus") { workspace.createFolder(remote: remote) }.labelStyle(.iconOnly)
                if !remote { Button(L10n.text("选择文件夹"), systemImage: "folder") { workspace.chooseLocal() }.labelStyle(.iconOnly) }
            }.padding(.horizontal, InterfaceStyle.paneInset).padding(.vertical, 10).controlSize(.small)
            TextField(remote && workspace.isS3 ? L10n.text("前缀（根目录为空，如 photos/）") : L10n.text("路径"), text: $path).textFieldStyle(.roundedBorder).font(.system(.callout, design: .monospaced))
                .onSubmit { if remote { workspace.refreshRemote() } else { workspace.refreshLocal() } }
                .padding(.horizontal, InterfaceStyle.paneInset).padding(.bottom, 10)
            Group {
                if viewMode.wrappedValue == .icons {
                    NativeFileIcons(files: filtered, revision: presentationRevision, selection: $selection, remote: remote, workspace: workspace)
                } else if viewMode.wrappedValue == .columns {
                    NativeFileColumns(columns: columns, selection: $selection, remote: remote, workspace: workspace,
                                      emptyMessage: query.isEmpty ? L10n.text("此目录为空。") : L10n.text("没有匹配的项目。"))
                } else {
                    NativeFileTable(files: filtered, revision: presentationRevision, selection: $selection,
                                    sortField: $sortField, descending: $descending, remote: remote, workspace: workspace)
                }
            }
                .disabled(loading || presentationPending)
                .overlay { if viewMode.wrappedValue != .columns && filtered.isEmpty && !loading && !presentationPending { ContentUnavailableView(L10n.text("没有文件"), systemImage: "folder", description: Text(query.isEmpty ? L10n.text("此目录为空。") : L10n.text("没有匹配的项目。"))) .allowsHitTesting(false) } }

        }.frame(minWidth: 350, maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: viewMode.wrappedValue) { _, _ in workspace.focusedRemote = remote }
        .task(id: request) {
            // Read entries and revision from the same observable source. A child can see a new
            // revision before its parent passes the refreshed value-type files argument.
            let current = request, snapshot = remote ? workspace.remoteFiles : workspace.localFiles
            let directory = remote ? workspace.remoteListingPath : workspace.localListingPath
            let previous = presentedRequest, previousColumns = columns
            let history = previous?.workspace == current.workspace && previous?.namespace == current.namespace ? columnHistory : FileColumnHistory()
            presenting = true
            do {
                if !current.query.isEmpty { try await Task.sleep(for: .milliseconds(120)) }
                let preparation = Task.detached {
                    try Task.checkCancellation()
                    let filtered = FilePresentation.entries(snapshot, query: current.query, showHidden: current.hidden, field: current.field, descending: current.descending)
                    var updated = FileColumnHistory(), prepared: [FileColumnContent] = []
                    if current.mode == .columns {
                        updated = history
                        updated.accept(FileColumnSnapshot(path: directory, files: snapshot, revision: current.revision))
                        let sameOptions = previous?.query == current.query && previous?.hidden == current.hidden
                            && previous?.field == current.field && previous?.descending == current.descending
                        for (index, column) in updated.columns.enumerated() {
                            try Task.checkCancellation()
                            let old = sameOptions ? previousColumns.first { $0.snapshot.id == column.id && $0.snapshot.revision == column.revision } : nil
                            let files = index == updated.columns.count - 1 ? filtered : (old?.files ?? FilePresentation.entries(column.files,
                                query: current.query, showHidden: current.hidden, field: current.field, descending: current.descending))
                            prepared.append(FileColumnContent(snapshot: column, files: files, revision: old?.revision ?? UUID(),
                                                              branchSelection: updated.branchSelection(at: index)))
                        }
                    }
                    try Task.checkCancellation()
                    return (filtered, updated, prepared)
                }
                let result = try await withTaskCancellationHandler(operation: { try await preparation.value }, onCancel: { preparation.cancel() })
                try Task.checkCancellation()
                filtered = result.0; columnHistory = result.1; columns = result.2
                presentationRevision = UUID(); presentedRequest = current; presenting = false
                selection.formIntersection(Set(result.0.map(\.id)))
            } catch is CancellationError { } catch { presenting = false }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard viewMode.wrappedValue != .columns, remote, workspace.canReceiveUpload, !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
            workspace.uploadURLs(urls); return true
        }
    }
}

struct ActivityView: View {
    @Environment(\.locale) private var interfaceLocale
    @ObservedObject var workspace: Workspace
    @Binding var expanded: Bool
    var body: some View {
        let _ = interfaceLocale
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { expanded.toggle() } label: { Label(L10n.text("传输活动"), systemImage: expanded ? "chevron.down" : "chevron.right").font(.callout.weight(.semibold)) }.buttonStyle(.plain)
                Spacer()
                Button(L10n.text("保留的传输…"), systemImage: "clock.arrow.circlepath") { workspace.showRecovery = true }.buttonStyle(.borderless).font(.caption)
                Text(workspace.activities.isEmpty ? L10n.text("暂无任务") : L10n.format("%@ 个进行中 · %@ 个任务", String(describing: workspace.activities.filter { $0.state == "传输中" }.count), String(describing: workspace.activities.count))).font(.caption).foregroundStyle(.secondary)
                if !workspace.activities.isEmpty { Button(L10n.text("清除已结束任务")) { workspace.clearFinishedActivities() }.buttonStyle(.borderless).font(.caption) }
            }.padding(.horizontal, 14).frame(height: 38)
            if expanded && workspace.activities.isEmpty {
                Text(L10n.text("上传或下载文件后，在这里查看进度。")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if expanded {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(workspace.activities) { item in
                            HStack {
                                Image(systemName: item.direction == "同步" ? "arrow.triangle.2.circlepath" : (item.direction == "上传" ? "arrow.up.circle" : "arrow.down.circle"))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name).lineLimit(1)
                                    if ["传输中", "已暂停", "待续传", "保留中"].contains(item.state) {
                                        if item.hasKnownTotal {
                                            ProgressView(value: item.progress).frame(maxWidth: 220)
                                            Text(L10n.format("%@：%@ / %@", String(describing: item.direction == "同步" ? L10n.text("同步总量") : (item.scope == .directory ? L10n.text("目录处理总量") : L10n.text("当前文件"))), String(describing: DisplayFormat.bytes(item.bytes)), String(describing: DisplayFormat.bytes(item.total)))).font(.caption).foregroundStyle(.secondary)
                                        } else { ProgressView().controlSize(.small) }
                                        if let rate = item.rate {
                                            HStack(spacing: 8) {
                                                Text(L10n.format("%@ %@/s", String(describing: item.scope == .file ? L10n.text("传输") : L10n.text("处理")), String(describing: DisplayFormat.bytes(Int64(min(rate.bytesPerSecond, Double(Int64.max).nextDown)), style: .binary))))
                                                if let remaining = rate.remainingSeconds {
                                                    Text(L10n.format("预计剩余 %@", String(describing: Self.remainingText(remaining))))
                                                }
                                            }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                        }
                                        if let phase = item.phase { Text(phase).font(.caption).foregroundStyle(.secondary) }
                                    }
                                    if let completed = item.completedItems, let total = item.totalItems {
                                        Text(L10n.format("已处理 %@ / %@ 个项目%@", String(describing: completed), String(describing: total), String(describing: item.skippedItems > 0 ? L10n.format(" · 跳过 %@ 项", String(describing: item.skippedItems)) : "")))
                                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                    }
                                    if let error = item.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
                                    if item.scope == .directory && (item.state == "失败" || item.state == "已取消") {
                                        Text(L10n.text("重新选择目录并确认冲突后，可再次传输。")).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Label(L10n.text(item.state), systemImage: item.state == "完成" ? "checkmark.circle.fill" : (item.state == "失败" ? "exclamationmark.circle" : "circle.dotted"))
                                    .font(.caption).foregroundStyle(item.state == "失败" ? Color.red : (item.state == "完成" ? Color.green : Color.secondary))
                                if item.state == "传输中" { Button(L10n.text("暂停"), systemImage: "pause.circle") { workspace.pause(item.id) }.labelStyle(.iconOnly).buttonStyle(.borderless) }
                                if item.state == "已暂停" { Button(L10n.text("继续"), systemImage: "play.circle") { workspace.resume(item.id) }.labelStyle(.iconOnly).buttonStyle(.borderless) }
                                if item.canRetain && (item.state == "传输中" || item.state == "已暂停") {
                                    Button(L10n.text("保留进度"), systemImage: "clock.arrow.circlepath") { workspace.retain(item.id) }.buttonStyle(.borderless)
                                }
                                if item.state == "传输中" || item.state == "等待中" || item.state == "已暂停" { Button(L10n.text("取消"), systemImage: "xmark.circle") { workspace.cancel(item.id) }.labelStyle(.iconOnly).buttonStyle(.borderless) }
                                if item.state == "待续传" || (item.state == "失败" && item.canRetain) {
                                    Button(item.requiresRestart ? L10n.text("从头上传") : L10n.text("继续传输"), systemImage: "play.circle") { workspace.retry(item.id) }.buttonStyle(.borderless)
                                    Button(L10n.text("丢弃进度"), systemImage: "trash") { workspace.discardRetained(item.id) }.labelStyle(.iconOnly).buttonStyle(.borderless)
                                } else if item.state == "失败" || item.state == "已取消" {
                                    if item.canRetry {
                                        Button(L10n.text("重试"), systemImage: "arrow.clockwise") { workspace.retry(item.id) }.labelStyle(.iconOnly).buttonStyle(.borderless)
                                    } else if item.direction == "同步" {
                                        Button(L10n.text("重新预览"), systemImage: "arrow.triangle.2.circlepath") { workspace.showSync = true }.buttonStyle(.borderless)
                                    }
                                }
                            }.padding(.vertical, 10).accessibilityElement(children: .contain)
                            Divider()
                        }
                    }.padding(.horizontal, 14)
                }
            }
        }
    }
    private static func remainingText(_ seconds: Double) -> String {
        if seconds >= 3600 { return L10n.format("约 %@ 小时", String(describing: Int(min(ceil(seconds / 3600), 9999)))) }
        if seconds >= 60 { return L10n.format("约 %@ 分钟", String(describing: Int(ceil(seconds / 60)))) }
        return L10n.format("约 %@ 秒", String(describing: Int(max(1, ceil(seconds)))))
    }
}

struct ConnectionView: View {
    @Environment(\.locale) private var interfaceLocale
    @Environment(\.dismiss) private var dismiss
    // The form owns its draft. File listings and transfer progress must not
    // invalidate every field while the native sheet is presenting or editing.
    let workspace: Workspace
    @State private var profile: ServerProfile
    @State private var password = ""
    @State private var passphrase = ""
    @State private var remember = false
    @State private var accessKey = ""
    @State private var secretKey = ""
    @State private var sessionToken = ""
    @State private var saving = false
    @State private var save = true
    @State private var error: String?
    @FocusState private var focusedField: ConnectionField?
    private enum ConnectionField: Hashable { case name, host }
    let editing: Bool
    let loadSaved: Bool
    init(workspace: Workspace, initial: ServerProfile = ServerProfile(), editing: Bool = false, loadSaved: Bool = false) {
        self.workspace = workspace; self.editing = editing; self.loadSaved = loadSaved
        _profile = State(initialValue: initial)
    }
    var body: some View {
        let _ = interfaceLocale
        VStack(spacing: 0) {
            SheetHeader(title: editing ? L10n.text("编辑服务器") : L10n.text("连接服务器"),
                        subtitle: editing ? L10n.text("保存连接资料与认证选项。") : L10n.text("连接到服务器，浏览和传输文件。"),
                        symbol: "server.rack")
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: InterfaceStyle.sectionGap) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: InterfaceStyle.fieldGap) {
                            inputRow(L10n.text("名称")) { TextField(L10n.text("名称"), text: $profile.name, prompt: Text(L10n.text("例如：我的服务器"))).labelsHidden().focused($focusedField, equals: .name) }
                            inputRow(L10n.text("收藏分组")) { TextField(L10n.text("收藏分组"), text: $profile.group, prompt: Text(L10n.text("可选"))).labelsHidden() }
                            inputRow(L10n.text("协议")) {
                                Picker(L10n.text("协议"), selection: $profile.protocolKind) { ForEach(TransferProtocol.allCases, id: \.self) { Text($0.title).tag($0) } }.labelsHidden()
                            }
                            inputRow(L10n.text("服务器地址")) { TextField(L10n.text("服务器地址"), text: $profile.host, prompt: Text(L10n.text("例如 files.example.com"))).labelsHidden().focused($focusedField, equals: .host) }
                            inputRow(L10n.text("端口")) { TextField(L10n.text("端口"), value: $profile.port, format: .number.grouping(.never)).labelsHidden() }
                            if profile.protocolKind == .s3 {
                                inputRow(L10n.text("存储桶")) { TextField(L10n.text("存储桶"), text: Binding(get: { profile.s3Bucket ?? "" }, set: { profile.s3Bucket = $0 }), prompt: Text(L10n.text("存储桶名称"))).labelsHidden() }
                                inputRow(L10n.text("区域")) { TextField(L10n.text("区域"), text: Binding(get: { profile.s3Region ?? "us-east-1" }, set: { profile.s3Region = $0 })).labelsHidden() }
                                inputRow("Access Key") { TextField("Access Key", text: $accessKey).labelsHidden() }
                                inputRow("Secret Key") { SecureField("Secret Key", text: $secretKey, prompt: Text(L10n.text("输入访问密钥"))).labelsHidden() }
                                inputRow("Session Token") { SecureField(L10n.text("Session Token（可选）"), text: $sessionToken, prompt: Text(L10n.text("可选"))).labelsHidden() }
                                inputRow(L10n.text("起始前缀")) { TextField(L10n.text("起始前缀"), text: $profile.initialPath, prompt: Text(L10n.text("根目录留空，如 photos/"))).labelsHidden() }
                                inputRow(L10n.text("自定义 CA")) { HStack {
                                        TextField(L10n.text("自定义 CA（可选）"), text: Binding(get: { profile.s3CertificateAuthorityPath ?? "" }, set: { profile.s3CertificateAuthorityPath = $0.isEmpty ? nil : $0 }), prompt: Text(L10n.text("可选：证书文件路径"))).labelsHidden()
                                        Button(L10n.text("选择…")) {
                                            let panel = NSOpenPanel(); panel.canChooseDirectories = false
                                            if panel.runModal() == .OK { profile.s3CertificateAuthorityPath = panel.url?.path }
                                        }
                                    } }
                            } else {
                                inputRow(L10n.text("用户名")) { TextField(L10n.text("用户名"), text: $profile.username, prompt: Text(L10n.text("登录用户名"))).labelsHidden() }
                                inputRow(L10n.text("密码")) { SecureField(L10n.text("密码"), text: $password, prompt: Text(L10n.text("输入密码"))).labelsHidden() }
                                inputRow(L10n.text("远程路径")) { TextField(L10n.text("远程路径"), text: $profile.initialPath).labelsHidden() }
                            }
                            if profile.protocolKind == .sftp {
                                inputRow(L10n.text("SSH 私钥")) { HStack {
                                        TextField(L10n.text("SSH 私钥"), text: $profile.privateKeyPath, prompt: Text(L10n.text("可选：私钥文件路径"))).labelsHidden()
                                        Button(L10n.text("选择…")) {
                                            let panel = NSOpenPanel(); panel.showsHiddenFiles = true
                                            if panel.runModal() == .OK { profile.privateKeyPath = panel.url?.path ?? "" }
                                        }
                                    } }
                                inputRow(L10n.text("私钥口令")) { SecureField(L10n.text("私钥口令"), text: $passphrase, prompt: Text(L10n.text("可选"))).labelsHidden() }
                            }
                        }.padding(8)
                    } label: {
                        Text(L10n.text("连接信息")).font(.headline)
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            if !editing { Toggle(L10n.text("保存服务器收藏"), isOn: $save) }
                            Toggle(profile.protocolKind == .s3 ? L10n.text("将访问密钥 / 令牌保存到钥匙串") : L10n.text("将密码 / 口令保存到钥匙串"), isOn: $remember)
                            if profile.protocolKind == .ftp { Text(L10n.text("FTP 会以明文传输认证和文件内容。建议优先选择 SFTP 或 FTPS。")).font(.caption).foregroundStyle(.secondary) }
                            if profile.protocolKind == .webdav { Text(L10n.text("HTTP 会以明文传输认证和文件内容。建议优先选择 WebDAV · HTTPS。")).font(.caption).foregroundStyle(.secondary) }
                            if profile.protocolKind.isWebDAV { Text(L10n.text("填写服务器主机和 WebDAV 起始路径；如 /remote.php/dav/files/用户名/。HTTPS 会验证服务器证书。")).font(.caption).foregroundStyle(.secondary) }
                            if profile.protocolKind == .s3 {
                                Text(L10n.text("使用 HTTPS 路径式端点；服务器地址仅填主机名。R2 区域通常填 auto。支持前缀浏览、文件和目录传输以及对象删除；重启续传正在适配。"))
                                .font(.caption).foregroundStyle(.secondary)
                                Text(L10n.text("自定义 CA 仍验证证书和服务器名称；留空时使用应用自带的公共根证书。"))
                                .font(.caption).foregroundStyle(.secondary)
                            }
                            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                        }.padding(8)
                    } label: {
                        Text(L10n.text("连接设置")).font(.headline)
                    }
                }.padding(InterfaceStyle.pageInset)
            }.disabled(saving)
            Divider()
            HStack(spacing: 12) {
                Button(L10n.text("取消")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button(editing ? L10n.text("保存") : L10n.text("连接")) {
                    saving = true; error = nil
                    Task {
                        defer { saving = false }
                        do {
                            let credentials = Credentials(password: password, passphrase: passphrase, accessKey: accessKey, secretKey: secretKey, sessionToken: sessionToken)
                            try profile.validate()
                            if profile.protocolKind == .s3 && (!editing || remember) { try credentials.s3.validate() }
                            if save || editing { profile = try await workspace.save(profile, credentials: credentials, remember: remember) }
                            if !editing { workspace.connect(profile, credentials: credentials) }
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                    .disabled(saving || (try? profile.validate()) == nil || (profile.protocolKind == .s3 && (!editing || remember) && (accessKey.isEmpty || secretKey.isEmpty)))
            }.padding(20)
        }.frame(width: InterfaceStyle.connectionWidth, height: 640)
        .onAppear { focusedField = editing ? .name : .host }
        .task {
            guard editing || loadSaved else { return }
            do {
                let requested = profile
                let stored = try await Task.detached { try CredentialStore.load(profile: requested) }.value
                guard profile.credentialIdentity == requested.credentialIdentity else { return }
                password = stored.password; passphrase = stored.passphrase
                accessKey = stored.accessKey; secretKey = stored.secretKey; sessionToken = stored.sessionToken
                remember = !password.isEmpty || !passphrase.isEmpty || !accessKey.isEmpty || !secretKey.isEmpty || !sessionToken.isEmpty
            } catch { self.error = error.localizedDescription }
        }
        .onChange(of: profile.credentialIdentity) { old, new in
            if (editing || loadSaved) && old != new {
                password = ""; passphrase = ""; accessKey = ""; secretKey = ""; sessionToken = ""; remember = false
            }
        }
        .onChange(of: profile.protocolKind) { old, kind in
            profile.port = kind.defaultPort
            password = ""; passphrase = ""; accessKey = ""; secretKey = ""; sessionToken = ""; remember = false
            if kind == .s3 { profile.initialPath = "" }
            else if old == .s3 { profile.initialPath = "/" }
        }
        .interactiveDismissDisabled(saving)
    }
    private func inputRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        LabeledContent {
            content().textFieldStyle(.roundedBorder).multilineTextAlignment(.leading)
                .frame(minWidth: 250, maxWidth: .infinity)
        } label: {
            Text(title).frame(width: InterfaceStyle.fieldLabelWidth, alignment: .leading)
        }
    }
}
