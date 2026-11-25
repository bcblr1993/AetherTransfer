import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import AetherTransferCore

// MARK: - Settings & Drawer Preferences Models

enum ActivityDrawerTab: String, CaseIterable, Identifiable, Sendable {
    case queue
    case transcript

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .queue: return L10n.tr("传输队列", "Transfers Queue")
        case .transcript: return L10n.tr("传输日志", "Transcript")
        }
    }
}

enum DefaultFocusPane: String, CaseIterable, Identifiable, Sendable {
    case local
    case remoteWhenConnected
    case lastActive

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .local: return L10n.tr("始终聚焦本地面板", "Always Focus Local Pane")
        case .remoteWhenConnected: return L10n.tr("连接后聚焦远程面板", "Focus Remote Pane on Connect")
        case .lastActive: return L10n.tr("记住上次活动面板", "Remember Last Active Pane")
        }
    }
}

enum DoubleClickFileAction: String, CaseIterable, Identifiable, Sendable {
    case openOrEdit
    case transfer
    case externalEditor

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .openOrEdit: return L10n.tr("打开文件夹 / 内置编辑文本", "Open Folder / Built-in Text Edit")
        case .transfer: return L10n.tr("直接传输 (上传/下载)", "Transfer Immediately")
        case .externalEditor: return L10n.tr("在外部编辑器中打开", "Open in External Editor")
        }
    }
}

enum BandwidthPreset: Int64, CaseIterable, Identifiable, Sendable {
    case unlimited = 0
    case kbps500 = 512_000
    case mbps1 = 1_048_576
    case mbps2 = 2_097_152
    case mbps5 = 5_242_880
    case mbps10 = 10_485_760
    case mbps25 = 26_214_400
    case mbps50 = 52_428_800

    var id: Int64 { rawValue }

    var bytesPerSec: Int64? {
        rawValue == 0 ? nil : rawValue
    }

    var localizedTitle: String {
        switch self {
        case .unlimited: return L10n.tr("不限速", "Unlimited")
        case .kbps500: return "500 KB/s"
        case .mbps1: return "1 MB/s"
        case .mbps2: return "2 MB/s"
        case .mbps5: return "5 MB/s"
        case .mbps10: return "10 MB/s"
        case .mbps25: return "25 MB/s"
        case .mbps50: return "50 MB/s"
        }
    }

    static func matching(_ bytesPerSec: Int64?) -> BandwidthPreset {
        guard let bytesPerSec, bytesPerSec > 0 else { return .unlimited }
        return BandwidthPreset(rawValue: bytesPerSec) ?? .unlimited
    }
}

// MARK: - Shared Store Attached per Workspace

@MainActor
private final class RulesAndTranscriptRegistry {
    private final class WeakBox {
        weak var workspace: Workspace?
        let store: RulesAndTranscriptStore

        init(workspace: Workspace, store: RulesAndTranscriptStore) {
            self.workspace = workspace
            self.store = store
        }
    }

    static let shared = RulesAndTranscriptRegistry()
    private var entries: [ObjectIdentifier: WeakBox] = [:]

    func store(for workspace: Workspace) -> RulesAndTranscriptStore {
        let key = ObjectIdentifier(workspace)
        if let existing = entries[key], existing.workspace === workspace {
            return existing.store
        }
        entries = entries.filter { $0.value.workspace != nil }
        let store = RulesAndTranscriptStore(workspace: workspace)
        entries[key] = WeakBox(workspace: workspace, store: store)
        return store
    }
}

@MainActor
final class RulesAndTranscriptStore: ObservableObject {
    private enum DefaultsKey {
        static let copyURLAfterUpload = "com.aethernative.AetherTransfer.copyURLAfterUpload"
        static let preserveModificationDates = "com.aethernative.AetherTransfer.preserveModificationDates"
        static let defaultShowHidden = "com.aethernative.AetherTransfer.defaultShowHidden"
        static let defaultViewMode = "com.aethernative.AetherTransfer.defaultViewMode"
        static let defaultFocusPane = "com.aethernative.AetherTransfer.defaultFocusPane"
        static let doubleClickBehavior = "com.aethernative.AetherTransfer.doubleClickBehavior"
        static let defaultBandwidthLimit = "com.aethernative.AetherTransfer.defaultBandwidthLimit"
        static let preferredExternalEditorPath = "com.aethernative.AetherTransfer.preferredExternalEditorPath"
    }

    weak var workspace: Workspace?

    let transcriptLogger = TranscriptLogger(maxEntries: 1000)
    let rulesStore = FileRulesStore()

    @Published private(set) var transcriptEntries: [TranscriptEntry] = []
    @Published var skipRules: [SkipRule] = []
    @Published var asciiExtensions: [String] = []

    @Published var copyURLAfterUpload: Bool {
        didSet {
            UserDefaults.standard.set(copyURLAfterUpload, forKey: DefaultsKey.copyURLAfterUpload)
        }
    }
    @Published var preserveModificationDates: Bool {
        didSet {
            UserDefaults.standard.set(preserveModificationDates, forKey: DefaultsKey.preserveModificationDates)
        }
    }
    @Published var defaultFocusPane: DefaultFocusPane {
        didSet {
            UserDefaults.standard.set(defaultFocusPane.rawValue, forKey: DefaultsKey.defaultFocusPane)
        }
    }
    @Published var doubleClickAction: DoubleClickFileAction {
        didSet {
            UserDefaults.standard.set(doubleClickAction.rawValue, forKey: DefaultsKey.doubleClickBehavior)
        }
    }
    @Published var defaultBandwidthLimit: Int64? {
        didSet {
            UserDefaults.standard.set(Int(defaultBandwidthLimit ?? 0), forKey: DefaultsKey.defaultBandwidthLimit)
            workspace?.setSpeedLimit(defaultBandwidthLimit)
        }
    }
    @Published var preferredExternalEditorPath: String {
        didSet {
            UserDefaults.standard.set(preferredExternalEditorPath, forKey: DefaultsKey.preferredExternalEditorPath)
        }
    }

    @Published var lastUploadedURLString: String?
    @Published private(set) var detectedTerminal: (kind: TerminalAppKind, appURL: URL?)

    // Queue & External Edit & Sync helpers
    @Published private var prioritizedQueuedIDs: [UUID] = []
    @Published private var stoppedExternalEditSessionIDs: Set<UUID> = []

    private var knownTransferStates: [UUID: TransferState] = [:]
    private var resolvedUploadURLs: [UUID: String] = [:]
    private var previousConnectedProfile: ServerProfile?
    private var previousRemotePath: String = "/"
    private var previousLoadingRemote: Bool = false
    private var baseSyncPlan: SyncPlan?
    private var lastAppliedFilteredItemIDs: [UUID]?
    private var cancellables: Set<AnyCancellable> = []
    private var transcriptRefreshScheduled = false

    init(workspace: Workspace) {
        self.workspace = workspace

        let defaults = UserDefaults.standard
        self.copyURLAfterUpload = defaults.bool(forKey: DefaultsKey.copyURLAfterUpload)
        self.preserveModificationDates = defaults.object(forKey: DefaultsKey.preserveModificationDates) as? Bool ?? true

        let focusRaw = defaults.string(forKey: DefaultsKey.defaultFocusPane) ?? ""
        self.defaultFocusPane = DefaultFocusPane(rawValue: focusRaw) ?? .local

        let dblRaw = defaults.string(forKey: DefaultsKey.doubleClickBehavior) ?? ""
        self.doubleClickAction = DoubleClickFileAction(rawValue: dblRaw) ?? .openOrEdit

        if let rawLimit = (defaults.object(forKey: DefaultsKey.defaultBandwidthLimit) as? NSNumber)?.int64Value, rawLimit > 0 {
            self.defaultBandwidthLimit = rawLimit
            workspace.setSpeedLimit(rawLimit)
        } else {
            self.defaultBandwidthLimit = nil
        }

        self.preferredExternalEditorPath = defaults.string(forKey: DefaultsKey.preferredExternalEditorPath) ?? ""

        if defaults.object(forKey: DefaultsKey.defaultShowHidden) != nil {
            let savedHidden = defaults.bool(forKey: DefaultsKey.defaultShowHidden)
            if workspace.showHidden != savedHidden {
                workspace.showHidden = savedHidden
            }
        }
        if let rawMode = defaults.string(forKey: DefaultsKey.defaultViewMode),
           let savedMode = FileViewMode(rawValue: rawMode),
           workspace.viewMode != savedMode {
            workspace.viewMode = savedMode
        }

        self.skipRules = rulesStore.loadRules()
        self.asciiExtensions = rulesStore.loadAsciiExtensions()
        self.detectedTerminal = TerminalIntegration.detectPreferredTerminal()

        self.previousConnectedProfile = workspace.connectedProfile
        self.previousRemotePath = workspace.remotePath
        self.previousLoadingRemote = workspace.loadingRemote
        self.baseSyncPlan = workspace.syncPlan
        for item in workspace.transferTasks {
            self.knownTransferStates[item.id] = item.state
            if let url = item.remoteURLString, !url.isEmpty {
                self.resolvedUploadURLs[item.id] = url
                if item.state == .completed && item.direction == .upload {
                    self.lastUploadedURLString = url
                }
            }
        }

        transcriptLogger.onEntriesUpdated = { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleTranscriptRefresh()
            }
        }
        self.transcriptEntries = transcriptLogger.entries()

        bindWorkspaceObservers(workspace)
    }

    private func scheduleTranscriptRefresh() {
        guard !transcriptRefreshScheduled else { return }
        transcriptRefreshScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.transcriptRefreshScheduled = false
            self.transcriptEntries = self.transcriptLogger.entries()
        }
    }

    private func bindWorkspaceObservers(_ workspace: Workspace) {
        workspace.$connectedProfile
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newProfile in
                self?.handleConnectedProfileChange(newProfile)
            }
            .store(in: &cancellables)

        workspace.$remotePath
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newPath in
                guard let self, let profile = self.workspace?.connectedProfile else { return }
                guard newPath != self.previousRemotePath else { return }
                self.previousRemotePath = newPath
                self.appendTranscript(
                    for: profile,
                    category: .command,
                    message: "LIST \(newPath)"
                )
            }
            .store(in: &cancellables)

        workspace.$loadingRemote
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isLoading in
                guard let self, let workspace = self.workspace else { return }
                let wasLoading = self.previousLoadingRemote
                self.previousLoadingRemote = isLoading
                if wasLoading && !isLoading, let profile = workspace.connectedProfile, workspace.error == nil {
                    self.appendTranscript(
                        for: profile,
                        category: .response,
                        message: "Listed \(workspace.remoteFiles.count) item(s) in \(workspace.remotePath)"
                    )
                }
            }
            .store(in: &cancellables)

        workspace.$error
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newError in
                guard let self, let err = newError, !err.isEmpty else { return }
                self.appendTranscript(
                    for: self.workspace?.connectedProfile,
                    category: .error,
                    message: err
                )
            }
            .store(in: &cancellables)

        workspace.$transferTasks
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tasks in
                self?.handleTransferTasksUpdate(tasks)
            }
            .store(in: &cancellables)

        workspace.$syncPlan
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] plan in
                self?.handleExternalSyncPlanUpdate(plan)
            }
            .store(in: &cancellables)

        workspace.$activeExternalEditSessions
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                guard let self else { return }
                let activeIDs = Set(sessions.map(\.id))
                self.stoppedExternalEditSessionIDs = self.stoppedExternalEditSessionIDs.intersection(activeIDs)
            }
            .store(in: &cancellables)
    }

    private func handleConnectedProfileChange(_ newProfile: ServerProfile?) {
        if let profile = newProfile {
            let previous = previousConnectedProfile
            if previous?.id != profile.id || previous?.host != profile.host || previous?.port != profile.port {
                let endpoint = profile.host.isEmpty ? profile.name : "\(profile.host):\(profile.port)"
                appendTranscript(
                    for: profile,
                    category: .connect,
                    message: "Connected (\(profile.protocolKind.title)) user=\(profile.username) host=\(endpoint) path=\(profile.initialPath)"
                )
            }
            previousRemotePath = workspace?.remotePath ?? profile.initialPath
        } else if let old = previousConnectedProfile {
            appendTranscript(
                for: old,
                category: .connect,
                message: "Disconnected from \(old.name.isEmpty ? old.host : old.name)"
            )
        }
        previousConnectedProfile = newProfile
    }

    private func handleTransferTasksUpdate(_ tasks: [TransferTaskItem]) {
        let activeQueuedIDs = Set(tasks.filter { $0.state == .queued }.map(\.id))
        prioritizedQueuedIDs.removeAll { !activeQueuedIDs.contains($0) }

        for item in tasks {
            let previousState = knownTransferStates[item.id]
            if previousState == item.state { continue }
            knownTransferStates[item.id] = item.state

            if let explicitURL = item.remoteURLString, !explicitURL.isEmpty {
                resolvedUploadURLs[item.id] = explicitURL
            }

            let profile = workspace?.connectedProfile
            switch item.state {
            case .queued:
                let verb = previousState == nil ? "Queued" : "Re-queued"
                appendTranscript(
                    for: profile,
                    category: .transfer,
                    message: "\(verb) \(item.direction == .upload ? "upload" : "download"): \(item.name)"
                )
            case .inProgress:
                appendTranscript(
                    for: profile,
                    category: .transfer,
                    message: "Transferring \(item.direction == .upload ? "upload" : "download"): \(item.name)"
                )
            case .completed:
                let sizeStr = item.totalBytes > 0 ? " (\(L10n.formatByteCount(item.totalBytes)))" : ""
                appendTranscript(
                    for: profile,
                    category: .transfer,
                    message: "Completed \(item.direction == .upload ? "upload" : "download"): \(item.name)\(sizeStr)"
                )
                handleCompletedTransfer(item)
            case .failed:
                appendTranscript(
                    for: profile,
                    category: .error,
                    message: "Transfer failed [\(item.name)]: \(item.error ?? "Unknown error")"
                )
            case .cancelled:
                appendTranscript(
                    for: profile,
                    category: .transfer,
                    message: "Transfer cancelled: \(item.name)"
                )
            }
        }
    }

    private func handleCompletedTransfer(_ item: TransferTaskItem) {
        guard item.direction == .upload else { return }
        guard let urlString = resolveUploadedURLString(for: item) else { return }
        resolvedUploadURLs[item.id] = urlString
        lastUploadedURLString = urlString

        if item.copyURLOnComplete || copyURLAfterUpload {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(urlString, forType: .string)
            appendTranscript(
                for: workspace?.connectedProfile,
                category: .transfer,
                message: "Copied uploaded URL: \(urlString)"
            )
            workspace?.flashNotice(L10n.tr("上传完成，已复制链接到剪贴板", "Upload finished; copied URL to clipboard"))
        }
    }

    private func resolveUploadedURLString(for item: TransferTaskItem) -> String? {
        if let explicit = item.remoteURLString, !explicit.isEmpty {
            return TranscriptRedactor.sanitize(explicit)
        }
        if let cached = resolvedUploadURLs[item.id], !cached.isEmpty {
            return cached
        }
        guard let workspace, let profile = workspace.connectedProfile else { return nil }
        // Avoid guessing paths for prefixed droplet or auto-save task titles.
        if item.name.hasPrefix("[") || item.name.contains(": ") {
            return nil
        }
        let cleanName = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return nil }
        let candidatePath = RemotePath.normalize(workspace.remotePath + "/" + cleanName)
        if let webURL = mappedSiteWebURL(remotePath: candidatePath, profile: profile) {
            return TranscriptRedactor.sanitize(webURL.absoluteString)
        }
        let entry = FileEntry(name: (cleanName as NSString).lastPathComponent, path: candidatePath, isDirectory: false)
        let rawURL = FileClipboard.remoteURLString(for: entry, profile: profile)
        return TranscriptRedactor.sanitize(rawURL)
    }

    private func mappedSiteWebURL(remotePath: String, profile: ServerProfile) -> URL? {
        let rawSite = profile.siteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawSite.isEmpty else { return nil }
        let candidate = rawSite.contains("://") ? rawSite : "https://\(rawSite)"
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else {
            return nil
        }

        let normalizedRemote = RemotePath.normalize(remotePath)
        let normalizedRoot = RemotePath.normalize(profile.initialPath)
        let relative: String
        if normalizedRoot == "/" {
            relative = normalizedRemote == "/" ? "" : String(normalizedRemote.dropFirst())
        } else if normalizedRemote == normalizedRoot {
            relative = ""
        } else if normalizedRemote.hasPrefix(normalizedRoot + "/") {
            relative = String(normalizedRemote.dropFirst(normalizedRoot.count + 1))
        } else {
            relative = normalizedRemote == "/" ? "" : String(normalizedRemote.dropFirst())
        }

        var basePath = components.path
        while basePath.hasSuffix("/") && basePath.count > 1 {
            basePath.removeLast()
        }
        if basePath == "/" { basePath = "" }
        components.path = relative.isEmpty ? (basePath.isEmpty ? "/" : basePath) : "\(basePath)/\(relative)"
        return components.url
    }

    // MARK: - General Preferences Helpers

    func setDefaultShowHidden(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: DefaultsKey.defaultShowHidden)
        if workspace?.showHidden != enabled {
            workspace?.showHidden = enabled
        }
    }

    func setDefaultViewMode(_ mode: FileViewMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: DefaultsKey.defaultViewMode)
        if workspace?.viewMode != mode {
            workspace?.viewMode = mode
        }
    }

    func choosePreferredExternalEditor() {
        let panel = NSOpenPanel()
        panel.title = L10n.tr("选择首选外部编辑器", "Choose Preferred External Editor")
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url {
            preferredExternalEditorPath = url.path
            appendTranscript(
                for: workspace?.connectedProfile,
                category: .command,
                message: "Preferred external editor set to \(url.lastPathComponent)"
            )
        }
    }

    func clearPreferredExternalEditor() {
        preferredExternalEditorPath = ""
    }

    // MARK: - Transcript API

    func appendTranscript(
        for profile: ServerProfile? = nil,
        category: TranscriptCategory,
        message: String
    ) {
        let connName = profile.map { $0.name.isEmpty ? $0.host : $0.name } ?? ""
        let protoTitle = profile?.protocolKind.title ?? "App"
        transcriptLogger.append(
            connectionName: connName,
            protocolTitle: protoTitle,
            category: category,
            message: message
        )
    }

    func filteredTranscriptEntries(category: TranscriptCategory?, search: String) -> [TranscriptEntry] {
        // Trigger dependency on published snapshot while delegating filtering to TranscriptLogger.
        _ = transcriptEntries.count
        return transcriptLogger.entries(category: category, search: search)
    }

    func exportSanitizedTranscriptText(category: TranscriptCategory?, search: String) -> String {
        TranscriptRedactor.sanitize(transcriptLogger.exportText(category: category, search: search))
    }

    func copyTranscript(category: TranscriptCategory?, search: String) {
        let text = exportSanitizedTranscriptText(category: category, search: search)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        workspace?.flashNotice(L10n.tr("已复制脱敏传输日志", "Copied sanitized transcript"))
    }

    func exportSanitizedTranscriptWithSavePanel(category: TranscriptCategory?, search: String) {
        let text = exportSanitizedTranscriptText(category: category, search: search)
        let panel = NSSavePanel()
        panel.title = L10n.tr("导出脱敏传输日志", "Export Sanitized Transcript")
        panel.nameFieldStringValue = "AetherTransfer-Transcript.log"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                }.value
                self?.workspace?.flashNotice(L10n.tr("已导出脱敏日志：\(url.lastPathComponent)", "Exported transcript: \(url.lastPathComponent)"))
            } catch {
                self?.workspace?.error = L10n.tr("导出日志失败：\(error.localizedDescription)", "Failed to export transcript: \(error.localizedDescription)")
            }
        }
    }

    func clearTranscript() {
        transcriptLogger.clear()
        transcriptEntries = []
    }

    // MARK: - Queue Helpers

    func filteredTransferTasks(_ filter: TransferFilter) -> [TransferTaskItem] {
        guard let tasks = workspace?.transferTasks else { return [] }
        let ordered = orderedTransferTasks(tasks)
        switch filter {
        case .all:
            return ordered
        case .active:
            return ordered.filter { $0.state == .queued || $0.state == .inProgress }
        case .completed:
            return ordered.filter { $0.state == .completed }
        case .failed:
            return ordered.filter { $0.state == .failed }
        case .cancelled:
            return ordered.filter { $0.state == .cancelled }
        }
    }

    func count(for filter: TransferFilter) -> Int {
        filteredTransferTasks(filter).count
    }

    private func orderedTransferTasks(_ tasks: [TransferTaskItem]) -> [TransferTaskItem] {
        guard !prioritizedQueuedIDs.isEmpty else { return tasks }
        var remaining = tasks
        var promoted: [TransferTaskItem] = []
        for id in prioritizedQueuedIDs {
            if let idx = remaining.firstIndex(where: { $0.id == id && $0.state == .queued }) {
                promoted.append(remaining.remove(at: idx))
            }
        }
        return promoted + remaining
    }

    func moveQueuedTransferToTop(_ id: UUID) {
        guard let workspace else { return }
        guard let idx = workspace.transferTasks.firstIndex(where: { $0.id == id && $0.state == .queued }) else { return }
        let item = workspace.transferTasks[idx]
        prioritizedQueuedIDs.removeAll { $0 == id }
        prioritizedQueuedIDs.insert(id, at: 0)
        // Wave 3 Integrator: delegate directly to queue.moveToTop(id: id) in Workspace.swift
        var updated = workspace.transferTasks
        let moved = updated.remove(at: idx)
        updated.insert(moved, at: 0)
        workspace.transferTasks = updated
        appendTranscript(
            for: workspace.connectedProfile,
            category: .transfer,
            message: "Moved queued transfer to top: \(item.name)"
        )
    }

    @discardableResult
    func retryAllFailedTransfers() -> Int {
        guard let workspace else { return 0 }
        let failedIDs = workspace.transferTasks.filter { $0.state == .failed }.reversed().map(\.id)
        guard !failedIDs.isEmpty else { return 0 }
        // Wave 3 Integrator: delegate directly to queue.retryAllFailed() in Workspace.swift
        for id in failedIDs {
            workspace.retryTransfer(id)
        }
        appendTranscript(
            for: workspace.connectedProfile,
            category: .transfer,
            message: "Retrying \(failedIDs.count) failed transfer(s)"
        )
        return failedIDs.count
    }

    func resolvedURLString(for item: TransferTaskItem) -> String? {
        if let explicit = item.remoteURLString, !explicit.isEmpty {
            return TranscriptRedactor.sanitize(explicit)
        }
        if let cached = resolvedUploadURLs[item.id], !cached.isEmpty {
            return cached
        }
        return resolveUploadedURLString(for: item)
    }

    func copyUploadedURL(for item: TransferTaskItem) {
        guard let urlStr = resolvedURLString(for: item) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urlStr, forType: .string)
        lastUploadedURLString = urlStr
        workspace?.flashNotice(L10n.tr("已复制文件链接", "Copied uploaded URL"))
    }

    func copyLastUploadedURL() {
        guard let urlStr = lastUploadedURLString, !urlStr.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urlStr, forType: .string)
        workspace?.flashNotice(L10n.tr("已复制最近上传的链接", "Copied last uploaded URL"))
    }

    // MARK: - Skip Rules & ASCII Extensions (FileRulesStore)

    func setRuleEnabled(_ id: UUID, enabled: Bool) {
        guard let idx = skipRules.firstIndex(where: { $0.id == id }) else { return }
        skipRules[idx].isEnabled = enabled
        persistRulesAndRefreshSync()
    }

    func saveRule(_ rule: SkipRule) {
        if let idx = skipRules.firstIndex(where: { $0.id == rule.id }) {
            skipRules[idx] = rule
        } else {
            skipRules.append(rule)
        }
        persistRulesAndRefreshSync()
    }

    func deleteRule(_ id: UUID) {
        skipRules.removeAll { $0.id == id }
        persistRulesAndRefreshSync()
    }

    func resetRulesToDefaults() {
        skipRules = rulesStore.resetRulesToDefaults()
        applySkipRulesToSyncPreview()
        workspace?.flashNotice(L10n.tr("已恢复默认跳过规则", "Restored default skip rules"))
    }

    private func persistRulesAndRefreshSync() {
        rulesStore.saveRules(skipRules)
        applySkipRulesToSyncPreview()
    }

    func addAsciiExtensions(_ rawInput: String) {
        let additions = rawInput
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .map { ($0.hasPrefix(".") && $0.count > 1) ? String($0.dropFirst()) : $0 }
            .filter { !$0.isEmpty }
        guard !additions.isEmpty else { return }

        var existing = Set(asciiExtensions.map { $0.lowercased() })
        var updated = asciiExtensions
        for ext in additions where existing.insert(ext).inserted {
            updated.append(ext)
        }
        asciiExtensions = updated
        rulesStore.saveAsciiExtensions(updated)
    }

    func removeAsciiExtension(_ ext: String) {
        asciiExtensions.removeAll { $0.caseInsensitiveCompare(ext) == .orderedSame }
        rulesStore.saveAsciiExtensions(asciiExtensions)
    }

    func resetAsciiExtensionsToDefaults() {
        asciiExtensions = AsciiFileExtensions.defaultList
        rulesStore.saveAsciiExtensions(asciiExtensions)
        workspace?.flashNotice(L10n.tr("已恢复默认 ASCII 扩展名列表", "Restored default ASCII extensions"))
    }

    // MARK: - Sync Rules Integration

    private func handleExternalSyncPlanUpdate(_ newPlan: SyncPlan?) {
        guard let newPlan else {
            baseSyncPlan = nil
            lastAppliedFilteredItemIDs = nil
            return
        }
        let incomingIDs = newPlan.items.map(\.id)
        if incomingIDs == lastAppliedFilteredItemIDs {
            if var base = baseSyncPlan {
                let enabledByID = Dictionary(uniqueKeysWithValues: newPlan.items.map { ($0.id, $0.isEnabled) })
                for idx in base.items.indices {
                    if let updated = enabledByID[base.items[idx].id] {
                        base.items[idx].isEnabled = updated
                    }
                }
                baseSyncPlan = base
            }
            return
        }
        baseSyncPlan = newPlan
        applySkipRulesToSyncPreview()

        if let activePlan = workspace?.syncPlan {
            appendTranscript(
                for: workspace?.connectedProfile,
                category: .sync,
                message: "Sync plan ready: \(activePlan.uploadItems.count) upload, \(activePlan.downloadItems.count) download, \(activePlan.deleteItems.count) delete, \(activePlan.skipItems.count) skip"
            )
        }
    }

    func recalculateSyncPlanWithRules() {
        guard let workspace else { return }
        workspace.recalculateSyncPlan()
        // Wave 3 Integrator: pass active skipRules directly into SyncEngine.generatePlan(..., skipRules:)
        baseSyncPlan = workspace.syncPlan
        applySkipRulesToSyncPreview()
    }

    func applySkipRulesToSyncPreview() {
        guard let workspace, let basePlan = baseSyncPlan else { return }
        let enabledRules = skipRules.filter { $0.isEnabled && $0.scope.appliesToSync }

        let filteredItems: [SyncItem]
        if enabledRules.isEmpty {
            filteredItems = basePlan.items
        } else {
            filteredItems = basePlan.items.filter { item in
                !matchesAnySyncSkipRule(item: item, rules: enabledRules)
            }
        }

        let updatedPlan = SyncPlan(
            direction: basePlan.direction,
            rule: basePlan.rule,
            deleteOrphans: basePlan.deleteOrphans,
            items: filteredItems
        )
        lastAppliedFilteredItemIDs = updatedPlan.items.map(\.id)
        workspace.syncPlan = updatedPlan
    }

    private func matchesAnySyncSkipRule(item: SyncItem, rules: [SkipRule]) -> Bool {
        var rel = item.relativePath
        if rel.hasPrefix("/") { rel.removeFirst() }
        let components = rel.split(separator: "/").map(String.init)
        let name = components.last ?? rel

        var prefix = ""
        for idx in 0..<max(0, components.count - 1) {
            let component = components[idx]
            prefix = prefix.isEmpty ? component : "\(prefix)/\(component)"
            for rule in rules where rule.matchMode != .none && rule.predicates.allSatisfy({ $0.field == .name || $0.field == .path }) {
                if rule.matches(name: component, relativePath: prefix, isDirectory: true, size: 0, modified: nil) {
                    return true
                }
            }
        }

        let itemDate = item.sourceDate ?? item.targetDate
        for rule in rules {
            if rule.matches(name: name, relativePath: rel, isDirectory: item.isDirectory, size: item.size, modified: itemDate) {
                return true
            }
        }
        return false
    }

    func exportSyncReportMarkdown(_ plan: SyncPlan) {
        let markdown = plan.exportReportMarkdown()
        let panel = NSSavePanel()
        panel.title = L10n.tr("导出同步计划报告", "Export Sync Report")
        panel.nameFieldStringValue = "AetherTransfer-Sync-Report.md"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try markdown.write(to: url, atomically: true, encoding: .utf8)
                }.value
                self?.appendTranscript(
                    for: self?.workspace?.connectedProfile,
                    category: .sync,
                    message: "Exported Markdown sync report: \(url.lastPathComponent)"
                )
                self?.workspace?.flashNotice(L10n.tr("已导出同步报告：\(url.lastPathComponent)", "Exported report: \(url.lastPathComponent)"))
            } catch {
                self?.workspace?.error = L10n.tr("导出同步报告失败：\(error.localizedDescription)", "Failed to export sync report: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - External Editor Sessions & Terminal Detection

    func visibleExternalEditSessions() -> [ExternalEditorSession] {
        guard let sessions = workspace?.activeExternalEditSessions else { return [] }
        return sessions.filter { !stoppedExternalEditSessionIDs.contains($0.id) }
    }

    func stopWatchingExternalEditSession(_ session: ExternalEditorSession) {
        stoppedExternalEditSessionIDs.insert(session.id)
        workspace?.activeExternalEditSessions.removeAll { $0.id == session.id }
        // Remove isolated temp staging folder so ExternalEditorManager stops detecting changes;
        // Wave 3 Integrator: also call externalEditorManager.removeSession(id: session.id)
        let folder = session.localFileURL.deletingLastPathComponent()
        if folder.path.contains("AetherExternalEdit") {
            try? FileManager.default.removeItem(at: folder)
        }
        appendTranscript(
            for: session.profile,
            category: .transfer,
            message: "Stopped external editor watcher for \(session.entryName)"
        )
        workspace?.flashNotice(L10n.tr("已停止监听外部编辑：\(session.entryName)", "Stopped watching \(session.entryName)"))
    }

    func stopAllExternalEditSessions() {
        let sessions = visibleExternalEditSessions()
        for session in sessions {
            stopWatchingExternalEditSession(session)
        }
    }

    func refreshTerminalDetection() {
        detectedTerminal = TerminalIntegration.detectPreferredTerminal()
    }

    // MARK: - Droplet Exporter

    func exportDropletWithSavePanel(for profile: ServerProfile, remotePath: String? = nil) {
        let baseName = profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (profile.host.isEmpty ? "Server" : profile.host)
            : profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = baseName.replacingOccurrences(of: "/", with: "-")
        let panel = NSSavePanel()
        panel.title = L10n.tr("导出独立 Droplet 应用", "Export Standalone Droplet")
        panel.nameFieldStringValue = "\(safeName) Droplet.app"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        let destinationURL = selectedURL.pathExtension.lowercased() == "app"
            ? selectedURL
            : selectedURL.appendingPathExtension("app")
        let targetRemote = remotePath ?? (profile.initialPath.isEmpty ? "/" : profile.initialPath)

        Task { @MainActor [weak self] in
            do {
                let exportedURL = try await Task.detached(priority: .userInitiated) {
                    try DropletExporter.exportDroplet(
                        for: profile,
                        remotePath: targetRemote,
                        destinationAppURL: destinationURL
                    )
                }.value
                self?.appendTranscript(
                    for: profile,
                    category: .command,
                    message: "Exported Droplet app '\(exportedURL.lastPathComponent)' -> \(targetRemote)"
                )
                self?.workspace?.flashNotice(L10n.tr("已导出 Droplet：\(exportedURL.lastPathComponent)", "Exported Droplet: \(exportedURL.lastPathComponent)"))
            } catch {
                self?.workspace?.error = L10n.tr("导出 Droplet 失败：\(error.localizedDescription)", "Failed to export Droplet: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Workspace Extension Accessors

extension Workspace {
    var rulesAndTranscriptStore: RulesAndTranscriptStore {
        RulesAndTranscriptRegistry.shared.store(for: self)
    }

    var transcriptLogger: TranscriptLogger {
        rulesAndTranscriptStore.transcriptLogger
    }

    var fileRulesStore: FileRulesStore {
        rulesAndTranscriptStore.rulesStore
    }

    var copyURLAfterUpload: Bool {
        get { rulesAndTranscriptStore.copyURLAfterUpload }
        set { rulesAndTranscriptStore.copyURLAfterUpload = newValue }
    }

    var lastUploadedURLString: String? {
        rulesAndTranscriptStore.lastUploadedURLString
    }

    func filteredTransferTasks(_ filter: TransferFilter) -> [TransferTaskItem] {
        rulesAndTranscriptStore.filteredTransferTasks(filter)
    }

    func moveQueuedTransferToTop(_ id: UUID) {
        rulesAndTranscriptStore.moveQueuedTransferToTop(id)
    }

    @discardableResult
    func retryAllFailedTransfers() -> Int {
        rulesAndTranscriptStore.retryAllFailedTransfers()
    }
}
