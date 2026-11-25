import AppKit
import SwiftUI
import UniformTypeIdentifiers
import AetherTransferCore

struct ProtocolBadge: View {
    let protocolKind: TransferProtocol

    var badgeColor: Color {
        switch protocolKind {
        case .sftp: return .blue
        case .ftps, .ftpsExplicit: return .green
        case .ftp: return .orange
        case .webdav, .webdavs: return .purple
        case .s3: return .pink
        case .b2: return .red
        case .azureBlob: return .cyan
        case .openstackSwift: return .indigo
        }
    }

    var body: some View {
        Text(protocolKind.title)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(badgeColor.opacity(0.15))
            .foregroundStyle(badgeColor)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Disconnected State View (Compatible Entry Point for BrowserPaneViews)

struct DisconnectedStateView: View {
    @Binding var showConnect: Bool
    var workspace: Workspace?
    var onDropWithoutConnection: () -> Void = {}

    // Wave 3 Integrator: pass `workspace: workspace` in BrowserPaneViews.swift -> DisconnectedStateView(showConnect: $showConnect, workspace: workspace)
    init(
        showConnect: Binding<Bool>,
        workspace: Workspace? = nil,
        onDropWithoutConnection: @escaping () -> Void = {}
    ) {
        self._showConnect = showConnect
        self.workspace = workspace
        self.onDropWithoutConnection = onDropWithoutConnection
    }

    var body: some View {
        ServersLaunchpadView(
            workspace: workspace,
            showConnect: $showConnect,
            onDropWithoutConnection: onDropWithoutConnection
        )
    }
}

// MARK: - Transmit 5 Servers Launchpad & Quick Connect

private enum LaunchpadSegment: String, CaseIterable, Identifiable {
    case favorites
    case quickConnect

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .favorites: return L10n.tr("收藏服务器", "Favorites")
        case .quickConnect: return L10n.tr("快速连接", "Quick Connect")
        }
    }
}

struct ServersLaunchpadView: View {
    var workspace: Workspace?
    @Binding var showConnect: Bool
    var onDropWithoutConnection: () -> Void = {}

    @State private var activeTab: LaunchpadSegment = .favorites
    @State private var searchText = ""
    @State private var selectedTag: ServerColorTag?
    @State private var fallbackProfiles: [ServerProfile] = []

    // Quick Connect state
    @State private var qcProfile = ServerProfile()
    @State private var qcPassword = ""
    @State private var qcPassphrase = ""
    @State private var qcSessionToken = ""
    @State private var qcSaveToBookmarks = false
    @State private var qcRememberCredentials = true
    @State private var qcError: String?

    private var allProfiles: [ServerProfile] {
        workspace?.profiles ?? fallbackProfiles
    }

    private var filteredProfiles: [ServerProfile] {
        allProfiles.filter { profile in
            let matchesSearch = LaunchpadInspectorHelpers.matchesSearch(profile, query: searchText)
            let matchesTag: Bool
            if let selectedTag {
                matchesTag = ServerColorTag(tagString: profile.colorTag) == selectedTag
            } else {
                matchesTag = true
            }
            return matchesSearch && matchesTag
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            launchpadHeader
            Divider()

            if activeTab == .favorites {
                favoritesBody
            } else {
                quickConnectBody
            }
        }
        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.01))
        .task {
            if workspace == nil {
                fallbackProfiles = (try? ProfileStore().load()) ?? []
            }
        }
        .onChange(of: qcProfile.protocolKind) { _, newKind in
            qcProfile.port = newKind.defaultPort
        }
        .dropDestination(for: DroppedItem.self) { _, _ in
            onDropWithoutConnection()
            return false
        }
    }

    private var launchpadHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .foregroundStyle(Color.accentColor)
            Text(L10n.tr("服务器启动台", "Servers"))
                .fontWeight(.semibold)

            Spacer()

            Picker("", selection: $activeTab) {
                ForEach(LaunchpadSegment.allCases) { tab in
                    Text(tab.localizedTitle).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 210)

            Spacer()

            if let workspace {
                Button {
                    workspace.showSSHKeyManager = true
                } label: {
                    Image(systemName: "key.horizontal")
                }
                .buttonStyle(.borderless)
                .help(L10n.tr("SSH 密钥管理器…", "SSH Key Manager…"))
            }

            Button {
                workspace?.editingProfile = nil
                showConnect = true
            } label: {
                Label(L10n.tr("新建书签", "New Bookmark"), systemImage: "plus")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(L10n.tr("添加新服务器书签…", "Add New Server Bookmark…"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    // MARK: - Favorites Tab
    private var favoritesBody: some View {
        VStack(spacing: 0) {
            favoritesFilterBar
            Divider()

            if filteredProfiles.isEmpty {
                favoritesEmptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        let groups = ServerProfile.grouped(filteredProfiles)
                        ForEach(groups) { group in
                            let displayGroup = group.groupName == "未分组"
                                ? L10n.tr("未分组", "Ungrouped")
                                : group.groupName

                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 6) {
                                    Text(displayGroup)
                                        .font(.caption.bold())
                                        .foregroundStyle(.secondary)
                                    Text("\(group.profiles.count)")
                                        .font(.caption2.monospacedDigit())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(Color.primary.opacity(0.06))
                                        .clipShape(Capsule())
                                        .foregroundStyle(.secondary)
                                }

                                LazyVGrid(
                                    columns: [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 12)],
                                    spacing: 12
                                ) {
                                    ForEach(group.profiles) { profile in
                                        LaunchpadServerCard(
                                            profile: profile,
                                            onConnect: { connectBookmark(profile) },
                                            onEdit: { editBookmark(profile) },
                                            onDuplicate: { duplicateBookmark(profile) },
                                            onSaveAsDroplet: { exportDroplet(profile) },
                                            onDelete: { deleteBookmark(profile) }
                                        )
                                    }
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    private var favoritesFilterBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    TextField(
                        L10n.tr("搜索书签名称、主机、桶名或站点 URL…", "Search bookmarks, host, bucket, or site URL…"),
                        text: $searchText
                    )
                    .textFieldStyle(.plain)
                    .font(.callout)

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    colorFilterChip(tag: nil, title: L10n.tr("全部", "All"), color: nil)
                    ForEach(ServerColorTag.allCases.filter { $0 != .none }) { tag in
                        colorFilterChip(tag: tag, title: tag.localizedTitle, color: tag.color)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.015))
    }

    private func colorFilterChip(tag: ServerColorTag?, title: String, color: Color?) -> some View {
        let isSelected = selectedTag == tag
        return Button {
            selectedTag = (isSelected && tag != nil) ? nil : tag
        } label: {
            HStack(spacing: 5) {
                if let color {
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                }
                Text(title)
                    .font(.caption2.weight(isSelected ? .semibold : .regular))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
            )
            .overlay(
                Capsule().strokeBorder(isSelected ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: 1)
            )
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var favoritesEmptyState: some View {
        if allProfiles.isEmpty {
            ContentUnavailableView {
                Label(L10n.tr("还没有收藏服务器", "No Favorite Servers Yet"), systemImage: "externaldrive.connected.to.line.below")
            } description: {
                Text(L10n.tr("添加书签以保存连接信息、颜色标签与关联本地文件夹，或直接使用快速连接。",
                             "Save bookmarks with color tags and linked local folders, or use Quick Connect."))
            } actions: {
                HStack(spacing: 10) {
                    Button(L10n.tr("快速连接", "Quick Connect")) {
                        activeTab = .quickConnect
                    }
                    Button(L10n.tr("添加书签…", "Add Bookmark…")) {
                        workspace?.editingProfile = nil
                        showConnect = true
                    }
                    .buttonStyle(.glassProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label(L10n.tr("没有匹配的服务器", "No Matching Servers"), systemImage: "magnifyingglass")
            } description: {
                Text(L10n.tr("尝试调整搜索关键词或清除颜色标签筛选。", "Try adjusting your search or clearing the color tag filter."))
            } actions: {
                Button(L10n.tr("清除筛选", "Clear Filters")) {
                    searchText = ""
                    selectedTag = nil
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Quick Connect Tab
    private var quickConnectBody: some View {
        VStack(spacing: 0) {
            Form {
                Section(L10n.tr("即时连接 (支持全部 10 种协议)", "Quick Connect (All 10 Protocols)")) {
                    ProtocolConnectionFieldsView(
                        profile: $qcProfile,
                        password: $qcPassword,
                        passphrase: $qcPassphrase,
                        sessionToken: $qcSessionToken,
                        onOpenKeyManager: workspace.map { ws in { ws.showSSHKeyManager = true } }
                    )
                }

                Section(L10n.tr("可选保存设置", "Bookmark Options")) {
                    Toggle(L10n.tr("连接时保存到收藏书签", "Save to Bookmarks"), isOn: $qcSaveToBookmarks)
                    if qcSaveToBookmarks {
                        TextField(
                            L10n.tr("书签名称", "Bookmark Name"),
                            text: $qcProfile.name,
                            prompt: Text(L10n.tr("留空则使用主机名", "Defaults to host if empty"))
                        )
                        TextField(
                            L10n.tr("分组", "Group"),
                            text: $qcProfile.group,
                            prompt: Text(L10n.tr("例如：生产环境", "e.g. Production"))
                        )
                        Toggle(
                            L10n.tr("将凭据保存到系统钥匙串 (Keychain)", "Save credentials in macOS Keychain"),
                            isOn: $qcRememberCredentials
                        )
                    }
                }

                if let qcError {
                    Section {
                        Text(qcError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button(L10n.tr("重置表单", "Reset")) {
                    qcProfile = ServerProfile()
                    qcPassword = ""
                    qcPassphrase = ""
                    qcSessionToken = ""
                    qcError = nil
                }

                Spacer()

                Button(L10n.tr("高级书签弹窗…", "Full Bookmark Editor…")) {
                    workspace?.editingProfile = nil
                    showConnect = true
                }

                Button(L10n.tr("立即连接", "Connect")) {
                    connectQuickForm()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
            .background(.ultraThinMaterial)
        }
    }

    // MARK: - Actions
    private func connectBookmark(_ profile: ServerProfile) {
        if let workspace {
            workspace.connectSavedApplyingFolderLink(profile)
        } else {
            showConnect = true
        }
    }

    private func editBookmark(_ profile: ServerProfile) {
        workspace?.editingProfile = profile
        showConnect = true
    }

    private func duplicateBookmark(_ profile: ServerProfile) {
        workspace?.duplicateProfile(profile)
    }

    private func exportDroplet(_ profile: ServerProfile) {
        if let workspace {
            workspace.saveBookmarkAsDroplet(profile)
        } else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(profile.name.isEmpty ? profile.host : profile.name) Droplet.app"
            panel.allowedContentTypes = [.applicationBundle]
            if panel.runModal() == .OK, let url = panel.url {
                try? LaunchpadInspectorHelpers.exportDropletBundle(
                    for: profile,
                    remotePath: profile.initialPath,
                    destinationAppURL: url
                )
            }
        }
    }

    private func deleteBookmark(_ profile: ServerProfile) {
        workspace?.deleteProfile(profile)
    }

    private func connectQuickForm() {
        qcError = nil
        do {
            var targetProfile = qcProfile
            targetProfile.id = UUID()
            try targetProfile.validate()
            let creds = Credentials(
                password: qcPassword,
                passphrase: qcPassphrase,
                sessionToken: qcSessionToken
            )
            if let workspace {
                if qcSaveToBookmarks {
                    if targetProfile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        targetProfile.name = LaunchpadInspectorHelpers.endpointSummary(for: targetProfile)
                    }
                    try workspace.save(targetProfile, credentials: creds, remember: qcRememberCredentials)
                }
                workspace.connectApplyingFolderLink(targetProfile, credentials: creds)
            } else {
                showConnect = true
            }
        } catch {
            qcError = error.localizedDescription
        }
    }
}

// MARK: - Launchpad Server Card

private struct LaunchpadServerCard: View {
    let profile: ServerProfile
    let onConnect: () -> Void
    let onEdit: () -> Void
    let onDuplicate: () -> Void
    let onSaveAsDroplet: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    private var tagColor: Color? {
        ServerColorTag(tagString: profile.colorTag).color
    }

    private var displayTitle: String {
        let trimmedName = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty { return trimmedName }
        let trimmedHost = profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedHost.isEmpty { return trimmedHost }
        return LaunchpadInspectorHelpers.endpointSummary(for: profile)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                if let tagColor {
                    Circle()
                        .fill(tagColor)
                        .frame(width: 9, height: 9)
                } else {
                    Image(systemName: "server.rack")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(displayTitle)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                ProtocolBadge(protocolKind: profile.protocolKind)
            }

            Text(LaunchpadInspectorHelpers.endpointSummary(for: profile))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(spacing: 6) {
                if !profile.defaultLocalPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let folderName = URL(fileURLWithPath: profile.defaultLocalPath).lastPathComponent
                    Label(folderName.isEmpty ? profile.defaultLocalPath : folderName, systemImage: "folder.fill")
                        .font(.caption2)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(Capsule())
                        .foregroundStyle(.secondary)
                        .help(L10n.tr("关联本地目录: \(profile.defaultLocalPath)", "Linked Local Folder: \(profile.defaultLocalPath)"))
                }

                if !profile.siteURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let siteLabel = URL(string: profile.siteURL)?.host ?? profile.siteURL
                    Label(siteLabel, systemImage: "globe")
                        .font(.caption2)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.1))
                        .clipShape(Capsule())
                        .foregroundStyle(Color.accentColor)
                        .help(profile.siteURL)
                }

                Spacer(minLength: 0)

                if (profile.trustedHostKey ?? "").isEmpty == false {
                    Image(systemName: "lock.shield.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .help(L10n.tr("已保存主机公钥指纹", "Trusted host key fingerprint stored"))
                }

                Button(L10n.tr("连接", "Connect")) {
                    onConnect()
                }
                .buttonStyle(.glassProminent)
                .controlSize(.mini)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isHovering ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.08),
                    lineWidth: 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture(count: 2) {
            onConnect()
        }
        .contextMenu {
            Button(L10n.tr("连接", "Connect")) { onConnect() }
            Button(L10n.tr("编辑书签…", "Edit Bookmark…")) { onEdit() }
            Button(L10n.tr("创建副本", "Duplicate")) { onDuplicate() }
            Button(L10n.tr("存储为 Droplet…", "Save as Droplet…")) { onSaveAsDroplet() }
            Divider()
            Button(L10n.tr("删除", "Delete"), role: .destructive) { onDelete() }
        }
    }
}

// MARK: - Shared Protocol Fields Form Section (Used by Quick Connect & Bookmark Editor)

private struct ProtocolConnectionFieldsView: View {
    @Binding var profile: ServerProfile
    @Binding var password: String
    @Binding var passphrase: String
    @Binding var sessionToken: String
    var onOpenKeyManager: (() -> Void)?

    private static let s3StorageClasses = [
        "STANDARD",
        "STANDARD_IA",
        "ONEZONE_IA",
        "INTELLIGENT_TIERING",
        "GLACIER",
        "DEEP_ARCHIVE",
        "REDUCED_REDUNDANCY"
    ]

    var body: some View {
        Picker(L10n.tr("传输协议", "Protocol"), selection: $profile.protocolKind) {
            ForEach(TransferProtocol.allCases, id: \.self) { kind in
                Text(kind.title).tag(kind)
            }
        }

        switch profile.protocolKind {
        case .s3:
            TextField(L10n.tr("S3 Bucket 名称", "S3 Bucket Name"), text: $profile.s3Bucket, prompt: Text("my-production-bucket"))
            TextField(L10n.tr("AWS Region 区域", "AWS Region"), text: $profile.s3Region, prompt: Text("us-east-1 / auto"))
            TextField(L10n.tr("Endpoint 终端节点", "Custom Endpoint (Optional)"), text: $profile.host, prompt: Text(L10n.tr("留空默认 AWS S3，或填 R2 / MinIO 域名", "s3.amazonaws.com or <id>.r2.cloudflarestorage.com")))
            TextField(L10n.tr("端口号", "Port"), value: $profile.port, format: .number.grouping(.never))
            TextField(L10n.tr("Access Key ID", "Access Key ID"), text: $profile.username)
            SecureField(L10n.tr("Secret Access Key", "Secret Access Key"), text: $password)
            Toggle(L10n.tr("使用 Path-Style 路径寻址 (MinIO / 私有云)", "Use Path-Style Addressing (MinIO / Self-hosted)"), isOn: $profile.s3PathStyle)

            Picker(L10n.tr("默认存储类型 (Storage Class)", "Storage Class"), selection: $profile.s3StorageClass) {
                ForEach(Self.s3StorageClasses, id: \.self) { cls in
                    Text(cls).tag(cls)
                }
            }

            Toggle(L10n.tr("使用临时 STS Session Token", "Use STS Session Token"), isOn: $profile.s3UseSessionToken)
            if profile.s3UseSessionToken {
                SecureField(L10n.tr("Session Token (存入钥匙串)", "Session Token (Keychain)"), text: $sessionToken)
            }

            TextField(L10n.tr("初始前缀路径", "Initial Prefix Path"), text: $profile.initialPath)

        case .b2:
            TextField(L10n.tr("B2 Bucket 名称", "Bucket Name"), text: $profile.b2BucketName, prompt: Text("my-b2-bucket"))
            TextField(L10n.tr("Bucket ID (可选)", "Bucket ID (Optional)"), text: $profile.b2BucketId, prompt: Text("4a48fe8875c6214145260818"))
            TextField(L10n.tr("自定义 Endpoint (可选)", "Custom Endpoint (Optional)"), text: $profile.host, prompt: Text("api.backblazeb2.com"))
            TextField(L10n.tr("端口号", "Port"), value: $profile.port, format: .number.grouping(.never))
            TextField(L10n.tr("Key ID", "Key ID"), text: $profile.username)
            SecureField(L10n.tr("Application Key", "Application Key"), text: $password)
            TextField(L10n.tr("初始前缀路径", "Initial Prefix Path"), text: $profile.initialPath)

        case .azureBlob:
            TextField(L10n.tr("存储账户名 (Account Name)", "Account Name"), text: $profile.azureAccountName, prompt: Text("mystorageaccount"))
            TextField(L10n.tr("容器名 (Container)", "Container"), text: $profile.azureContainer, prompt: Text("assets"))
            TextField(L10n.tr("自定义 Endpoint (可选)", "Custom Endpoint (Optional)"), text: $profile.host, prompt: Text("<account>.blob.core.windows.net"))
            TextField(L10n.tr("端口号", "Port"), value: $profile.port, format: .number.grouping(.never))
            Toggle(L10n.tr("使用 SAS 令牌认证 (Shared Access Signature)", "Use SAS Token Authentication"), isOn: $profile.azureUseSAS)

            if profile.azureUseSAS {
                SecureField(L10n.tr("SAS Token (存入钥匙串)", "SAS Token (Keychain)"), text: $sessionToken)
            } else {
                SecureField(L10n.tr("Account Key (存入钥匙串)", "Account Key (Keychain)"), text: $password)
            }
            TextField(L10n.tr("初始前缀路径", "Initial Prefix Path"), text: $profile.initialPath)

        case .openstackSwift:
            TextField(L10n.tr("认证 URL (Auth URL)", "Auth URL"), text: $profile.swiftAuthURL, prompt: Text("https://identity.example.com/v3/auth/tokens"))
            TextField(L10n.tr("容器名 (Container)", "Container"), text: $profile.swiftContainer, prompt: Text("my-container"))
            TextField(L10n.tr("租户 / 项目 (Tenant / Project)", "Tenant / Project"), text: $profile.swiftTenantOrProject, prompt: Text("prod-project"))
            TextField(L10n.tr("用户名", "Username"), text: $profile.username)
            SecureField(L10n.tr("API Key / 密码", "API Key / Password"), text: $password)
            TextField(L10n.tr("自定义主机 (可选)", "Custom Host (Optional)"), text: $profile.host, prompt: Text(L10n.tr("留空则从 Auth URL 解析", "Derived from Auth URL if empty")))
            TextField(L10n.tr("端口号", "Port"), value: $profile.port, format: .number.grouping(.never))
            TextField(L10n.tr("初始前缀路径", "Initial Prefix Path"), text: $profile.initialPath)

        case .sftp, .ftp, .ftps, .ftpsExplicit, .webdav, .webdavs:
            TextField(L10n.tr("服务器地址 (Host)", "Host"), text: $profile.host)
            TextField(L10n.tr("端口号", "Port"), value: $profile.port, format: .number.grouping(.never))
            TextField(L10n.tr("用户名", "Username"), text: $profile.username)
            SecureField(L10n.tr("登录密码", "Password"), text: $password)
            TextField(L10n.tr("初始远程路径", "Initial Remote Path"), text: $profile.initialPath)

            if profile.protocolKind == .sftp {
                Toggle(L10n.tr("优先使用 macOS SSH Agent 免密认证", "Use macOS SSH Agent Authentication"), isOn: $profile.useSSHAgent)

                HStack {
                    TextField(L10n.tr("SSH 私钥文件", "SSH Private Key"), text: $profile.privateKeyPath)
                    Button(L10n.tr("选择…", "Choose…")) {
                        let panel = NSOpenPanel()
                        panel.showsHiddenFiles = true
                        if panel.runModal() == .OK {
                            profile.privateKeyPath = panel.url?.path ?? ""
                        }
                    }
                    if let onOpenKeyManager {
                        Button(L10n.tr("密钥管理…", "Keys…")) {
                            onOpenKeyManager()
                        }
                    }
                }
                SecureField(L10n.tr("私钥解密口令 (Passphrase)", "Private Key Passphrase"), text: $passphrase)
            } else if profile.protocolKind == .ftp {
                Text(L10n.tr("提示：FTP 会以明文传输凭据和文件内容。生产环境推荐选择 SFTP 或 FTPS。",
                             "Note: FTP transmits credentials and data in cleartext. Prefer SFTP or FTPS for production."))
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if profile.protocolKind == .ftpsExplicit {
                Text(L10n.tr("显式 TLS (AUTH TLS) 通过端口 21 协商加密传输，严格校验证书。",
                             "Explicit AUTH TLS upgrades port 21 with strict certificate verification."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Host Challenge Dialog

struct HostChallengeDialog: View {
    let challenge: Workspace.HostChallenge
    @ObservedObject var workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(L10n.tr("核对服务器安全指纹", "Verify Server Host Key Fingerprint"), systemImage: "lock.shield")
                .font(.title2.bold())

            Text(L10n.tr("首次连接至服务器「\(challenge.profile.host)」需要验证其公钥指纹。确认可信后才会建立加密会话：",
                         "First connection to \"\(challenge.profile.host)\". Verify its public key fingerprint before establishing an encrypted session:"))
                .font(.body)

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("SHA-256 指纹：", "SHA-256 Fingerprint:"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(RemoteClient.fingerprint(challenge.key))
                    .font(.system(.body, design: .monospaced))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05))
                    .cornerRadius(6)
                    .textSelection(.enabled)
            }

            HStack {
                Button(L10n.tr("取消", "Cancel")) {
                    workspace.hostChallenge = nil
                    workspace.disconnect()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(L10n.tr("信任并连接", "Trust & Connect")) {
                    workspace.approveHostKey()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 580)
    }
}

// MARK: - Password Prompt (saved bookmark without a stored password)

struct PasswordPromptSheet: View {
    let profile: ServerProfile
    @ObservedObject var workspace: Workspace
    @State private var password = ""
    @State private var remember = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(L10n.tr("输入密码", "Enter Password"), systemImage: "key.fill")
                .font(.title2.bold())
            Text(L10n.tr("钥匙串中没有「\(profile.username)@\(profile.host)」的密码。",
                         "No password for \"\(profile.username)@\(profile.host)\" is stored in Keychain."))
                .foregroundStyle(.secondary)
            SecureField(L10n.tr("登录密码", "Password"), text: $password)
                .textFieldStyle(.roundedBorder)
            Toggle(L10n.tr("将密码保存到系统钥匙串 (Keychain)", "Save password in macOS Keychain"), isOn: $remember)
            HStack {
                Button(L10n.tr("取消", "Cancel")) { workspace.passwordPrompt = nil }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.tr("连接", "Connect")) {
                    let localTarget = profile.defaultLocalPath.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !localTarget.isEmpty {
                        var isDir: ObjCBool = false
                        if FileManager.default.fileExists(atPath: localTarget, isDirectory: &isDir), isDir.boolValue {
                            workspace.navigateLocal(to: localTarget)
                        }
                    }
                    workspace.connectWithPromptedPassword(profile, password: password, remember: remember)
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

// MARK: - Connection View (Full Bookmark Editor)

struct ConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var workspace: Workspace
    let isEditing: Bool
    @State private var profile: ServerProfile
    @State private var password: String
    @State private var passphrase: String
    @State private var sessionToken: String
    @State private var remember: Bool
    @State private var save: Bool
    @State private var error: String?

    init(workspace: Workspace, existingProfile: ServerProfile? = nil) {
        self.workspace = workspace
        if let existing = existingProfile {
            self.isEditing = true
            self._profile = State(initialValue: existing)
            let creds = workspace.loadCredentials(for: existing)
            self._password = State(initialValue: creds.password)
            self._passphrase = State(initialValue: creds.passphrase)
            self._sessionToken = State(initialValue: creds.sessionToken)
            self._remember = State(initialValue: true)
            self._save = State(initialValue: true)
        } else {
            self.isEditing = false
            self._profile = State(initialValue: ServerProfile())
            self._password = State(initialValue: "")
            self._passphrase = State(initialValue: "")
            self._sessionToken = State(initialValue: "")
            self._remember = State(initialValue: true)
            self._save = State(initialValue: true)
        }
    }

    private var selectedColorTagBinding: Binding<ServerColorTag> {
        Binding(
            get: { ServerColorTag(tagString: profile.colorTag) },
            set: { profile.colorTag = $0.rawValue }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(isEditing ? L10n.tr("编辑服务器书签", "Edit Server Bookmark") : L10n.tr("服务器设置", "Server Settings")) {
                    TextField(L10n.tr("书签名称", "Bookmark Name"), text: $profile.name, prompt: Text(L10n.tr("例如：生产环境 Web 服务器", "e.g. Production Web Server")))
                    TextField(L10n.tr("分组", "Group"), text: $profile.group, prompt: Text(L10n.tr("例如：项目 A、客户…", "e.g. Project A, Clients…")))

                    ProtocolConnectionFieldsView(
                        profile: $profile,
                        password: $password,
                        passphrase: $passphrase,
                        sessionToken: $sessionToken,
                        onOpenKeyManager: { workspace.showSSHKeyManager = true }
                    )
                }

                Section(L10n.tr("文件夹关联与站点元数据", "Folder Linking & Metadata")) {
                    HStack {
                        TextField(
                            L10n.tr("默认本地文件夹", "Default Local Folder"),
                            text: $profile.defaultLocalPath,
                            prompt: Text(L10n.tr("连接后自动切换本地面板路径", "Optional local folder to open on connect"))
                        )
                        Button(L10n.tr("选择…", "Choose…")) {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK, let url = panel.url {
                                profile.defaultLocalPath = url.path
                            }
                        }
                    }

                    TextField(
                        L10n.tr("站点 / 公开 Web URL", "Site / Public Web URL"),
                        text: $profile.siteURL,
                        prompt: Text("https://cdn.example.com")
                    )

                    Picker(L10n.tr("颜色标签", "Color Tag"), selection: selectedColorTagBinding) {
                        ForEach(ServerColorTag.allCases) { tag in
                            HStack(spacing: 6) {
                                if let dotColor = tag.color {
                                    Circle()
                                        .fill(dotColor)
                                        .frame(width: 10, height: 10)
                                }
                                Text(tag.localizedTitle)
                            }
                            .tag(tag)
                        }
                    }

                    Toggle(
                        L10n.tr("下载时保留服务器文件修改日期", "Preserve Modification Dates"),
                        isOn: $profile.preserveModificationDate
                    )
                }

                Section {
                    Toggle(L10n.tr("保存到书签列表", "Save to Bookmarks"), isOn: $save)
                    Toggle(L10n.tr("将凭据保存到系统钥匙串 (Keychain)", "Save credentials in macOS Keychain"), isOn: $remember)

                    if let error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button(L10n.tr("取消", "Cancel")) {
                    workspace.editingProfile = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if isEditing {
                    Button(L10n.tr("仅保存修改", "Save Only")) {
                        do {
                            let credentials = currentCredentials()
                            try workspace.save(profile, credentials: credentials, remember: remember)
                            workspace.editingProfile = nil
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                }

                Button(isEditing ? L10n.tr("保存并连接", "Save & Connect") : L10n.tr("连接", "Connect")) {
                    do {
                        let credentials = currentCredentials()
                        try profile.validate()
                        if save {
                            try workspace.save(profile, credentials: credentials, remember: remember)
                        }
                        workspace.editingProfile = nil
                        workspace.connectApplyingFolderLink(profile, credentials: credentials)
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 590, height: 680)
        .onChange(of: profile.protocolKind) { oldKind, newKind in
            if !isEditing || profile.port == oldKind.defaultPort {
                profile.port = newKind.defaultPort
            }
        }
    }

    private func currentCredentials() -> Credentials {
        Credentials(
            password: password,
            passphrase: passphrase,
            sessionToken: sessionToken
        )
    }
}
