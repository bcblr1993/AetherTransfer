import SwiftUI
import AppKit
import AetherTransferCore

// MARK: - File Inspector View
struct FileInspectorView: View {
    let entry: FileEntry?
    @ObservedObject var workspace: Workspace

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(L10n.tr("文件检查器", "File Inspector"))
                    .font(.headline)
                Spacer()
                Button {
                    workspace.showInspector = false
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            Divider()

            if let item = entry {
                ScrollView {
                    VStack(spacing: 14) {
                        Image(systemName: item.isDirectory ? "folder.fill" : "doc.text.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(item.isDirectory ? Color.accentColor : Color.secondary)
                            .padding(.top, 8)

                        Text(item.name)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)

                        Divider()

                        InspectorRow(title: L10n.tr("种类", "Kind"), value: item.localizedKindDescription)
                        InspectorRow(
                            title: L10n.tr("大小", "Size"),
                            value: item.isDirectory
                                ? "—"
                                : "\(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)) (\(item.size) \(L10n.tr("字节", "bytes")))"
                        )
                        if let date = item.modified {
                            InspectorRow(title: L10n.tr("修改时间", "Modified"), value: date.formatted(date: .abbreviated, time: .standard))
                        }
                        InspectorRow(title: L10n.tr("完整路径", "Full Path"), value: item.path)

                        if !item.permissions.isEmpty {
                            Divider()
                            PermissionsEditor(entry: item, workspace: workspace)
                        }
                    }
                    .padding(.horizontal, 14)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text(L10n.tr("选择一个文件以查看详细信息", "Select a file to inspect details"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct InspectorRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Permissions Editor
struct PermissionsEditor: View {
    let entry: FileEntry
    @ObservedObject var workspace: Workspace
    @State private var permissions: POSIXPermissions
    @State private var appliedNotice = false

    init(entry: FileEntry, workspace: Workspace) {
        self.entry = entry
        self.workspace = workspace
        self._permissions = State(initialValue: POSIXPermissions(fromModeString: entry.permissions))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.tr("权限设置 (POSIX)", "Permissions (POSIX)"))
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(permissions.octalString)
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06))
                    .cornerRadius(4)
            }

            VStack(spacing: 6) {
                permissionRow(title: L10n.tr("所有者", "Owner"), triad: $permissions.owner)
                permissionRow(title: L10n.tr("用户组", "Group"), triad: $permissions.group)
                permissionRow(title: L10n.tr("其他人", "Others"), triad: $permissions.others)
            }

            HStack {
                if appliedNotice {
                    Text(L10n.tr("已成功修改", "Applied"))
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
                Spacer()
                Button(L10n.tr("应用修改", "Apply")) {
                    let isRemote = workspace.remoteSelection.contains(entry.id)
                    workspace.applyPermissions(to: entry, permissions: permissions, remote: isRemote)
                    appliedNotice = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        appliedNotice = false
                    }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(8)
    }

    private func permissionRow(title: String, triad: Binding<PermissionTriad>) -> some View {
        HStack {
            Text(title)
                .font(.caption2)
                .frame(width: 50, alignment: .leading)
            Toggle(L10n.tr("读", "R"), isOn: triad.read).toggleStyle(.checkbox).font(.caption2)
            Toggle(L10n.tr("写", "W"), isOn: triad.write).toggleStyle(.checkbox).font(.caption2)
            Toggle(L10n.tr("执", "X"), isOn: triad.execute).toggleStyle(.checkbox).font(.caption2)
        }
    }
}

// MARK: - Batch Rename Sheet
struct BatchRenameSheet: View {
    @ObservedObject var workspace: Workspace
    let items: [FileEntry]
    let isRemote: Bool
    @Environment(\.dismiss) private var dismiss

    @State private var ruleType = 0
    @State private var findText = ""
    @State private var replaceText = ""
    @State private var prefixText = ""
    @State private var suffixText = ""
    @State private var seqFormat = "Item_{N}"
    @State private var seqStart = 1
    @State private var seqPadding = 2

    var currentRule: RenameRule {
        switch ruleType {
        case 0: return .replace(find: findText, replaceWith: replaceText)
        case 1: return .addPrefix(prefixText)
        case 2: return .addSuffix(suffixText)
        case 3: return .sequence(format: seqFormat, start: seqStart, padding: seqPadding)
        default: return .replace(find: "", replaceWith: "")
        }
    }

    var plan: [RenameItemPlan] {
        let renamer = BatchRenamer(rule: currentRule)
        return renamer.plan(for: items.map(\.name))
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Label(L10n.tr("批量重命名 \(items.count) 个项目", "Batch Rename \(items.count) Items"), systemImage: "pencil.and.list.clipboard")
                    .font(.headline)
                Spacer()
            }

            Picker(L10n.tr("规则类型", "Rule"), selection: $ruleType) {
                Text(L10n.tr("替换文本", "Replace Text")).tag(0)
                Text(L10n.tr("添加前缀", "Add Prefix")).tag(1)
                Text(L10n.tr("添加后缀", "Add Suffix")).tag(2)
                Text(L10n.tr("序列编号", "Sequence")).tag(3)
            }
            .pickerStyle(.segmented)

            VStack(spacing: 8) {
                if ruleType == 0 {
                    HStack {
                        TextField(L10n.tr("查找文本", "Find"), text: $findText)
                        TextField(L10n.tr("替换为", "Replace with"), text: $replaceText)
                    }
                } else if ruleType == 1 {
                    TextField(L10n.tr("输入前缀字符串", "Enter prefix"), text: $prefixText)
                } else if ruleType == 2 {
                    TextField(L10n.tr("输入后缀字符串", "Enter suffix"), text: $suffixText)
                } else {
                    HStack {
                        TextField(L10n.tr("格式 (如 Photo_{N})", "Format (e.g. Photo_{N})"), text: $seqFormat)
                        TextField(L10n.tr("起始", "Start"), value: $seqStart, format: .number)
                            .frame(width: 60)
                        TextField(L10n.tr("位数", "Digits"), value: $seqPadding, format: .number)
                            .frame(width: 50)
                    }
                }
            }
            .textFieldStyle(.roundedBorder)

            Text(L10n.tr("效果预览：", "Preview:"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            List(plan) { item in
                HStack {
                    Text(item.originalName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(item.newName)
                        .font(.caption.bold())
                        .foregroundStyle(item.hasError ? .red : .primary)
                    Spacer()
                    if let err = item.errorDescription {
                        Text(err)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
            }
            .frame(height: 170)
            .border(Color.primary.opacity(0.08))

            HStack {
                Button(L10n.tr("取消", "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.tr("执行重命名", "Rename")) {
                    workspace.executeBatchRename(plans: plan, remote: isRemote)
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .disabled(plan.contains { $0.hasError } || plan.allSatisfy { $0.originalName == $0.newName })
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540, height: 440)
    }
}

// MARK: - Quick Text Editor Sheet
struct QuickEditorSheet: View {
    @ObservedObject var workspace: Workspace
    let context: EditingFileContext
    @State private var text: String

    init(workspace: Workspace, context: EditingFileContext) {
        self.workspace = workspace
        self.context = context
        self._text = State(initialValue: context.content)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(context.name, systemImage: "doc.text.fill")
                    .font(.headline)

                Text(context.remote ? L10n.tr("远程服务器文件", "Remote File") : L10n.tr("本地文件", "Local File"))
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15))
                    .foregroundStyle(Color.accentColor)
                    .cornerRadius(4)

                Spacer()

                if context.isSaving {
                    ProgressView().controlSize(.small)
                }

                Button(L10n.tr("关闭", "Close")) {
                    workspace.editingFile = nil
                }
                .keyboardShortcut(.cancelAction)

                Button(L10n.tr("保存更改", "Save Changes")) {
                    workspace.saveEditorContent(text)
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut("s", modifiers: [.command])
            }
            .padding(14)
            .background(.ultraThinMaterial)

            Divider()

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .padding(10)
        }
        .frame(minWidth: 700, minHeight: 520)
    }
}

// MARK: - Built-in SSH Key Manager Sheet (Transmit Key Manager Parity)
struct SSHKeyManagerSheet: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var keys: [SSHKeyPairItem] = SSHKeyManager.listKeys()
    @State private var newKeyName = "id_ed25519_aether"
    @State private var algorithm: SSHKeyAlgorithm = .ed25519
    @State private var comment = "\(NSUserName())@AetherTransfer"
    @State private var passphrase = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L10n.tr("SSH 密钥管理器 (~/.ssh)", "SSH Key Manager (~/.ssh)"), systemImage: "key.horizontal.fill")
                    .font(.title3.bold())
                Spacer()
                Button(L10n.tr("刷新", "Refresh")) {
                    keys = SSHKeyManager.listKeys()
                }
            }
            .padding(18)
            .background(.ultraThinMaterial)

            Divider()

            HSplitView {
                // Existing Keys List
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.tr("本机已有密钥对 (\(keys.count))", "Existing Key Pairs (\(keys.count))"))
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)

                    List(keys) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(item.name)
                                    .font(.headline)
                                Spacer()
                                Text(item.keyType)
                                    .font(.caption2.monospaced())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.15))
                                    .cornerRadius(4)
                            }
                            Text(item.privateKeyPath)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                            HStack {
                                Button(L10n.tr("复制公钥 (.pub)", "Copy Public Key")) {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(item.publicKeyContent, forType: .string)
                                    workspace.flashNotice(L10n.tr("已复制公钥 \(item.name).pub", "Copied public key \(item.name).pub"))
                                }
                                .controlSize(.small)

                                Button(L10n.tr("在访达中显示", "Reveal in Finder")) {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.privateKeyPath)])
                                }
                                .controlSize(.small)
                            }
                            .padding(.top, 2)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .frame(minWidth: 320)

                // Generate New Key Form
                Form {
                    Section(L10n.tr("生成新 SSH 密钥对", "Generate New SSH Key Pair")) {
                        TextField(L10n.tr("密钥文件名", "Key Filename"), text: $newKeyName)
                        Picker(L10n.tr("加密算法", "Algorithm"), selection: $algorithm) {
                            ForEach(SSHKeyAlgorithm.allCases) { alg in
                                Text(alg.localizedDisplayName).tag(alg)
                            }
                        }
                        TextField(L10n.tr("备注 (Comment)", "Comment"), text: $comment)
                        SecureField(L10n.tr("私钥保护口令 (可选)", "Passphrase (Optional)"), text: $passphrase)

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        Button(L10n.tr("立即生成密钥对", "Generate Key Pair")) {
                            do {
                                errorMessage = nil
                                let created = try SSHKeyManager.generateKeyPair(
                                    name: newKeyName,
                                    algorithm: algorithm,
                                    comment: comment,
                                    passphrase: passphrase
                                )
                                keys = SSHKeyManager.listKeys()
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(created.publicKeyContent, forType: .string)
                                workspace.flashNotice(L10n.tr("已生成 \(created.name) 并复制公钥至剪贴板", "Generated \(created.name) and copied public key"))
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                        .buttonStyle(.glassProminent)
                    }
                }
                .formStyle(.grouped)
                .frame(minWidth: 300)
            }

            Divider()

            HStack {
                Text(L10n.tr("提示：生成的公钥将自动复制到剪贴板，可直接粘贴至服务器 ~/.ssh/authorized_keys",
                             "Tip: Generated public keys are copied to clipboard for ~/.ssh/authorized_keys"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.tr("完成", "Done")) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
            .background(.ultraThinMaterial)
        }
        .frame(width: 680, height: 440)
    }
}

// MARK: - Zero-Knowledge Encrypted Bookmark Sync Sheet (Transmit Panic Sync Parity)
struct EncryptedSyncVaultSheet: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var masterPassword = ""
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.tr("零知识加密书签保险箱 (.aethersync)", "Zero-Knowledge Encrypted Bookmark Vault"))
                        .font(.title3.bold())
                    Text(L10n.tr("采用 HKDF-SHA256 + AES-GCM-256 端到端加密，安全通过 iCloud Drive 或 Git 跨设备同步所有书签。",
                                 "End-to-end encrypted with HKDF-SHA256 + AES-GCM-256 for secure cross-Mac sync via iCloud Drive or Git."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Form {
                Section(L10n.tr("加密主密码 (Master Password)", "Master Encryption Password")) {
                    SecureField(L10n.tr("输入用于加解密保险箱的主密码", "Enter master password for vault encryption/decryption"), text: $masterPassword)
                }

                if let statusMessage {
                    Text(statusMessage).font(.caption).foregroundStyle(.green)
                }
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)

            HStack(spacing: 12) {
                Button(L10n.tr("关闭", "Close")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(L10n.tr("从加密保险箱恢复…", "Import Encrypted Vault…")) {
                    importVault()
                }
                .disabled(masterPassword.isEmpty)

                Button(L10n.tr("导出加密保险箱 (.aethersync)…", "Export Encrypted Vault…")) {
                    exportVault()
                }
                .buttonStyle(.glassProminent)
                .disabled(masterPassword.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 540, height: 300)
    }

    private func exportVault() {
        errorMessage = nil; statusMessage = nil
        do {
            let encryptedData = try workspace.exportEncryptedVault(password: masterPassword)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "AetherBookmarks.aethersync"
            if panel.runModal() == .OK, let url = panel.url {
                try encryptedData.write(to: url, options: .atomic)
                statusMessage = L10n.tr("已成功加密并导出 \(workspace.profiles.count) 个服务器书签！",
                                        "Encrypted and exported \(workspace.profiles.count) server bookmark(s)!")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importVault() {
        errorMessage = nil; statusMessage = nil
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try Data(contentsOf: url)
                let count = try workspace.importEncryptedVault(data: data, password: masterPassword)
                statusMessage = L10n.tr("验证通过！已成功解密并合并 \(count) 个服务器书签。",
                                        "Verified! Decrypted and merged \(count) server bookmark(s).")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
