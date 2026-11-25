import SwiftUI
import AppKit
import UniformTypeIdentifiers
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

// MARK: - Directory Synchronization Sheet (Liquid Glass + FileRulesStore + SyncOptions)

private enum SyncFilterCategory: String, CaseIterable, Identifiable {
    case all
    case changed
    case unchanged
    case deleted

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .all: return L10n.tr("全部", "All")
        case .changed: return L10n.tr("有变更", "Changed")
        case .unchanged: return L10n.tr("无变化", "Unchanged")
        case .deleted: return L10n.tr("待删除", "Deleted")
        }
    }

    func matches(_ item: SyncItem) -> Bool {
        switch self {
        case .all:
            return true
        case .changed:
            return item.actionType == .upload || item.actionType == .download
        case .unchanged:
            return item.actionType == .skipIdentical
        case .deleted:
            return item.actionType == .deleteRemote || item.actionType == .deleteLocal
        }
    }
}

private enum ModifiedWithinPreset: String, CaseIterable, Identifiable {
    case any
    case hours24
    case days7
    case days30
    case days90

    var id: String { rawValue }

    var seconds: TimeInterval? {
        switch self {
        case .any: return nil
        case .hours24: return 86_400
        case .days7: return 7 * 86_400
        case .days30: return 30 * 86_400
        case .days90: return 90 * 86_400
        }
    }

    var localizedTitle: String {
        switch self {
        case .any: return L10n.tr("不限时间", "Any")
        case .hours24: return L10n.tr("最近 24 小时", "24 Hours")
        case .days7: return L10n.tr("最近 7 天", "7 Days")
        case .days30: return L10n.tr("最近 30 天", "30 Days")
        case .days90: return L10n.tr("最近 90 天", "90 Days")
        }
    }
}

struct SyncSheet: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var store: RulesAndTranscriptStore
    @Environment(\.dismiss) private var dismiss
    @State private var showRulesBar = true

    // Wave 3 v3-integrator: pass syncOptions directly into Workspace.startSyncAnalysis() and Workspace.recalculateSyncPlan()
    @State private var syncOptions = SyncOptions()
    @State private var offsetHours: Int = 0
    @State private var offsetMinutes: Int = 0
    @State private var offsetSeconds: Int = 0
    @State private var modifiedWithinPreset: ModifiedWithinPreset = .any
    @State private var searchText: String = ""
    @State private var filterCategory: SyncFilterCategory = .all

    init(workspace: Workspace) {
        self.workspace = workspace
        self._store = ObservedObject(wrappedValue: workspace.rulesAndTranscriptStore)
    }

    private var syncApplicableRules: [SkipRule] {
        store.skipRules.filter { $0.scope.appliesToSync }
    }

    private func filteredItems(from plan: SyncPlan) -> [SyncItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return plan.items.filter { item in
            guard filterCategory.matches(item) else { return false }
            if query.isEmpty { return true }
            return item.relativePath.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            syncHeader
            Divider()
            syncConfigBar
            Divider()
            syncPlanBody
            Divider()
            syncFooter
        }
        .frame(width: 840, height: 690)
    }

    private var syncHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(LinearGradient(colors: [Color.accentColor, Color.cyan], startPoint: .topLeading, endPoint: .bottomTrailing))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(L10n.tr("文件夹同步 (Folder Sync)", "Folder Synchronization"))
                        .font(.title3.bold())

                    if syncOptions.simulateOnly || (workspace.syncPlan?.simulateOnly == true) {
                        Text("[SIMULATE]")
                            .font(.caption2.monospaced().bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.18)))
                            .foregroundStyle(.orange)
                    }
                }

                Text("\(L10n.tr("本地", "Local")): \(workspace.localPath)  ⇄  \(L10n.tr("远程", "Remote")): \(workspace.remotePath)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(18)
        .background(.ultraThinMaterial)
    }

    private var syncConfigBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Picker(L10n.tr("同步方向", "Direction"), selection: $workspace.syncDirection) {
                    ForEach(SyncDirection.allCases, id: \.self) { dir in
                        Text(dir.localizedTitle).tag(dir)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: workspace.syncDirection) { recalculateWithSyncOptions() }

                Picker(L10n.tr("比较规则", "Compare By"), selection: $workspace.syncRule) {
                    Text(SyncComparisonRule.sizeAndDate.localizedTitle).tag(SyncComparisonRule.sizeAndDate)
                    Text(SyncComparisonRule.sizeOnly.localizedTitle).tag(SyncComparisonRule.sizeOnly)
                }
                .pickerStyle(.menu)
                .onChange(of: workspace.syncRule) { recalculateWithSyncOptions() }

                Picker(L10n.tr("仅同步最近修改", "Modified Within"), selection: $modifiedWithinPreset) {
                    ForEach(ModifiedWithinPreset.allCases) { preset in
                        Text(preset.localizedTitle).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: modifiedWithinPreset) {
                    syncOptions.modifiedWithinSeconds = modifiedWithinPreset.seconds
                    recalculateWithSyncOptions()
                }

                Spacer()

                Button {
                    workspace.startSyncAnalysis()
                } label: {
                    Label(L10n.tr("重新比对", "Re-analyze"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }

            // Time Offset + Auto-Detect Row
            HStack(spacing: 10) {
                Text(L10n.tr("时间偏移:", "Time Offset:"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 4) {
                    Stepper(value: $offsetHours, in: -24...24) {
                        Text("\(offsetHours)h")
                            .font(.caption.monospacedDigit())
                            .frame(minWidth: 28, alignment: .trailing)
                    }
                    .accessibilityLabel(L10n.tr("时间偏移小时", "Time Offset Hours"))
                    .onChange(of: offsetHours) { syncOffsetComponentsToOptions() }

                    Stepper(value: $offsetMinutes, in: -59...59) {
                        Text("\(offsetMinutes)m")
                            .font(.caption.monospacedDigit())
                            .frame(minWidth: 30, alignment: .trailing)
                    }
                    .accessibilityLabel(L10n.tr("时间偏移分钟", "Time Offset Minutes"))
                    .onChange(of: offsetMinutes) { syncOffsetComponentsToOptions() }

                    Stepper(value: $offsetSeconds, in: -59...59) {
                        Text("\(offsetSeconds)s")
                            .font(.caption.monospacedDigit())
                            .frame(minWidth: 30, alignment: .trailing)
                    }
                    .accessibilityLabel(L10n.tr("时间偏移秒", "Time Offset Seconds"))
                    .onChange(of: offsetSeconds) { syncOffsetComponentsToOptions() }
                }

                Button {
                    autoDetectTimeOffset()
                } label: {
                    Label(L10n.tr("自动检测", "Auto-Detect"), systemImage: "wand.and.stars")
                }
                .controlSize(.small)

                if syncOptions.timeOffsetSeconds != 0 {
                    Button(L10n.tr("归零", "Reset")) {
                        offsetHours = 0
                        offsetMinutes = 0
                        offsetSeconds = 0
                        syncOffsetComponentsToOptions()
                    }
                    .controlSize(.small)
                }

                Spacer()

                Toggle(L10n.tr("依照符号链接", "Follow Symlinks"), isOn: $syncOptions.followSymlinks)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .onChange(of: syncOptions.followSymlinks) { recalculateWithSyncOptions() }

                Toggle(L10n.tr("模拟试运行", "Simulate"), isOn: $syncOptions.simulateOnly)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .onChange(of: syncOptions.simulateOnly) { recalculateWithSyncOptions() }
            }

            HStack(spacing: 10) {
                Toggle(L10n.tr("删除目标位置的多余文件 (默认关闭)", "Delete orphan files on target (off by default)"), isOn: $workspace.syncDeleteOrphans)
                    .toggleStyle(.checkbox)
                    .onChange(of: workspace.syncDeleteOrphans) { recalculateWithSyncOptions() }

                Spacer()

                if workspace.syncDeleteOrphans {
                    Label(
                        L10n.tr("危险：目标端多余文件将被删除", "Warning: Target orphan files will be deleted"),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.red.opacity(0.15)))
                    .foregroundStyle(.red)
                } else {
                    Label(
                        L10n.tr("安全模式：保留目标端多余文件", "Safe Mode: Orphans Preserved"),
                        systemImage: "checkmark.shield.fill"
                    )
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.green.opacity(0.14)))
                    .foregroundStyle(.green)
                }
            }

            // Skip Rules from FileRulesStore
            if !syncApplicableRules.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                showRulesBar.toggle()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: showRulesBar ? "chevron.down" : "chevron.right")
                                    .font(.caption2)
                                Image(systemName: "line.3.horizontal.decrease.circle")
                                    .font(.caption)
                                let activeCount = syncApplicableRules.filter(\.isEnabled).count
                                Text(L10n.tr("跳过规则 (\(activeCount)/\(syncApplicableRules.count) 启用)",
                                             "Skip Rules (\(activeCount)/\(syncApplicableRules.count) Active)"))
                                    .font(.caption.bold())
                            }
                        }
                        .buttonStyle(.plain)

                        Spacer()
                    }

                    if showRulesBar {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(syncApplicableRules) { rule in
                                    Button {
                                        store.setRuleEnabled(rule.id, enabled: !rule.isEnabled)
                                        recalculateWithSyncOptions()
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: rule.isEnabled ? "checkmark.circle.fill" : "circle")
                                                .font(.caption2)
                                            Text(rule.name)
                                                .font(.caption2)
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(
                                            Capsule().fill(rule.isEnabled ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05))
                                        )
                                        .foregroundStyle(rule.isEnabled ? Color.accentColor : Color.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }

            // Custom Glob Ignore Patterns (SyncIgnoreFilter)
            HStack(spacing: 8) {
                Text(L10n.tr("额外 Glob 忽略:", "Glob Ignores:"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(".DS_Store, .git, node_modules, *.log", text: $workspace.syncIgnorePatternsText)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onSubmit { recalculateWithSyncOptions() }
                Button(L10n.tr("应用过滤", "Apply Filter")) {
                    recalculateWithSyncOptions()
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.02))
    }

    @ViewBuilder
    private var syncPlanBody: some View {
        if let plan = workspace.syncPlan {
            let visibleItems = filteredItems(from: plan)

            if syncOptions.simulateOnly || plan.simulateOnly {
                HStack(spacing: 8) {
                    Image(systemName: "eye.fill")
                        .foregroundStyle(.orange)
                    Text(L10n.tr(
                        "[模拟试运行] 仅预览同步计划与导出报告，已禁用实际上传/下载/删除操作。",
                        "[SIMULATE] Dry-run preview only — file transfers and deletions are disabled. You can export the report."
                    ))
                    .font(.caption.weight(.medium))
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.12))

                Divider()
            }

            HStack(spacing: 10) {
                summaryCapsule(
                    icon: "arrow.up.circle.fill",
                    color: .blue,
                    text: L10n.tr("上传: \(plan.uploadItems.count)", "Upload: \(plan.uploadItems.count)"),
                    bold: true
                )
                summaryCapsule(
                    icon: "arrow.down.circle.fill",
                    color: .green,
                    text: L10n.tr("下载: \(plan.downloadItems.count)", "Download: \(plan.downloadItems.count)"),
                    bold: true
                )
                summaryCapsule(
                    icon: "trash.circle.fill",
                    color: .red,
                    text: L10n.tr("删除: \(plan.deleteItems.count)", "Delete: \(plan.deleteItems.count)"),
                    bold: true
                )
                summaryCapsule(
                    icon: "checkmark.circle.fill",
                    color: .secondary,
                    text: L10n.tr("跳过: \(plan.skipItems.count)", "Skip: \(plan.skipItems.count)"),
                    bold: false
                )

                Spacer()

                Text(L10n.tr("计划传输: \(L10n.formatByteCount(plan.totalTransferBytes))",
                             "Total: \(L10n.formatByteCount(plan.totalTransferBytes))"))
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)

            // Search bar + Filter pills + Select All / Deselect All
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(L10n.tr("搜索相对路径…", "Filter by relative path…"), text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.caption)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.tr("清除搜索", "Clear search"))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                .frame(maxWidth: 230)

                HStack(spacing: 4) {
                    ForEach(SyncFilterCategory.allCases) { category in
                        Button {
                            filterCategory = category
                        } label: {
                            Text(category.localizedTitle)
                                .font(.caption2.weight(filterCategory == category ? .semibold : .regular))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule().fill(filterCategory == category ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
                                )
                                .foregroundStyle(filterCategory == category ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer()

                Button(L10n.tr("全选", "Select All")) {
                    setFilteredActionableItemsEnabled(true, visibleIDs: Set(visibleItems.map(\.id)))
                }
                .controlSize(.small)
                .disabled(visibleItems.allSatisfy { $0.actionType == .skipIdentical })

                Button(L10n.tr("全不选", "Deselect All")) {
                    setFilteredActionableItemsEnabled(false, visibleIDs: Set(visibleItems.map(\.id)))
                }
                .controlSize(.small)
                .disabled(visibleItems.allSatisfy { $0.actionType == .skipIdentical })
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 8)

            Divider()

            if visibleItems.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(plan.items.isEmpty
                         ? L10n.tr("没有需要同步的项目（已被规则过滤或完全一致）", "No items to synchronize (filtered by rules or already in sync)")
                         : L10n.tr("当前筛选条件下没有匹配项", "No items match the current filter"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(visibleItems) { item in
                        HStack(spacing: 10) {
                            Toggle("", isOn: Binding(
                                get: {
                                    workspace.syncPlan?.items.first(where: { $0.id == item.id })?.isEnabled ?? false
                                },
                                set: { newValue in
                                    if let idx = workspace.syncPlan?.items.firstIndex(where: { $0.id == item.id }) {
                                        workspace.syncPlan?.items[idx].isEnabled = newValue
                                    }
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                            .accessibilityLabel(item.relativePath)
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
                                        Text(L10n.formatByteCount(item.size))
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }

                                    if let d1 = item.sourceDate {
                                        Text("\(L10n.tr("源", "Src")): \(L10n.formatDateTime(d1))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }

                                    if let d2 = item.targetDate {
                                        Text("\(L10n.tr("目标", "Dst")): \(L10n.formatDateTime(d2))")
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
            }
        } else {
            VStack(spacing: 12) {
                ProgressView()
                Text(L10n.tr("正在生成同步计划…", "Generating sync plan…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var syncFooter: some View {
        HStack {
            Button(L10n.tr("取消", "Cancel")) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            if let plan = workspace.syncPlan {
                Button(L10n.tr("复制报告", "Copy Report")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(plan.exportReportMarkdown(), forType: .string)
                    workspace.flashNotice(L10n.tr("已复制 Markdown 同步计划报告", "Copied Markdown sync report"))
                }

                Button(L10n.tr("保存报告…", "Save Report…")) {
                    saveSyncReportWithPanel(plan)
                }

                let isDryRun = syncOptions.simulateOnly || plan.simulateOnly
                Button(
                    isDryRun
                    ? L10n.tr("[试运行] 执行同步 (\(plan.activeItems.count) 项)", "[SIMULATE] Synchronize (\(plan.activeItems.count))")
                    : L10n.tr("执行同步 (\(plan.activeItems.count) 项)", "Synchronize (\(plan.activeItems.count) Items)")
                ) {
                    workspace.executeSyncPlan()
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .disabled(plan.activeItems.isEmpty || isDryRun)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
    }

    private func syncOffsetComponentsToOptions() {
        syncOptions.timeOffsetSeconds = TimeInterval(offsetHours * 3600 + offsetMinutes * 60 + offsetSeconds)
        recalculateWithSyncOptions()
    }

    private func autoDetectTimeOffset() {
        var locals: [LocalFileItem] = []
        var remotes: [FileEntry] = []
        let remoteRoot = RemotePath.normalize(workspace.remotePath)

        if let plan = workspace.syncPlan {
            for item in plan.items where !item.isDirectory {
                guard let localURL = item.localURL, let remotePath = item.remotePath else { continue }
                let localDate: Date?
                let remoteDate: Date?
                if item.actionType == .download {
                    localDate = item.targetDate
                    remoteDate = item.sourceDate
                } else {
                    localDate = item.sourceDate
                    remoteDate = item.targetDate
                }
                guard localDate != nil, remoteDate != nil else { continue }
                locals.append(LocalFileItem(
                    relativePath: item.relativePath,
                    fileURL: localURL,
                    isDirectory: false,
                    size: item.size,
                    modified: localDate
                ))
                remotes.append(FileEntry(
                    name: (item.relativePath as NSString).lastPathComponent,
                    path: remotePath,
                    isDirectory: false,
                    isSymbolicLink: false,
                    size: item.size,
                    modified: remoteDate
                ))
            }
        }

        if locals.isEmpty || remotes.isEmpty {
            let localRootURL = URL(fileURLWithPath: workspace.localPath)
            locals = workspace.localFiles
                .filter { !$0.isDirectory }
                .map {
                    LocalFileItem(
                        relativePath: $0.name,
                        fileURL: localRootURL.appendingPathComponent($0.name),
                        isDirectory: false,
                        size: $0.size,
                        modified: $0.modified
                    )
                }
            remotes = workspace.remoteFiles.filter { !$0.isDirectory }
        }

        let detected = SyncEngine.estimateTimeOffset(
            localFiles: locals,
            remoteFiles: remotes,
            remoteRoot: remoteRoot
        )
        let total = Int(detected.rounded())
        offsetHours = total / 3600
        let remainder = total % 3600
        offsetMinutes = remainder / 60
        offsetSeconds = remainder % 60
        syncOptions.timeOffsetSeconds = TimeInterval(total)
        recalculateWithSyncOptions()

        if total == 0 {
            workspace.flashNotice(L10n.tr("未检测到明显时钟偏移 (0 秒)", "No significant clock offset detected (0s)"))
        } else {
            workspace.flashNotice(L10n.tr(
                "已自动检测时间偏移：\(offsetHours)h \(offsetMinutes)m \(offsetSeconds)s",
                "Auto-detected time offset: \(offsetHours)h \(offsetMinutes)m \(offsetSeconds)s"
            ))
        }
    }

    private func recalculateWithSyncOptions() {
        store.recalculateSyncPlanWithRules()
        guard let basePlan = workspace.syncPlan else { return }

        let cutoff = syncOptions.modifiedWithinSeconds.map { Date().addingTimeInterval(-$0) }
        var updatedItems: [SyncItem] = []
        updatedItems.reserveCapacity(basePlan.items.count)

        for item in basePlan.items {
            var nextAction = item.actionType
            var nextEnabled = item.isEnabled

            // Re-evaluate timestamp comparison when both sourceDate and targetDate exist and rule == .sizeAndDate
            if basePlan.rule == .sizeAndDate,
               !item.isDirectory,
               let src = item.sourceDate,
               let dst = item.targetDate,
               item.localURL != nil,
               item.remotePath != nil {
                let localDate: Date
                let remoteDate: Date
                if item.actionType == .download {
                    localDate = dst
                    remoteDate = src
                } else {
                    localDate = src
                    remoteDate = dst
                }
                let adjustedRemote = remoteDate.addingTimeInterval(syncOptions.timeOffsetSeconds)
                let diff = localDate.timeIntervalSince(adjustedRemote)
                if abs(diff) <= 2.0 && item.actionType != .deleteLocal && item.actionType != .deleteRemote {
                    // Only treat as identical if sizes matched in the original comparison
                    if item.actionType == .skipIdentical {
                        nextAction = .skipIdentical
                        nextEnabled = false
                    }
                }
                if abs(diff) > 2.0 && item.actionType == .skipIdentical {
                    switch basePlan.direction {
                    case .localToRemote:
                        nextAction = .upload
                        nextEnabled = true
                    case .remoteToLocal:
                        nextAction = .download
                        nextEnabled = true
                    case .bidirectional:
                        nextAction = diff > 2.0 ? .upload : .download
                        nextEnabled = true
                    }
                }
            }

            if let cutoff, !item.isDirectory, nextAction == .upload || nextAction == .download {
                let relevantDate: Date? = nextAction == .download
                    ? item.sourceDate?.addingTimeInterval(syncOptions.timeOffsetSeconds)
                    : item.sourceDate
                if let relevantDate, relevantDate < cutoff {
                    nextAction = .skipIdentical
                    nextEnabled = false
                }
            }

            updatedItems.append(SyncItem(
                id: item.id,
                relativePath: item.relativePath,
                actionType: nextAction,
                localURL: item.localURL,
                remotePath: item.remotePath,
                size: item.size,
                sourceDate: item.sourceDate,
                targetDate: item.targetDate,
                isDirectory: item.isDirectory,
                isEnabled: nextEnabled
            ))
        }

        workspace.syncPlan = SyncPlan(
            direction: basePlan.direction,
            rule: basePlan.rule,
            deleteOrphans: basePlan.deleteOrphans,
            simulateOnly: syncOptions.simulateOnly,
            items: updatedItems
        )
    }

    private func setFilteredActionableItemsEnabled(_ enabled: Bool, visibleIDs: Set<UUID>) {
        guard var plan = workspace.syncPlan else { return }
        for index in plan.items.indices {
            if visibleIDs.contains(plan.items[index].id),
               plan.items[index].actionType != .skipIdentical {
                plan.items[index].isEnabled = enabled
            }
        }
        workspace.syncPlan = plan
    }

    private func saveSyncReportWithPanel(_ plan: SyncPlan) {
        let panel = NSSavePanel()
        panel.title = L10n.tr("保存同步计划报告", "Save Sync Plan Report")
        panel.nameFieldStringValue = "AetherTransfer-Sync-Report.md"
        panel.allowedContentTypes = [.plainText, .commaSeparatedText]
        panel.canCreateDirectories = true

        let formatPicker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 190, height: 26), pullsDown: false)
        formatPicker.addItems(withTitles: [
            L10n.tr("Markdown 报告 (.md)", "Markdown Report (.md)"),
            L10n.tr("CSV 表格 (.csv)", "CSV Spreadsheet (.csv)")
        ])

        let accessoryContainer = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 36))
        let label = NSTextField(labelWithString: L10n.tr("导出格式:", "Format:"))
        label.frame = NSRect(x: 10, y: 8, width: 85, height: 20)
        formatPicker.frame = NSRect(x: 100, y: 5, width: 205, height: 26)
        accessoryContainer.addSubview(label)
        accessoryContainer.addSubview(formatPicker)
        panel.accessoryView = accessoryContainer

        guard panel.runModal() == .OK, let chosenURL = panel.url else { return }
        let selectedCSV = formatPicker.indexOfSelectedItem == 1 || chosenURL.pathExtension.lowercased() == "csv"
        let targetURL: URL = {
            if selectedCSV && chosenURL.pathExtension.lowercased() != "csv" {
                return chosenURL.deletingPathExtension().appendingPathExtension("csv")
            }
            if !selectedCSV && chosenURL.pathExtension.isEmpty {
                return chosenURL.appendingPathExtension("md")
            }
            return chosenURL
        }()
        let reportText = selectedCSV ? plan.exportReportCSV() : plan.exportReportMarkdown()

        Task { @MainActor in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try reportText.write(to: targetURL, atomically: true, encoding: .utf8)
                }.value
                store.appendTranscript(
                    for: workspace.connectedProfile,
                    category: .sync,
                    message: "Saved sync report (\(selectedCSV ? "CSV" : "Markdown")): \(targetURL.lastPathComponent)"
                )
                workspace.flashNotice(L10n.tr("已保存同步报告：\(targetURL.lastPathComponent)", "Saved sync report: \(targetURL.lastPathComponent)"))
            } catch {
                workspace.error = L10n.tr("保存同步报告失败：\(error.localizedDescription)", "Failed to save sync report: \(error.localizedDescription)")
            }
        }
    }

    private func summaryCapsule(icon: String, color: Color, text: String, bold: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(text)
                .font(bold ? .caption.bold() : .caption)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(color == .secondary ? Color.primary.opacity(0.06) : color.opacity(0.11))
        .clipShape(Capsule())
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

// MARK: - Native Multi-Tab Settings View (⌘, Transmit 5 Parity)

struct SettingsView: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var store: RulesAndTranscriptStore
    @ObservedObject private var filesPrefs = FilesPreferencesStore.shared

    init(workspace: Workspace) {
        self.workspace = workspace
        self._store = ObservedObject(wrappedValue: workspace.rulesAndTranscriptStore)
    }

    var body: some View {
        TabView {
            GeneralSettingsTab(workspace: workspace, store: store)
                .tabItem {
                    Label(L10n.tr("通用", "General"), systemImage: "gearshape")
                }

            TransfersSettingsTab(workspace: workspace, store: store, filesPrefs: filesPrefs)
                .tabItem {
                    Label(L10n.tr("传输", "Transfers"), systemImage: "arrow.up.arrow.down.circle")
                }

            RulesSettingsTab(store: store)
                .tabItem {
                    Label(L10n.tr("规则", "Rules"), systemImage: "line.3.horizontal.decrease.circle")
                }

            FilesAndEditorsSettingsTab(store: store, filesPrefs: filesPrefs)
                .tabItem {
                    Label(L10n.tr("文件与编辑器", "Files & Editors"), systemImage: "doc.badge.gearshape")
                }

            UpdatesSettingsTab(workspace: workspace)
                .tabItem {
                    Label(L10n.tr("更新", "Updates"), systemImage: "arrow.down.app")
                }
        }
        .frame(width: 720, height: 560)
    }
}

// MARK: - Tab 1: General Settings

private struct GeneralSettingsTab: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var store: RulesAndTranscriptStore

    var body: some View {
        Form {
            Section(L10n.tr("语言与本地目录", "Language & Local Startup")) {
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
            }

            Section(L10n.tr("文件浏览器与交互", "Browser Display & Behavior")) {
                Toggle(
                    L10n.tr("默认显示隐藏文件 (以 . 开头)", "Show hidden files by default"),
                    isOn: Binding(
                        get: { workspace.showHidden },
                        set: { store.setDefaultShowHidden($0) }
                    )
                )

                Picker(
                    L10n.tr("默认视图模式", "Default View Mode"),
                    selection: Binding(
                        get: { workspace.viewMode },
                        set: { store.setDefaultViewMode($0) }
                    )
                ) {
                    ForEach(FileViewMode.allCases) { mode in
                        Text(mode.localizedTitle).tag(mode)
                    }
                }

                Picker(L10n.tr("默认焦点面板", "Default Focus Pane"), selection: $store.defaultFocusPane) {
                    ForEach(DefaultFocusPane.allCases) { pane in
                        Text(pane.localizedTitle).tag(pane)
                    }
                }

                Picker(L10n.tr("双击文件行为", "Double-Click File Action"), selection: $store.doubleClickAction) {
                    ForEach(DoubleClickFileAction.allCases) { action in
                        Text(action.localizedTitle).tag(action)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Tab 2: Transfers Settings

private struct TransfersSettingsTab: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var store: RulesAndTranscriptStore
    @ObservedObject var filesPrefs: FilesPreferencesStore

    var body: some View {
        Form {
            Section(L10n.tr("队列与限速", "Queue & Bandwidth")) {
                Stepper(value: $workspace.maxConcurrentTransfers, in: 1...10) {
                    HStack {
                        Text(L10n.tr("最大并发传输任务数", "Max Concurrent Transfers"))
                        Spacer()
                        Text("\(workspace.maxConcurrentTransfers)")
                            .font(.body.monospacedDigit().bold())
                    }
                }

                Picker(
                    L10n.tr("默认传输限速", "Default Bandwidth Limit"),
                    selection: Binding(
                        get: { BandwidthPreset.matching(store.defaultBandwidthLimit) },
                        set: { store.defaultBandwidthLimit = $0.bytesPerSec }
                    )
                ) {
                    ForEach(BandwidthPreset.allCases) { preset in
                        Text(preset.localizedTitle).tag(preset)
                    }
                }

                Picker(L10n.tr("默认传输模式", "Default Transfer Mode"), selection: $filesPrefs.transferMode) {
                    ForEach(TransferMode.allCases) { mode in
                        Text(mode.localizedTitle).tag(mode)
                    }
                }
            }

            Section(L10n.tr("冲突与文件属性", "Conflicts & Attributes")) {
                Picker(L10n.tr("遇到同名文件冲突时", "When File Conflict Occurs"), selection: $workspace.defaultConflictPreference) {
                    ForEach(DefaultConflictPreference.allCases) { pref in
                        Text(pref.localizedTitle).tag(pref)
                    }
                }

                Toggle(L10n.tr("保留远程与本地文件修改时间", "Preserve modification dates"), isOn: $store.preserveModificationDates)

                Toggle(L10n.tr("上传完成后默认复制文件 URL", "Copy URL after upload by default"), isOn: $store.copyURLAfterUpload)
            }

            Section(L10n.tr("完成通知与提示音", "Completion Notifications")) {
                Toggle(
                    L10n.tr("传输完成后发送 macOS 通知", "Send macOS notification when transfer completes"),
                    isOn: $filesPrefs.notifyOnTransferComplete
                )

                Toggle(
                    L10n.tr("传输完成后播放提示音", "Play sound when transfer completes"),
                    isOn: $filesPrefs.playSoundOnTransferComplete
                )
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Tab 3: Rules & ASCII Types Settings

private struct RulesSettingsTab: View {
    @ObservedObject var store: RulesAndTranscriptStore

    @State private var editingRule: SkipRule?
    @State private var newAsciiInput: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Skip Rules Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("跳过规则 (Skip Rules)", "Skip Rules"))
                        .font(.headline)
                    Text(L10n.tr("在文件夹同步或传输过滤中自动跳过匹配的文件与目录。", "Automatically exclude matching files and folders during sync and transfers."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(L10n.tr("恢复默认", "Reset Defaults")) {
                    store.resetRulesToDefaults()
                }
                .controlSize(.small)

                Button {
                    editingRule = SkipRule(
                        name: L10n.tr("自定义规则", "Custom Rule"),
                        isEnabled: true,
                        matchMode: .all,
                        scope: .transfersAndSync,
                        predicates: [RulePredicate(field: .name, op: .matchesGlob, value: "*.tmp")]
                    )
                } label: {
                    Label(L10n.tr("添加规则…", "Add Rule…"), systemImage: "plus")
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 8)

            List {
                ForEach(store.skipRules) { rule in
                    HStack(spacing: 10) {
                        Toggle("", isOn: Binding(
                            get: { rule.isEnabled },
                            set: { store.setRuleEnabled(rule.id, enabled: $0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .accessibilityLabel(rule.name)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(rule.name)
                                    .font(.system(size: 13, weight: .medium))

                                Text(rule.scope.localizedTitle)
                                    .font(.system(size: 10, weight: .medium))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                                    .foregroundStyle(Color.accentColor)

                                Text(rule.matchMode.localizedTitle)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }

                            Text(predicateSummary(for: rule))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Button {
                            editingRule = rule
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .help(L10n.tr("编辑规则", "Edit Rule"))
                        .accessibilityLabel(L10n.tr("编辑规则 \(rule.name)", "Edit Rule \(rule.name)"))

                        Button(role: .destructive) {
                            store.deleteRule(rule.id)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .help(L10n.tr("删除规则", "Delete Rule"))
                        .accessibilityLabel(L10n.tr("删除规则 \(rule.name)", "Delete Rule \(rule.name)"))
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(minHeight: 205)

            Divider()

            // ASCII File Extensions Editor
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.tr("ASCII 文本传输扩展名", "ASCII File Extensions"))
                            .font(.subheadline.bold())
                        Text(L10n.tr("以下扩展名将识别为纯文本 / ASCII 模式文件。", "Extensions treated as ASCII text files during transfers."))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    TextField("toml, env, md", text: $newAsciiInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .frame(width: 150)
                        .onSubmit { commitAsciiExtensions() }

                    Button(L10n.tr("添加", "Add")) {
                        commitAsciiExtensions()
                    }
                    .controlSize(.small)
                    .disabled(newAsciiInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button(L10n.tr("恢复默认", "Reset")) {
                        store.resetAsciiExtensionsToDefaults()
                    }
                    .controlSize(.small)
                }

                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64, maximum: 110), spacing: 6)], spacing: 6) {
                        ForEach(store.asciiExtensions, id: \.self) { ext in
                            HStack(spacing: 4) {
                                Text(".\(ext)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Button {
                                    store.removeAsciiExtension(ext)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help(L10n.tr("移除扩展名 .\(ext)", "Remove Extension .\(ext)"))
                                .accessibilityLabel(L10n.tr("移除扩展名 .\(ext)", "Remove Extension .\(ext)"))
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                        }
                    }
                }
                .frame(height: 112)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color.primary.opacity(0.02))
        }
        .sheet(item: $editingRule) { rule in
            SkipRuleEditorSheet(initialRule: rule) { saved in
                store.saveRule(saved)
            }
        }
    }

    private func commitAsciiExtensions() {
        store.addAsciiExtensions(newAsciiInput)
        newAsciiInput = ""
    }

    private func predicateSummary(for rule: SkipRule) -> String {
        rule.predicates.map { pred in
            "\(pred.field.localizedTitle) \(pred.op.localizedTitle) \"\(pred.value)\""
        }.joined(separator: " · ")
    }
}

// MARK: - SkipRule Predicate Builder Sheet

private struct SkipRuleEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var rule: SkipRule
    @State private var testFileName: String = "debug.log"
    @State private var testSizeText: String = "2048"

    let onSave: (SkipRule) -> Void

    init(initialRule: SkipRule, onSave: @escaping (SkipRule) -> Void) {
        self._rule = State(initialValue: initialRule)
        self.onSave = onSave
    }

    private var previewMatches: Bool {
        let size = RulePredicate.parseByteSize(testSizeText) ?? 0
        let baseName = (testFileName as NSString).lastPathComponent
        return rule.matches(
            name: baseName,
            relativePath: testFileName,
            isDirectory: false,
            size: size,
            modified: Date()
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.tr("编辑跳过规则", "Configure Skip Rule"))
                    .font(.headline)
                Spacer()
                Toggle(L10n.tr("启用此规则", "Enabled"), isOn: $rule.isEnabled)
                    .toggleStyle(.checkbox)
            }
            .padding(16)
            .background(.ultraThinMaterial)

            Divider()

            Form {
                Section(L10n.tr("基本信息", "Rule Details")) {
                    TextField(L10n.tr("规则名称", "Rule Name"), text: $rule.name)

                    Picker(L10n.tr("条件匹配方式", "Match Mode"), selection: $rule.matchMode) {
                        ForEach(RuleMatchMode.allCases) { mode in
                            Text(mode.localizedTitle).tag(mode)
                        }
                    }

                    Picker(L10n.tr("应用范围", "Scope"), selection: $rule.scope) {
                        ForEach(RuleScope.allCases) { scope in
                            Text(scope.localizedTitle).tag(scope)
                        }
                    }
                }

                Section {
                    ForEach(rule.predicates) { predicate in
                        predicateRow(for: predicate)
                    }

                    Button {
                        rule.predicates.append(RulePredicate(field: .name, op: .contains, value: ""))
                    } label: {
                        Label(L10n.tr("添加条件", "Add Condition"), systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                } header: {
                    Text(L10n.tr("匹配条件 (Predicates)", "Conditions"))
                }

                Section(L10n.tr("实时测试", "Rule Test Preview")) {
                    HStack(spacing: 8) {
                        TextField(L10n.tr("示例路径，如 build/app.log", "Sample path e.g. build/app.log"), text: $testFileName)
                        TextField(L10n.tr("字节大小", "Bytes"), text: $testSizeText)
                            .frame(width: 90)
                        Label(
                            previewMatches ? L10n.tr("会跳过", "Skips") : L10n.tr("不跳过", "Allows"),
                            systemImage: previewMatches ? "nosign" : "checkmark.circle"
                        )
                        .font(.caption.bold())
                        .foregroundStyle(previewMatches ? Color.orange : Color.green)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button(L10n.tr("取消", "Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(L10n.tr("保存规则", "Save Rule")) {
                    var trimmed = rule
                    trimmed.name = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.name.isEmpty {
                        trimmed.name = L10n.tr("未命名规则", "Untitled Rule")
                    }
                    onSave(trimmed)
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .disabled(rule.predicates.isEmpty || rule.predicates.allSatisfy { $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
            .background(.ultraThinMaterial)
        }
        .frame(width: 620, height: 500)
    }

    @ViewBuilder
    private func predicateRow(for predicate: RulePredicate) -> some View {
        let predicateId = predicate.id
        if let current = rule.predicates.first(where: { $0.id == predicateId }) {
            let operators = allowedOperators(for: current.field, currentOp: current.op)
            HStack(spacing: 8) {
                Picker("", selection: Binding(
                    get: { rule.predicates.first(where: { $0.id == predicateId })?.field ?? current.field },
                    set: { newField in
                        guard let idx = rule.predicates.firstIndex(where: { $0.id == predicateId }) else { return }
                        rule.predicates[idx].field = newField
                        let validOps = allowedOperators(for: newField, currentOp: nil)
                        if !validOps.contains(rule.predicates[idx].op), let fallback = validOps.first {
                            rule.predicates[idx].op = fallback
                        }
                    }
                )) {
                    ForEach(RuleField.allCases) { field in
                        Text(field.localizedTitle).tag(field)
                    }
                }
                .labelsHidden()
                .accessibilityLabel(L10n.tr("条件字段", "Predicate Field"))
                .frame(width: 115)

                Picker("", selection: Binding(
                    get: { rule.predicates.first(where: { $0.id == predicateId })?.op ?? current.op },
                    set: { newOp in
                        guard let idx = rule.predicates.firstIndex(where: { $0.id == predicateId }) else { return }
                        rule.predicates[idx].op = newOp
                    }
                )) {
                    ForEach(operators) { op in
                        Text(op.localizedTitle).tag(op)
                    }
                }
                .labelsHidden()
                .accessibilityLabel(L10n.tr("匹配操作符", "Predicate Operator"))
                .frame(width: 145)

                TextField(valuePlaceholder(for: current.field), text: Binding(
                    get: { rule.predicates.first(where: { $0.id == predicateId })?.value ?? current.value },
                    set: { newValue in
                        guard let idx = rule.predicates.firstIndex(where: { $0.id == predicateId }) else { return }
                        rule.predicates[idx].value = newValue
                    }
                ))
                .textFieldStyle(.roundedBorder)

                if current.field == .name || current.field == .fileExtension || current.field == .path {
                    Toggle("Aa", isOn: Binding(
                        get: { rule.predicates.first(where: { $0.id == predicateId })?.caseSensitive ?? current.caseSensitive },
                        set: { newCaseSensitive in
                            guard let idx = rule.predicates.firstIndex(where: { $0.id == predicateId }) else { return }
                            rule.predicates[idx].caseSensitive = newCaseSensitive
                        }
                    ))
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help(L10n.tr("区分大小写", "Case Sensitive"))
                    .accessibilityLabel(L10n.tr("区分大小写", "Case Sensitive"))
                }

                if rule.predicates.count > 1 {
                    Button {
                        rule.predicates.removeAll { $0.id == predicateId }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.tr("删除此条件", "Remove Condition"))
                    .accessibilityLabel(L10n.tr("删除此条件", "Remove Condition"))
                }
            }
        }
    }

    private func allowedOperators(for field: RuleField, currentOp: RuleOperator?) -> [RuleOperator] {
        var list: [RuleOperator]
        switch field {
        case .modifiedDate:
            list = [.greaterThan, .lessThan, .is, .isNot]
        case .sizeBytes:
            list = [.greaterThan, .lessThan, .is, .isNot]
        case .name, .fileExtension, .path:
            list = RuleOperator.allCases
        }
        if let currentOp, !list.contains(currentOp) {
            list.append(currentOp)
        }
        return list
    }

    private func valuePlaceholder(for field: RuleField) -> String {
        switch field {
        case .name: return L10n.tr("如 .DS_Store 或 *.tmp", "e.g. .DS_Store or *.tmp")
        case .fileExtension: return L10n.tr("如 log 或 swp", "e.g. log or swp")
        case .path: return L10n.tr("如 build/ 或 /.git/", "e.g. build/ or /.git/")
        case .sizeBytes: return L10n.tr("如 10 MB 或 512 KB", "e.g. 10 MB or 512 KB")
        case .modifiedDate: return L10n.tr("如 7d 或 2026-01-01", "e.g. 7d or 2026-01-01")
        }
    }
}

// MARK: - Tab 4: Files & Editors Settings

private struct FilesAndEditorsSettingsTab: View {
    @ObservedObject var store: RulesAndTranscriptStore
    @ObservedObject var filesPrefs: FilesPreferencesStore

    @State private var newExtensionInput: String = ""
    @State private var selectedMappingID: UUID?

    private var activeSessions: [ExternalEditorSession] {
        store.visibleExternalEditSessions()
    }

    private var defaultEditorDisplayName: String {
        let path = filesPrefs.defaultExternalEditorPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty {
            return L10n.tr("跟随 macOS 系统默认打开方式", "macOS System Default Application")
        }
        return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    var body: some View {
        Form {
            Section(L10n.tr("文件操作与安全", "Files & Interaction")) {
                Picker(L10n.tr("双击文件默认操作", "Double-Click File Action"), selection: $filesPrefs.doubleClickAction) {
                    ForEach(DoubleClickAction.allCases) { action in
                        Text(action.localizedTitle).tag(action)
                    }
                }

                Toggle(
                    L10n.tr("删除文件或文件夹前询问确认", "Ask before deleting files or folders"),
                    isOn: $filesPrefs.askBeforeDeleting
                )
            }

            Section(L10n.tr("默认外部编辑器", "Default External Editor")) {
                HStack(spacing: 10) {
                    Image(systemName: "pencil.and.outline")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(defaultEditorDisplayName)
                            .font(.subheadline.weight(.medium))
                        Text(filesPrefs.defaultExternalEditorPath.isEmpty
                             ? L10n.tr("支持保存后自动检测 SHA-256 变更并回传服务器", "Monitors saved changes via SHA-256 and auto-uploads to server")
                             : filesPrefs.defaultExternalEditorPath)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()

                    if !filesPrefs.defaultExternalEditorPath.isEmpty {
                        Button(L10n.tr("恢复默认", "Use Default")) {
                            filesPrefs.defaultExternalEditorPath = ""
                            store.preferredExternalEditorPath = ""
                        }
                        .controlSize(.small)
                    }

                    Button(L10n.tr("选择应用…", "Choose App…")) {
                        if let url = chooseApplicationPanel(title: L10n.tr("选择默认外部编辑器", "Choose Default External Editor")) {
                            filesPrefs.defaultExternalEditorPath = url.path
                            store.preferredExternalEditorPath = url.path
                        }
                    }
                    .controlSize(.small)
                }
            }

            Section {
                if filesPrefs.customEditors.isEmpty {
                    Text(L10n.tr("暂无按扩展名指定的编辑器映射。可在下方输入扩展名并选择 .app。", "No per-extension editor mappings yet. Enter an extension below and choose an .app."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(filesPrefs.customEditors) { mapping in
                        HStack(spacing: 10) {
                            Text(".\(mapping.fileExtension)")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.12)))
                                .foregroundStyle(Color.accentColor)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(mapping.appName)
                                    .font(.subheadline.weight(.medium))
                                Text(mapping.appPath)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer()

                            Button(role: .destructive) {
                                if selectedMappingID == mapping.id {
                                    selectedMappingID = nil
                                }
                                filesPrefs.removeCustomEditor(id: mapping.id)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .help(L10n.tr("移除映射 .\(mapping.fileExtension)", "Remove mapping .\(mapping.fileExtension)"))
                            .accessibilityLabel(L10n.tr("移除扩展名 .\(mapping.fileExtension) 编辑器映射", "Remove editor mapping for .\(mapping.fileExtension)"))
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selectedMappingID == mapping.id ? Color.accentColor.opacity(0.08) : Color.clear)
                        )
                        .onTapGesture {
                            selectedMappingID = mapping.id
                        }
                    }
                }

                HStack(spacing: 8) {
                    TextField(L10n.tr("扩展名 (如 swift, json)", "Extension (e.g. swift, json)"), text: $newExtensionInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .frame(maxWidth: 190)

                    Button {
                        addCustomEditorMapping()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .controlSize(.small)
                    .disabled(normalizedNewExtension.isEmpty)
                    .help(L10n.tr("为扩展名选择外部编辑器应用", "Add Custom Editor Mapping"))
                    .accessibilityLabel(L10n.tr("添加自定义编辑器映射", "Add Custom Editor Mapping"))

                    Button {
                        if let selectedMappingID {
                            filesPrefs.removeCustomEditor(id: selectedMappingID)
                            self.selectedMappingID = nil
                        } else if let last = filesPrefs.customEditors.last {
                            filesPrefs.removeCustomEditor(id: last.id)
                        }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .controlSize(.small)
                    .disabled(filesPrefs.customEditors.isEmpty)
                    .help(L10n.tr("移除选中映射", "Remove Selected Mapping"))
                    .accessibilityLabel(L10n.tr("移除选中的自定义编辑器映射", "Remove Selected Custom Editor Mapping"))

                    Spacer()
                }
            } header: {
                Text(L10n.tr("按扩展名自定义编辑器", "Custom Extension Editors"))
            }

            Section {
                if activeSessions.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "eye.slash")
                            .foregroundStyle(.tertiary)
                        Text(L10n.tr("当前没有正在监听的外部编辑文件会话。", "No active external editor watch sessions."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    ForEach(activeSessions) { session in
                        HStack(spacing: 10) {
                            Image(systemName: "doc.badge.clock")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.entryName)
                                    .font(.system(size: 13, weight: .medium))
                                Text("\(session.profile.name.isEmpty ? session.profile.host : session.profile.name) · \(session.remotePath)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                HStack(spacing: 8) {
                                    Text(L10n.tr("自动回传次数: \(session.uploadCount)", "Auto-uploads: \(session.uploadCount)"))
                                    if let lastUploaded = session.lastUploadedAt {
                                        Text("· \(L10n.tr("最近保存", "Last")): \(L10n.formatDateTime(lastUploaded))")
                                    }
                                }
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Button(L10n.tr("停止监听", "Stop Watching")) {
                                store.stopWatchingExternalEditSession(session)
                            }
                            .controlSize(.small)
                        }
                    }
                }
            } header: {
                HStack {
                    Text(L10n.tr("实时外部编辑监听会话 (\(activeSessions.count))", "Live External Edit Sessions (\(activeSessions.count))"))
                    Spacer()
                    if activeSessions.count > 1 {
                        Button(L10n.tr("全部停止", "Stop All")) {
                            store.stopAllExternalEditSessions()
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }
            }

            Section(L10n.tr("终端集成检测", "Terminal Integration Status")) {
                HStack(spacing: 10) {
                    Image(systemName: "terminal.fill")
                        .font(.title3)
                        .foregroundStyle(store.detectedTerminal.kind == .apexTerm ? Color.green : Color.secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(store.detectedTerminal.kind == .apexTerm
                                 ? L10n.tr("已检测到 ApexTerm", "ApexTerm Detected")
                                 : L10n.tr("使用 macOS 原生终端 (Terminal.app)", "Using Apple Terminal.app"))
                                .font(.subheadline.weight(.medium))

                            Text(store.detectedTerminal.kind == .apexTerm
                                 ? L10n.tr("优先", "Preferred")
                                 : L10n.tr("默认回退", "Fallback"))
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(store.detectedTerminal.kind == .apexTerm ? Color.green.opacity(0.15) : Color.secondary.opacity(0.15)))
                                .foregroundStyle(store.detectedTerminal.kind == .apexTerm ? Color.green : Color.secondary)
                        }

                        Text(store.detectedTerminal.appURL?.path ?? "/System/Applications/Utilities/Terminal.app")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    Button(L10n.tr("重新检测", "Refresh")) {
                        store.refreshTerminalDetection()
                    }
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            store.refreshTerminalDetection()
        }
    }

    private var normalizedNewExtension: String {
        var trimmed = newExtensionInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while trimmed.hasPrefix(".") {
            trimmed.removeFirst()
        }
        return trimmed
    }

    private func addCustomEditorMapping() {
        let ext = normalizedNewExtension
        guard !ext.isEmpty else { return }
        guard let url = chooseApplicationPanel(title: L10n.tr("为 .\(ext) 选择编辑器应用", "Choose Application for .\(ext)")) else {
            return
        }
        let appName = url.deletingPathExtension().lastPathComponent
        filesPrefs.upsertCustomEditor(fileExtension: ext, appPath: url.path, appName: appName)
        newExtensionInput = ""
    }

    private func chooseApplicationPanel(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = [.application]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        return panel.runModal() == .OK ? panel.url : nil
    }
}

// MARK: - Tab 5: Updates Settings

private struct UpdatesSettingsTab: View {
    @ObservedObject var workspace: Workspace

    private var statusSummary: String {
        switch workspace.updateState {
        case .idle:
            return L10n.tr("尚未执行手动检查", "No manual check run yet")
        case .checking:
            return L10n.tr("正在检查新版本…", "Checking for updates…")
        case .upToDate(let ver):
            return L10n.tr("已是最新版本 (v\(ver))", "Up to date (v\(ver))")
        case .available(let rel):
            return L10n.tr("发现新版本 v\(rel.version)", "New version v\(rel.version) available")
        case .downloading(let rel, _, _, let progress):
            return L10n.tr("正在下载 v\(rel.version) (\(Int(progress * 100))%)", "Downloading v\(rel.version) (\(Int(progress * 100))%)")
        case .verifying(let rel):
            return L10n.tr("正在校验 v\(rel.version) 签名…", "Verifying v\(rel.version)…")
        case .readyToInstall(let rel, _):
            return L10n.tr("v\(rel.version) 已就绪，可重启更新", "v\(rel.version) ready to install")
        case .installing(let rel):
            return L10n.tr("正在安装 v\(rel.version)…", "Installing v\(rel.version)…")
        case .failed(let msg):
            return L10n.tr("检查失败：\(msg)", "Check failed: \(msg)")
        }
    }

    var body: some View {
        Form {
            Section(L10n.tr("自动更新设置", "Automatic Updates")) {
                Toggle(L10n.tr("启动时自动在后台检查更新", "Automatically check for updates on launch"), isOn: $workspace.autoCheckForUpdates)
            }

            Section(L10n.tr("版本信息", "Version Information")) {
                LabeledContent(L10n.tr("当前版本", "Current Version")) {
                    Text("v\(AutoUpdater.currentAppVersion())")
                        .font(.body.monospacedDigit())
                }
                LabeledContent(L10n.tr("构建号", "Build Number")) {
                    Text(AutoUpdater.currentBuildNumber())
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                LabeledContent(L10n.tr("更新状态", "Status")) {
                    Text(statusSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button(L10n.tr("立即检查更新", "Check Now")) {
                        workspace.openUpdateWindowAndCheck()
                    }
                    .buttonStyle(.glassProminent)
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
    }
}
