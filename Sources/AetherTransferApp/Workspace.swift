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
}

@MainActor final class Workspace: ObservableObject {
    @Published var profiles: [ServerProfile] = []
    @Published var selectedServer: UUID?
    @Published var localPath = FileManager.default.homeDirectoryForCurrentUser.path
    @Published var remotePath = "/"
    @Published var localFiles: [FileEntry] = []
    @Published var remoteFiles: [FileEntry] = []
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
    private var credentials = Credentials()
    private let store = ProfileStore()
    private let queue: TransferQueue
    private var retryOperations: [UUID: TransferQueue.Operation] = [:]
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

    init(queue: TransferQueue = TransferQueue(limit: 2)) {
        self.queue = queue
        do { profiles = try store.load() } catch { self.error = error.localizedDescription }
        refreshLocal()
    }
    func persist() { do { try store.save(profiles) } catch { self.error = error.localizedDescription } }
    func save(_ profile: ServerProfile, credentials: Credentials, remember: Bool) throws {
        try profile.validate()
        profiles = try store.load()
        if remember {
            try CredentialStore.save(credentials.password, id: profile.id)
            try CredentialStore.save(credentials.passphrase, id: profile.id, kind: "passphrase")
        }
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile }
        else { profiles.append(profile) }
        try store.save(profiles)
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
            connect(profile, credentials: Credentials(password: try CredentialStore.load(id: profile.id),
                                                      passphrase: try CredentialStore.load(id: profile.id, kind: "passphrase")))
        } catch { self.error = error.localizedDescription }
    }
    func connect(_ profile: ServerProfile, credentials: Credentials) {
        browseTask?.cancel()
        connectedProfile = profile; self.credentials = credentials
        selectedServer = profile.id; remotePath = RemotePath.normalize(profile.initialPath)
        remoteFiles = []; connecting = true
        refreshRemote()
    }
    func disconnect() {
        browseTask?.cancel(); remoteGeneration = UUID(); connectedProfile = nil; remoteFiles = []
        remoteSelection = []; connecting = false; loadingRemote = false
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
                localFiles = files; localSelection = []
            } catch {
                if generation == localGeneration { localFiles = []; localSelection = []; self.error = error.localizedDescription }
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
                remoteFiles = files; remoteSelection = []
            } catch let failure as TransferError {
                guard generation == remoteGeneration else { return }
                remoteFiles = []; remoteSelection = []
                if case .hostKeyRequired(let key, let changed) = failure, !changed {
                    hostChallenge = HostChallenge(key: key, profile: client.profile)
                } else { error = failure.localizedDescription }
            } catch is CancellationError { }
            catch {
                if generation == remoteGeneration { remoteFiles = []; remoteSelection = []; self.error = error.localizedDescription }
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
    func chooseLocal() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { localPath = url.path; refreshLocal() }
    }
    func uploadSelection() { upload(localFiles.filter { localSelection.contains($0.id) }) }
    func downloadSelection() { download(remoteFiles.filter { remoteSelection.contains($0.id) }) }
    func upload(_ entries: [FileEntry]) {
        guard let client else { return }
        for entry in entries {
            do {
                let target = try RemotePath.join(remotePath, entry.name)
                let exists = remoteFiles.contains { $0.name == entry.name }
                guard let policy = exists ? conflictPolicy(entry.name, directory: entry.isDirectory) : .reject else { continue }
                enqueue(name: entry.name, direction: "上传") { progress in
                    try await client.uploadTree(URL(fileURLWithPath: entry.path), to: target, policy: policy, progress: progress)
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    func download(_ entries: [FileEntry]) {
        guard let client else { return }
        for entry in entries {
            let target = URL(fileURLWithPath: localPath).appendingPathComponent(entry.name)
            let exists = FileManager.default.fileExists(atPath: target.path)
            guard let policy = exists ? conflictPolicy(entry.name, directory: entry.isDirectory) : .reject else { continue }
            enqueue(name: entry.name, direction: "下载") { progress in
                try await client.downloadTree(entry, to: target, policy: policy, progress: progress)
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
    private func enqueue(name: String, direction: String,
                         operation: @escaping @Sendable (@escaping @Sendable (TransferProgress) -> Void) async throws -> Void) {
        let id = UUID(); activities.insert(ActivityItem(id: id, name: name, direction: direction), at: 0)
        retryOperations[id] = operation
        submit(id, operation: operation)
    }
    private func submit(_ id: UUID, operation: @escaping TransferQueue.Operation) {
        Task { [self] in
            await queue.enqueue(id: id, operation: operation) { [weak self] id, event in
                Task { @MainActor in self?.receive(id, event) }
            }
        }
    }
    private func receive(_ id: UUID, _ event: QueueEvent) {
        switch event {
        case .queued: setState(id, "等待中")
        case .running: setState(id, "传输中")
        case .progress(let progress):
            guard let index = activities.firstIndex(where: { $0.id == id }), activities[index].state == "传输中" else { return }
            activities[index].bytes = progress.completed; activities[index].total = progress.total
            activities[index].progress = progress.total > 0 ? Double(progress.completed) / Double(progress.total) : 0
        case .completed: setState(id, "完成"); retryOperations[id] = nil; refreshLocal(); refreshRemote()
        case .cancelled: setState(id, "已取消"); refreshLocal(); refreshRemote()
        case .failed(let error): setState(id, "失败", error: error); refreshLocal(); refreshRemote()
        }
    }
    private func setState(_ id: UUID, _ state: String, error: String? = nil) {
        guard let index = activities.firstIndex(where: { $0.id == id }) else { return }
        activities[index].state = state; activities[index].error = error
        if state == "完成" { activities[index].progress = 1 }
    }
    func cancel(_ id: UUID) { Task { await queue.cancel(id) } }
    func retry(_ id: UUID) {
        guard let operation = retryOperations[id] else { return }
        setState(id, "等待中"); submit(id, operation: operation)
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
