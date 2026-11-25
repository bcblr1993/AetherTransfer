import SwiftUI
import AppKit
import AetherTransferCore

// MARK: - Activity Queue & Sanitized Transcript Drawer (Transmit 5 Parity)

struct ActivityQueueDrawer: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var store: RulesAndTranscriptStore

    @State private var selectedFilter: TransferFilter = .all
    @State private var selectedTranscriptCategory: TranscriptCategory? = nil
    @State private var transcriptSearch: String = ""
    @State private var autoScrollTranscript: Bool = true

    init(workspace: Workspace) {
        self.workspace = workspace
        self._store = ObservedObject(wrappedValue: workspace.rulesAndTranscriptStore)
    }

    private var visibleQueueFilters: [TransferFilter] {
        var filters: [TransferFilter] = [.all, .active, .failed, .completed]
        if store.count(for: .cancelled) > 0 || selectedFilter == .cancelled {
            filters.append(.cancelled)
        }
        return filters
    }

    private var filteredQueueItems: [TransferTaskItem] {
        store.filteredTransferTasks(selectedFilter)
    }

    private var failedCount: Int {
        store.count(for: .failed)
    }

    private var filteredTranscriptEntries: [TranscriptEntry] {
        store.filteredTranscriptEntries(category: selectedTranscriptCategory, search: transcriptSearch)
    }

    var body: some View {
        VStack(spacing: 0) {
            drawerHeaderBar
            Divider()
            if store.activeDrawerTab == .queue {
                queueFilterStrip
                Divider()
                queueContent
            } else {
                transcriptFilterStrip
                Divider()
                transcriptContent
            }
        }
    }

    // MARK: - Top Header Bar

    private var drawerHeaderBar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $store.activeDrawerTab) {
                ForEach(ActivityDrawerTab.allCases) { tab in
                    Text(tab.localizedTitle).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(L10n.tr("活动面板视图", "Activity Drawer Mode"))
            .frame(width: 210)

            if store.activeDrawerTab == .queue {
                queueHeaderMetricsAndActions
            } else {
                transcriptHeaderMetricsAndActions
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var queueHeaderMetricsAndActions: some View {
        if workspace.activeTransferCount > 0 {
            Text(L10n.tr("\(workspace.activeTransferCount) 个进行中", "\(workspace.activeTransferCount) Active"))
                .font(.caption.bold())
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                .foregroundStyle(Color.accentColor)

            Text("⚡️ \(workspace.overallTransferSpeed)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }

        Spacer()

        Toggle(isOn: $store.copyURLAfterUpload) {
            Label(L10n.tr("上传后复制链接", "Copy URL after upload"), systemImage: "link")
                .font(.caption)
        }
        .toggleStyle(.checkbox)
        .help(L10n.tr("上传完成后自动将文件 URL 复制到剪贴板", "Automatically copy remote file URL after upload completes"))

        Menu {
            Button(L10n.tr("不限速", "Unlimited")) { workspace.setSpeedLimit(nil) }
            Divider()
            Button("500 KB/s") { workspace.setSpeedLimit(500 * 1024) }
            Button("1 MB/s") { workspace.setSpeedLimit(1024 * 1024) }
            Button("2 MB/s") { workspace.setSpeedLimit(2 * 1024 * 1024) }
            Button("5 MB/s") { workspace.setSpeedLimit(5 * 1024 * 1024) }
            Button("10 MB/s") { workspace.setSpeedLimit(10 * 1024 * 1024) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: workspace.speedLimit == nil ? "gauge.with.needle" : "gauge.with.needle.fill")
                Text(workspace.speedLimitText)
            }
            .font(.caption)
        }
        .menuStyle(.borderlessButton)

        Button {
            workspace.toggleQueuePause()
        } label: {
            Label(
                workspace.isQueuePaused ? L10n.tr("继续", "Resume") : L10n.tr("暂停", "Pause"),
                systemImage: workspace.isQueuePaused ? "play.fill" : "pause.fill"
            )
            .font(.caption)
        }
        .buttonStyle(.borderless)
        .disabled(workspace.activeTransferCount == 0 && !workspace.isQueuePaused)
        .help(workspace.isQueuePaused ? L10n.tr("恢复传输队列", "Resume Queue") : L10n.tr("暂停传输队列", "Pause Queue"))

        Button {
            _ = store.retryAllFailedTransfers()
        } label: {
            Label(
                failedCount > 0
                    ? L10n.tr("重试失败 (\(failedCount))", "Retry All Failed (\(failedCount))")
                    : L10n.tr("重试失败", "Retry All Failed"),
                systemImage: "arrow.clockwise"
            )
            .font(.caption)
        }
        .buttonStyle(.borderless)
        .disabled(failedCount == 0)
        .help(L10n.tr("重新入队所有失败传输", "Retry all failed transfers"))

        Button(L10n.tr("清除已完成", "Clear Completed")) {
            workspace.clearCompletedTransfers()
        }
        .font(.caption)
        .buttonStyle(.borderless)
        .disabled(workspace.transferTasks.allSatisfy { $0.state != .completed })

        Button(L10n.tr("全部取消", "Cancel All")) {
            workspace.cancelAllTransfers()
        }
        .font(.caption)
        .buttonStyle(.borderless)
        .disabled(workspace.activeTransferCount == 0)
    }

    @ViewBuilder
    private var transcriptHeaderMetricsAndActions: some View {
        HStack(spacing: 4) {
            Image(systemName: "lock.shield.fill")
                .font(.caption2)
                .foregroundStyle(.green)
            Text(L10n.tr("已脱敏 · \(filteredTranscriptEntries.count) 条", "Sanitized · \(filteredTranscriptEntries.count)"))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.green.opacity(0.12)))

        Spacer()

        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField(L10n.tr("过滤日志…", "Filter transcript…"), text: $transcriptSearch)
                .textFieldStyle(.plain)
                .font(.caption)
                .frame(width: 150)
            if !transcriptSearch.isEmpty {
                Button {
                    transcriptSearch = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L10n.tr("清除搜索", "Clear Search"))
                .accessibilityLabel(L10n.tr("清除搜索", "Clear Search"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))

        Toggle(L10n.tr("自动滚动", "Auto-scroll"), isOn: $autoScrollTranscript)
            .toggleStyle(.checkbox)
            .font(.caption)

        Button {
            store.copyTranscript(category: selectedTranscriptCategory, search: transcriptSearch)
        } label: {
            Label(L10n.tr("复制日志", "Copy Log"), systemImage: "doc.on.doc")
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .disabled(filteredTranscriptEntries.isEmpty)

        Button {
            store.exportSanitizedTranscriptWithSavePanel(category: selectedTranscriptCategory, search: transcriptSearch)
        } label: {
            Label(L10n.tr("导出脱敏日志…", "Export Sanitized Log…"), systemImage: "square.and.arrow.up")
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .disabled(filteredTranscriptEntries.isEmpty)

        Button(L10n.tr("清空", "Clear")) {
            store.clearTranscript()
        }
        .font(.caption)
        .buttonStyle(.borderless)
        .disabled(store.transcriptEntries.isEmpty)
    }

    // MARK: - Queue Filter Strip & Rows

    private var queueFilterStrip: some View {
        HStack(spacing: 6) {
            ForEach(visibleQueueFilters) { filter in
                let count = store.count(for: filter)
                let isSelected = selectedFilter == filter
                Button {
                    selectedFilter = filter
                } label: {
                    HStack(spacing: 4) {
                        Text(filter.localizedTitle)
                        if count > 0 || filter == .all {
                            Text("\(count)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                        }
                    }
                    .font(.caption)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(isSelected ? Color.accentColor : Color.primary.opacity(0.06))
                    )
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            if let lastURL = store.lastUploadedURLString, !lastURL.isEmpty {
                Button {
                    store.copyLastUploadedURL()
                } label: {
                    Label(L10n.tr("复制最近上传链接", "Copy Last Uploaded URL"), systemImage: "link.badge.plus")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .help(lastURL)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.02))
    }

    @ViewBuilder
    private var queueContent: some View {
        let items = filteredQueueItems
        if items.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: selectedFilter == .failed ? "checkmark.circle" : "tray")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                Text(emptyQueueMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(items) { item in
                TransferQueueRow(
                    item: item,
                    resolvedURL: store.resolvedURLString(for: item),
                    onMoveToTop: { store.moveQueuedTransferToTop(item.id) },
                    onCancel: { workspace.cancelTransfer(item.id) },
                    onRetry: { workspace.retryTransfer(item.id) },
                    onCopyURL: { store.copyUploadedURL(for: item) }
                )
            }
            .listStyle(.plain)
        }
    }

    private var emptyQueueMessage: String {
        switch selectedFilter {
        case .all: return L10n.tr("无传输活动", "No Active Transfers")
        case .active: return L10n.tr("当前没有正在进行的传输", "No Active or Queued Transfers")
        case .failed: return L10n.tr("没有失败的传输任务", "No Failed Transfers")
        case .completed: return L10n.tr("暂无已完成传输", "No Completed Transfers")
        case .cancelled: return L10n.tr("暂无已取消传输", "No Cancelled Transfers")
        }
    }

    // MARK: - Transcript Filter Strip & Log List

    private var transcriptFilterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                transcriptCategoryPill(
                    title: L10n.tr("全部", "All"),
                    symbol: "text.alignleft",
                    count: store.transcriptEntries.count,
                    isSelected: selectedTranscriptCategory == nil
                ) {
                    selectedTranscriptCategory = nil
                }

                ForEach(TranscriptCategory.allCases) { category in
                    let count = store.transcriptEntries.filter { $0.category == category }.count
                    transcriptCategoryPill(
                        title: category.localizedTitle,
                        symbol: category.symbolName,
                        count: count,
                        isSelected: selectedTranscriptCategory == category
                    ) {
                        selectedTranscriptCategory = category
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
        }
        .background(Color.primary.opacity(0.02))
    }

    private func transcriptCategoryPill(
        title: String,
        symbol: String,
        count: Int,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.caption2)
                Text(title)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                }
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(isSelected ? Color.accentColor : Color.primary.opacity(0.06))
            )
            .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var transcriptContent: some View {
        let entries = filteredTranscriptEntries
        if entries.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                Text(store.transcriptEntries.isEmpty
                     ? L10n.tr("暂无传输或协议日志（凭据与签名将自动脱敏）", "No transcript entries yet (secrets are automatically redacted)")
                     : L10n.tr("没有匹配当前筛选条件的日志条目", "No transcript entries match the current filter"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(entries) { entry in
                            TranscriptEntryRow(entry: entry)
                                .id(entry.id)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("transcript-bottom-anchor")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .onChange(of: entries.count) {
                    if autoScrollTranscript {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("transcript-bottom-anchor", anchor: .bottom)
                        }
                    }
                }
                .onAppear {
                    if autoScrollTranscript {
                        proxy.scrollTo("transcript-bottom-anchor", anchor: .bottom)
                    }
                }
            }
        }
    }
}

// MARK: - Transfer Queue Row

private struct TransferQueueRow: View {
    let item: TransferTaskItem
    let resolvedURL: String?
    let onMoveToTop: () -> Void
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onCopyURL: () -> Void

    private var effectiveETA: Double? {
        if let eta = item.etaSeconds { return eta }
        if item.speedBytesPerSec > 0 && item.totalBytes > item.completedBytes {
            return Double(item.totalBytes - item.completedBytes) / item.speedBytesPerSec
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .foregroundStyle(item.direction == .upload ? Color.blue : Color.orange)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                if item.state == .inProgress {
                    HStack(spacing: 8) {
                        ProgressView(value: item.progress)
                            .frame(maxWidth: 165)

                        Text("\(Int((item.progress * 100).rounded()))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)

                        if item.totalBytes > 0 {
                            Text("\(L10n.formatByteCount(item.completedBytes)) / \(L10n.formatByteCount(item.totalBytes))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        if item.speedBytesPerSec > 0 {
                            Text(TransferQueueManager.formatSpeed(item.speedBytesPerSec))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        if let eta = effectiveETA {
                            Text(L10n.tr("剩余 \(TransferQueueManager.formatETA(eta))", "ETA \(TransferQueueManager.formatETA(eta))"))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let err = item.error {
                    Text(TranscriptRedactor.sanitize(err))
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(item.state.localizedTitle)
                .font(.caption)
                .foregroundStyle(stateColor)

            if item.state == .queued {
                Button(action: onMoveToTop) {
                    Image(systemName: "arrow.up.to.line")
                }
                .buttonStyle(.borderless)
                .help(L10n.tr("移至队列顶部", "Move to Top"))
                .accessibilityLabel(L10n.tr("移至队列顶部", "Move to Top"))
            }

            if item.state == .inProgress || item.state == .queued {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help(L10n.tr("取消传输", "Cancel Transfer"))
                .accessibilityLabel(L10n.tr("取消传输", "Cancel Transfer"))
            } else if item.state == .failed || item.state == .cancelled {
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise.circle")
                }
                .buttonStyle(.borderless)
                .help(L10n.tr("重试传输", "Retry Transfer"))
                .accessibilityLabel(L10n.tr("重试传输", "Retry Transfer"))
            } else if item.state == .completed, item.direction == .upload, resolvedURL != nil {
                Button(action: onCopyURL) {
                    Image(systemName: "link")
                }
                .buttonStyle(.borderless)
                .help(L10n.tr("复制文件链接", "Copy Uploaded URL"))
                .accessibilityLabel(L10n.tr("复制文件链接", "Copy Uploaded URL"))
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if item.state == .queued {
                Button(L10n.tr("移至队列顶部", "Move to Top"), action: onMoveToTop)
            }
            if item.state == .inProgress || item.state == .queued {
                Button(L10n.tr("取消传输", "Cancel Transfer"), action: onCancel)
            }
            if item.state == .failed || item.state == .cancelled {
                Button(L10n.tr("重试传输", "Retry Transfer"), action: onRetry)
            }
            if item.state == .completed, item.direction == .upload, resolvedURL != nil {
                Button(L10n.tr("复制文件链接", "Copy Uploaded URL"), action: onCopyURL)
            }
        }
    }

    private var stateColor: Color {
        switch item.state {
        case .completed: return .green
        case .failed: return .red
        case .inProgress: return .accentColor
        case .queued, .cancelled: return .secondary
        }
    }
}

// MARK: - Transcript Entry Row

private struct TranscriptEntryRow: View {
    let entry: TranscriptEntry

    private var sanitizedMessage: String {
        TranscriptRedactor.sanitize(entry.message)
    }

    private var categoryColor: Color {
        switch entry.category {
        case .connect: return .blue
        case .command: return .purple
        case .response: return .teal
        case .transfer: return .green
        case .sync: return .indigo
        case .error: return .red
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(L10n.formatTimestamp(entry.timestamp))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)

            Label(entry.category.localizedTitle, systemImage: entry.category.symbolName)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(categoryColor.opacity(0.14)))
                .foregroundStyle(categoryColor)

            if !entry.connectionName.isEmpty || !entry.protocolTitle.isEmpty {
                let conn = entry.connectionName.isEmpty ? "App" : entry.connectionName
                Text("[\(conn) · \(entry.protocolTitle)]")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(sanitizedMessage)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(entry.category == .error ? Color.red : Color.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Menu Bar Quick Upload Droplet (Transmit Droplet Parity)

struct MenuBarDropletView: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var store: RulesAndTranscriptStore
    @State private var targetedProfileId: UUID?
    @State private var copiedURLNotice = false

    init(workspace: Workspace) {
        self.workspace = workspace
        self._store = ObservedObject(wrappedValue: workspace.rulesAndTranscriptStore)
    }

    private var activeTransfers: [TransferTaskItem] {
        store.filteredTransferTasks(.active)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("AetherTransfer", systemImage: "bolt.horizontal.circle.fill")
                    .font(.headline)
                Spacer()
                if workspace.activeTransferCount > 0 {
                    Text("\(workspace.activeTransferCount) · \(workspace.overallTransferSpeed)")
                        .font(.caption2.monospacedDigit().bold())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                        .foregroundStyle(Color.accentColor)
                }
            }

            if !activeTransfers.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("正在传输 (\(activeTransfers.count))", "Active Transfers (\(activeTransfers.count))"))
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)

                    ForEach(activeTransfers.prefix(3)) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Image(systemName: item.direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(item.direction == .upload ? Color.blue : Color.orange)
                                Text(item.name)
                                    .font(.caption)
                                    .lineLimit(1)
                                Spacer()
                                if item.state == .inProgress {
                                    Text("\(Int((item.progress * 100).rounded()))%")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text(item.state.localizedTitle)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            ProgressView(value: item.state == .inProgress ? item.progress : 0)
                                .progressViewStyle(.linear)
                            if item.state == .inProgress && item.speedBytesPerSec > 0 {
                                HStack {
                                    Text(TransferQueueManager.formatSpeed(item.speedBytesPerSec))
                                    Spacer()
                                    if let eta = item.etaSeconds {
                                        Text(L10n.tr("剩余 \(TransferQueueManager.formatETA(eta))", "ETA \(TransferQueueManager.formatETA(eta))"))
                                    }
                                }
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if activeTransfers.count > 3 {
                        Text(L10n.tr("另有 \(activeTransfers.count - 3) 项在队列中…", "+\(activeTransfers.count - 3) more in queue…"))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            }

            if let lastURL = store.lastUploadedURLString, !lastURL.isEmpty {
                Button {
                    store.copyLastUploadedURL()
                    copiedURLNotice = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copiedURLNotice = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: copiedURLNotice ? "checkmark.circle.fill" : "link.circle.fill")
                            .foregroundStyle(copiedURLNotice ? .green : Color.accentColor)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(copiedURLNotice
                                 ? L10n.tr("已复制最近上传链接", "Copied Last Uploaded URL")
                                 : L10n.tr("复制最近上传链接", "Copy Last Uploaded URL"))
                                .font(.caption.bold())
                            Text(lastURL)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                    }
                    .padding(7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }

            Text(L10n.tr("将访达文件拖拽至下方服务器即可后台闪电上传：",
                         "Drop files from Finder onto any server below for instant upload:"))
                .font(.caption2)
                .foregroundStyle(.secondary)

            if workspace.profiles.isEmpty {
                Text(L10n.tr("暂无已保存的服务器书签", "No saved server bookmarks yet"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(workspace.profiles) { profile in
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.up.doc.fill")
                                    .foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(profile.name.isEmpty ? profile.host : profile.name)
                                        .font(.caption.bold())
                                        .lineLimit(1)
                                    Text("\(profile.protocolKind.title) · \(profile.initialPath)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()

                                Button {
                                    store.exportDropletWithSavePanel(for: profile)
                                } label: {
                                    Image(systemName: "square.and.arrow.down.on.square")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderless)
                                .help(L10n.tr("导出为独立 Droplet 应用…", "Export Droplet…"))
                                .accessibilityLabel(L10n.tr("导出为独立 Droplet 应用", "Export Droplet"))

                                Button(L10n.tr("选择文件", "Upload…")) {
                                    let panel = NSOpenPanel()
                                    panel.canChooseFiles = true
                                    panel.canChooseDirectories = false
                                    panel.allowsMultipleSelection = true
                                    if panel.runModal() == .OK {
                                        workspace.uploadDroppedURLs(panel.urls, to: profile)
                                    }
                                }
                                .controlSize(.mini)
                            }
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(targetedProfileId == profile.id ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.05))
                            )
                            .contextMenu {
                                Button(L10n.tr("导出为独立 Droplet 应用…", "Export Droplet…")) {
                                    store.exportDropletWithSavePanel(for: profile)
                                }
                            }
                            .dropDestination(for: URL.self) { urls, _ in
                                workspace.uploadDroppedURLs(urls, to: profile)
                                return true
                            } isTargeted: { targeted in
                                targetedProfileId = targeted ? profile.id : (targetedProfileId == profile.id ? nil : targetedProfileId)
                            }
                        }
                    }
                }
                .frame(maxHeight: 195)
            }

            Divider()

            HStack(spacing: 8) {
                Button(L10n.tr("打开主窗口", "Open App")) {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
                }
                .controlSize(.small)

                if workspace.profiles.count == 1, let onlyProfile = workspace.profiles.first {
                    Button(L10n.tr("导出 Droplet…", "Export Droplet…")) {
                        store.exportDropletWithSavePanel(for: onlyProfile)
                    }
                    .controlSize(.small)
                } else if !workspace.profiles.isEmpty {
                    Menu(L10n.tr("导出 Droplet…", "Export Droplet…")) {
                        ForEach(workspace.profiles) { profile in
                            Button(profile.name.isEmpty ? profile.host : profile.name) {
                                store.exportDropletWithSavePanel(for: profile)
                            }
                        }
                    }
                    .controlSize(.small)
                }

                Spacer()

                Button(L10n.tr("退出", "Quit")) {
                    NSApp.terminate(nil)
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 340)
    }
}
