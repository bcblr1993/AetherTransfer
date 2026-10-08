import SwiftUI
import AppKit
import AetherTransferCore

@main struct AetherTransferApp: App {
    @StateObject private var tabs = BrowserTabs()
    @NSApplicationDelegateAdaptor(TransferAppDelegate.self) private var appDelegate
    @AppStorage("appearance") private var appearance = "system"
    var body: some Scene {
        WindowGroup("AetherTransfer") {
            MainView(workspace: tabs.current, tabs: tabs).frame(minWidth: 1000, minHeight: 640)
                .preferredColorScheme(appearance == "dark" ? .dark : (appearance == "light" ? .light : nil))
                .onAppear { appDelegate.editors = tabs.editors; appDelegate.tabs = tabs }
        }
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandGroup(after: .newItem) {
                Button("新建标签页") { tabs.add() }.keyboardShortcut("t")
                Button("选择本地文件夹…") { tabs.current.chooseLocal() }.keyboardShortcut("o")
                Button("刷新") { tabs.current.refreshLocal(); tabs.current.refreshRemote() }.keyboardShortcut("r")
                Button("上传所选文件") { tabs.current.uploadSelection() }.keyboardShortcut("u", modifiers: [.command, .shift])
                Button("下载所选文件") { tabs.current.downloadSelection() }.keyboardShortcut("d", modifiers: [.command, .shift])
                Button("同步目录…") { tabs.current.showSync = true }.disabled(tabs.current.isS3).keyboardShortcut("s", modifiers: [.command, .shift])
                Button("编辑所选文本…") { tabs.current.editSelection() }.keyboardShortcut("e")
                Button("快速查看…") { tabs.current.previewSelection() }.keyboardShortcut("y")
                Button("文件信息") { tabs.current.showInspector.toggle() }.keyboardShortcut("i")
                Button("保留的传输…") { tabs.current.showRecovery = true }
            }
            CommandMenu("显示") {
                Button("图标视图") { tabs.current.setViewMode(.icons) }.keyboardShortcut("1")
                Button("列表视图") { tabs.current.setViewMode(.list) }.keyboardShortcut("2")
                Divider()
                Button("显示 / 隐藏隐藏文件") { tabs.current.showHidden.toggle() }.keyboardShortcut(".", modifiers: [.command, .shift])
            }
            CommandGroup(after: .textEditing) {
                Button("查找…") {
                    let sender = NSMenuItem(); sender.tag = NSTextFinder.Action.showFindInterface.rawValue
                    NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)), to: nil, from: sender)
                }.keyboardShortcut("f")
            }
        }
        Settings { TransferSettingsView(tabs: tabs) }
    }
}

struct TransferSettingsView: View {
    @ObservedObject var tabs: BrowserTabs
    @AppStorage("maxConcurrentTransfers") private var concurrency = 2
    @AppStorage("transferRateKiB") private var rate = 0
    @AppStorage("appearance") private var appearance = "system"
    var body: some View {
        Form {
            Section("外观") {
                Picker("主题", selection: $appearance) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                Text("动效遵循系统“减少动态效果”设置。").font(.caption).foregroundStyle(.secondary)
            }
            Section("传输") {
                Picker("同时进行的任务", selection: $concurrency) {
                    ForEach(1...8, id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("每个任务的速度上限", selection: $rate) {
                    Text("不限速").tag(0)
                    Text("256 KiB/s").tag(256)
                    Text("1 MiB/s").tag(1024)
                    Text("5 MiB/s").tag(5120)
                    Text("20 MiB/s").tag(20480)
                }
                Text("速度上限对新任务生效。降低并发数时，已开始的任务会继续运行。").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).frame(width: 480, height: 370)
        .preferredColorScheme(appearance == "dark" ? .dark : (appearance == "light" ? .light : nil))
        .onChange(of: concurrency) { _, value in tabs.setConcurrency(value) }
    }
}

struct MainView: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var tabs: BrowserTabs
    @State private var showConnect = false
    @State private var showActivities = false
    @State private var query = ""
    @Namespace private var tabGlass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editingProfile: ServerProfile?
    private var groups: [String] { Set(workspace.profiles.map(\.group)).sorted() }
    var body: some View {
        NavigationSplitView {
            List(selection: $workspace.selectedServer) {
                Section("位置") {
                    Button { workspace.localPath = FileManager.default.homeDirectoryForCurrentUser.path; workspace.refreshLocal() } label: { Label("个人文件夹", systemImage: "house") }.buttonStyle(.plain)
                    Button { workspace.localPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path; workspace.refreshLocal() } label: { Label("下载", systemImage: "arrow.down.circle") }.buttonStyle(.plain)
                }
                Section("服务器") {
                    ForEach(groups, id: \.self) { group in
                        if !group.isEmpty { Text(group).font(.caption).foregroundStyle(.secondary) }
                        ForEach(workspace.profiles.filter { $0.group == group }) { profile in
                            VStack(alignment: .leading, spacing: 3) {
                                Label(profile.name.isEmpty ? profile.host : profile.name, systemImage: "server.rack")
                                Text(profile.protocolKind.title).font(.caption).foregroundStyle(.secondary)
                            }.tag(profile.id).onTapGesture(count: 2) { workspace.connectSaved(profile) }
                            .contextMenu {
                                Button("连接") { workspace.connectSaved(profile) }
                                Button("编辑…") { editingProfile = profile }
                                Divider()
                                Button("移除收藏…", role: .destructive) { workspace.removeProfile(profile) }
                            }
                        }
                    }
                    Button { showConnect = true } label: { Label("添加服务器", systemImage: "plus") }.buttonStyle(.plain)
                    Menu("管理收藏", systemImage: "ellipsis.circle") {
                        Button("导入收藏…") { workspace.importProfiles() }
                        Button("导出收藏…") { workspace.exportProfiles() }.disabled(workspace.profiles.isEmpty)
                    }.menuStyle(.borderlessButton)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ScrollView(.horizontal) {
                        GlassEffectContainer(spacing: 8) {
                            HStack(spacing: 4) {
                                ForEach(tabs.tabs) { tab in BrowserTabItem(id: tab.id, workspace: tab.workspace, tabs: tabs, namespace: tabGlass) }
                                Button("新建标签页", systemImage: "plus") { tabs.add() }
                                    .labelStyle(.iconOnly).buttonStyle(.borderless).padding(.horizontal, 8)
                            }.padding(.horizontal, 10).padding(.vertical, 7)
                        }.animation(reduceMotion ? nil : .snappy(duration: 0.25), value: tabs.selected)
                            .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: tabs.tabs.count)
                    }.scrollIndicators(.hidden)
                    Divider()
                    HSplitView {
                        FilePane(title: "本地", path: $workspace.localPath, files: workspace.localFiles,
                                 selection: $workspace.localSelection, loading: workspace.loadingLocal,
                                 query: query, remote: false, workspace: workspace)
                        if workspace.connectedProfile != nil {
                            FilePane(title: workspace.connectedProfile?.name.isEmpty == false ? workspace.connectedProfile!.name : "远程",
                                     path: $workspace.remotePath, files: workspace.remoteFiles, selection: $workspace.remoteSelection,
                                     loading: workspace.loadingRemote, query: query, remote: true, workspace: workspace)
                        } else {
                            ConnectionWelcomeView { showConnect = true }
                                .frame(minWidth: 350, maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }.id(workspace.connectedProfile?.id).transaction { $0.animation = nil }
                    Divider()
                    ActivityView(workspace: workspace, expanded: $showActivities).frame(height: showActivities ? 170 : 44)
                        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: showActivities)
                    Divider()
                    HStack {
                        Text(workspace.connectedProfile.map { "\($0.protocolKind.title) · \($0.name.isEmpty ? $0.host : $0.name)" } ?? "未连接")
                        Spacer()
                        Text("\(workspace.localFiles.count) 个本地项目 · \(workspace.remoteFiles.count) 个远程项目")
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
                Button("连接", systemImage: "plus") { showConnect = true }
                Button("刷新", systemImage: "arrow.clockwise") { workspace.refreshLocal(); workspace.refreshRemote() }
                Button("上传", systemImage: "arrow.up") { workspace.uploadSelection() }.disabled(workspace.localSelection.isEmpty || !workspace.hasRemoteConnection)
                Button("下载", systemImage: "arrow.down") { workspace.downloadSelection() }.disabled(workspace.remoteSelection.isEmpty)
            }
            ToolbarItem { Button("活动", systemImage: "list.bullet.rectangle") { showActivities.toggle() } }
            ToolbarItem { Button("文件信息", systemImage: "info.circle") { workspace.showInspector.toggle() } }
            ToolbarItem { Button("同步", systemImage: "arrow.triangle.2.circlepath") { workspace.showSync = true }.disabled(workspace.isS3) }
            ToolbarItem { Button("断开", systemImage: "eject") { workspace.disconnect() }.disabled(!workspace.hasRemoteConnection) }
        }
        .searchable(text: $query, prompt: "筛选当前目录")
        .sheet(isPresented: $showConnect) { ConnectionView(workspace: workspace) }
        .sheet(isPresented: $workspace.showSync) { SyncReviewView(workspace: workspace, tabs: tabs) }
        .sheet(isPresented: $workspace.showRecovery) { RecoveryView(workspace: workspace, tabs: tabs) }
        .sheet(item: $editingProfile) { profile in ConnectionView(workspace: workspace, initial: profile, editing: true) }
        .sheet(item: $workspace.connectionPrompt) { profile in ConnectionView(workspace: workspace, initial: profile, loadSaved: true) }
        .alert("操作失败", isPresented: Binding(get: { workspace.error != nil }, set: { if !$0 { workspace.error = nil } })) {
            Button("确定") { workspace.error = nil }
        } message: { Text(workspace.error ?? "") }
        .sheet(item: $workspace.hostChallenge) { challenge in
            VStack(alignment: .leading, spacing: 20) {
                Label("核对服务器指纹", systemImage: "lock.shield").font(.title2)
                Text("请通过可信渠道核对服务器的 SHA-256 指纹。确认后才会进行认证和文件操作。")
                Text(RemoteClient.fingerprint(challenge.key)).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                HStack {
                    Button("取消") { workspace.hostChallenge = nil; workspace.disconnect() }
                    Spacer()
                    Button("信任并连接") { workspace.approveHostKey() }.buttonStyle(.glassProminent)
                }
            }.padding(28).frame(width: 570)
        }
        .onChange(of: workspace.showHidden) { workspace.refreshLocal() }
        .onChange(of: tabs.selected) { workspace.reloadProfiles() }
        .onChange(of: workspace.activities.count) { old, new in if new > old { showActivities = true } }
        .onReceive(NotificationCenter.default.publisher(for: .init("AetherTransferEditedFile"))) { _ in
            workspace.refreshLocal(); workspace.refreshRemote()
        }
        .onAppear { workspace.reloadProfiles() }
    }
}

private struct ConnectionWelcomeView: View {
    let connect: () -> Void
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 30, weight: .medium)).foregroundStyle(.blue.gradient)
                .frame(width: 76, height: 76).background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 23))
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("文件，自由往来").font(.title2.weight(.semibold))
                Text("连接服务器，让本地与远程并肩工作。")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            HStack(spacing: 8) {
                ForEach(["SFTP", "FTP", "FTPS", "WebDAV", "S3"], id: \.self) { name in
                    Text(name).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.quaternary, in: Capsule())
                }
            }
            Button("连接服务器", systemImage: "plus") { connect() }.buttonStyle(.glassProminent).controlSize(.large)
                .padding(.top, 4)
            Text("密码可保存在系统钥匙串").font(.caption).foregroundStyle(.tertiary)
        }.padding(32)
    }
}

struct FilePane: View {
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
    @State private var presenting = true
    private struct PresentationRequest: Hashable {
        let revision: UUID
        let query: String
        let hidden: Bool
        let field: FileSortField
        let descending: Bool
    }
    private var request: PresentationRequest {
        PresentationRequest(revision: remote ? workspace.remoteRevision : workspace.localRevision,
                            query: query, hidden: workspace.showHidden, field: sortField, descending: descending)
    }
    private var viewMode: Binding<FileViewMode> {
        remote ? $workspace.remoteViewMode : $workspace.localViewMode
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: remote ? "network" : "internaldrive").foregroundStyle(.secondary)
                Text(title).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Spacer()
                if loading || presenting { ProgressView().controlSize(.small) }
                Picker("\(title)视图", selection: viewMode) {
                    Image(systemName: "square.grid.2x2").accessibilityLabel("图标视图").tag(FileViewMode.icons)
                    Image(systemName: "list.bullet").accessibilityLabel("列表视图").tag(FileViewMode.list)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 78)
                if viewMode.wrappedValue == .icons {
                    Menu("排序", systemImage: "arrow.up.arrow.down") {
                        Picker("排序依据", selection: $sortField) {
                            Text("名称").tag(FileSortField.name); Text("大小").tag(FileSortField.size); Text("修改日期").tag(FileSortField.modified)
                        }
                        Divider()
                        Button(descending ? "升序" : "降序") { descending.toggle() }
                    }.labelStyle(.iconOnly).menuStyle(.borderlessButton)
                }
                Button("上一级", systemImage: "arrow.up") { workspace.parent(remote: remote) }.labelStyle(.iconOnly)
                Button("新建文件夹", systemImage: "folder.badge.plus") { workspace.createFolder(remote: remote) }.labelStyle(.iconOnly)
                if !remote { Button("选择文件夹", systemImage: "folder") { workspace.chooseLocal() }.labelStyle(.iconOnly) }
            }.padding(.horizontal, 12).padding(.vertical, 10).controlSize(.small)
            TextField(remote && workspace.isS3 ? "前缀（根目录为空，如 photos/）" : "路径", text: $path).textFieldStyle(.roundedBorder).font(.system(.callout, design: .monospaced))
                .onSubmit { if remote { workspace.refreshRemote() } else { workspace.refreshLocal() } }
                .padding(.horizontal, 12).padding(.bottom, 10)
            Group {
                if viewMode.wrappedValue == .icons {
                    NativeFileIcons(files: filtered, revision: presentationRevision, selection: $selection, remote: remote, workspace: workspace)
                } else {
                    NativeFileTable(files: filtered, revision: presentationRevision, selection: $selection,
                                    sortField: $sortField, descending: $descending, remote: remote, workspace: workspace)
                }
            }
                .disabled(loading || presenting)
                .overlay { if filtered.isEmpty && !loading && !presenting { ContentUnavailableView("没有文件", systemImage: "folder", description: Text(query.isEmpty ? "此目录为空。" : "没有匹配的项目。")) .allowsHitTesting(false) } }

        }.frame(minWidth: 350, maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: viewMode.wrappedValue) { _, _ in workspace.focusedRemote = remote }
        .task(id: request) {
            // Read entries and revision from the same observable source. A child can see a new
            // revision before its parent passes the refreshed value-type files argument.
            let current = request, snapshot = remote ? workspace.remoteFiles : workspace.localFiles
            presenting = true
            do {
                if !current.query.isEmpty { try await Task.sleep(for: .milliseconds(120)) }
                let result = await Task.detached {
                    FilePresentation.entries(snapshot, query: current.query, showHidden: current.hidden, field: current.field, descending: current.descending)
                }.value
                try Task.checkCancellation()
                filtered = result; presentationRevision = UUID(); presenting = false
                selection.formIntersection(Set(result.map(\.id)))
            } catch is CancellationError { } catch { presenting = false }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard remote, workspace.canReceiveUpload, !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
            workspace.uploadURLs(urls); return true
        }
    }
}

struct ActivityView: View {
    @ObservedObject var workspace: Workspace
    @Binding var expanded: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { expanded.toggle() } label: { Label("传输活动", systemImage: expanded ? "chevron.down" : "chevron.right").font(.callout.weight(.semibold)) }.buttonStyle(.plain)
                Spacer()
                Button("保留的传输…", systemImage: "clock.arrow.circlepath") { workspace.showRecovery = true }.buttonStyle(.borderless).font(.caption)
                Text(workspace.activities.isEmpty ? "暂无任务" : "\(workspace.activities.filter { $0.state == "传输中" }.count) 个进行中 · \(workspace.activities.count) 个任务").font(.caption).foregroundStyle(.secondary)
                if !workspace.activities.isEmpty { Button("清除已结束任务") { workspace.clearFinishedActivities() }.buttonStyle(.borderless).font(.caption) }
            }.padding(.horizontal, 14).frame(height: 38)
            if expanded && workspace.activities.isEmpty {
                Text("上传或下载文件后，在这里查看进度。").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
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
                                            Text("\(item.direction == "同步" ? "同步总量" : (item.scope == .directory ? "目录处理总量" : "当前文件"))：\(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: item.total, countStyle: .file))").font(.caption).foregroundStyle(.secondary)
                                        } else { ProgressView().controlSize(.small) }
                                        if let rate = item.rate {
                                            HStack(spacing: 8) {
                                                Text("\(item.scope == .file ? "传输" : "处理") \(ByteCountFormatter.string(fromByteCount: Int64(min(rate.bytesPerSecond, Double(Int64.max).nextDown)), countStyle: .binary))/s")
                                                if let remaining = rate.remainingSeconds {
                                                    Text("预计剩余 \(Self.remainingText(remaining))")
                                                }
                                            }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                        }
                                        if let phase = item.phase { Text(phase).font(.caption).foregroundStyle(.secondary) }
                                    }
                                    if let completed = item.completedItems, let total = item.totalItems {
                                        Text("已处理 \(completed) / \(total) 个项目\(item.skippedItems > 0 ? " · 跳过 \(item.skippedItems) 项" : "")")
                                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                    }
                                    if let error = item.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
                                    if item.scope == .directory && (item.state == "失败" || item.state == "已取消") {
                                        Text("重新选择目录并确认冲突后，可再次传输。").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Label(item.state, systemImage: item.state == "完成" ? "checkmark.circle.fill" : (item.state == "失败" ? "exclamationmark.circle" : "circle.dotted"))
                                    .font(.caption).foregroundStyle(item.state == "失败" ? Color.red : (item.state == "完成" ? Color.green : Color.secondary))
                                if item.state == "传输中" { Button("暂停", systemImage: "pause.circle") { workspace.pause(item.id) }.labelStyle(.iconOnly).buttonStyle(.borderless) }
                                if item.state == "已暂停" { Button("继续", systemImage: "play.circle") { workspace.resume(item.id) }.labelStyle(.iconOnly).buttonStyle(.borderless) }
                                if item.canRetain && (item.state == "传输中" || item.state == "已暂停") {
                                    Button("保留进度", systemImage: "clock.arrow.circlepath") { workspace.retain(item.id) }.buttonStyle(.borderless)
                                }
                                if item.state == "传输中" || item.state == "等待中" || item.state == "已暂停" { Button("取消", systemImage: "xmark.circle") { workspace.cancel(item.id) }.labelStyle(.iconOnly).buttonStyle(.borderless) }
                                if item.state == "待续传" || (item.state == "失败" && item.canRetain) {
                                    Button(item.requiresRestart ? "从头上传" : "继续传输", systemImage: "play.circle") { workspace.retry(item.id) }.buttonStyle(.borderless)
                                    Button("丢弃进度", systemImage: "trash") { workspace.discardRetained(item.id) }.labelStyle(.iconOnly).buttonStyle(.borderless)
                                } else if item.state == "失败" || item.state == "已取消" {
                                    if item.canRetry {
                                        Button("重试", systemImage: "arrow.clockwise") { workspace.retry(item.id) }.labelStyle(.iconOnly).buttonStyle(.borderless)
                                    } else if item.direction == "同步" {
                                        Button("重新预览", systemImage: "arrow.triangle.2.circlepath") { workspace.showSync = true }.buttonStyle(.borderless)
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
        if seconds >= 3600 { return "约 \(Int(min(ceil(seconds / 3600), 9999))) 小时" }
        if seconds >= 60 { return "约 \(Int(ceil(seconds / 60))) 分钟" }
        return "约 \(Int(max(1, ceil(seconds)))) 秒"
    }
}

struct ConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var workspace: Workspace
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
    let editing: Bool
    let loadSaved: Bool
    init(workspace: Workspace, initial: ServerProfile = ServerProfile(), editing: Bool = false, loadSaved: Bool = false) {
        self.workspace = workspace; self.editing = editing; self.loadSaved = loadSaved
        _profile = State(initialValue: initial)
    }
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("连接服务器") {
                    inputRow("名称") { TextField("名称", text: $profile.name, prompt: Text("例如：我的服务器")).labelsHidden() }
                    inputRow("收藏分组") { TextField("收藏分组", text: $profile.group, prompt: Text("可选")).labelsHidden() }
                    Picker("协议", selection: $profile.protocolKind) { ForEach(TransferProtocol.allCases, id: \.self) { Text($0.title).tag($0) } }
                    inputRow("服务器地址") { TextField("服务器地址", text: $profile.host, prompt: Text("例如 files.example.com")).labelsHidden() }
                    inputRow("端口") { TextField("端口", value: $profile.port, format: .number.grouping(.never)).labelsHidden() }
                    if profile.protocolKind == .s3 {
                        inputRow("存储桶") { TextField("存储桶", text: Binding(get: { profile.s3Bucket ?? "" }, set: { profile.s3Bucket = $0 }), prompt: Text("存储桶名称")).labelsHidden() }
                        inputRow("区域") { TextField("区域", text: Binding(get: { profile.s3Region ?? "us-east-1" }, set: { profile.s3Region = $0 })).labelsHidden() }
                        inputRow("Access Key") { TextField("Access Key", text: $accessKey).labelsHidden() }
                        inputRow("Secret Key") { SecureField("Secret Key", text: $secretKey, prompt: Text("输入访问密钥")).labelsHidden() }
                        inputRow("Session Token") { SecureField("Session Token（可选）", text: $sessionToken, prompt: Text("可选")).labelsHidden() }
                        inputRow("起始前缀") { TextField("起始前缀", text: $profile.initialPath, prompt: Text("根目录留空，如 photos/")).labelsHidden() }
                        inputRow("自定义 CA") { HStack {
                            TextField("自定义 CA（可选）", text: Binding(get: { profile.s3CertificateAuthorityPath ?? "" }, set: { profile.s3CertificateAuthorityPath = $0.isEmpty ? nil : $0 }), prompt: Text("可选：证书文件路径")).labelsHidden()
                            Button("选择…") {
                                let panel = NSOpenPanel(); panel.canChooseDirectories = false
                                if panel.runModal() == .OK { profile.s3CertificateAuthorityPath = panel.url?.path }
                            }
                        } }
                    } else {
                        inputRow("用户名") { TextField("用户名", text: $profile.username, prompt: Text("登录用户名")).labelsHidden() }
                        inputRow("密码") { SecureField("密码", text: $password, prompt: Text("输入密码")).labelsHidden() }
                        inputRow("远程路径") { TextField("远程路径", text: $profile.initialPath).labelsHidden() }
                    }
                    if profile.protocolKind == .sftp {
                        inputRow("SSH 私钥") { HStack {
                            TextField("SSH 私钥", text: $profile.privateKeyPath, prompt: Text("可选：私钥文件路径")).labelsHidden()
                            Button("选择…") {
                                let panel = NSOpenPanel(); panel.showsHiddenFiles = true
                                if panel.runModal() == .OK { profile.privateKeyPath = panel.url?.path ?? "" }
                            }
                        } }
                        inputRow("私钥口令") { SecureField("私钥口令", text: $passphrase, prompt: Text("可选")).labelsHidden() }
                    }
                }
                Section {
                    if !editing { Toggle("保存服务器收藏", isOn: $save) }
                    Toggle(profile.protocolKind == .s3 ? "将访问密钥 / 令牌保存到钥匙串" : "将密码 / 口令保存到钥匙串", isOn: $remember)
                    if profile.protocolKind == .ftp { Text("FTP 会以明文传输认证和文件内容。建议优先选择 SFTP 或 FTPS。").font(.caption).foregroundStyle(.secondary) }
                    if profile.protocolKind == .webdav { Text("HTTP 会以明文传输认证和文件内容。建议优先选择 WebDAV · HTTPS。").font(.caption).foregroundStyle(.secondary) }
                    if profile.protocolKind.isWebDAV { Text("填写服务器主机和 WebDAV 起始路径；如 /remote.php/dav/files/用户名/。HTTPS 会验证服务器证书。").font(.caption).foregroundStyle(.secondary) }
                    if profile.protocolKind == .s3 {
                        Text("使用 HTTPS 路径式端点；服务器地址仅填主机名。R2 区域通常填 auto。当前支持前缀浏览、普通文件传输与对象删除，目录传输和续传正在适配。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("自定义 CA 仍验证证书和服务器名称；留空时使用应用自带的公共根证书。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error { Text(error).foregroundStyle(.red) }
                }
            }.formStyle(.grouped).disabled(saving)
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Spacer()
                Button(editing ? "保存" : "连接") {
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
        }.frame(width: 540, height: 640)
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
            Text(title).frame(width: 115, alignment: .leading)
        }
    }
}
