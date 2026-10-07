import SwiftUI
import AppKit
import AetherTransferCore

@main struct AetherTransferApp: App {
    @StateObject private var tabs = BrowserTabs()
    @AppStorage("appearance") private var appearance = "system"
    var body: some Scene {
        WindowGroup("AetherTransfer") {
            MainView(workspace: tabs.current, tabs: tabs).frame(minWidth: 1000, minHeight: 640)
                .preferredColorScheme(appearance == "dark" ? .dark : (appearance == "light" ? .light : nil))
        }
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandGroup(after: .newItem) {
                Button("新建标签页") { tabs.add() }.keyboardShortcut("t")
                Button("选择本地文件夹…") { tabs.current.chooseLocal() }.keyboardShortcut("o")
                Button("刷新") { tabs.current.refreshLocal(); tabs.current.refreshRemote() }.keyboardShortcut("r")
                Button("上传所选文件") { tabs.current.uploadSelection() }.keyboardShortcut("u", modifiers: [.command, .shift])
                Button("下载所选文件") { tabs.current.downloadSelection() }.keyboardShortcut("d", modifiers: [.command, .shift])
                Button("同步目录…") { tabs.current.showSync = true }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandMenu("显示") {
                Button("显示 / 隐藏隐藏文件") { tabs.current.showHidden.toggle() }.keyboardShortcut(".", modifiers: [.command, .shift])
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
        }
        .navigationTitle("AetherTransfer")
        .toolbar {
            ToolbarItemGroup {
                Button("连接", systemImage: "plus") { showConnect = true }
                Button("刷新", systemImage: "arrow.clockwise") { workspace.refreshLocal(); workspace.refreshRemote() }
                Button("上传", systemImage: "arrow.up") { workspace.uploadSelection() }.disabled(workspace.localSelection.isEmpty || workspace.client == nil)
                Button("下载", systemImage: "arrow.down") { workspace.downloadSelection() }.disabled(workspace.remoteSelection.isEmpty)
            }
            ToolbarItem { Button("活动", systemImage: "list.bullet.rectangle") { showActivities.toggle() } }
            ToolbarItem { Button("同步", systemImage: "arrow.triangle.2.circlepath") { workspace.showSync = true } }
            ToolbarItem { Button("断开", systemImage: "eject") { workspace.disconnect() }.disabled(workspace.client == nil) }
        }
        .searchable(text: $query, prompt: "筛选当前目录")
        .sheet(isPresented: $showConnect) { ConnectionView(workspace: workspace) }
        .sheet(isPresented: $workspace.showSync) { SyncReviewView(workspace: workspace, tabs: tabs) }
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
                ForEach(["SFTP", "FTP", "FTPS"], id: \.self) { name in
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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: remote ? "network" : "internaldrive").foregroundStyle(.secondary)
                Text(title).font(.callout.weight(.semibold))
                Spacer()
                if loading || presenting { ProgressView().controlSize(.small) }
                Button("上一级", systemImage: "arrow.up") { workspace.parent(remote: remote) }.labelStyle(.iconOnly)
                Button("新建文件夹", systemImage: "folder.badge.plus") { workspace.createFolder(remote: remote) }.labelStyle(.iconOnly)
                if !remote { Button("选择文件夹", systemImage: "folder") { workspace.chooseLocal() }.labelStyle(.iconOnly) }
            }.padding(.horizontal, 12).padding(.vertical, 10).controlSize(.small)
            TextField("路径", text: $path).textFieldStyle(.roundedBorder).font(.system(.callout, design: .monospaced))
                .onSubmit { if remote { workspace.refreshRemote() } else { workspace.refreshLocal() } }
                .padding(.horizontal, 12).padding(.bottom, 10)
            NativeFileTable(files: filtered, revision: presentationRevision, selection: $selection,
                            sortField: $sortField, descending: $descending, remote: remote, workspace: workspace)
                .disabled(loading || presenting)
                .overlay { if filtered.isEmpty && !loading && !presenting { ContentUnavailableView("没有文件", systemImage: "folder", description: Text(query.isEmpty ? "此目录为空。" : "没有匹配的项目。")) } }

        }.frame(minWidth: 350, maxWidth: .infinity, maxHeight: .infinity)
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
            guard remote, workspace.client != nil, urls.allSatisfy(\.isFileURL) else { return false }
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
                Text(workspace.activities.isEmpty ? "暂无任务" : "\(workspace.activities.filter { $0.state == "传输中" }.count) 个进行中 · \(workspace.activities.count) 个任务").font(.caption).foregroundStyle(.secondary)
                if !workspace.activities.isEmpty { Button("清除已结束任务") { workspace.clearFinishedActivities() }.buttonStyle(.borderless).font(.caption) }
            }.padding(.horizontal, 14).frame(height: 38)
            if expanded && workspace.activities.isEmpty {
                Text("上传或下载文件后，在这里查看进度。").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if expanded {
                List(workspace.activities) { item in
                    HStack {
                        Image(systemName: item.direction == "同步" ? "arrow.triangle.2.circlepath" : (item.direction == "上传" ? "arrow.up.circle" : "arrow.down.circle"))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name).lineLimit(1)
                            if item.state == "传输中" || item.state == "已暂停" {
                                ProgressView(value: item.progress).frame(maxWidth: 220)
                                Text("\(item.direction == "同步" ? "同步总量" : "当前文件")：\(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: item.total, countStyle: .file))").font(.caption).foregroundStyle(.secondary)
                            }
                            if let error = item.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
                        }
                        Spacer()
                        Label(item.state, systemImage: item.state == "完成" ? "checkmark.circle.fill" : (item.state == "失败" ? "exclamationmark.circle" : "circle.dotted"))
                            .font(.caption).foregroundStyle(item.state == "失败" ? Color.red : (item.state == "完成" ? Color.green : Color.secondary))
                        if item.state == "传输中" { Button("暂停", systemImage: "pause.circle") { workspace.pause(item.id) }.labelStyle(.iconOnly).buttonStyle(.borderless) }
                        if item.state == "已暂停" { Button("继续", systemImage: "play.circle") { workspace.resume(item.id) }.labelStyle(.iconOnly).buttonStyle(.borderless) }
                        if item.state == "传输中" || item.state == "等待中" || item.state == "已暂停" { Button("取消", systemImage: "xmark.circle") { workspace.cancel(item.id) }.labelStyle(.iconOnly).buttonStyle(.borderless) }
                        if item.state == "失败" || item.state == "已取消" {
                            if item.canRetry {
                                Button("重试", systemImage: "arrow.clockwise") { workspace.retry(item.id) }.labelStyle(.iconOnly).buttonStyle(.borderless)
                            } else {
                                Button("重新预览", systemImage: "arrow.triangle.2.circlepath") { workspace.showSync = true }.buttonStyle(.borderless)
                            }
                        }
                    }
                }.listStyle(.plain)
            }
        }
    }
}

struct ConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var workspace: Workspace
    @State private var profile: ServerProfile
    @State private var password = ""
    @State private var passphrase = ""
    @State private var remember = false
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
                    TextField("名称", text: $profile.name)
                    TextField("收藏分组", text: $profile.group)
                    Picker("协议", selection: $profile.protocolKind) { ForEach(TransferProtocol.allCases, id: \.self) { Text($0.title).tag($0) } }
                    TextField("服务器地址", text: $profile.host)
                    TextField("端口", value: $profile.port, format: .number.grouping(.never))
                    TextField("用户名", text: $profile.username)
                    SecureField("密码", text: $password)
                    TextField("远程路径", text: $profile.initialPath)
                    if profile.protocolKind == .sftp {
                        HStack {
                            TextField("SSH 私钥", text: $profile.privateKeyPath)
                            Button("选择…") {
                                let panel = NSOpenPanel(); panel.showsHiddenFiles = true
                                if panel.runModal() == .OK { profile.privateKeyPath = panel.url?.path ?? "" }
                            }
                        }
                        SecureField("私钥口令", text: $passphrase)
                    }
                }
                Section {
                    if !editing { Toggle("保存服务器收藏", isOn: $save) }
                    Toggle("将密码 / 口令保存到钥匙串", isOn: $remember)
                    if profile.protocolKind == .ftp { Text("FTP 会以明文传输认证和文件内容。建议优先选择 SFTP 或 FTPS。").font(.caption).foregroundStyle(.secondary) }
                    if let error { Text(error).foregroundStyle(.red) }
                }
            }.formStyle(.grouped)
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(editing ? "保存" : "连接") {
                    do {
                        let credentials = Credentials(password: password, passphrase: passphrase)
                        try profile.validate()
                        if save || editing { profile = try workspace.save(profile, credentials: credentials, remember: remember) }
                        if !editing { workspace.connect(profile, credentials: credentials) }
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
            }.padding(20)
        }.frame(width: 540, height: 640)
        .task {
            guard editing || loadSaved else { return }
            do {
                let id = profile.id, endpoint = profile.host, port = profile.port, kind = profile.protocolKind
                let stored = try await Task.detached {
                    try Credentials(password: CredentialStore.load(id: id), passphrase: CredentialStore.load(id: id, kind: "passphrase"))
                }.value
                guard profile.host == endpoint && profile.port == port && profile.protocolKind == kind else { return }
                password = stored.password; passphrase = stored.passphrase
                remember = !password.isEmpty || !passphrase.isEmpty
            } catch { self.error = error.localizedDescription }
        }
        .onChange(of: profile.host) { old, new in
            if editing && old != new { password = ""; passphrase = ""; remember = false }
        }
        .onChange(of: profile.protocolKind) { _, kind in profile.port = kind.defaultPort }
    }
}
