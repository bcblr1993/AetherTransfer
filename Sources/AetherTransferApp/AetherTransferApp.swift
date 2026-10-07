import SwiftUI
import AppKit
import AetherTransferCore

@main struct AetherTransferApp: App {
    @StateObject private var tabs = BrowserTabs()
    var body: some Scene {
        WindowGroup("AetherTransfer") {
            MainView(workspace: tabs.current, tabs: tabs).id(tabs.selected).frame(minWidth: 1000, minHeight: 640)
        }
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandGroup(after: .newItem) {
                Button("新建标签页") { tabs.add() }.keyboardShortcut("t")
                Button("选择本地文件夹…") { tabs.current.chooseLocal() }.keyboardShortcut("o")
                Button("刷新") { tabs.current.refreshLocal(); tabs.current.refreshRemote() }.keyboardShortcut("r")
                Button("上传所选文件") { tabs.current.uploadSelection() }.keyboardShortcut("u", modifiers: [.command, .shift])
                Button("下载所选文件") { tabs.current.downloadSelection() }.keyboardShortcut("d", modifiers: [.command, .shift])
            }
            CommandMenu("显示") {
                Button("显示 / 隐藏隐藏文件") { tabs.current.showHidden.toggle() }.keyboardShortcut(".", modifiers: [.command, .shift])
            }
        }
    }
}

struct MainView: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var tabs: BrowserTabs
    @State private var showConnect = false
    @State private var showActivities = true
    @State private var query = ""
    var body: some View {
        NavigationSplitView {
            List(selection: $workspace.selectedServer) {
                Section("位置") {
                    Button { workspace.localPath = FileManager.default.homeDirectoryForCurrentUser.path; workspace.refreshLocal() } label: { Label("个人文件夹", systemImage: "house") }.buttonStyle(.plain)
                    Button { workspace.localPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path; workspace.refreshLocal() } label: { Label("下载", systemImage: "arrow.down.circle") }.buttonStyle(.plain)
                }
                Section("服务器") {
                    ForEach(workspace.profiles) { profile in
                        VStack(alignment: .leading, spacing: 3) {
                            Label(profile.name.isEmpty ? profile.host : profile.name, systemImage: "server.rack")
                            Text(profile.protocolKind.title).font(.caption).foregroundStyle(.secondary)
                        }.tag(profile.id).onTapGesture(count: 2) { workspace.connectSaved(profile) }
                        .contextMenu { Button("连接") { workspace.connectSaved(profile) } }
                    }
                    Button { showConnect = true } label: { Label("添加服务器", systemImage: "plus") }.buttonStyle(.plain)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            VStack(spacing: 0) {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(tabs.tabs) { tab in BrowserTabItem(id: tab.id, workspace: tab.workspace, tabs: tabs) }
                        Button("新建标签页", systemImage: "plus") { tabs.add() }.labelStyle(.iconOnly).buttonStyle(.borderless).padding(.horizontal, 8)
                    }.padding(.horizontal, 10).padding(.vertical, 6)
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
                        ContentUnavailableView {
                            Label("连接服务器", systemImage: "externaldrive.connected.to.line.below")
                        } description: { Text("选择收藏或添加 FTP / SFTP 连接，开始浏览与传输。") }
                        actions: { Button("快速连接", systemImage: "bolt") { showConnect = true }.buttonStyle(.glassProminent) }
                        .frame(minWidth: 350, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.id(workspace.connectedProfile?.id)
                if showActivities {
                    Divider()
                    ActivityView(workspace: workspace).frame(height: 170)
                }
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
            ToolbarItem { Button("断开", systemImage: "eject") { workspace.disconnect() }.disabled(workspace.client == nil) }
        }
        .searchable(text: $query, prompt: "筛选当前目录")
        .sheet(isPresented: $showConnect) { ConnectionView(workspace: workspace) }
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
        .onAppear { workspace.reloadProfiles() }
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
    @State private var sortOrder = [KeyPathComparator(\FileEntry.name, comparator: .localizedStandard)]
    var filtered: [FileEntry] {
        files.filter { (workspace.showHidden || !$0.name.hasPrefix(".")) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }.sorted(using: sortOrder)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: remote ? "network" : "internaldrive")
                Text(title).fontWeight(.semibold)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button("上一级", systemImage: "arrow.up") { workspace.parent(remote: remote) }.labelStyle(.iconOnly)
                Button("新建文件夹", systemImage: "folder.badge.plus") { workspace.createFolder(remote: remote) }.labelStyle(.iconOnly)
                if !remote { Button("选择文件夹", systemImage: "folder") { workspace.chooseLocal() }.labelStyle(.iconOnly) }
            }.padding(12)
            TextField("路径", text: $path).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                .onSubmit { if remote { workspace.refreshRemote() } else { workspace.refreshLocal() } }
                .padding(.horizontal, 12).padding(.bottom, 10)
            Table(filtered, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("名称", value: \.name) { entry in
                    Label { Text(entry.name) } icon: {
                        Image(systemName: entry.isDirectory ? "folder.fill" : "doc").foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                    }
                        .modifier(LocalFileDrag(url: remote ? nil : URL(fileURLWithPath: entry.path)))
                        .onTapGesture(count: 2) { workspace.open(entry, remote: remote) }
                }.width(min: 140, ideal: 240)
                TableColumn("大小", value: \.size) { entry in
                    Text(entry.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                        .foregroundStyle(.secondary).monospacedDigit()
                }.width(80)
                TableColumn("修改日期", value: \.modifiedSortValue) { entry in
                    Text(entry.modified?.formatted(date: .numeric, time: .shortened) ?? "—").foregroundStyle(.secondary)
                }.width(min: 100, ideal: 150)
            }
            .disabled(loading)
            .contextMenu(forSelectionType: String.self) { ids in
                if let entry = files.first(where: { ids.contains($0.id) }) {
                    Button(entry.isDirectory ? "打开" : (remote ? "下载" : "打开")) { workspace.open(entry, remote: remote) }
                    if !remote { Button("上传") { workspace.upload(files.filter { ids.contains($0.id) }) }.disabled(workspace.client == nil) }
                    Button("重命名…") { workspace.rename(entry, remote: remote) }
                    Button("删除…", role: .destructive) { workspace.delete(entry, remote: remote) }
                }
            } primaryAction: { ids in
                if let entry = files.first(where: { ids.contains($0.id) }) { workspace.open(entry, remote: remote) }
            }
            .overlay { if filtered.isEmpty && !loading { ContentUnavailableView("没有文件", systemImage: "folder", description: Text(query.isEmpty ? "此目录为空。" : "没有匹配的项目。")) } }
        }.frame(minWidth: 350, maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            guard remote, workspace.client != nil, urls.allSatisfy(\.isFileURL) else { return false }
            workspace.uploadURLs(urls); return true
        }
    }
}

private struct LocalFileDrag: ViewModifier {
    let url: URL?
    @ViewBuilder func body(content: Content) -> some View {
        if let url { content.draggable(url) } else { content }
    }
}

struct ActivityView: View {
    @ObservedObject var workspace: Workspace
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text("传输活动").font(.headline); Spacer(); Text("\(workspace.activities.filter { $0.state == "传输中" }.count) 个进行中").foregroundStyle(.secondary) }.padding(.horizontal, 14).padding(.top, 10)
            if workspace.activities.isEmpty {
                Text("上传或下载文件后，在这里查看进度。").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(workspace.activities) { item in
                    HStack {
                        Image(systemName: item.direction == "上传" ? "arrow.up.circle" : "arrow.down.circle")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name).lineLimit(1)
                            if item.state == "传输中" { ProgressView(value: item.progress).frame(maxWidth: 220) }
                            if let error = item.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
                        }
                        Spacer()
                        Text(item.state).foregroundStyle(item.state == "失败" ? .red : .secondary)
                        if item.state == "传输中" || item.state == "等待中" { Button("取消", systemImage: "xmark.circle") { workspace.cancel(item.id) }.labelStyle(.iconOnly).buttonStyle(.borderless) }
                        if item.state == "失败" || item.state == "已取消" { Button("重试", systemImage: "arrow.clockwise") { workspace.retry(item.id) }.labelStyle(.iconOnly).buttonStyle(.borderless) }
                    }
                }.listStyle(.plain)
            }
        }
    }
}

struct ConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var workspace: Workspace
    @State private var profile = ServerProfile()
    @State private var password = ""
    @State private var passphrase = ""
    @State private var remember = false
    @State private var save = true
    @State private var error: String?
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("连接服务器") {
                    TextField("名称", text: $profile.name)
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
                    Toggle("保存服务器收藏", isOn: $save)
                    Toggle("将密码 / 口令保存到钥匙串", isOn: $remember)
                    if profile.protocolKind == .ftp { Text("FTP 会以明文传输认证和文件内容。建议优先选择 SFTP 或 FTPS。").font(.caption).foregroundStyle(.secondary) }
                    if let error { Text(error).foregroundStyle(.red) }
                }
            }.formStyle(.grouped)
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("连接") {
                    do {
                        let credentials = Credentials(password: password, passphrase: passphrase)
                        try profile.validate()
                        if save { try workspace.save(profile, credentials: credentials, remember: remember) }
                        workspace.connect(profile, credentials: credentials); dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
            }.padding(20)
        }.frame(width: 540, height: 600)
        .onChange(of: profile.protocolKind) { _, kind in profile.port = kind.defaultPort }
    }
}
