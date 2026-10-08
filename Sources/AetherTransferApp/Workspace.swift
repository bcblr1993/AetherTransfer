import AppKit
import SwiftUI
import AetherTransferCore

struct ActivityItem: Identifiable {
    let id: UUID
    let name: String
    let direction: String
    var progress: Double = 0
    var bytes: Int64 = 0
    var total: Int64 = 0
    var state: String = "等待中"
    var error: String?
    var canRetry = true
    var canRetain = false
    var requiresRestart = false
    var phase: String?
    var scope: TransferProgress.Scope = .file
    var hasKnownTotal = false
    var completedItems: Int?
    var totalItems: Int?
    var skippedItems = 0
    var rate: TransferRateEstimate?
    var rateEstimator = TransferRateEstimator()
}

@MainActor final class Workspace: ObservableObject {
    let id = UUID()
    @Published var profiles: [ServerProfile] = []
    @Published var selectedServer: UUID?
    @Published var localPath = FileManager.default.homeDirectoryForCurrentUser.path
    @Published var remotePath = "/"
    @Published var localFiles: [FileEntry] = []
    @Published var remoteFiles: [FileEntry] = []
    @Published private(set) var localRevision = UUID()
    @Published private(set) var remoteRevision = UUID()
    private(set) var localListingPath = FileManager.default.homeDirectoryForCurrentUser.path
    private(set) var remoteListingPath = "/"
    private(set) var connectionRevision = UUID()
    @Published var localSelection: Set<String> = []
    @Published var remoteSelection: Set<String> = []
    @Published var activities: [ActivityItem] = []
    var activityObserver: ((ActivityItem) -> Void)?
    @Published var connecting = false
    @Published var loadingLocal = false
    @Published var loadingRemote = false
    @Published var showHidden = false
    @Published var error: String?
    @Published var hostChallenge: HostChallenge?
    @Published var connectedProfile: ServerProfile?
    @Published var connectionPrompt: ServerProfile?
    @Published var showSync = false
    @Published var showRecovery = false
    @Published var showInspector = false
    @Published var permissionRequest: PermissionRequest?
    @Published var permissionBusy = false
    @Published var focusedRemote = false
    @Published var localViewMode: FileViewMode = .list
    @Published var remoteViewMode: FileViewMode = .list
    private var credentials = Credentials()
    private let repository = ProfileRepository.shared
    private var profileGeneration = UUID()
    private let queue: TransferQueue
    private let editors: FileEditorManager
    private let previews: FilePreviewManager
    private var retryOperations: [UUID: TransferQueue.Operation] = [:]
    private var controls: [UUID: TransferControl] = [:]
    private struct ResumeJob {
        let transfer: ResumableTransfer
        let record: ResumeTransferRecord
        let client: RemoteClient
        let control: TransferControl
        let rateLimit: Int64
    }
    private var resumeJobs: [UUID: ResumeJob] = [:]
    var resumeIDs: Set<UUID> { Set(resumeJobs.values.map { $0.record.id }) }
    private var browseTask: Task<Void, Never>?
    private var localTask: Task<Void, Never>?
    private var localGeneration = UUID()
    private var remoteGeneration = UUID()
    private var authenticationGeneration = UUID()

    struct HostChallenge: Identifiable {
        let id = UUID()
        let key: String
        let profile: ServerProfile
    }
    var client: RemoteClient? {
        guard let profile = connectedProfile, profile.protocolKind != .s3 else { return nil }
        return RemoteClient(profile: profile, credentials: credentials)
    }
    var isS3: Bool { connectedProfile?.protocolKind == .s3 }
    var hasRemoteConnection: Bool { connectedProfile != nil }
    var s3Client: S3Client? {
        guard let profile = connectedProfile, profile.protocolKind == .s3 else { return nil }
        let ca = profile.s3CertificateAuthorityPath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        return S3Client(endpoint: profile.s3Endpoint, credentials: credentials.s3, certificateAuthority: ca)
    }

    func setViewMode(_ mode: FileViewMode) {
        if focusedRemote { remoteViewMode = mode } else { localViewMode = mode }
    }
    var canEditPermissions: Bool {
        let remote = focusedRemote
        let selected = remote ? remoteSelection : localSelection
        guard !permissionBusy, !(remote ? loadingRemote || connecting : loadingLocal), !selected.isEmpty,
              !remote || connectedProfile?.protocolKind.supportsUnixPermissions == true else { return false }
        var found = 0
        for entry in remote ? remoteFiles : localFiles where selected.contains(entry.id) {
            if entry.isSymbolicLink { return false }
            found += 1
            if found == selected.count { return true }
        }
        return found > 0
    }
    func editPermissions(remote: Bool? = nil) {
        if let remote { focusedRemote = remote }
        guard canEditPermissions else { return }
        let entries = (focusedRemote ? remoteFiles : localFiles).filter { (focusedRemote ? remoteSelection : localSelection).contains($0.id) }
        permissionRequest = PermissionRequest(entries: entries, remote: focusedRemote, connection: connectionRevision,
                                              client: focusedRemote ? client : nil)
    }

    init(queue: TransferQueue = TransferQueue(limit: 2), editors: FileEditorManager = FileEditorManager(),
         previews: FilePreviewManager = FilePreviewManager()) {
        self.queue = queue; self.editors = editors; self.previews = previews
        reloadProfiles(); refreshLocal()
    }
    @discardableResult func save(_ profile: ServerProfile, credentials: Credentials, remember: Bool) async throws -> ServerProfile {
        profileGeneration = UUID()
        let saved = try await repository.save(profile, credentials: credentials, remember: remember)
        profiles = saved.1; return saved.0
    }
    func removeProfile(_ profile: ServerProfile) {
        let alert = NSAlert()
        alert.messageText = L10n.text("移除服务器收藏？")
        alert.informativeText = L10n.format("将移除“%@”及其保存的钥匙串凭据。服务器上的文件不会改变。", String(describing: profile.name.isEmpty ? profile.host : profile.name))
        alert.addButton(withTitle: L10n.text("移除收藏")); alert.addButton(withTitle: L10n.text("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        profileGeneration = UUID()
        Task {
            do {
                profiles = try await repository.remove(profile)
                if selectedServer == profile.id { selectedServer = nil }
            } catch { self.error = error.localizedDescription }
        }
    }
    func exportProfiles() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "AetherTransfer-servers.json"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task {
            do {
                try await repository.export(to: destination)
            } catch { self.error = error.localizedDescription }
        }
    }
    func importProfiles() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        Task {
            do {
                let data = try await Task.detached {
                    let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 1024 * 1024 else { throw TransferError.remote(L10n.text("收藏文件超过 1 MiB。")) }
                    return try Data(contentsOf: source)
                }.value
                profileGeneration = UUID()
                profiles = try await repository.importing(data)
            } catch { self.error = error.localizedDescription }
        }
    }
    func reloadProfiles() {
        let generation = UUID(); profileGeneration = generation
        Task {
            do {
                let values = try await repository.load()
                if generation == profileGeneration { profiles = values }
            } catch { if generation == profileGeneration { self.error = error.localizedDescription } }
        }
    }
    var canReceiveUpload: Bool { hasRemoteConnection && !connecting && !loadingRemote }
    var canUploadSelection: Bool { canReceiveUpload && !loadingLocal && !localSelection.isEmpty }
    var canDownloadSelection: Bool { hasRemoteConnection && !connecting && !loadingRemote && !loadingLocal && !remoteSelection.isEmpty }
    func uploadURLs(_ urls: [URL]) {
        guard canReceiveUpload, !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return }
        if let s3Client { uploadS3URLs(urls, client: s3Client, prefix: remotePath, existing: remoteFiles); return }
        guard let client else { return }
        let destination = remotePath, remoteNames = Set(remoteFiles.map(\.name))
        Task {
            do {
                let entries = try await Task.detached {
                    try urls.filter(\.isFileURL).map { url in
                        let info = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
                        return FileEntry(name: url.lastPathComponent, path: url.path, isDirectory: info.isDirectory == true,
                                         isSymbolicLink: info.isSymbolicLink == true, size: Int64(info.fileSize ?? 0))
                    }
                }.value
                upload(entries, client: client, destination: destination, remoteNames: remoteNames)
            } catch { self.error = error.localizedDescription }
        }
    }
    func connectSaved(_ profile: ServerProfile) {
        let generation = UUID(); authenticationGeneration = generation
        Task {
            do {
                let credentials = try await Task.detached { try CredentialStore.load(profile: profile) }.value
                guard generation == authenticationGeneration else { return }
                let missing = profile.protocolKind == .s3 ? credentials.accessKey.isEmpty || credentials.secretKey.isEmpty
                    : credentials.password.isEmpty && profile.privateKeyPath.isEmpty
                if missing { connectionPrompt = profile } else { connect(profile, credentials: credentials) }
            } catch { self.error = error.localizedDescription }
        }
    }
    func connect(_ profile: ServerProfile, credentials: Credentials) {
        guard !permissionBusy else { error = L10n.text("请先完成或停止权限操作。"); return }
        authenticationGeneration = UUID(); hostChallenge = nil
        browseTask?.cancel()
        connectionRevision = UUID()
        connectedProfile = profile; self.credentials = credentials
        selectedServer = profile.id; remotePath = profile.protocolKind == .s3 ? profile.initialPath : RemotePath.normalize(profile.initialPath)
        remoteListingPath = remotePath
        remoteFiles = []; remoteRevision = UUID(); connecting = true
        refreshRemote()
    }
    func disconnect() {
        guard !permissionBusy else { error = L10n.text("请先完成或停止权限操作。"); return }
        authenticationGeneration = UUID()
        browseTask?.cancel(); remoteGeneration = UUID(); connectionRevision = UUID(); connectedProfile = nil; remoteFiles = []
        remoteSelection = []; remoteRevision = UUID(); connecting = false; loadingRemote = false; credentials = Credentials()
    }
    func approveHostKey() {
        guard let challenge = hostChallenge else { return }
        var profile = challenge.profile; profile.trustedHostKey = challenge.key
        profileGeneration = UUID()
        Task {
            do { profiles = try await repository.trust(profile) }
            catch { self.error = error.localizedDescription }
        }
        hostChallenge = nil; connect(profile, credentials: credentials)
    }
    func refreshLocal() {
        localTask?.cancel()
        let path = localPath, generation = UUID()
        localGeneration = generation; loadingLocal = true
        localTask = Task {
            do {
                // All presentations filter the same complete metadata snapshot.
                // Retained columns can reveal hidden items without another IO pass.
                let files = try await Task.detached { try LocalFiles.list(URL(fileURLWithPath: path), showHidden: true) }.value
                guard generation == localGeneration else { return }
                localListingPath = path; localFiles = files; localRevision = UUID(); localSelection = []
            } catch {
                if generation == localGeneration { localListingPath = path; localFiles = []; localRevision = UUID(); localSelection = []; self.error = error.localizedDescription }
            }
            if generation == localGeneration { loadingLocal = false }
        }
    }
    func refreshRemote() {
        let client = self.client, s3 = s3Client
        guard client != nil || s3 != nil else { return }
        browseTask?.cancel()
        let path = remotePath, generation = UUID()
        remoteGeneration = generation; loadingRemote = true
        browseTask = Task {
            do {
                let files: [FileEntry]
                if let client { files = try await client.list(path) }
                else if let s3 {
                    let objects = try await s3.list(prefix: path)
                    files = await Task.detached { objects.map(\.fileEntry) }.value
                } else { return }
                guard generation == remoteGeneration else { return }
                remoteListingPath = path; remoteFiles = files; remoteRevision = UUID(); remoteSelection = []
            } catch let failure as TransferError {
                guard generation == remoteGeneration else { return }
                remoteListingPath = path; remoteFiles = []; remoteRevision = UUID(); remoteSelection = []
                if case .hostKeyRequired(let key, let changed) = failure, !changed, let client {
                    hostChallenge = HostChallenge(key: key, profile: client.profile)
                } else { error = failure.localizedDescription }
            } catch is CancellationError { }
            catch {
                if generation == remoteGeneration { remoteListingPath = path; remoteFiles = []; remoteRevision = UUID(); remoteSelection = []; self.error = error.localizedDescription }
            }
            if generation == remoteGeneration { loadingRemote = false; connecting = false }
        }
    }
    /// A visited column is an ordinary listing snapshot, refreshed explicitly
    /// like any file view. Switching columns never blocks on a directory read.
    func activateColumn(_ snapshot: FileColumnSnapshot, remote: Bool, selection: Set<String>) {
        guard !remote || (hasRemoteConnection && !connecting) else { return }
        if remote {
            browseTask?.cancel(); remoteGeneration = UUID()
            remotePath = snapshot.path; remoteListingPath = snapshot.path; remoteFiles = snapshot.files
            remoteSelection = selection; loadingRemote = false; remoteRevision = UUID()
        } else {
            localTask?.cancel(); localGeneration = UUID()
            localPath = snapshot.path; localListingPath = snapshot.path; localFiles = snapshot.files
            localSelection = selection; loadingLocal = false; localRevision = UUID()
        }
        focusedRemote = remote
    }
    func open(_ entry: FileEntry, remote: Bool) {
        if entry.isDirectory {
            if remote { remotePath = entry.path; refreshRemote() }
            else { localPath = entry.path; refreshLocal() }
        } else if remote { download([entry]) }
        else { NSWorkspace.shared.open(URL(fileURLWithPath: entry.path)) }
    }
    func parent(remote: Bool) {
        if remote { remotePath = isS3 ? S3BrowserPath.parent(remotePath) : RemotePath.parent(remotePath); refreshRemote() }
        else { localPath = URL(fileURLWithPath: localPath).deletingLastPathComponent().path; refreshLocal() }
    }
    func edit(_ entry: FileEntry, remote: Bool) {
        guard !entry.isDirectory, !entry.isSymbolicLink else { return }
        if remote, let s3Client, let key = entry.s3Key { editors.open(entry, source: .s3(s3Client, key)) }
        else if remote, let client { editors.open(entry, source: .remote(client, entry.path)) }
        else if !remote { editors.open(entry, source: .local(URL(fileURLWithPath: entry.path))) }
    }
    func editSelection() {
        let files = focusedRemote ? remoteFiles : localFiles, selection = focusedRemote ? remoteSelection : localSelection
        if let entry = files.first(where: { selection.contains($0.id) }) { edit(entry, remote: focusedRemote) }
    }
    func preview(_ entry: FileEntry, remote: Bool) {
        guard !entry.isDirectory, !entry.isSymbolicLink else { return }
        if remote, let s3Client, let key = entry.s3Key { previews.open(entry, source: .s3(s3Client, key)) }
        else if remote, let client { previews.open(entry, source: .remote(client, entry.path)) }
        else if !remote { previews.open(entry, source: .local(URL(fileURLWithPath: entry.path))) }
    }
    func previewSelection(remote: Bool? = nil) {
        let remote = remote ?? focusedRemote
        let files = remote ? remoteFiles : localFiles, selection = remote ? remoteSelection : localSelection
        if let entry = files.first(where: { selection.contains($0.id) }) { preview(entry, remote: remote) }
    }
    func chooseLocal() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { localPath = url.path; refreshLocal() }
    }
    func uploadSelection() { if canUploadSelection { upload(localFiles.filter { localSelection.contains($0.id) }) } }
    func downloadSelection() { if canDownloadSelection { download(remoteFiles.filter { remoteSelection.contains($0.id) }) } }
    func enqueueSync(_ plan: SyncPlan, left: SyncRoot, right: SyncRoot, selected: Set<String>, resolutions: [String: SyncDirection]) {
        let rate = Int64(max(0, UserDefaults.standard.integer(forKey: "transferRateKiB"))) * 1024
        enqueue(name: L10n.format("%@ 个同步操作", String(describing: selected.count)), direction: "同步", retryable: false, scope: .synchronization) { control, progress in
            do {
                _ = try await SyncEngine.execute(plan, left: left, right: right, selected: selected, resolutions: resolutions,
                                                 control: control, rateLimit: rate, progress: progress)
            } catch S3Error.cleanupRequired(let record) {
                do { try await S3CleanupStore.shared.add(record) }
                catch { throw TransferError.remote(L10n.format("S3 分片清理未完成，清理记录保存失败：%@", String(describing: error.localizedDescription))) }
                throw TransferError.remote(L10n.text("S3 分片清理未完成；请在“保留的传输”中重新连接并重试清理。"))
            }
        }
    }
    func upload(_ entries: [FileEntry]) {
        guard canReceiveUpload else { return }
        if let s3Client { uploadS3(entries, client: s3Client, prefix: remotePath, existing: remoteFiles); return }
        guard let client else { return }
        upload(entries, client: client, destination: remotePath, remoteNames: Set(remoteFiles.map(\.name)))
    }
    private func upload(_ entries: [FileEntry], client: RemoteClient, destination: String, remoteNames: Set<String>) {
        let rateLimit = Int64(max(0, UserDefaults.standard.integer(forKey: "transferRateKiB"))) * 1024
        for entry in entries {
            do {
                let target = try RemotePath.join(destination, entry.name)
                let exists = remoteNames.contains(entry.name)
                guard let policy = exists ? conflictPolicy(entry.name, directory: entry.isDirectory) : .reject else { continue }
                if !entry.isDirectory {
                    guard !entry.isSymbolicLink else { throw ResumeTransferError.unsupportedVersion }
                    enqueueFileResume(name: entry.name, direction: "上传", client: client, rateLimit: rateLimit) { controlled in
                        try await controlled.resumableUpload(URL(fileURLWithPath: entry.path), to: target, policy: policy)
                    }
                    continue
                }
                enqueue(name: entry.name, direction: "上传", retryable: false, scope: .directory) { control, progress in
                    let controlled = RemoteClient(profile: client.profile, credentials: client.credentials, control: control, rateLimit: rateLimit)
                    try await controlled.uploadTree(URL(fileURLWithPath: entry.path), to: target, policy: policy, progress: progress)
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    func download(_ entries: [FileEntry]) {
        guard hasRemoteConnection, !connecting, !loadingRemote, !loadingLocal else { return }
        if let s3Client { downloadS3(entries, client: s3Client); return }
        guard let client else { return }
        let rateLimit = Int64(max(0, UserDefaults.standard.integer(forKey: "transferRateKiB"))) * 1024
        let localNames = Set(localFiles.map(\.name))
        for entry in entries {
            let target = URL(fileURLWithPath: localPath).appendingPathComponent(entry.name)
            let exists = localNames.contains(entry.name)
            guard let policy = exists ? conflictPolicy(entry.name, directory: entry.isDirectory) : .reject else { continue }
            if !entry.isDirectory {
                enqueueFileResume(name: entry.name, direction: "下载", client: client, rateLimit: rateLimit) { controlled in
                    try await controlled.resumableDownload(entry, to: target, policy: policy)
                }
                continue
            }
            enqueue(name: entry.name, direction: "下载", retryable: false, scope: .directory) { control, progress in
                let controlled = RemoteClient(profile: client.profile, credentials: client.credentials, control: control, rateLimit: rateLimit)
                try await controlled.downloadTree(entry, to: target, policy: policy, progress: progress)
            }
        }
    }
    func conflictPolicy(_ name: String, directory: Bool) -> ConflictPolicy? {
        let alert = NSAlert(); alert.messageText = L10n.format("目标已存在：%@", String(describing: name))
        alert.informativeText = directory ? L10n.text("合并目录将覆盖其中同名文件。也可以保留两份或跳过。") : L10n.text("请选择覆盖、保留两份或跳过。")
        alert.addButton(withTitle: directory ? L10n.text("合并并覆盖") : L10n.text("覆盖"))
        alert.addButton(withTitle: L10n.text("保留两份")); alert.addButton(withTitle: L10n.text("跳过")); alert.addButton(withTitle: L10n.text("取消"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .overwrite
        case .alertSecondButtonReturn: return .keepBoth
        case .alertThirdButtonReturn: return .skip
        default: return nil
        }
    }
    func enqueue(name: String, direction: String, retryable: Bool = true, scope: TransferProgress.Scope = .file,
                         operation: @escaping @Sendable (TransferControl, @escaping @Sendable (TransferProgress) -> Void) async throws -> Void) {
        let id = UUID(); activities.insert(ActivityItem(id: id, name: name, direction: direction, canRetry: retryable, scope: scope), at: 0)
        activityObserver?(activities[0])
        let control = TransferControl(); controls[id] = control
        let wrapped: TransferQueue.Operation = { progress in try await operation(control, progress) }
        if retryable { retryOperations[id] = wrapped }
        submit(id, operation: wrapped)
    }
    private func submit(_ id: UUID, operation: @escaping TransferQueue.Operation) {
        Task { [self] in
            await queue.enqueue(id: id, operation: operation) { [weak self] id, event in
                let time = ContinuousClock.now
                Task { @MainActor in self?.receive(id, event, at: time) }
            }
        }
    }
    private func enqueueFileResume(name: String, direction: String, client: RemoteClient, rateLimit: Int64,
                                   prepare: @escaping @Sendable (RemoteClient) async throws -> ResumableTransfer?) {
        let id = UUID(), control = TransferControl()
        activities.insert(ActivityItem(id: id, name: name, direction: direction), at: 0)
        activityObserver?(activities[0])
        controls[id] = control
        let operation: TransferQueue.Operation = { [weak self] progress in
            let controlled = RemoteClient(profile: client.profile, credentials: client.credentials, control: control,
                                          rateLimit: rateLimit, certificateAuthority: client.certificateAuthority)
            // Preparation uses the same queue slot as transfer, including metadata and conflict checks.
            guard let transfer = try await prepare(controlled) else { return }
            try Task.checkCancellation()
            let record = await transfer.checkpoint()
            let job = ResumeJob(transfer: transfer, record: record, client: client, control: control, rateLimit: rateLimit)
            guard let self, await self.attachResume(job, to: id) else { throw CancellationError() }
            try await transfer.run(client: controlled, progress: progress)
        }
        retryOperations[id] = operation
        submit(id, operation: operation)
    }
    private func attachResume(_ job: ResumeJob, to id: UUID) -> Bool {
        guard let index = activities.firstIndex(where: { $0.id == id }) else { return false }
        resumeJobs[id] = job
        activities[index].canRetain = true
        activities[index].requiresRestart = job.record.direction == .upload && job.record.endpoint.protocolKind.isWebDAV
        return true
    }
    private func enqueueResume(_ transfer: ResumableTransfer, client: RemoteClient, rateLimit: Int64,
                               restart: Bool = false) async {
        let record = await transfer.checkpoint()
        guard !resumeIDs.contains(record.id) else { return }
        let id = UUID(), control = TransferControl()
        let job = ResumeJob(transfer: transfer, record: record, client: client, control: control, rateLimit: rateLimit)
        resumeJobs[id] = job; controls[id] = control
        activities.insert(ActivityItem(id: id, name: record.name, direction: record.direction == .upload ? "上传" : "下载",
                                       bytes: record.retainedBytes, total: record.expectedSize, canRetain: true,
                                       requiresRestart: record.direction == .upload && record.endpoint.protocolKind.isWebDAV,
                                       hasKnownTotal: record.expectedSize > 0), at: 0)
        activityObserver?(activities[0])
        submit(id, operation: resumeOperation(job, restart: restart))
    }
    private func resumeOperation(_ job: ResumeJob, restart: Bool) -> TransferQueue.Operation {
        { progress in
            let controlled = RemoteClient(profile: job.client.profile, credentials: job.client.credentials,
                                          control: job.control, rateLimit: job.rateLimit,
                                          certificateAuthority: job.client.certificateAuthority)
            try await job.transfer.run(client: controlled, restartWebDAVUpload: restart, progress: progress)
        }
    }
    func recover(_ record: ResumeTransferRecord, restart: Bool) async throws {
        guard let client, ResumeEndpoint(client.profile) == record.endpoint else { throw ResumeTransferError.invalidCheckpoint }
        let transfer = try ResumableTransfer(restoring: record)
        let rate = Int64(max(0, UserDefaults.standard.integer(forKey: "transferRateKiB"))) * 1024
        await enqueueResume(transfer, client: client, rateLimit: rate, restart: restart)
    }
    private func receive(_ id: UUID, _ event: QueueEvent, at time: ContinuousClock.Instant) {
        switch event {
        case .queued: setState(id, "等待中")
        case .running: setState(id, "传输中")
        case .progress(let progress):
            guard let index = activities.firstIndex(where: { $0.id == id }), activities[index].state == "传输中" else { return }
            var item = activities[index]
            item.bytes = progress.completed; item.total = progress.total
            item.progress = progress.fraction; item.scope = progress.scope; item.hasKnownTotal = progress.hasKnownTotal
            item.completedItems = progress.completedItems; item.totalItems = progress.totalItems; item.skippedItems = progress.skippedItems
            item.phase = progress.phase
            item.rate = item.rateEstimator.observe(progress, at: time)
            activities[index] = item
            activityObserver?(item)
        case .completed: setState(id, "完成"); retryOperations[id] = nil; controls[id] = nil; resumeJobs[id] = nil; refreshLocal(); refreshRemote()
        case .suspended:
            setState(id, "待续传"); refreshLocal(); refreshRemote()
            if let job = resumeJobs[id] {
                Task {
                    let record = await job.transfer.checkpoint()
                    guard let index = activities.firstIndex(where: { $0.id == id }), activities[index].state == "待续传" else { return }
                    activities[index].bytes = record.retainedBytes; activities[index].total = record.expectedSize
                    activities[index].hasKnownTotal = record.expectedSize > 0
                    activities[index].progress = record.expectedSize > 0 ? Double(record.retainedBytes) / Double(record.expectedSize) : 0
                }
            }
        case .cancelled:
            setState(id, "已取消")
            if let job = resumeJobs[id], let index = activities.firstIndex(where: { $0.id == id }) {
                activities[index].canRetry = false; activities[index].canRetain = false
                setState(id, "清理中")
                Task {
                    do { try await job.transfer.discard(client: job.client); setState(id, "已取消") }
                    catch { setState(id, "失败", error: L10n.format("进度清理未完成，可在保留的传输中重试：%@", String(describing: error.localizedDescription))) }
                }
            }
            resumeJobs[id] = nil; refreshLocal(); refreshRemote()
        case .failed(let error): setState(id, "失败", error: error); refreshLocal(); refreshRemote()
        }
    }
    private func setState(_ id: UUID, _ state: String, error: String? = nil) {
        guard let index = activities.firstIndex(where: { $0.id == id }) else { return }
        var item = activities[index]
        item.state = state; item.error = error; item.phase = nil
        item.rate = nil; item.rateEstimator.reset()
        if state == "完成" { item.progress = 1 }
        activities[index] = item
        activityObserver?(item)
    }
    func cancel(_ id: UUID) {
        controls[id]?.resume()
        Task { await queue.cancel(id) }
    }
    func retain(_ id: UUID) { controls[id]?.retainProgress(); setState(id, "保留中") }
    func pause(_ id: UUID) { controls[id]?.pause(); setState(id, "已暂停") }
    func resume(_ id: UUID) { controls[id]?.resume(); setState(id, "传输中") }
    func retry(_ id: UUID) {
        if let job = resumeJobs[id] {
            job.control.resume()
            setState(id, "等待中")
            submit(id, operation: resumeOperation(job, restart: job.record.direction == .upload && job.record.endpoint.protocolKind.isWebDAV))
            return
        }
        guard let operation = retryOperations[id] else { return }
        controls[id]?.resume()
        setState(id, "等待中"); submit(id, operation: operation)
    }
    func discardRetained(_ id: UUID) {
        guard let job = resumeJobs[id] else { return }
        let alert = NSAlert(); alert.messageText = L10n.format("丢弃“%@”的保留进度？", String(describing: job.record.name))
        alert.informativeText = L10n.text("将清理此任务的部分文件。原始文件和原有目标文件会保留。")
        alert.addButton(withTitle: L10n.text("丢弃进度")); alert.addButton(withTitle: L10n.text("返回"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        setState(id, "清理中")
        Task {
            do {
                try await job.transfer.discard(client: job.client)
                resumeJobs[id] = nil; controls[id] = nil; setState(id, "已取消")
                if let index = activities.firstIndex(where: { $0.id == id }) { activities[index].canRetry = false; activities[index].canRetain = false }
            } catch { setState(id, "失败", error: L10n.format("进度清理未完成：%@", String(describing: error.localizedDescription))) }
        }
    }
    func clearFinishedActivities() {
        let ended = Set(activities.filter { ["完成", "失败", "已取消"].contains($0.state) }.map(\.id))
        activities.removeAll { ended.contains($0.id) }
        for id in ended { retryOperations[id] = nil; controls[id] = nil; resumeJobs[id] = nil }
    }
    func createFolder(remote: Bool) {
        guard let name = askName(title: L10n.text("新建文件夹"), initial: L10n.text("新文件夹")) else { return }
        do {
            if remote && isS3 {
                guard let s3Client else { return }
                let prefix = try S3BrowserPath.append(name, to: remotePath) + "/"
                Task { do { try await s3Client.createPrefix(prefix); refreshRemote() } catch { self.error = error.localizedDescription } }
                return
            }
            guard !remote || client != nil else { return }
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
        guard !remote || !isS3 else { error = L10n.text("S3 对象复制 / 重命名尚未接入。"); return }
        guard !remote || client != nil else { return }
        guard let name = askName(title: L10n.text("重命名"), initial: entry.name) else { return }
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
        guard !remote || hasRemoteConnection else { return }
        guard !remote || !isS3 || !entry.isDirectory else { error = L10n.text("S3 前缀递归删除尚未接入。"); return }
        let alert = NSAlert(); alert.messageText = L10n.format("删除 %@？", String(describing: entry.name))
        alert.informativeText = remote ? L10n.text("服务器删除无法从本机废纸篓恢复。") : L10n.text("文件将移到废纸篓。")
        alert.addButton(withTitle: L10n.text("删除")); alert.addButton(withTitle: L10n.text("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if remote, let s3Client, let key = entry.s3Key {
            Task { do { try await s3Client.remove(key); refreshRemote() } catch { self.error = error.localizedDescription } }
        } else if remote, let client {
            Task { do { try await client.remove(entry.path, directory: entry.isDirectory); refreshRemote() } catch { self.error = error.localizedDescription } }
        } else if !remote {
            do { try FileManager.default.trashItem(at: URL(fileURLWithPath: entry.path), resultingItemURL: nil); refreshLocal() }
            catch { self.error = error.localizedDescription }
        }
    }
    private func askName(title: String, initial: String) -> String? {
        let alert = NSAlert(); alert.messageText = title
        let field = NSTextField(string: initial); field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: L10n.text("确定")); alert.addButton(withTitle: L10n.text("取消"))
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
}
