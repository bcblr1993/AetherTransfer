import AppKit
import SwiftUI
import AetherTransferCore

public struct EditingFileContext: Identifiable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let remote: Bool
    public var content: String
    public var isSaving: Bool = false
    public init(name: String, path: String, remote: Bool, content: String) {
        self.name = name
        self.path = path
        self.remote = remote
        self.content = content
    }
}

public enum FileViewMode: String, CaseIterable, Identifiable, Sendable {
    case list = "列表"
    case icons = "网格"
    public var id: String { rawValue }
    public var localizedTitle: String {
        switch self {
        case .list: return L10n.tr("列表", "List")
        case .icons: return L10n.tr("网格", "Grid")
        }
    }
}

public enum DefaultConflictPreference: String, CaseIterable, Identifiable, Sendable {
    case ask = "ask"
    case overwrite = "overwrite"
    case keepBoth = "keepBoth"
    case skip = "skip"

    public var id: String { rawValue }
    public var localizedTitle: String {
        switch self {
        case .ask: return L10n.tr("每次询问", "Always Ask")
        case .overwrite: return ConflictResolution.overwrite.localizedTitle
        case .keepBoth: return ConflictResolution.keepBoth.localizedTitle
        case .skip: return ConflictResolution.skip.localizedTitle
        }
    }
}

@MainActor final class Workspace: ObservableObject {
    @Published var profiles: [ServerProfile] = []
    @Published var selectedServer: UUID?
    @Published var localPath: String
    @Published var remotePath: String = "/"
    @Published var localFiles: [FileEntry] = []
    @Published var remoteFiles: [FileEntry] = []
    @Published var localSelection: Set<String> = []
    @Published var remoteSelection: Set<String> = []
    @Published var transferTasks: [TransferTaskItem] = []
    @Published var connecting = false
    @Published var loadingLocal = false
    @Published var loadingRemote = false
    @Published var showHidden = false
    @Published var error: String?
    @Published var hostChallenge: HostChallenge?
    @Published var connectedProfile: ServerProfile?

    // Bookmark editing
    @Published var editingProfile: ServerProfile?

    // Multi-tab Management
    @Published var tabManager: TabSessionManager

    // Navigation History
    @Published var localHistory: NavigationHistory
    @Published var remoteHistory: NavigationHistory

    // View & Sorting options
    @Published var viewMode: FileViewMode = .list
    @Published var localSortField: FileSortField = .name
    @Published var localSortAscending: Bool = true
    @Published var remoteSortField: FileSortField = .name
    @Published var remoteSortAscending: Bool = true

    // File Inspector
    @Published var showInspector: Bool = false

    // Quick Text Editor
    @Published var editingFile: EditingFileContext?

    // Batch Renamer
    @Published var showBatchRename: Bool = false
    @Published var batchRenameTargetRemote: Bool = false

    // Quick Look Preview
    @Published var previewURL: URL?
    @Published var isFetchingPreview: Bool = false

    // Directory Synchronization
    @Published var syncPlan: SyncPlan?
    @Published var showSyncSheet: Bool = false
    @Published var isAnalyzingSync: Bool = false
    @Published var syncDirection: SyncDirection = .localToRemote
    @Published var syncRule: SyncComparisonRule = .sizeAndDate
    @Published var syncDeleteOrphans: Bool = false

    // Synchronized Browsing (Transmit Sync Navigation)
    @Published var isSyncBrowsingEnabled: Bool = false
    private var syncNavManager = SyncNavigationManager(localRoot: "", remoteRoot: "", isEnabled: false)

    // In-App Auto-Updater
    @Published var updateState: UpdateState = .idle
    @Published var showUpdateSheet: Bool = false
    @Published var autoCheckForUpdates: Bool {
        didSet {
            UserDefaults.standard.set(autoCheckForUpdates, forKey: "com.aethernative.AetherTransfer.autoCheckUpdates")
        }
    }
    private var updateTask: Task<Void, Never>?

    // Language & User Preferences
    @Published var appLanguage: AppLanguage {
        didSet {
            L10n.currentPreference = appLanguage
            objectWillChange.send()
        }
    }
    @Published var maxConcurrentTransfers: Int {
        didSet {
            let clamped = min(10, max(1, maxConcurrentTransfers))
            if maxConcurrentTransfers != clamped {
                maxConcurrentTransfers = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: "com.aethernative.AetherTransfer.maxConcurrentTransfers")
            queue.setMaxConcurrentTransfers(clamped)
        }
    }
    @Published var defaultConflictPreference: DefaultConflictPreference {
        didSet {
            UserDefaults.standard.set(defaultConflictPreference.rawValue, forKey: "com.aethernative.AetherTransfer.defaultConflictPreference")
        }
    }
    @Published var defaultLocalPath: String {
        didSet {
            UserDefaults.standard.set(defaultLocalPath, forKey: "com.aethernative.AetherTransfer.defaultLocalPath")
        }
    }

    private struct TabStateSnapshot {
        var localPath: String
        var remotePath: String
        var connectedProfile: ServerProfile?
        var credentials: Credentials
        var localFiles: [FileEntry]
        var remoteFiles: [FileEntry]
        var localHistory: NavigationHistory
        var remoteHistory: NavigationHistory
    }
    private var tabSnapshots: [UUID: TabStateSnapshot] = [:]

    // Cached tree for sync recalculation
    private var cachedSyncLocalFiles: [LocalFileItem] = []
    private var cachedSyncRemoteFiles: [FileEntry] = []

    private var credentials = Credentials()
    private let store = ProfileStore()
    private let queue = TransferQueueManager(maxConcurrentTransfers: 3)
    private var browseTask: Task<Void, Never>?
    private var localTask: Task<Void, Never>?
    private var localGeneration = UUID()
    private var remoteGeneration = UUID()

    struct HostChallenge: Identifiable {
        let id = UUID()
        let key: String
        let profile: ServerProfile
    }

    var client: RemoteClient? {
        connectedProfile.map {
            RemoteClient(profile: $0, credentials: credentials, speedLimitBytesPerSec: queue.speedLimitBytesPerSec)
        }
    }

    var sortedLocalFiles: [FileEntry] {
        FileEntry.sorted(localFiles, by: localSortField, ascending: localSortAscending, foldersFirst: true)
    }

    var sortedRemoteFiles: [FileEntry] {
        FileEntry.sorted(remoteFiles, by: remoteSortField, ascending: remoteSortAscending, foldersFirst: true)
    }

    func toggleSort(_ field: FileSortField, remote: Bool) {
        if remote {
            if remoteSortField == field {
                remoteSortAscending.toggle()
            } else {
                remoteSortField = field
                remoteSortAscending = true
            }
        } else {
            if localSortField == field {
                localSortAscending.toggle()
            } else {
                localSortField = field
                localSortAscending = true
            }
        }
    }

    var activeTransferCount: Int {
        transferTasks.filter { $0.state == .inProgress || $0.state == .queued }.count
    }

    var overallTransferSpeed: String {
        TransferQueueManager.formatSpeed(queue.totalSpeed)
    }

    var speedLimit: Int64? {
        queue.speedLimitBytesPerSec
    }

    var speedLimitText: String {
        if let limit = speedLimit {
            return L10n.tr("限速: \(TransferQueueManager.formatSpeed(Double(limit)))",
                           "Limit: \(TransferQueueManager.formatSpeed(Double(limit)))")
        }
        return L10n.tr("不限速", "Unlimited")
    }

    func setSpeedLimit(_ limit: Int64?) {
        queue.setSpeedLimit(limit)
        objectWillChange.send()
    }

    var isQueuePaused: Bool {
        queue.isPaused
    }

    func toggleQueuePause() {
        if queue.isPaused {
            queue.resume()
        } else {
            queue.pause()
        }
        objectWillChange.send()
    }

    func toggleSyncBrowsing() {
        isSyncBrowsingEnabled.toggle()
        syncNavManager.updateRoots(localRoot: localPath, remoteRoot: remotePath)
        syncNavManager.isEnabled = isSyncBrowsingEnabled
    }

    var selectedEntry: FileEntry? {
        if !remoteSelection.isEmpty, let id = remoteSelection.first {
            return remoteFiles.first(where: { $0.id == id })
        }
        if !localSelection.isEmpty, let id = localSelection.first {
            return localFiles.first(where: { $0.id == id })
        }
        return nil
    }

    var hasAvailableUpdate: Bool {
        if case .available = updateState { return true }
        if case .readyToInstall = updateState { return true }
        return false
    }

    init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let savedDefaultLocal = UserDefaults.standard.string(forKey: "com.aethernative.AetherTransfer.defaultLocalPath")
        let initialLocal = (savedDefaultLocal != nil && FileManager.default.fileExists(atPath: savedDefaultLocal!)) ? savedDefaultLocal! : homeDir
        self.defaultLocalPath = initialLocal
        self.localPath = initialLocal
        self.localHistory = NavigationHistory(initialPath: initialLocal)
        self.remoteHistory = NavigationHistory(initialPath: "/")
        self.tabManager = TabSessionManager(initialLocalPath: initialLocal)
        self.appLanguage = L10n.currentPreference

        let savedConcurrency = UserDefaults.standard.integer(forKey: "com.aethernative.AetherTransfer.maxConcurrentTransfers")
        let initialConcurrency = (1...10).contains(savedConcurrency) ? savedConcurrency : 3
        self.maxConcurrentTransfers = initialConcurrency
        self.queue.setMaxConcurrentTransfers(initialConcurrency)

        let savedConflictRaw = UserDefaults.standard.string(forKey: "com.aethernative.AetherTransfer.defaultConflictPreference") ?? "ask"
        self.defaultConflictPreference = DefaultConflictPreference(rawValue: savedConflictRaw) ?? .ask

        let autoCheckDefault = UserDefaults.standard.object(forKey: "com.aethernative.AetherTransfer.autoCheckUpdates") as? Bool ?? true
        self.autoCheckForUpdates = autoCheckDefault

        do { profiles = try store.load() } catch { self.error = error.localizedDescription }

        queue.onQueueUpdated = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.transferTasks = self.queue.items
                let count = self.activeTransferCount
                NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
            }
        }

        refreshLocal()

        if autoCheckDefault {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self?.checkForUpdates(silentIfUpToDate: true)
            }
        }
    }

    // MARK: - In-App Auto-Updater Actions
    func openUpdateWindowAndCheck() {
        showUpdateSheet = true
        switch updateState {
        case .idle, .upToDate, .failed:
            checkForUpdates(silentIfUpToDate: false)
        default:
            break
        }
    }

    func checkForUpdates(silentIfUpToDate: Bool = false) {
        updateTask?.cancel()
        if !silentIfUpToDate {
            showUpdateSheet = true
        }
        updateState = .checking
        let currentVersion = AutoUpdater.currentAppVersion()
        let allowLocal = ProcessInfo.processInfo.environment["AETHER_UPDATE_ALLOW_FILE_URL"] == "1"

        updateTask = Task {
            do {
                let feedURL = try AutoUpdater.resolvedFeedURL()
                let manifest = try await AutoUpdater.fetchManifest(from: feedURL, allowLocalFileURL: allowLocal)
                try Task.checkCancellation()
                if let release = try AutoUpdater.evaluateUpdate(currentVersion: currentVersion, manifest: manifest) {
                    self.updateState = .available(release)
                    self.showUpdateSheet = true
                } else {
                    self.updateState = .upToDate(currentVersion: currentVersion)
                }
            } catch is CancellationError {
                self.updateState = .idle
            } catch {
                if silentIfUpToDate {
                    self.updateState = .idle
                } else {
                    self.updateState = .failed(error.localizedDescription)
                }
            }
        }
    }

    func downloadUpdate(_ release: UpdateRelease) {
        updateTask?.cancel()
        updateState = .downloading(release: release, completedBytes: 0, totalBytes: release.sizeBytes, progress: 0)
        let allowLocal = ProcessInfo.processInfo.environment["AETHER_UPDATE_ALLOW_FILE_URL"] == "1"

        updateTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stagedApp = try await AutoUpdater.downloadAndStageUpdate(
                    release: release,
                    allowLocalFileURL: allowLocal,
                    requireCodeSignature: true,
                    progress: { [weak self] completed, total in
                        Task { @MainActor in
                            guard let self else { return }
                            let fraction = total > 0 ? min(1.0, Double(completed) / Double(total)) : 0
                            self.updateState = .downloading(
                                release: release,
                                completedBytes: completed,
                                totalBytes: total,
                                progress: fraction
                            )
                        }
                    }
                )
                try Task.checkCancellation()
                self.updateState = .readyToInstall(release: release, stagedAppURL: stagedApp)
            } catch is CancellationError {
                self.updateState = .available(release)
            } catch {
                self.updateState = .failed(error.localizedDescription)
            }
        }
    }

    func cancelUpdateDownload() {
        updateTask?.cancel()
        if case .downloading(let release, _, _, _) = updateState {
            updateState = .available(release)
        }
    }

    func installUpdateAndRelaunch() {
        guard case .readyToInstall(let release, let stagedAppURL) = updateState else { return }
        updateState = .installing(release: release)
        do {
            try AutoUpdater.installAndRelaunch(stagedAppURL: stagedAppURL) {
                NSApp.terminate(nil)
            }
        } catch {
            updateState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Profile Persistence & Bookmark Management
    func persist() { do { try store.save(profiles) } catch { self.error = error.localizedDescription } }

    func save(_ profile: ServerProfile, credentials: Credentials, remember: Bool) throws {
        try profile.validate()
        if remember {
            try CredentialStore.save(credentials.password, id: profile.id)
            try CredentialStore.save(credentials.passphrase, id: profile.id, kind: "passphrase")
        }
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile }
        else { profiles.append(profile) }
        try store.save(profiles)
    }

    func loadCredentials(for profile: ServerProfile) -> Credentials {
        let pwd = (try? CredentialStore.load(id: profile.id)) ?? ""
        let pass = (try? CredentialStore.load(id: profile.id, kind: "passphrase")) ?? ""
        return Credentials(password: pwd, passphrase: pass)
    }

    func deleteProfile(_ profile: ServerProfile) {
        profiles.removeAll { $0.id == profile.id }
        persist()
        try? CredentialStore.save("", id: profile.id)
        try? CredentialStore.save("", id: profile.id, kind: "passphrase")
        if connectedProfile?.id == profile.id {
            disconnect()
        }
    }

    func duplicateProfile(_ profile: ServerProfile) {
        var copy = profile
        copy.id = UUID()
        copy.name = "\(profile.name) \(L10n.tr("副本", "Copy"))"
        profiles.append(copy)
        persist()
    }

    func connectSaved(_ profile: ServerProfile) {
        do {
            connect(profile, credentials: Credentials(password: try CredentialStore.load(id: profile.id),
                                                      passphrase: try CredentialStore.load(id: profile.id, kind: "passphrase")))
        } catch { self.error = error.localizedDescription }
    }

    func connect(_ profile: ServerProfile, credentials: Credentials) {
        browseTask?.cancel()
        connectedProfile = profile; self.credentials = credentials
        selectedServer = profile.id; remotePath = RemotePath.normalize(profile.initialPath)
        remoteHistory = NavigationHistory(initialPath: remotePath)
        remoteFiles = []; connecting = true
        let title = profile.name.isEmpty ? profile.host : profile.name
        tabManager.updateActiveTab(localPath: localPath, remotePath: remotePath, profileId: profile.id, profileName: title, title: title)
        syncNavManager.updateRoots(localRoot: localPath, remoteRoot: remotePath)
        refreshRemote()
    }

    func disconnect() {
        browseTask?.cancel(); remoteGeneration = UUID(); connectedProfile = nil; remoteFiles = []
        remoteSelection = []; connecting = false; loadingRemote = false
        tabManager.clearActiveConnection(fallbackTitle: L10n.tr("本地工作区", "Local Workspace"))
        saveActiveTabSnapshot()
    }

    func approveHostKey() {
        guard let challenge = hostChallenge else { return }
        var profile = challenge.profile; profile.trustedHostKey = challenge.key
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile; persist() }
        hostChallenge = nil; connect(profile, credentials: credentials)
    }

    // MARK: - Navigation
    func navigateLocal(to path: String) {
        localHistory.navigateTo(path)
        localPath = localHistory.currentPath
        refreshLocal()

        if isSyncBrowsingEnabled, connectedProfile != nil,
           let targetRemote = syncNavManager.remotePathForLocalNavigation(to: path) {
            remoteHistory.navigateTo(targetRemote)
            remotePath = remoteHistory.currentPath
            refreshRemote()
        }
    }

    func navigateRemote(to path: String) {
        remoteHistory.navigateTo(path)
        remotePath = remoteHistory.currentPath
        refreshRemote()

        if isSyncBrowsingEnabled,
           let targetLocal = syncNavManager.localPathForRemoteNavigation(to: path) {
            localHistory.navigateTo(targetLocal)
            localPath = localHistory.currentPath
            refreshLocal()
        }
    }

    func goBack(remote: Bool) {
        if remote {
            if remoteHistory.goBack() {
                remotePath = remoteHistory.currentPath
                refreshRemote()
            }
        } else {
            if localHistory.goBack() {
                localPath = localHistory.currentPath
                refreshLocal()
            }
        }
    }

    func goForward(remote: Bool) {
        if remote {
            if remoteHistory.goForward() {
                remotePath = remoteHistory.currentPath
                refreshRemote()
            }
        } else {
            if localHistory.goForward() {
                localPath = localHistory.currentPath
                refreshLocal()
            }
        }
    }

    func refreshLocal() {
        localTask?.cancel()
        let path = localPath, hidden = showHidden, generation = UUID()
        localGeneration = generation; loadingLocal = true
        localTask = Task {
            do {
                let files = try await Task.detached { try LocalFiles.list(URL(fileURLWithPath: path), showHidden: hidden) }.value
                guard generation == localGeneration else { return }
                localFiles = files; localSelection = []
            } catch { if generation == localGeneration { self.error = error.localizedDescription } }
            if generation == localGeneration { loadingLocal = false }
        }
    }

    func refreshRemote() {
        guard let client else { return }
        browseTask?.cancel()
        let path = remotePath, generation = UUID()
        remoteGeneration = generation; loadingRemote = true
        browseTask = Task {
            do {
                let files = try await client.list(path)
                guard generation == remoteGeneration else { return }
                remoteFiles = files; remoteSelection = []
            } catch let failure as TransferError {
                guard generation == remoteGeneration else { return }
                if case .hostKeyRequired(let key, let changed) = failure, !changed {
                    hostChallenge = HostChallenge(key: key, profile: client.profile)
                } else { error = failure.localizedDescription }
            } catch is CancellationError { }
            catch { if generation == remoteGeneration { self.error = error.localizedDescription } }
            if generation == remoteGeneration { loadingRemote = false; connecting = false }
        }
    }

    func open(_ entry: FileEntry, remote: Bool) {
        if entry.isDirectory {
            if remote { navigateRemote(to: entry.path) }
            else { navigateLocal(to: entry.path) }
        } else if remote { download([entry]) }
        else { NSWorkspace.shared.open(URL(fileURLWithPath: entry.path)) }
    }

    func parent(remote: Bool) {
        if remote { navigateRemote(to: RemotePath.parent(remotePath)) }
        else { navigateLocal(to: URL(fileURLWithPath: localPath).deletingLastPathComponent().path) }
    }

    func chooseLocal() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { navigateLocal(to: url.path) }
    }

    // MARK: - Uploads & Downloads
    func uploadSelection() { upload(localFiles.filter { localSelection.contains($0.id) }) }
    func downloadSelection() { download(remoteFiles.filter { remoteSelection.contains($0.id) }) }

    func upload(_ entries: [FileEntry]) {
        guard let client else { return }
        for entry in entries {
            if entry.isDirectory {
                uploadDirectory(entry, client: client)
            } else {
                uploadSingleFile(entry, client: client)
            }
        }
    }

    private func uploadSingleFile(_ entry: FileEntry, client: RemoteClient) {
        do {
            var targetName = entry.name
            var overwrite = remoteFiles.contains { $0.name == targetName }
            if overwrite {
                let choice = confirmConflict(targetName)
                switch choice {
                case .skip: return
                case .overwrite: overwrite = true
                case .keepBoth:
                    targetName = RemotePath.uniqueName(for: targetName, existingNames: remoteFiles.map(\.name))
                    overwrite = false
                }
            }
            let finalTarget = try RemotePath.join(remotePath, targetName)
            let finalOverwrite = overwrite
            queue.enqueue(name: targetName, direction: .upload) { [weak self] progress in
                let activeClient = await MainActor.run { self?.client ?? client }
                let task = try ResumableTransfer(
                    direction: .upload,
                    local: URL(fileURLWithPath: entry.path),
                    remote: finalTarget,
                    profile: activeClient.profile,
                    overwrite: finalOverwrite
                )
                try await task.run(client: activeClient, progress: progress)
                await MainActor.run { self?.refreshRemote() }
            }
        } catch { self.error = error.localizedDescription }
    }

    private func uploadDirectory(_ entry: FileEntry, client: RemoteClient) {
        let rootURL = URL(fileURLWithPath: entry.path)
        var folderName = entry.name
        var overwriteFiles = true
        if remoteFiles.contains(where: { $0.name == folderName }) {
            let choice = confirmConflict(folderName)
            switch choice {
            case .skip: return
            case .overwrite: overwriteFiles = true
            case .keepBoth:
                folderName = RemotePath.uniqueName(for: folderName, existingNames: remoteFiles.map(\.name))
                overwriteFiles = false
            }
        }
        let baseRemoteFolder = RemotePath.normalize(remotePath + "/" + folderName)
        let finalOverwrite = overwriteFiles
        Task { [weak self] in
            guard let self else { return }
            do {
                try await client.mkdirRecursive(baseRemoteFolder)
                let items = try LocalFiles.walk(rootURL, showHidden: showHidden)
                for item in items {
                    let targetRemote = RemotePath.normalize(baseRemoteFolder + "/" + item.relativePath)
                    if item.isDirectory {
                        try await client.mkdirRecursive(targetRemote)
                    } else {
                        let parent = RemotePath.parent(targetRemote)
                        try await client.mkdirRecursive(parent)
                        queue.enqueue(name: "\(folderName)/\(item.relativePath)", direction: .upload) { [weak self] progress in
                            let activeClient = await MainActor.run { self?.client ?? client }
                            let task = try ResumableTransfer(
                                direction: .upload,
                                local: item.fileURL,
                                remote: targetRemote,
                                profile: activeClient.profile,
                                overwrite: finalOverwrite
                            )
                            try await task.run(client: activeClient, progress: progress)
                        }
                    }
                }
                refreshRemote()
            } catch { self.error = error.localizedDescription }
        }
    }

    func download(_ entries: [FileEntry]) {
        guard let client else { return }
        for entry in entries {
            if entry.isDirectory {
                downloadDirectory(entry, client: client)
            } else {
                downloadSingleFile(entry, client: client)
            }
        }
    }

    private func downloadSingleFile(_ entry: FileEntry, client: RemoteClient) {
        var targetName = entry.name
        let localDir = URL(fileURLWithPath: localPath)
        var destination = localDir.appendingPathComponent(targetName)
        var overwrite = FileManager.default.fileExists(atPath: destination.path)
        if overwrite {
            let choice = confirmConflict(targetName)
            switch choice {
            case .skip: return
            case .overwrite: overwrite = true
            case .keepBoth:
                targetName = RemotePath.uniqueName(for: targetName, existingNames: localFiles.map(\.name))
                destination = localDir.appendingPathComponent(targetName)
                overwrite = false
            }
        }
        let finalDestination = destination
        let finalOverwrite = overwrite
        queue.enqueue(name: targetName, direction: .download) { [weak self] progress in
            let activeClient = await MainActor.run { self?.client ?? client }
            let task = try ResumableTransfer(
                direction: .download,
                local: finalDestination,
                remote: entry.path,
                profile: activeClient.profile,
                overwrite: finalOverwrite
            )
            try await task.run(client: activeClient, progress: progress)
            await MainActor.run { self?.refreshLocal() }
        }
    }

    private func downloadDirectory(_ entry: FileEntry, client: RemoteClient) {
        var folderName = entry.name
        let localParent = URL(fileURLWithPath: localPath)
        var baseLocalDir = localParent.appendingPathComponent(folderName)
        var overwriteFiles = true
        if FileManager.default.fileExists(atPath: baseLocalDir.path) {
            let choice = confirmConflict(folderName)
            switch choice {
            case .skip: return
            case .overwrite: overwriteFiles = true
            case .keepBoth:
                folderName = RemotePath.uniqueName(for: folderName, existingNames: localFiles.map(\.name))
                baseLocalDir = localParent.appendingPathComponent(folderName)
                overwriteFiles = false
            }
        }
        let finalBaseLocalDir = baseLocalDir
        let finalFolderName = folderName
        let finalOverwrite = overwriteFiles
        let remoteBase = entry.path
        Task { [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.createDirectory(at: finalBaseLocalDir, withIntermediateDirectories: true)
                let remoteItems = try await client.listRecursive(remoteBase)
                for item in remoteItems {
                    guard item.path != remoteBase else { continue }
                    var rel = String(item.path.dropFirst(remoteBase.count))
                    if rel.hasPrefix("/") { rel.removeFirst() }
                    guard !rel.isEmpty else { continue }
                    let localTarget = finalBaseLocalDir.appendingPathComponent(rel)
                    if item.isDirectory {
                        try FileManager.default.createDirectory(at: localTarget, withIntermediateDirectories: true)
                    } else {
                        try FileManager.default.createDirectory(at: localTarget.deletingLastPathComponent(), withIntermediateDirectories: true)
                        queue.enqueue(name: "\(finalFolderName)/\(rel)", direction: .download) { [weak self] progress in
                            let activeClient = await MainActor.run { self?.client ?? client }
                            let task = try ResumableTransfer(
                                direction: .download,
                                local: localTarget,
                                remote: item.path,
                                profile: activeClient.profile,
                                overwrite: finalOverwrite
                            )
                            try await task.run(client: activeClient, progress: progress)
                        }
                    }
                }
                refreshLocal()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func confirmConflict(_ name: String) -> ConflictResolution {
        switch defaultConflictPreference {
        case .overwrite: return .overwrite
        case .keepBoth: return .keepBoth
        case .skip: return .skip
        case .ask: break
        }
        let alert = NSAlert()
        alert.messageText = L10n.tr("目标文件 \(name) 已存在", "Target \"\(name)\" already exists")
        alert.informativeText = L10n.tr("请选择如何处理此文件冲突：", "Choose how to resolve this conflict:")
        alert.addButton(withTitle: ConflictResolution.overwrite.localizedTitle)
        alert.addButton(withTitle: ConflictResolution.keepBoth.localizedTitle)
        alert.addButton(withTitle: ConflictResolution.skip.localizedTitle)
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn: return .overwrite
        case .alertSecondButtonReturn: return .keepBoth
        default: return .skip
        }
    }

    func cancelTransfer(_ id: UUID) { queue.cancel(id: id) }
    func retryTransfer(_ id: UUID) { queue.retry(id: id) }
    func clearCompletedTransfers() { queue.clearCompleted() }
    func cancelAllTransfers() { queue.cancelAll() }

    func createFolder(remote: Bool) {
        guard let name = askName(
            title: L10n.tr("新建文件夹", "New Folder"),
            initial: L10n.tr("新文件夹", "Untitled Folder")
        ) else { return }
        do {
            try RemotePath.validateName(name)
            if remote, let client {
                let path = try RemotePath.join(remotePath, name)
                Task { do { try await client.mkdir(path); refreshRemote() } catch { self.error = error.localizedDescription } }
            } else {
                try FileManager.default.createDirectory(at: URL(fileURLWithPath: localPath).appendingPathComponent(name), withIntermediateDirectories: false)
                refreshLocal()
            }
        } catch { self.error = error.localizedDescription }
    }

    func rename(_ entry: FileEntry, remote: Bool) {
        guard let name = askName(title: L10n.tr("重命名", "Rename"), initial: entry.name) else { return }
        do {
            try RemotePath.validateName(name)
            if remote, let client {
                let destination = try RemotePath.join(remotePath, name)
                if remoteFiles.contains(where: { $0.path == destination }) { throw TransferError.conflict(name) }
                Task { do { try await client.rename(entry.path, to: destination); refreshRemote() } catch { self.error = error.localizedDescription } }
            } else {
                try FileManager.default.moveItem(at: URL(fileURLWithPath: entry.path), to: URL(fileURLWithPath: localPath).appendingPathComponent(name))
                refreshLocal()
            }
        } catch { self.error = error.localizedDescription }
    }

    func delete(_ entry: FileEntry, remote: Bool) {
        let alert = NSAlert()
        alert.messageText = L10n.tr("删除 \(entry.name)？", "Delete \"\(entry.name)\"?")
        alert.informativeText = remote
            ? L10n.tr("服务器删除无法从本机废纸篓恢复。", "Remote deletion is permanent and cannot be undone from local Trash.")
            : L10n.tr("文件将移到废纸篓。", "The item will be moved to the Trash.")
        alert.addButton(withTitle: L10n.tr("删除", "Delete"))
        alert.addButton(withTitle: L10n.tr("取消", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if remote, let client {
            Task { do { try await client.remove(entry.path, directory: entry.isDirectory); refreshRemote() } catch { self.error = error.localizedDescription } }
        } else {
            do { try FileManager.default.trashItem(at: URL(fileURLWithPath: entry.path), resultingItemURL: nil); refreshLocal() }
            catch { self.error = error.localizedDescription }
        }
    }

    private func saveActiveTabSnapshot() {
        let currentId = tabManager.activeTabId
        tabManager.updateActiveTab(localPath: localPath, remotePath: remotePath)
        tabSnapshots[currentId] = TabStateSnapshot(
            localPath: localPath,
            remotePath: remotePath,
            connectedProfile: connectedProfile,
            credentials: credentials,
            localFiles: localFiles,
            remoteFiles: remoteFiles,
            localHistory: localHistory,
            remoteHistory: remoteHistory
        )
    }

    func addNewTab() {
        saveActiveTabSnapshot()
        tabManager.createTab(
            title: connectedProfile?.name.isEmpty == false ? connectedProfile!.name : L10n.tr("新标签页", "New Tab"),
            localPath: localPath,
            remotePath: remotePath,
            connectedProfileId: connectedProfile?.id,
            connectedProfileName: connectedProfile?.name
        )
        saveActiveTabSnapshot()
    }

    func selectTab(_ id: UUID) {
        guard id != tabManager.activeTabId else { return }
        saveActiveTabSnapshot()
        tabManager.selectTab(id)
        if let snapshot = tabSnapshots[id] {
            localPath = snapshot.localPath
            remotePath = snapshot.remotePath
            connectedProfile = snapshot.connectedProfile
            credentials = snapshot.credentials
            selectedServer = snapshot.connectedProfile?.id
            localFiles = snapshot.localFiles
            remoteFiles = snapshot.remoteFiles
            localHistory = snapshot.localHistory
            remoteHistory = snapshot.remoteHistory
            localSelection = []
            remoteSelection = []
            return
        }
        if let tab = tabManager.activeTab {
            localPath = tab.localPath
            localHistory = NavigationHistory(initialPath: tab.localPath)
            remotePath = tab.remotePath
            remoteHistory = NavigationHistory(initialPath: tab.remotePath)
            if let pid = tab.connectedProfileId, let profile = profiles.first(where: { $0.id == pid }) {
                connectSaved(profile)
            } else if tab.connectedProfileId == nil {
                disconnect()
            }
            refreshLocal()
        }
    }

    func closeTab(_ id: UUID) {
        tabSnapshots.removeValue(forKey: id)
        let wasActive = (id == tabManager.activeTabId)
        tabManager.closeTab(id: id)
        if wasActive {
            let newActiveId = tabManager.activeTabId
            if let snapshot = tabSnapshots[newActiveId] {
                localPath = snapshot.localPath
                remotePath = snapshot.remotePath
                connectedProfile = snapshot.connectedProfile
                credentials = snapshot.credentials
                selectedServer = snapshot.connectedProfile?.id
                localFiles = snapshot.localFiles
                remoteFiles = snapshot.remoteFiles
                localHistory = snapshot.localHistory
                remoteHistory = snapshot.remoteHistory
            } else if let tab = tabManager.activeTab {
                localPath = tab.localPath
                remotePath = tab.remotePath
                refreshLocal()
                if connectedProfile != nil { refreshRemote() }
            }
        }
    }

    func applyPermissions(to entry: FileEntry, permissions: POSIXPermissions, remote: Bool) {
        if remote, let client {
            Task {
                do {
                    try await client.chmod(entry.path, permissions: permissions)
                    refreshRemote()
                } catch { self.error = error.localizedDescription }
            }
        } else {
            do {
                try FileManager.default.setAttributes([.posixPermissions: permissions.octalInt], ofItemAtPath: entry.path)
                refreshLocal()
            } catch { self.error = error.localizedDescription }
        }
    }

    func executeBatchRename(plans: [RenameItemPlan], remote: Bool) {
        let validPlans = plans.filter { !$0.hasError && $0.originalName != $0.newName }
        guard !validPlans.isEmpty else { return }
        Task {
            if remote, let client {
                for plan in validPlans {
                    do {
                        let source = try RemotePath.join(remotePath, plan.originalName)
                        let target = try RemotePath.join(remotePath, plan.newName)
                        try await client.rename(source, to: target)
                    } catch {
                        self.error = L10n.tr("重命名 \(plan.originalName) 失败: \(error.localizedDescription)",
                                             "Failed to rename \(plan.originalName): \(error.localizedDescription)")
                    }
                }
                refreshRemote()
            } else {
                let localDir = URL(fileURLWithPath: localPath)
                for plan in validPlans {
                    do {
                        let source = localDir.appendingPathComponent(plan.originalName)
                        let target = localDir.appendingPathComponent(plan.newName)
                        try FileManager.default.moveItem(at: source, to: target)
                    } catch {
                        self.error = L10n.tr("重命名 \(plan.originalName) 失败: \(error.localizedDescription)",
                                             "Failed to rename \(plan.originalName): \(error.localizedDescription)")
                    }
                }
                refreshLocal()
            }
        }
    }

    func openEditor(for entry: FileEntry, remote: Bool) {
        if remote, let client {
            Task {
                do {
                    let tempCache = FileManager.default.temporaryDirectory.appendingPathComponent("aether-edit-\(UUID().uuidString)-\(entry.name)")
                    defer { try? FileManager.default.removeItem(at: tempCache) }
                    try await client.download(entry.path, to: tempCache, overwrite: true)
                    let text = try String(contentsOf: tempCache, encoding: .utf8)
                    self.editingFile = EditingFileContext(name: entry.name, path: entry.path, remote: true, content: text)
                } catch {
                    self.error = L10n.tr("无法以文本形式打开此文件：\(error.localizedDescription)",
                                         "Unable to open file as text: \(error.localizedDescription)")
                }
            }
        } else {
            do {
                let text = try String(contentsOfFile: entry.path, encoding: .utf8)
                self.editingFile = EditingFileContext(name: entry.name, path: entry.path, remote: false, content: text)
            } catch {
                self.error = L10n.tr("无法以文本形式打开此文件：\(error.localizedDescription)",
                                     "Unable to open file as text: \(error.localizedDescription)")
            }
        }
    }

    func saveEditorContent(_ newContent: String) {
        guard var ctx = editingFile else { return }
        ctx.isSaving = true
        self.editingFile = ctx
        Task {
            if ctx.remote, let client {
                do {
                    let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("aether-save-\(UUID().uuidString)-\(ctx.name)")
                    try newContent.write(to: tempFile, atomically: true, encoding: .utf8)
                    defer { try? FileManager.default.removeItem(at: tempFile) }
                    try await client.upload(tempFile, to: ctx.path, overwrite: true)
                    refreshRemote()
                    self.editingFile = nil
                } catch {
                    self.error = L10n.tr("保存远程文件失败：\(error.localizedDescription)",
                                         "Failed to save remote file: \(error.localizedDescription)")
                    ctx.isSaving = false
                    self.editingFile = ctx
                }
            } else {
                do {
                    try newContent.write(toFile: ctx.path, atomically: true, encoding: .utf8)
                    refreshLocal()
                    self.editingFile = nil
                } catch {
                    self.error = L10n.tr("保存本地文件失败：\(error.localizedDescription)",
                                         "Failed to save local file: \(error.localizedDescription)")
                    ctx.isSaving = false
                    self.editingFile = ctx
                }
            }
        }
    }

    func openTerminal(remote: Bool) {
        let shellCmd: String
        if remote, let server = connectedProfile {
            let target = ShellEscape.singleQuoted("\(server.username)@\(server.host)")
            shellCmd = "ssh -p \(server.port) \(target)"
        } else {
            shellCmd = "cd \(ShellEscape.singleQuoted(localPath))"
        }
        let script = "tell application \"Terminal\" to do script \(ShellEscape.appleScriptQuoted(shellCmd))"
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }

    // MARK: - Quick Look Preview
    func previewItem(_ entry: FileEntry, remote: Bool) {
        if !remote {
            self.previewURL = URL(fileURLWithPath: entry.path)
            return
        }

        guard !entry.isDirectory, let client else { return }
        isFetchingPreview = true
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("AetherPreview", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let cacheFile = tempDir.appendingPathComponent(entry.name)

        Task {
            do {
                try await client.download(entry.path, to: cacheFile, overwrite: true)
                await MainActor.run {
                    self.previewURL = cacheFile
                    self.isFetchingPreview = false
                }
            } catch {
                await MainActor.run {
                    self.isFetchingPreview = false
                    self.error = L10n.tr("预览下载失败: \(error.localizedDescription)",
                                         "Preview download failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Directory Synchronization
    func startSyncAnalysis() {
        guard let client else { return }
        isAnalyzingSync = true

        let currentLocal = localPath
        let currentRemote = remotePath
        let currentHidden = showHidden
        let currentDirection = syncDirection
        let currentRule = syncRule
        let currentDelete = syncDeleteOrphans

        Task {
            do {
                let localRoot = URL(fileURLWithPath: currentLocal)
                let locals = try LocalFiles.walk(localRoot, showHidden: currentHidden)
                let remotes = try await client.listRecursive(currentRemote)
                let plan = SyncEngine.generatePlan(
                    localRoot: localRoot,
                    localFiles: locals,
                    remoteRoot: currentRemote,
                    remoteFiles: remotes,
                    direction: currentDirection,
                    rule: currentRule,
                    deleteOrphans: currentDelete
                )

                await MainActor.run {
                    self.cachedSyncLocalFiles = locals
                    self.cachedSyncRemoteFiles = remotes
                    self.syncPlan = plan
                    self.showSyncSheet = true
                    self.isAnalyzingSync = false
                }
            } catch {
                await MainActor.run {
                    self.isAnalyzingSync = false
                    self.error = L10n.tr("同步分析失败: \(error.localizedDescription)",
                                         "Sync analysis failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func recalculateSyncPlan() {
        let localRoot = URL(fileURLWithPath: localPath)
        self.syncPlan = SyncEngine.generatePlan(
            localRoot: localRoot,
            localFiles: cachedSyncLocalFiles,
            remoteRoot: remotePath,
            remoteFiles: cachedSyncRemoteFiles,
            direction: syncDirection,
            rule: syncRule,
            deleteOrphans: syncDeleteOrphans
        )
    }

    func executeSyncPlan() {
        guard let plan = syncPlan, let client else { return }
        showSyncSheet = false
        self.syncPlan = nil

        Task { [weak self] in
            guard let self else { return }
            for item in plan.activeItems {
                switch item.actionType {
                case .upload:
                    guard let localURL = item.localURL, let remotePath = item.remotePath else { continue }
                    if item.isDirectory {
                        try? await client.mkdirRecursive(remotePath)
                    } else {
                        let parent = RemotePath.parent(remotePath)
                        try? await client.mkdirRecursive(parent)
                        queue.enqueue(name: "\(L10n.tr("同步上传", "Sync Upload")): \(item.relativePath)", direction: .upload) { [weak self] progress in
                            let activeClient = await MainActor.run { self?.client ?? client }
                            try await activeClient.upload(localURL, to: remotePath, overwrite: true, progress: progress)
                        }
                    }

                case .download:
                    guard let localURL = item.localURL, let remotePath = item.remotePath else { continue }
                    if item.isDirectory {
                        try? FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
                    } else {
                        try? FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        queue.enqueue(name: "\(L10n.tr("同步下载", "Sync Download")): \(item.relativePath)", direction: .download) { [weak self] progress in
                            let activeClient = await MainActor.run { self?.client ?? client }
                            try await activeClient.download(remotePath, to: localURL, overwrite: true, progress: progress)
                        }
                    }

                case .deleteRemote:
                    if plan.deleteOrphans, let remotePath = item.remotePath {
                        try? await client.remove(remotePath, directory: item.isDirectory)
                    }

                case .deleteLocal:
                    if plan.deleteOrphans, let localURL = item.localURL {
                        try? FileManager.default.removeItem(at: localURL)
                    }

                case .skipIdentical:
                    break
                }
            }

            refreshLocal()
            refreshRemote()
        }
    }

    // MARK: - Drag and Drop Helpers
    func handleDroppedItems(_ payloads: [String], toRemotePane: Bool) {
        for payload in payloads {
            if payload.hasPrefix("remote://") {
                let remoteItemPath = String(payload.dropFirst("remote://".count))
                if !toRemotePane, let entry = remoteFiles.first(where: { $0.path == remoteItemPath }) {
                    download([entry])
                }
            } else if payload.hasPrefix("local://") {
                let localItemPath = String(payload.dropFirst("local://".count))
                if toRemotePane, let entry = localFiles.first(where: { $0.path == localItemPath }) {
                    upload([entry])
                }
            }
        }
    }

    func uploadLocalURLs(_ urls: [URL]) {
        for url in urls {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            let entry = FileEntry(name: url.lastPathComponent, path: url.path, isDirectory: isDir, isSymbolicLink: false, size: 0, modified: nil)
            upload([entry])
        }
    }

    func copyLocalURLs(_ urls: [URL], to targetDirectory: String) {
        let destURL = URL(fileURLWithPath: targetDirectory)
        for url in urls {
            if url.deletingLastPathComponent().path == destURL.path { continue }
            let target = destURL.appendingPathComponent(url.lastPathComponent)
            do {
                if FileManager.default.fileExists(atPath: target.path) {
                    let uniqueTarget = destURL.appendingPathComponent(RemotePath.uniqueName(for: url.lastPathComponent, existingNames: localFiles.map(\.name)))
                    try FileManager.default.copyItem(at: url, to: uniqueTarget)
                } else {
                    try FileManager.default.copyItem(at: url, to: target)
                }
            } catch {
                self.error = L10n.tr("复制文件失败: \(error.localizedDescription)",
                                     "Failed to copy file: \(error.localizedDescription)")
            }
        }
        refreshLocal()
    }

    // MARK: - Compress and Upload
    func compressAndUpload(_ entries: [FileEntry]) {
        guard let client, !entries.isEmpty else { return }
        let zipName: String = {
            if entries.count == 1 {
                return "\(entries[0].name).zip"
            }
            return "Archive.zip"
        }()

        let tempZip = FileManager.default.temporaryDirectory.appendingPathComponent("aether-zip-\(UUID().uuidString)-\(zipName)")
        let sourceURLs = entries.map { URL(fileURLWithPath: $0.path) }

        Task { [weak self] in
            guard let self else { return }
            do {
                try ArchiveHelper.createZip(from: sourceURLs, destinationZipURL: tempZip)
                let targetRemote = try RemotePath.join(remotePath, zipName)
                queue.enqueue(name: "\(L10n.tr("压缩并上传", "Compress & Upload")): \(zipName)", direction: .upload) { [weak self] progress in
                    let activeClient = await MainActor.run { self?.client ?? client }
                    try await activeClient.upload(tempZip, to: targetRemote, overwrite: true, progress: progress)
                    try? FileManager.default.removeItem(at: tempZip)
                    await MainActor.run { self?.refreshRemote() }
                }
            } catch {
                await MainActor.run {
                    self.error = L10n.tr("压缩并上传失败: \(error.localizedDescription)",
                                         "Compress and upload failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Bookmark Export / Import
    func exportBookmarksJSON() -> Data? {
        try? ServerProfile.exportJSON(profiles)
    }

    func importBookmarksJSON(_ data: Data) throws {
        let imported = try ServerProfile.importJSON(data)
        for profile in imported {
            if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
                profiles[idx] = profile
            } else {
                profiles.append(profile)
            }
        }
        persist()
    }

    private func askName(title: String, initial: String) -> String? {
        let alert = NSAlert(); alert.messageText = title
        let field = NSTextField(string: initial); field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.tr("确定", "OK"))
        alert.addButton(withTitle: L10n.tr("取消", "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
}
