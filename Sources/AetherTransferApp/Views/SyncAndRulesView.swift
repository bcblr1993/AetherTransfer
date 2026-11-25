import SwiftUI
import AppKit
import AetherTransferCore

// MARK: - Software Update Sheet (In-App Online Update + Download + Immediate Restart)
struct SoftwareUpdateSheet: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 14) {
                Image(systemName: "arrow.down.app.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(LinearGradient(colors: [Color.accentColor, Color.cyan], startPoint: .topLeading, endPoint: .bottomTrailing))

                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("AetherTransfer 软件更新", "AetherTransfer Software Update"))
                        .font(.title3.bold())
                    Text(L10n.tr("当前版本：v\(AutoUpdater.currentAppVersion()) (Build \(AutoUpdater.currentBuildNumber()))",
                                 "Current Version: v\(AutoUpdater.currentAppVersion()) (Build \(AutoUpdater.currentBuildNumber()))"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle(L10n.tr("自动检查更新", "Auto-check for updates"), isOn: $workspace.autoCheckForUpdates)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
            .padding(20)
            .background(.ultraThinMaterial)

            Divider()

            // Main State Content
            VStack(alignment: .leading, spacing: 16) {
                switch workspace.updateState {
                case .idle:
                    updatePlaceholderView(
                        icon: "sparkles",
                        color: .secondary,
                        title: L10n.tr("准备检查新版本", "Ready to Check for Updates"),
                        subtitle: L10n.tr("点击下方「检查更新」获取最新正式版本。", "Click \"Check for Updates\" below to query the latest release.")
                    )

                case .checking:
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text(L10n.tr("正在连接更新服务器检查最新版本…", "Checking update server for new releases…"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .upToDate(let ver):
                    updatePlaceholderView(
                        icon: "checkmark.seal.fill",
                        color: .green,
                        title: L10n.tr("AetherTransfer 已是最新版本 (v\(ver))", "AetherTransfer is up to date (v\(ver))"),
                        subtitle: L10n.tr("您正在运行最新的 Apple Silicon 原生版本。", "You are running the latest native Apple Silicon release.")
                    )

                case .available(let release):
                    releaseDetailView(release: release)

                case .downloading(let release, let completed, let total, let progress):
                    VStack(alignment: .leading, spacing: 14) {
                        releaseDetailView(release: release)
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(L10n.tr("正在下载更新包 v\(release.version)…", "Downloading update v\(release.version)…"))
                                    .font(.caption.bold())
                                Spacer()
                                Text("\(ByteCountFormatter.string(fromByteCount: completed, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) (\(Int(progress * 100))%)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                        }
                    }

                case .verifying(let release):
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text(L10n.tr("正在校验 v\(release.version) 的 SHA-256 指纹与 Apple 代码签名…",
                                     "Verifying SHA-256 digest and code signature for v\(release.version)…"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .readyToInstall(let release, _):
                    VStack(alignment: .leading, spacing: 14) {
                        releaseDetailView(release: release)
                        Divider()
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.shield.fill")
                                .foregroundStyle(.green)
                            Text(L10n.tr("v\(release.version) 下载完成并通过 SHA-256 与代码签名校验，点击「立即重启并更新」即可完成升级。",
                                         "v\(release.version) downloaded and verified (SHA-256 & Code Signature). Click \"Restart & Update Now\" to relaunch."))
                                .font(.caption)
                                .foregroundStyle(.primary)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(8)
                    }

                case .installing(let release):
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text(L10n.tr("正在原子替换应用包并重启至 v\(release.version)…",
                                     "Swapping application bundle and relaunching v\(release.version)…"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .failed(let message):
                    updatePlaceholderView(
                        icon: "exclamationmark.triangle.fill",
                        color: .orange,
                        title: L10n.tr("未能完成更新检查或安装", "Update Check or Installation Failed"),
                        subtitle: message
                    )
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Footer Actions
            HStack {
                Button(L10n.tr("关闭", "Close")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                switch workspace.updateState {
                case .idle, .upToDate, .failed:
                    Button(L10n.tr("检查更新", "Check for Updates")) {
                        workspace.checkForUpdates(silentIfUpToDate: false)
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)

                case .checking, .verifying, .installing:
                    EmptyView()

                case .available(let release):
                    Button(L10n.tr("立即下载更新 (\(ByteCountFormatter.string(fromByteCount: release.sizeBytes, countStyle: .file)))",
                                 "Download Update (\(ByteCountFormatter.string(fromByteCount: release.sizeBytes, countStyle: .file)))")) {
                        workspace.downloadUpdate(release)
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)

                case .downloading:
                    Button(L10n.tr("取消下载", "Cancel Download")) {
                        workspace.cancelUpdateDownload()
                    }

                case .readyToInstall:
                    Button(L10n.tr("立即重启并更新", "Restart & Update Now")) {
                        workspace.installUpdateAndRelaunch()
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .background(.ultraThinMaterial)
        }
        .frame(width: 560, height: 420)
    }

    @ViewBuilder
    private func updatePlaceholderView(icon: String, color: Color, title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(color)
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func releaseDetailView(release: UpdateRelease) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(L10n.tr("发现新版本 v\(release.version)", "New Version v\(release.version) Available"), systemImage: "sparkles")
                    .font(.headline)
                    .foregroundStyle(Color.accentColor)
                Spacer()
                Text(release.publishedAt)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(L10n.tr("更新说明：", "Release Notes:"))
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            ScrollView {
                Text(release.localizedReleaseNotes)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color.primary.opacity(0.04))
            .cornerRadius(8)

            HStack(spacing: 12) {
                Text("SHA-256: \(release.sha256.prefix(16))…")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(L10n.tr("安装包大小: \(ByteCountFormatter.string(fromByteCount: release.sizeBytes, countStyle: .file))",
                             "Size: \(ByteCountFormatter.string(fromByteCount: release.sizeBytes, countStyle: .file))"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Directory Synchronization Sheet (Liquid Glass)
struct SyncSheet: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(LinearGradient(colors: [Color.accentColor, Color.cyan], startPoint: .topLeading, endPoint: .bottomTrailing))

                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.tr("文件夹同步 (Folder Sync)", "Folder Synchronization"))
                        .font(.title3.bold())

                    Text("\(L10n.tr("本地", "Local")): \(workspace.localPath)  ⇄  \(L10n.tr("远程", "Remote")): \(workspace.remotePath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(18)
            .background(.ultraThinMaterial)

            Divider()

            // Configuration Bar
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    Picker(L10n.tr("同步方向", "Direction"), selection: $workspace.syncDirection) {
                        ForEach(SyncDirection.allCases, id: \.self) { dir in
                            Text(dir.localizedTitle).tag(dir)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: workspace.syncDirection) { workspace.recalculateSyncPlan() }

                    Picker(L10n.tr("比较规则", "Compare By"), selection: $workspace.syncRule) {
                        Text(SyncComparisonRule.sizeAndDate.localizedTitle).tag(SyncComparisonRule.sizeAndDate)
                        Text(SyncComparisonRule.sizeOnly.localizedTitle).tag(SyncComparisonRule.sizeOnly)
                    }
                    .pickerStyle(.menu)
                    .onChange(of: workspace.syncRule) { workspace.recalculateSyncPlan() }

                    Spacer()

                    Button {
                        workspace.startSyncAnalysis()
                    } label: {
                        Label(L10n.tr("重新比对", "Re-analyze"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                }

                HStack {
                    Toggle(L10n.tr("删除目标位置的多余文件 (慎用，默认关闭)", "Delete orphan files on target (Use with caution, off by default)"), isOn: $workspace.syncDeleteOrphans)
                        .toggleStyle(.checkbox)
                        .onChange(of: workspace.syncDeleteOrphans) { workspace.recalculateSyncPlan() }

                    Spacer()

                    Text(L10n.tr("🛡️ 遵循安全性原则，默认不删除任何远程文件", "🛡️ Safe by default: remote files are never deleted unless explicitly checked"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Text(L10n.tr("忽略规则 (Glob):", "Ignore Rules:"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(".DS_Store, .git, node_modules, *.log", text: $workspace.syncIgnorePatternsText)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .onSubmit { workspace.recalculateSyncPlan() }
                    Button(L10n.tr("应用过滤", "Apply Filter")) {
                        workspace.recalculateSyncPlan()
                    }
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color.primary.opacity(0.02))

            Divider()

            // Summary Stats Pill Bar
            if let plan = workspace.syncPlan {
                HStack(spacing: 14) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundStyle(.blue)
                        Text(L10n.tr("上传: \(plan.uploadItems.count) 项", "Upload: \(plan.uploadItems.count)"))
                            .font(.caption.bold())
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.1))
                    .clipShape(Capsule())

                    HStack(spacing: 5) {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(.green)
                        Text(L10n.tr("下载: \(plan.downloadItems.count) 项", "Download: \(plan.downloadItems.count)"))
                            .font(.caption.bold())
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.1))
                    .clipShape(Capsule())

                    HStack(spacing: 5) {
                        Image(systemName: "trash.circle.fill")
                            .foregroundStyle(.red)
                        Text(L10n.tr("删除: \(plan.deleteItems.count) 项", "Delete: \(plan.deleteItems.count)"))
                            .font(.caption.bold())
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.1))
                    .clipShape(Capsule())

                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                        Text(L10n.tr("跳过: \(plan.skipItems.count) 项", "Skip: \(plan.skipItems.count)"))
                            .font(.caption)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(Capsule())

                    Spacer()

                    Text(L10n.tr("计划传输: \(ByteCountFormatter.string(fromByteCount: plan.totalTransferBytes, countStyle: .file))",
                                 "Total: \(ByteCountFormatter.string(fromByteCount: plan.totalTransferBytes, countStyle: .file))"))
                        .font(.caption.monospacedDigit().bold())
                        .foregroundStyle(Color.accentColor)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)

                Divider()

                // Items Table
                List {
                    ForEach(plan.items.indices, id: \.self) { idx in
                        let item = plan.items[idx]
                        HStack(spacing: 10) {
                            Toggle("", isOn: Binding(
                                get: { workspace.syncPlan?.items[idx].isEnabled ?? false },
                                set: { workspace.syncPlan?.items[idx].isEnabled = $0 }
                            ))
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                            .disabled(item.actionType == .skipIdentical)

                            Image(systemName: item.actionType.iconName)
                                .foregroundStyle(colorForAction(item.actionType))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.relativePath)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)

                                HStack(spacing: 8) {
                                    Text(item.actionType.localizedTitle)
                                        .font(.caption2)
                                        .foregroundStyle(colorForAction(item.actionType))

                                    if item.size > 0 {
                                        Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }

                                    if let d1 = item.sourceDate {
                                        Text("\(L10n.tr("源", "Src")): \(d1.formatted(date: .numeric, time: .shortened))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }

                                    if let d2 = item.targetDate {
                                        Text("\(L10n.tr("目标", "Dst")): \(d2.formatted(date: .numeric, time: .shortened))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }

                            Spacer()
                        }
                        .padding(.vertical, 3)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(L10n.tr("正在生成同步计划…", "Generating sync plan…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            // Footer
            HStack {
                Button(L10n.tr("取消", "Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if let plan = workspace.syncPlan {
                    Button(L10n.tr("复制同步报告", "Copy Report")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(plan.exportReportMarkdown(), forType: .string)
                        workspace.flashNotice(L10n.tr("已复制 Markdown 同步计划报告", "Copied Markdown sync report"))
                    }

                    Button(L10n.tr("执行同步 (\(plan.activeItems.count) 项)", "Synchronize (\(plan.activeItems.count) Items)")) {
                        workspace.executeSyncPlan()
                        dismiss()
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(plan.activeItems.isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .background(.ultraThinMaterial)
        }
        .frame(width: 720, height: 560)
    }

    private func colorForAction(_ action: SyncActionType) -> Color {
        switch action {
        case .upload: return .blue
        case .download: return .green
        case .deleteRemote, .deleteLocal: return .red
        case .skipIdentical: return .secondary
        }
    }
}

// MARK: - Native Settings View (⌘,)
struct SettingsView: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        TabView {
            Form {
                Section(L10n.tr("通用与语言", "General & Language")) {
                    Picker(L10n.tr("界面语言", "Interface Language"), selection: $workspace.appLanguage) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }

                    HStack {
                        TextField(L10n.tr("默认本地起始文件夹", "Default Local Folder"), text: $workspace.defaultLocalPath)
                        Button(L10n.tr("选择…", "Choose…")) {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            if panel.runModal() == .OK, let url = panel.url {
                                workspace.defaultLocalPath = url.path
                            }
                        }
                    }

                    Toggle(L10n.tr("默认显示隐藏文件 (以 . 开头)", "Show hidden files by default"), isOn: $workspace.showHidden)
                }

                Section(L10n.tr("传输与冲突处理", "Transfers & Conflict Resolution")) {
                    Stepper(
                        value: $workspace.maxConcurrentTransfers,
                        in: 1...10
                    ) {
                        HStack {
                            Text(L10n.tr("最大并发传输任务数", "Max Concurrent Transfers"))
                            Spacer()
                            Text("\(workspace.maxConcurrentTransfers)")
                                .font(.body.monospacedDigit().bold())
                        }
                    }

                    Picker(L10n.tr("遇到同名文件冲突时", "When File Conflict Occurs"), selection: $workspace.defaultConflictPreference) {
                        ForEach(DefaultConflictPreference.allCases) { pref in
                            Text(pref.localizedTitle).tag(pref)
                        }
                    }
                }

                Section(L10n.tr("软件在线更新", "Software Updates")) {
                    Toggle(L10n.tr("启动时自动在后台检查更新", "Automatically check for updates on launch"), isOn: $workspace.autoCheckForUpdates)

                    HStack {
                        Text(L10n.tr("当前版本：v\(AutoUpdater.currentAppVersion()) (Build \(AutoUpdater.currentBuildNumber()))",
                                     "Current Version: v\(AutoUpdater.currentAppVersion()) (Build \(AutoUpdater.currentBuildNumber()))"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(L10n.tr("立即检查更新…", "Check for Updates Now…")) {
                            workspace.openUpdateWindowAndCheck()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label(L10n.tr("通用与传输", "General & Transfers"), systemImage: "gearshape")
            }
        }
        .frame(width: 520, height: 390)
    }
}
