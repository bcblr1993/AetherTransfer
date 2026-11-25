import AppKit
import SwiftUI
import UniformTypeIdentifiers
import AetherTransferCore

// MARK: - Raw Command Sheet

struct RawCommandSheet: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var v3Store: TransmitV3UIStore
    @Environment(\.dismiss) private var dismiss

    @State private var commandInput: String = ""
    @FocusState private var isCommandFocused: Bool

    private static let presetCommands = ["SYST", "FEAT", "STAT", "PWD", "HELP"]

    init(workspace: Workspace) {
        self.workspace = workspace
        self._v3Store = ObservedObject(wrappedValue: workspace.v3UIStore)
    }

    private var hasNewlines: Bool {
        commandInput.contains("\n") || commandInput.contains("\r") || commandInput.contains("\0")
    }

    private var trimmedCommand: String {
        commandInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canRunCommand: Bool {
        workspace.connectedProfile != nil && !trimmedCommand.isEmpty && !hasNewlines && !v3Store.isRunningRawCommand
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            commandComposerSection
            Divider()
            consoleOutputSection
            Divider()
            footerBar
        }
        .frame(width: 660, height: 480)
        .onAppear {
            DispatchQueue.main.async {
                isCommandFocused = true
            }
        }
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "apple.terminal.fill")
                .font(.system(size: 28))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr("发送原始服务器命令", "Send Raw Server Command"))
                    .font(.title3.bold())
                if let profile = workspace.connectedProfile {
                    Text("\(profile.protocolKind.title) · \(profile.name.isEmpty ? profile.host : profile.name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(L10n.tr("未连接远程服务器", "Not connected to a remote server"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            if v3Store.isRunningRawCommand {
                ProgressView().controlSize(.small)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
    }

    private var commandComposerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField(
                    L10n.tr("输入命令 (例如 STAT / PWD / FEAT)…", "Enter command (e.g. STAT / PWD / FEAT)…"),
                    text: $commandInput
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .focused($isCommandFocused)
                .onSubmit {
                    runCurrentCommand()
                }

                Button(L10n.tr("执行", "Run")) {
                    runCurrentCommand()
                }
                .buttonStyle(.glassProminent)
                .disabled(!canRunCommand)
                .keyboardShortcut(.defaultAction)
            }

            if hasNewlines {
                Text(L10n.tr("命令中不允许包含换行符或控制字符。", "Commands cannot contain newline or control characters."))
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Text(L10n.tr("常用命令：", "Presets:"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    ForEach(Self.presetCommands, id: \.self) { preset in
                        Button {
                            commandInput = preset
                            isCommandFocused = true
                        } label: {
                            Text(preset)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.tr("填入命令 \(preset)", "Insert command \(preset)"))
                    }
                }
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.02))
    }

    @ViewBuilder
    private var consoleOutputSection: some View {
        if v3Store.rawCommandHistory.isEmpty {
            ContentUnavailableView {
                Label(L10n.tr("命令输出控制台", "Command Console"), systemImage: "terminal")
            } description: {
                Text(L10n.tr("输入或选择上方预设命令后点击「执行」，服务器返回结果将自动脱敏显示在此。",
                             "Enter a command or select a preset above and click Run. Output is automatically redacted."))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(v3Store.rawCommandHistory.enumerated()), id: \.offset) { index, item in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(L10n.formatTimestamp(item.timestamp))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                    Text("> \(TranscriptRedactor.sanitize(item.command))")
                                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Color.accentColor)
                                        .textSelection(.enabled)
                                    Spacer()
                                    Image(systemName: item.succeeded ? "checkmark.circle.fill" : "info.circle.fill")
                                        .font(.caption2)
                                        .foregroundStyle(item.succeeded ? Color.green : Color.orange)
                                        .accessibilityLabel(item.succeeded ? L10n.tr("成功", "Succeeded") : L10n.tr("提示或失败", "Notice or Failed"))
                                }

                                Text(TranscriptRedactor.sanitize(item.output))
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.045)))
                            }
                            .id(index)
                        }
                    }
                    .padding(14)
                }
                .onChange(of: v3Store.rawCommandHistory.count) { _, newCount in
                    if newCount > 0 {
                        proxy.scrollTo(newCount - 1, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var footerBar: some View {
        HStack {
            Button(L10n.tr("清空", "Clear")) {
                v3Store.rawCommandHistory.removeAll()
            }
            .disabled(v3Store.rawCommandHistory.isEmpty)

            Spacer()

            Button(L10n.tr("关闭", "Close")) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(14)
        .background(.ultraThinMaterial)
    }

    private func runCurrentCommand() {
        guard canRunCommand else { return }
        let cmd = trimmedCommand
        workspace.sendRawCommand(cmd)
        commandInput = ""
    }
}

// MARK: - Import Servers Wizard Sheet

struct ImportServersSheet: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var v3Store: TransmitV3UIStore
    @Environment(\.dismiss) private var dismiss

    @State private var importPasswordsToKeychain: Bool = false

    init(workspace: Workspace) {
        self.workspace = workspace
        self._v3Store = ObservedObject(wrappedValue: workspace.v3UIStore)
    }

    private var selectedCount: Int {
        v3Store.importedItems.filter(\.selected).count
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            sourceChooserBar
            Divider()
            itemsTableSection
            Divider()
            footerBar
        }
        .frame(width: 740, height: 520)
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.down.on.square.fill")
                .font(.system(size: 30))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr("从其他客户端或本机配置导入服务器", "Import Servers Wizard"))
                    .font(.title3.bold())
                Text(L10n.tr("支持扫描 ~/.ssh/config、~/.aws，或导入 FileZilla (.xml)、Cyberduck (.duck)、Transmit (.exportedFavorites / .inetloc) 与 JSON。",
                             "Scan ~/.ssh/config & ~/.aws or choose FileZilla (.xml), Cyberduck (.duck), Transmit (.exportedFavorites / .inetloc), or JSON."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(16)
        .background(.ultraThinMaterial)
    }

    private var sourceChooserBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    workspace.loadLocalConfigsForImport()
                } label: {
                    Label(
                        L10n.tr("扫描本机配置 (~/.ssh/config, ~/.aws)", "Scan Local Configs (~/.ssh/config, ~/.aws)"),
                        systemImage: "magnifyingglass.circle.fill"
                    )
                }
                .buttonStyle(.glassProminent)

                Button {
                    chooseImportFile()
                } label: {
                    Label(
                        L10n.tr("选择文件… (FileZilla .xml / Cyberduck .duck / Transmit)", "Choose File… (FileZilla .xml, Cyberduck .duck, Transmit .exportedFavorites / .inetloc)"),
                        systemImage: "doc.badge.plus"
                    )
                }

                Spacer()

                if !v3Store.importedItems.isEmpty {
                    Button(L10n.tr("全选", "Select All")) {
                        for idx in v3Store.importedItems.indices {
                            v3Store.importedItems[idx].selected = true
                        }
                    }
                    .controlSize(.small)

                    Button(L10n.tr("全不选", "Deselect All")) {
                        for idx in v3Store.importedItems.indices {
                            v3Store.importedItems[idx].selected = false
                        }
                    }
                    .controlSize(.small)
                }
            }

            if let status = v3Store.importStatusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = v3Store.importErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.02))
    }

    @ViewBuilder
    private var itemsTableSection: some View {
        if v3Store.importedItems.isEmpty {
            ContentUnavailableView {
                Label(L10n.tr("尚未加载待导入的服务器", "No Servers Loaded"), systemImage: "tray.and.arrow.down")
            } description: {
                Text(L10n.tr("点击上方「扫描本机配置」或「选择文件…」以预览可导入的书签条目。",
                             "Click \"Scan Local Configs\" or \"Choose File…\" above to preview importable bookmarks."))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table($v3Store.importedItems) {
                TableColumn("") { $item in
                    Toggle("", isOn: $item.selected)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .accessibilityLabel(L10n.tr("选择 \(item.profile.name)", "Select \(item.profile.name)"))
                }
                .width(28)

                TableColumn(L10n.tr("来源格式", "Source")) { $item in
                    Text(item.sourceFormat)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                        .foregroundStyle(Color.accentColor)
                }
                .width(120)

                TableColumn(L10n.tr("名称", "Name")) { $item in
                    HStack(spacing: 4) {
                        Text(item.profile.name.isEmpty ? item.profile.host : item.profile.name)
                            .lineLimit(1)
                        if item.hasPassword {
                            Image(systemName: "key.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .help(L10n.tr("源文件中包含密码", "Contains password in source"))
                                .accessibilityLabel(L10n.tr("包含密码", "Contains password"))
                        }
                    }
                }
                .width(min: 120, ideal: 160)

                TableColumn(L10n.tr("协议", "Protocol")) { $item in
                    ProtocolBadge(protocolKind: item.profile.protocolKind)
                }
                .width(96)

                TableColumn(L10n.tr("主机", "Host")) { $item in
                    Text(item.profile.host)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                }
                .width(min: 140, ideal: 190)

                TableColumn(L10n.tr("端口", "Port")) { $item in
                    Text("\(item.profile.port)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .width(56)
            }
        }
    }

    private var footerBar: some View {
        HStack(spacing: 12) {
            Toggle(
                L10n.tr("将密码导入系统钥匙串（若源文件中包含）", "Import passwords to Keychain (if present)"),
                isOn: $importPasswordsToKeychain
            )
            .toggleStyle(.checkbox)
            .font(.caption)

            Spacer()

            Button(L10n.tr("取消", "Cancel")) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button(L10n.tr("导入所选 (\(selectedCount))", "Import Selected (\(selectedCount))")) {
                workspace.commitImportedServers(v3Store.importedItems, importPasswords: importPasswordsToKeychain)
                dismiss()
            }
            .buttonStyle(.glassProminent)
            .disabled(selectedCount == 0)
            .keyboardShortcut(.defaultAction)
        }
        .padding(14)
        .background(.ultraThinMaterial)
    }

    private func chooseImportFile() {
        let panel = NSOpenPanel()
        panel.title = L10n.tr("选择要导入的服务器配置文件", "Choose Server Bookmark File to Import")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        var types: [UTType] = [.xml, .json, .propertyList]
        for ext in ["duck", "exportedFavorites", "inetloc"] {
            if let custom = UTType(filenameExtension: ext) {
                types.append(custom)
            }
        }
        panel.allowedContentTypes = types
        if panel.runModal() == .OK, let url = panel.url {
            workspace.loadImportFile(url)
        }
    }
}

// MARK: - S3 Bucket Picker Sheet

struct S3BucketPickerSheet: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var v3Store: TransmitV3UIStore
    @Environment(\.dismiss) private var dismiss

    @State private var searchText: String = ""
    @State private var selectedBucketName: String?

    init(workspace: Workspace) {
        self.workspace = workspace
        self._v3Store = ObservedObject(wrappedValue: workspace.v3UIStore)
    }

    private var filteredBuckets: [S3BucketInfo] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return v3Store.discoveredBuckets }
        return v3Store.discoveredBuckets.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.connected.to.line.below.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("选择 S3 存储桶 (Bucket)", "Choose S3 Bucket"))
                        .font(.title3.bold())
                    if let profile = v3Store.bucketPickerProfile {
                        Text(profile.host.isEmpty ? "s3.amazonaws.com" : profile.host)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if v3Store.isLoadingBuckets {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(16)
            .background(.ultraThinMaterial)

            Divider()

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(L10n.tr("筛选存储桶名称…", "Filter buckets…"), text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.tr("清除筛选", "Clear Filter"))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.02))

            Divider()

            bucketListBody

            Divider()

            HStack {
                Button(L10n.tr("重新获取", "Refresh")) {
                    if let profile = v3Store.bucketPickerProfile {
                        workspace.browseS3Buckets(
                            for: profile,
                            credentials: v3Store.bucketPickerCredentials ?? Credentials(),
                            origin: v3Store.bucketPickerOrigin,
                            onSelect: v3Store.onBucketSelected
                        )
                    }
                }
                .disabled(v3Store.isLoadingBuckets || v3Store.bucketPickerProfile == nil)

                Spacer()

                Button(L10n.tr("取消", "Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(L10n.tr("选择", "Select")) {
                    confirmSelection()
                }
                .buttonStyle(.glassProminent)
                .disabled(selectedBucketName == nil)
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
            .background(.ultraThinMaterial)
        }
        .frame(width: 500, height: 420)
    }

    @ViewBuilder
    private var bucketListBody: some View {
        if v3Store.isLoadingBuckets {
            VStack(spacing: 10) {
                ProgressView().controlSize(.large)
                Text(L10n.tr("正在列举 S3 存储桶…", "Listing S3 buckets…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = v3Store.bucketDiscoveryError {
            ContentUnavailableView {
                Label(L10n.tr("未能列举存储桶", "Unable to List Buckets"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(err)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredBuckets.isEmpty {
            ContentUnavailableView {
                Label(L10n.tr("未找到存储桶", "No Buckets Found"), systemImage: "cylinder")
            } description: {
                Text(L10n.tr("尝试调整筛选条件或检查凭据权限。", "Adjust your filter or check credential permissions."))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(filteredBuckets, selection: $selectedBucketName) { bucket in
                HStack(spacing: 10) {
                    Image(systemName: "cylinder.fill")
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bucket.name)
                            .font(.body.weight(.medium))
                        if let created = bucket.creationDate {
                            Text(L10n.tr("创建于 \(L10n.formatDateTime(created))", "Created \(L10n.formatDateTime(created))"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .tag(bucket.name)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    selectedBucketName = bucket.name
                    confirmSelection()
                }
            }
            .listStyle(.inset)
        }
    }

    private func confirmSelection() {
        guard let bucket = selectedBucketName else { return }
        v3Store.onBucketSelected?(bucket)
        dismiss()
    }
}

// MARK: - View Options Popover

struct ViewOptionsPopover: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var appearance: PaneAppearanceState
    @ObservedObject private var v3Store: TransmitV3UIStore

    init(workspace: Workspace, appearance: PaneAppearanceState) {
        self.workspace = workspace
        self.appearance = appearance
        self._v3Store = ObservedObject(wrappedValue: workspace.v3UIStore)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(L10n.tr("显示选项", "View Options"), systemImage: "slider.horizontal.3")
                    .font(.headline)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("当前视图模式", "Active View Mode"))
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                Picker(
                    L10n.tr("当前视图模式", "Active View Mode"),
                    selection: Binding(
                        get: { appearance.displayMode },
                        set: { appearance.applyDisplayMode($0, to: workspace) }
                    )
                ) {
                    ForEach(BrowserDisplayMode.allCases) { mode in
                        Text(mode.localizedTitle).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel(L10n.tr("当前视图模式", "Active View Mode"))
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L10n.tr("默认新窗口视图", "Default View Mode"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker(
                        L10n.tr("默认新窗口视图", "Default View Mode"),
                        selection: Binding(
                            get: { workspace.viewMode },
                            set: { workspace.rulesAndTranscriptStore.setDefaultViewMode($0) }
                        )
                    ) {
                        ForEach(FileViewMode.allCases) { mode in
                            Text(mode.localizedTitle).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L10n.tr("网格缩略图大小", "Thumbnail Grid Size"))
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(appearance.gridItemSize)) pt")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Slider(value: $appearance.gridItemSize, in: 72...160, step: 4)
                    .accessibilityLabel(L10n.tr("网格缩略图大小", "Thumbnail Grid Size"))
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Toggle(L10n.tr("在列表中显示权限列", "Show Permissions Column"), isOn: $appearance.showPermissionsColumn)
                Toggle(L10n.tr("显示隐藏文件", "Show Hidden Files"), isOn: $workspace.showHidden)
                Toggle(L10n.tr("文件夹始终排在前面", "Keep Folders First"), isOn: $v3Store.foldersFirst)
            }
            .toggleStyle(.checkbox)
            .font(.callout)
        }
        .padding(16)
        .frame(width: 310)
    }
}

// MARK: - S3 IAM Role MFA Prompt Sheet

struct MFAPromptSheet: View {
    @ObservedObject var workspace: Workspace
    let profile: ServerProfile
    @Environment(\.dismiss) private var dismiss

    @State private var token: String = ""
    @FocusState private var isTokenFocused: Bool

    private var sanitizedDigits: String {
        String(token.filter(\.isNumber).prefix(6))
    }

    private var isValidToken: Bool {
        sanitizedDigits.count == 6
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .font(.title)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("输入 S3 IAM 角色 MFA 验证码", "Enter S3 IAM Role MFA Token"))
                        .font(.headline)
                    Text(profile.name.isEmpty ? profile.host : profile.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                if !profile.s3IAMRoleARN.isEmpty {
                    Text("Role: \(profile.s3IAMRoleARN)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !profile.s3MFASerial.isEmpty {
                    Text("MFA Device: \(profile.s3MFASerial)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))

            TextField(L10n.tr("6 位动态验证码 (TOTP)", "6-digit MFA TOTP token"), text: $token)
                .textFieldStyle(.roundedBorder)
                .font(.system(.title3, design: .monospaced))
                .focused($isTokenFocused)
                .onChange(of: token) { _, newValue in
                    let digitsOnly = String(newValue.filter(\.isNumber).prefix(6))
                    if digitsOnly != newValue {
                        token = digitsOnly
                    }
                }
                .onSubmit {
                    if isValidToken {
                        workspace.submitMFAToken(sanitizedDigits)
                        dismiss()
                    }
                }

            HStack {
                Button(L10n.tr("取消", "Cancel")) {
                    workspace.v3UIStore.mfaChallengeProfile = nil
                    workspace.v3UIStore.mfaChallengeCredentials = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(L10n.tr("验证并连接", "Verify & Connect")) {
                    workspace.submitMFAToken(sanitizedDigits)
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .disabled(!isValidToken)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 440)
        .onAppear {
            DispatchQueue.main.async {
                isTokenFocused = true
            }
        }
    }
}
