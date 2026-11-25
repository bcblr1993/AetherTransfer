import SwiftUI
import AppKit
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

// MARK: - Disconnected State View
struct DisconnectedStateView: View {
    @Binding var showConnect: Bool
    var onDropWithoutConnection: () -> Void = {}

    var body: some View {
        ContentUnavailableView {
            Label(L10n.tr("连接远程服务器", "Connect to Remote Server"), systemImage: "externaldrive.connected.to.line.below")
        } description: {
            Text(L10n.tr("连接到 SFTP / FTP / FTPS 服务器以开始双栏文件浏览与极速传输。",
                         "Connect to an SFTP, FTP, or FTPS server for dual-pane browsing and high-speed file transfers."))
        } actions: {
            Button(L10n.tr("快速连接…", "Quick Connect…"), systemImage: "bolt.fill") {
                showConnect = true
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
        .frame(minWidth: 350, maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.01))
        .dropDestination(for: DroppedItem.self) { _, _ in
            onDropWithoutConnection()
            return false
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

// MARK: - Connection View (Add / Edit Bookmark)
struct ConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var workspace: Workspace
    let isEditing: Bool
    @State private var profile: ServerProfile
    @State private var password: String
    @State private var passphrase: String
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
            self._remember = State(initialValue: true)
            self._save = State(initialValue: true)
        } else {
            self.isEditing = false
            self._profile = State(initialValue: ServerProfile())
            self._password = State(initialValue: "")
            self._passphrase = State(initialValue: "")
            self._remember = State(initialValue: true)
            self._save = State(initialValue: true)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(isEditing ? L10n.tr("编辑服务器书签", "Edit Server Bookmark") : L10n.tr("服务器设置", "Server Settings")) {
                    TextField(L10n.tr("书签名称", "Bookmark Name"), text: $profile.name, prompt: Text(L10n.tr("例如：生产环境 Web 服务器", "e.g. Production Web Server")))
                    TextField(L10n.tr("分组", "Group"), text: $profile.group, prompt: Text(L10n.tr("例如：项目 A、客户…", "e.g. Project A, Clients…")))

                    Picker(L10n.tr("传输协议", "Protocol"), selection: $profile.protocolKind) {
                        ForEach(TransferProtocol.allCases, id: \.self) { Text($0.title).tag($0) }
                    }

                    if profile.protocolKind == .s3 {
                        TextField(L10n.tr("S3 Bucket 名称", "S3 Bucket Name"), text: $profile.s3Bucket, prompt: Text("my-production-bucket"))
                        TextField(L10n.tr("AWS Region 区域", "AWS Region"), text: $profile.s3Region, prompt: Text("us-east-1 / auto"))
                        TextField(L10n.tr("Endpoint 终端节点", "Custom Endpoint (Optional)"), text: $profile.host, prompt: Text(L10n.tr("留空默认 AWS S3，或填 R2 / MinIO 域名", "s3.amazonaws.com or <id>.r2.cloudflarestorage.com")))
                        TextField(L10n.tr("Access Key ID", "Access Key ID"), text: $profile.username)
                        SecureField(L10n.tr("Secret Access Key", "Secret Access Key"), text: $password)
                        Toggle(L10n.tr("使用 Path-Style 路径寻址 (MinIO / 私有云对象存储)", "Use Path-Style Addressing (MinIO / Self-hosted S3)"), isOn: $profile.s3PathStyle)
                        TextField(L10n.tr("初始前缀路径", "Initial Prefix Path"), text: $profile.initialPath)
                    } else {
                        TextField(L10n.tr("服务器地址 (Host)", "Host"), text: $profile.host)
                        TextField(L10n.tr("端口号", "Port"), value: $profile.port, format: .number.grouping(.never))
                        TextField(L10n.tr("用户名", "Username"), text: $profile.username)
                        SecureField(L10n.tr("登录密码", "Password"), text: $password)
                        TextField(L10n.tr("初始远程路径", "Initial Remote Path"), text: $profile.initialPath)
                    }

                    if profile.protocolKind == .sftp {
                        Toggle(L10n.tr("优先使用 macOS SSH Agent 免密认证", "Use macOS SSH Agent Authentication"), isOn: $profile.useSSHAgent)

                        HStack {
                            TextField(L10n.tr("SSH 私钥文件", "SSH Private Key"), text: $profile.privateKeyPath)
                            Button(L10n.tr("选择…", "Choose…")) {
                                let panel = NSOpenPanel()
                                panel.showsHiddenFiles = true
                                if panel.runModal() == .OK { profile.privateKeyPath = panel.url?.path ?? "" }
                            }
                            Button(L10n.tr("密钥管理…", "Keys…")) {
                                workspace.showSSHKeyManager = true
                            }
                        }
                        SecureField(L10n.tr("私钥解密口令 (Passphrase)", "Private Key Passphrase"), text: $passphrase)
                    }
                }

                Section {
                    Toggle(L10n.tr("保存到书签列表", "Save to Bookmarks"), isOn: $save)
                    Toggle(L10n.tr("将凭据保存到系统钥匙串 (Keychain)", "Save credentials in macOS Keychain"), isOn: $remember)

                    if profile.protocolKind == .ftp {
                        Text(L10n.tr("提示：FTP 会以明文传输凭据和文件内容。生产环境推荐选择 SFTP 或 FTPS。",
                                     "Note: FTP transmits credentials and data in cleartext. Prefer SFTP or FTPS for production."))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

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
                            let credentials = Credentials(password: password, passphrase: passphrase)
                            try workspace.save(profile, credentials: credentials, remember: remember)
                            workspace.editingProfile = nil
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }

                Button(isEditing ? L10n.tr("保存并连接", "Save & Connect") : L10n.tr("连接", "Connect")) {
                    do {
                        let credentials = Credentials(password: password, passphrase: passphrase)
                        try profile.validate()
                        if save { try workspace.save(profile, credentials: credentials, remember: remember) }
                        workspace.editingProfile = nil
                        workspace.connect(profile, credentials: credentials)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 550, height: 620)
        .onChange(of: profile.protocolKind) { _, kind in
            if !isEditing {
                profile.port = kind.defaultPort
            }
        }
    }
}
