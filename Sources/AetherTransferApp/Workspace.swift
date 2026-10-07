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
}

@MainActor final class Workspace: ObservableObject {
    @Published var profiles: [ServerProfile] = []
    @Published var selectedServer: UUID?
    @Published var localPath = FileManager.default.homeDirectoryForCurrentUser.path
    @Published var remotePath = "/"
    @Published var localFiles: [FileEntry] = []
    @Published var remoteFiles: [FileEntry] = []
    @Published private(set) var localRevision = UUID()
    @Published private(set) var remoteRevision = UUID()
    @Published var localSelection: Set<String> = []
    @Published var remoteSelection: Set<String> = []
    @Published var activities: [ActivityItem] = []
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
    private var credentials = Credentials()
    private let store = ProfileStore()
    private let queue: TransferQueue
    private let editors: FileEditorManager
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

    struct HostChallenge: Identifiable {
        let id = UUID()
        let key: String
        let profile: ServerProfile
    }
    var client: RemoteClient? { connectedProfile.map { RemoteClient(profile: $0, credentials: credentials) } }

    init(queue: TransferQueue = TransferQueue(limit: 2), editors: FileEditorManager = FileEditorManager()) {
        self.queue = queue; self.editors = editors
        do { profiles = try store.load() } catch { self.error = error.localizedDescription }
        refreshLocal()
    }
    func persist() { do { try store.save(profiles) } catch { self.error = error.localizedDescription } }
    @discardableResult func save(_ profile: ServerProfile, credentials: Credentials, remember: Bool) throws -> ServerProfile {
        try profile.validate()
        profiles = try store.load()
        var profile = profile
        if let previous = profiles.first(where: { $0.id == profile.id }),
           previous.host != profile.host || previous.port != profile.port || previous.protocolKind != profile.protocolKind {
            profile.trustedHostKey = nil
        }
        if remember {
            try CredentialStore.save(credentials.password, id: profile.id)
            try CredentialStore.save(credentials.passphrase, id: profile.id, kind: "passphrase")
        }
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile }
        else { profiles.append(profile) }
        try store.save(profiles)
        return profile
    }
    func removeProfile(_ profile: ServerProfile) {
        let alert = NSAlert()
        alert.messageText = "移除服务器收藏？"
        alert.informativeText = "将移除“\(profile.name.isEmpty ? profile.host : profile.name)”及其保存的钥匙串凭据。服务器上的文件不会改变。"
        alert.addButton(withTitle: "移除收藏"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            var saved = try store.load(); saved.removeAll { $0.id == profile.id }
            try CredentialStore.save("", id: profile.id)
            try CredentialStore.save("", id: profile.id, kind: "passphrase")
            try store.save(saved); profiles = saved
            if selectedServer == profile.id { selectedServer = nil }
        } catch { self.error = error.localizedDescription }
    }
    func exportProfiles() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "AetherTransfer-servers.json"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task {
            do {
                try await Task.detached { try ProfileStore(file: destination).save(ProfileStore().load()) }.value
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
                    guard size <= 1024 * 1024 else { throw TransferError.remote("收藏文件超过 1 MiB。") }
                    return try Data(contentsOf: source)
                }.value
                let values = try ProfileStore.importing(data, into: store.load())
                try store.save(values); profiles = values
            } catch { self.error = error.localizedDescription }
        }
    }
    func reloadProfiles() {
        do { profiles = try store.load() } catch { self.error = error.localizedDescription }
    }
    func uploadURLs(_ urls: [URL]) {
        Task {
            do {
                let entries = try await Task.detached {
                    try urls.filter(\.isFileURL).map { url in
                        let info = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
                        return FileEntry(name: url.lastPathComponent, path: url.path, isDirectory: info.isDirectory == true,
                                         isSymbolicLink: info.isSymbolicLink == true, size: Int64(info.fileSize ?? 0))
                    }
                }.value
                upload(entries)
            } catch { self.error = error.localizedDescription }
        }
    }
    func connectSaved(_ profile: ServerProfile) {
        do {
            let credentials = Credentials(password: try CredentialStore.load(id: profile.id),
                                          passphrase: try CredentialStore.load(id: profile.id, kind: "passphrase"))
            if credentials.password.isEmpty && profile.privateKeyPath.isEmpty { connectionPrompt = profile }
            else { connect(profile, credentials: credentials) }
        } catch { self.error = error.localizedDescription }
    }
    func connect(_ profile: ServerProfile, credentials: Credentials) {
        browseTask?.cancel()
        connectedProfile = profile; self.credentials = credentials
        selectedServer = profile.id; remotePath = RemotePath.normalize(profile.initialPath)
        remoteFiles = []; remoteRevision = UUID(); connecting = true
        refreshRemote()
    }
    func disconnect() {
        browseTask?.cancel(); remoteGeneration = UUID(); connectedProfile = nil; remoteFiles = []
        remoteSelection = []; remoteRevision = UUID(); connecting = false; loadingRemote = false
    }
    func approveHostKey() {
        guard let challenge = hostChallenge else { return }
        var profile = challenge.profile; profile.trustedHostKey = challenge.key
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile; persist() }
        hostChallenge = nil; connect(profile, credentials: credentials)
    }
    func refreshLocal() {
        localTask?.cancel()
        let path = localPath, hidden = showHidden, generation = UUID()
        localGeneration = generation; loadingLocal = true
        localTask = Task {
            do {
                let files = try await Task.detached { try LocalFiles.list(URL(fileURLWithPath: path), showHidden: hidden) }.value
                guard generation == localGeneration else { return }
                localFiles = files; localRevision = UUID(); localSelection = []
            } catch {
                if generation == localGeneration { localFiles = []; localRevision = UUID(); localSelection = []; self.error = error.localizedDescription }
            }
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
                remoteFiles = files; remoteRevision = UUID(); remoteSelection = []
            } catch let failure as TransferError {
                guard generation == remoteGeneration else { return }
                remoteFiles = []; remoteRevision = UUID(); remoteSelection = []
                if case .hostKeyRequired(let key, let changed) = failure, !changed {
                    hostChallenge = HostChallenge(key: key, profile: client.profile)
                } else { error = failure.localizedDescription }
            } catch is CancellationError { }
            catch {
                if generation == remoteGeneration { remoteFiles = []; remoteRevision = UUID(); remoteSelection = []; self.error = error.localizedDescription }
            }
            if generation == remoteGeneration { loadingRemote = false; connecting = false }
        }
    }
    func open(_ entry: FileEntry, remote: Bool) {
        if entry.isDirectory {
            if remote { remotePath = entry.path; refreshRemote() }
            else { localPath = entry.path; refreshLocal() }
        } else if remote { download([entry]) }
        else { NSWorkspace.shared.open(URL(fileURLWithPath: entry.path)) }
    }
    func parent(remote: Bool) {
        if remote { remotePath = RemotePath.parent(remotePath); refreshRemote() }
        else { localPath = URL(fileURLWithPath: localPath).deletingLastPathComponent().path; refreshLocal() }
    }
    func edit(_ entry: FileEntry, remote: Bool) {
        guard !entry.isDirectory, !entry.isSymbolicLink else { return }
        if remote, let client { editors.open(entry, source: .remote(client, entry.path)) }
        else if !remote { editors.open(entry, source: .local(URL(fileURLWithPath: entry.path))) }
    }
    func editSelection() {
        if let entry = remoteFiles.first(where: { remoteSelection.contains($0.id) }) { edit(entry, remote: true) }
        else if let entry = localFiles.first(where: { localSelection.contains($0.id) }) { edit(entry, remote: false) }
    }
    func chooseLocal() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { localPath = url.path; refreshLocal() }
    }
    func uploadSelection() { upload(localFiles.filter { localSelection.contains($0.id) }) }
    func downloadSelection() { download(remoteFiles.filter { remoteSelection.contains($0.id) }) }
    func enqueueSync(_ plan: SyncPlan, left: SyncRoot, right: SyncRoot, selected: Set<String>, resolutions: [String: SyncDirection]) {
        let rate = Int64(max(0, UserDefaults.standard.integer(forKey: "transferRateKiB"))) * 1024
        enqueue(name: "\(selected.count) 个同步操作", direction: "同步", retryable: false) { control, progress in
            _ = try await SyncEngine.execute(plan, left: left, right: right, selected: selected, resolutions: resolutions,
                                             control: control, rateLimit: rate, progress: progress)
        }
    }
    func upload(_ entries: [FileEntry]) {
        guard let client else { return }
        let rateLimit = Int64(max(0, UserDefaults.standard.integer(forKey: "transferRateKiB"))) * 1024
        for entry in entries {
            do {
                let target = try RemotePath.join(remotePath, entry.name)
                let exists = remoteFiles.contains { $0.name == entry.name }
                guard let policy = exists ? conflictPolicy(entry.name, directory: entry.isDirectory) : .reject else { continue }
                if !entry.isDirectory {
                    guard !entry.isSymbolicLink else { throw ResumeTransferError.unsupportedVersion }
                    Task {
                        do {
                            if let transfer = try await client.resumableUpload(URL(fileURLWithPath: entry.path), to: target, policy: policy) {
                                await enqueueResume(transfer, client: client, rateLimit: rateLimit)
                            }
                        } catch { self.error = error.localizedDescription }
                    }
                    continue
                }
                enqueue(name: entry.name, direction: "上传") { control, progress in
                    let controlled = RemoteClient(profile: client.profile, credentials: client.credentials, control: control, rateLimit: rateLimit)
                    try await controlled.uploadTree(URL(fileURLWithPath: entry.path), to: target, policy: policy, progress: progress)
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    func download(_ entries: [FileEntry]) {
        guard let client else { return }
        let rateLimit = Int64(max(0, UserDefaults.standard.integer(forKey: "transferRateKiB"))) * 1024
        for entry in entries {
            let target = URL(fileURLWithPath: localPath).appendingPathComponent(entry.name)
            let exists = FileManager.default.fileExists(atPath: target.path)
            guard let policy = exists ? conflictPolicy(entry.name, directory: entry.isDirectory) : .reject else { continue }
            if !entry.isDirectory {
                Task {
                    do {
                        if let transfer = try await client.resumableDownload(entry, to: target, policy: policy) {
                            await enqueueResume(transfer, client: client, rateLimit: rateLimit)
                        }
                    } catch { self.error = error.localizedDescription }
                }
                continue
            }
            enqueue(name: entry.name, direction: "下载") { control, progress in
                let controlled = RemoteClient(profile: client.profile, credentials: client.credentials, control: control, rateLimit: rateLimit)
                try await controlled.downloadTree(entry, to: target, policy: policy, progress: progress)
            }
        }
    }
    private func conflictPolicy(_ name: String, directory: Bool) -> ConflictPolicy? {
        let alert = NSAlert(); alert.messageText = "目标已存在：\(name)"
        alert.informativeText = directory ? "合并目录将覆盖其中同名文件。也可以保留两份或跳过。" : "请选择覆盖、保留两份或跳过。"
        alert.addButton(withTitle: directory ? "合并并覆盖" : "覆盖")
        alert.addButton(withTitle: "保留两份"); alert.addButton(withTitle: "跳过"); alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .overwrite
        case .alertSecondButtonReturn: return .keepBoth
        case .alertThirdButtonReturn: return .skip
        default: return nil
        }
    }
    private func enqueue(name: String, direction: String, retryable: Bool = true,
                         operation: @escaping @Sendable (TransferControl, @escaping @Sendable (TransferProgress) -> Void) async throws -> Void) {
        let id = UUID(); activities.insert(ActivityItem(id: id, name: name, direction: direction, canRetry: retryable), at: 0)
        let control = TransferControl(); controls[id] = control
        let wrapped: TransferQueue.Operation = { progress in try await operation(control, progress) }
        if retryable { retryOperations[id] = wrapped }
        submit(id, operation: wrapped)
    }
    private func submit(_ id: UUID, operation: @escaping TransferQueue.Operation) {
        Task { [self] in
            await queue.enqueue(id: id, operation: operation) { [weak self] id, event in
                Task { @MainActor in self?.receive(id, event) }
            }
        }
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
                                       requiresRestart: record.direction == .upload && record.endpoint.protocolKind.isWebDAV), at: 0)
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
    private func receive(_ id: UUID, _ event: QueueEvent) {
        switch event {
        case .queued: setState(id, "等待中")
        case .running: setState(id, "传输中")
        case .progress(let progress):
            guard let index = activities.firstIndex(where: { $0.id == id }), activities[index].state == "传输中" else { return }
            activities[index].bytes = progress.completed; activities[index].total = progress.total
            activities[index].progress = progress.total > 0 ? Double(progress.completed) / Double(progress.total) : 0
            activities[index].phase = progress.phase
        case .completed: setState(id, "完成"); retryOperations[id] = nil; controls[id] = nil; resumeJobs[id] = nil; refreshLocal(); refreshRemote()
        case .suspended:
            setState(id, "待续传"); refreshLocal(); refreshRemote()
            if let job = resumeJobs[id] {
                Task {
                    let record = await job.transfer.checkpoint()
                    guard let index = activities.firstIndex(where: { $0.id == id }), activities[index].state == "待续传" else { return }
                    activities[index].bytes = record.retainedBytes; activities[index].total = record.expectedSize
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
                    catch { setState(id, "失败", error: "进度清理未完成，可在保留的传输中重试：\(error.localizedDescription)") }
                }
            }
            resumeJobs[id] = nil; refreshLocal(); refreshRemote()
        case .failed(let error): setState(id, "失败", error: error); refreshLocal(); refreshRemote()
        }
    }
    private func setState(_ id: UUID, _ state: String, error: String? = nil) {
        guard let index = activities.firstIndex(where: { $0.id == id }) else { return }
        activities[index].state = state; activities[index].error = error
        activities[index].phase = nil
        if state == "完成" { activities[index].progress = 1 }
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
        let alert = NSAlert(); alert.messageText = "丢弃“\(job.record.name)”的保留进度？"
        alert.informativeText = "将清理此任务的部分文件。原始文件和原有目标文件会保留。"
        alert.addButton(withTitle: "丢弃进度"); alert.addButton(withTitle: "返回")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        setState(id, "清理中")
        Task {
            do {
                try await job.transfer.discard(client: job.client)
                resumeJobs[id] = nil; controls[id] = nil; setState(id, "已取消")
                if let index = activities.firstIndex(where: { $0.id == id }) { activities[index].canRetry = false; activities[index].canRetain = false }
            } catch { setState(id, "失败", error: "进度清理未完成：\(error.localizedDescription)") }
        }
    }
    func clearFinishedActivities() {
        let ended = Set(activities.filter { ["完成", "失败", "已取消"].contains($0.state) }.map(\.id))
        activities.removeAll { ended.contains($0.id) }
        for id in ended { retryOperations[id] = nil; controls[id] = nil; resumeJobs[id] = nil }
    }
    func createFolder(remote: Bool) {
        guard let name = askName(title: "新建文件夹", initial: "新文件夹") else { return }
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
        guard let name = askName(title: "重命名", initial: entry.name) else { return }
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
        let alert = NSAlert(); alert.messageText = "删除 \(entry.name)？"
        alert.informativeText = remote ? "服务器删除无法从本机废纸篓恢复。" : "文件将移到废纸篓。"
        alert.addButton(withTitle: "删除"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if remote, let client {
            Task { do { try await client.remove(entry.path, directory: entry.isDirectory); refreshRemote() } catch { self.error = error.localizedDescription } }
        } else {
            do { try FileManager.default.trashItem(at: URL(fileURLWithPath: entry.path), resultingItemURL: nil); refreshLocal() }
            catch { self.error = error.localizedDescription }
        }
    }
    private func askName(title: String, initial: String) -> String? {
        let alert = NSAlert(); alert.messageText = title
        let field = NSTextField(string: initial); field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
}
