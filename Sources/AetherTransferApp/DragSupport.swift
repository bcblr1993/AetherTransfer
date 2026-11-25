import AppKit
import SwiftUI
import UniformTypeIdentifiers
import AetherTransferCore

extension UTType {
    /// 应用内拖动项目的描述，只对本进程可见；Info.plist 中以 UTExportedTypeDeclarations 声明。
    static let aetherTransferItem = UTType(exportedAs: "com.aethernative.aethertransfer.item", conformingTo: .data)
}

/// 投放到窗格或文件夹上的内容：本应用拖出的项目优先，其次是 Finder 等其他应用提供的文件。
enum DroppedItem: Transferable, Sendable {
    case app(DraggedFile)
    case file(URL)

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .aetherTransferItem) { data in
            DroppedItem.app(try JSONDecoder().decode(DraggedFile.self, from: data))
        }
        ProxyRepresentation(importing: { (url: URL) in DroppedItem.file(url) })
    }
}

extension Workspace {
    static let dragExportRoot = FileManager.default.temporaryDirectory.appendingPathComponent("AetherTransferDrag", isDirectory: true)

    /// 拖动来源。本地项目以文件副本提供给其他应用（不会被 Finder 移走）；
    /// 远程项目以文件承诺/按需导出提供：放下后经传输队列下载，校验完成才交给目标位置。
    func dragProvider(for entry: FileEntry, remote: Bool) -> NSItemProvider {
        makeDragProvider(for: entry, remote: remote, profileID: remote ? connectedProfile?.id : nil, clientOverride: nil)
    }

    func dragProvider(for entry: FileEntry, role: BrowserPaneRole, layout: PaneLayoutController) -> NSItemProvider {
        switch role {
        case .leftLocal, .secondLocal:
            return makeDragProvider(for: entry, remote: false, profileID: nil, clientOverride: nil)
        case .primaryRemote:
            return makeDragProvider(for: entry, remote: true, profileID: connectedProfile?.id, clientOverride: nil)
        case .secondRemote:
            let secondClient = layout.secondRemoteClient(speedLimit: speedLimit)
            return makeDragProvider(for: entry, remote: true, profileID: layout.secondRemoteProfile?.id, clientOverride: secondClient)
        }
    }

    private func makeDragProvider(
        for entry: FileEntry,
        remote: Bool,
        profileID: UUID?,
        clientOverride: RemoteClient?
    ) -> NSItemProvider {
        let item = DraggedFile(
            remote: remote,
            profileID: profileID,
            path: entry.path,
            name: entry.name,
            isDirectory: entry.isDirectory,
            size: entry.size
        )
        let provider = NSItemProvider()
        provider.suggestedName = entry.name
        if let data = try? JSONEncoder().encode(item) {
            provider.registerDataRepresentation(forTypeIdentifier: UTType.aetherTransferItem.identifier, visibility: .ownProcess) { completion in
                completion(data, nil)
                return nil
            }
        }
        let type = entry.isDirectory ? UTType.folder : (UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data)
        if remote {
            let session = DragExportSession()
            registerRemoteDragType(UTType.fileURL.identifier, on: provider, item: item, session: session, clientOverride: clientOverride)
            if type != .fileURL {
                registerRemoteDragType(type.identifier, on: provider, item: item, session: session, clientOverride: clientOverride)
            }
        } else {
            let url = URL(fileURLWithPath: entry.path)
            provider.registerFileRepresentation(forTypeIdentifier: UTType.fileURL.identifier, fileOptions: [], visibility: .all) { completion in
                completion(url, false, nil)
                return nil
            }
            if type != .fileURL {
                provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
                    completion(url, false, nil)
                    return nil
                }
            }
        }
        return provider
    }

    private func registerRemoteDragType(
        _ typeIdentifier: String,
        on provider: NSItemProvider,
        item: DraggedFile,
        session: DragExportSession,
        clientOverride: RemoteClient?
    ) {
        // 优先注册 fileURL，使 Finder、桌面与外部应用能够以标准文件 URL 接收拖拽内容
        provider.registerFileRepresentation(forTypeIdentifier: typeIdentifier, fileOptions: [], visibility: .all) { [weak self] completion in
            let progress = Progress(totalUnitCount: max(1, item.size))
            Task { @MainActor in
                guard let self else { completion(nil, false, CocoaError(.userCancelled)); return }
                do {
                    let url = try await session.export {
                        try await self.exportRemoteForDrag(item, using: clientOverride, progress: progress)
                    }
                    progress.completedUnitCount = progress.totalUnitCount
                    completion(url, false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return progress
        }
    }

    /// 处理投放。`directory` 为 nil 时投放到窗格当前目录，否则投放到该文件夹。
    @discardableResult
    func handleDrop(_ items: [DroppedItem], toRemote: Bool, directory: String?) -> Bool {
        let (localSources, remoteSources) = partitionDroppedItems(items)
        if toRemote {
            guard !localSources.isEmpty else { return false }
            upload(localFileEntries(from: localSources), to: directory)
            return true
        }
        if !remoteSources.isEmpty {
            guard remoteSources.allSatisfy({ $0.profileID == connectedProfile?.id }) else {
                error = L10n.tr("这些项目来自另一个连接，请切换到对应标签后再拖动。",
                                "These items come from another connection. Switch to its tab and drag again.")
                return false
            }
            download(remoteSources.map(\.entry), to: directory)
        }
        if !localSources.isEmpty { copyLocalURLs(localSources, to: directory ?? localPath) }
        return !remoteSources.isEmpty || !localSources.isEmpty
    }

    /// 跨多面板投放：支持本地 ⇄ 本地、本地 ⇄ 主/副远程、以及服务器 ⇄ 服务器拖放。
    @discardableResult
    func handleDrop(
        _ items: [DroppedItem],
        to targetRole: BrowserPaneRole,
        directory: String?,
        layout: PaneLayoutController
    ) -> Bool {
        let (localSources, remoteSources) = partitionDroppedItems(items)
        let targetDir = directory ?? currentPath(for: targetRole, layout: layout)

        switch targetRole {
        case .leftLocal, .secondLocal:
            var handled = false
            if !remoteSources.isEmpty {
                let primaryID = connectedProfile?.id
                let secondID = layout.secondRemoteProfile?.id
                let fromPrimary = remoteSources.filter { $0.profileID == primaryID }
                let fromSecond = remoteSources.filter { $0.profileID == secondID && $0.profileID != primaryID }
                let unknown = remoteSources.filter { $0.profileID != primaryID && $0.profileID != secondID }
                if !unknown.isEmpty {
                    error = L10n.tr("这些项目来自另一个连接，请切换到对应标签后再拖动。",
                                    "These items come from another connection. Switch to its tab and drag again.")
                    return false
                }
                if !fromPrimary.isEmpty, let primaryClient = client {
                    transferRemoteToLocal(fromPrimary.map(\.entry), client: primaryClient, toLocalDir: targetDir, targetLocalRole: targetRole, layout: layout)
                    handled = true
                }
                if !fromSecond.isEmpty, let secondClient = layout.secondRemoteClient(speedLimit: speedLimit) {
                    transferRemoteToLocal(fromSecond.map(\.entry), client: secondClient, toLocalDir: targetDir, targetLocalRole: targetRole, layout: layout)
                    handled = true
                }
            }
            if !localSources.isEmpty {
                let entries = localFileEntries(from: localSources)
                transferLocalBetweenPanes(entries, toDirectory: targetDir, move: false, targetRole: targetRole, layout: layout)
                handled = true
            }
            return handled

        case .primaryRemote:
            guard let primaryClient = client else {
                error = L10n.tr("请先连接服务器。", "Connect to a server first.")
                return false
            }
            var handled = false
            if !localSources.isEmpty {
                upload(localFileEntries(from: localSources), to: targetDir)
                handled = true
            }
            let fromSecondRemote = remoteSources.filter { $0.profileID == layout.secondRemoteProfile?.id && $0.profileID != primaryClient.profile.id }
            if !fromSecondRemote.isEmpty, let secondClient = layout.secondRemoteClient(speedLimit: speedLimit) {
                transferServerToServer(
                    fromSecondRemote.map(\.entry),
                    sourceClient: secondClient,
                    destinationClient: primaryClient,
                    destinationDir: targetDir,
                    targetRole: .primaryRemote,
                    layout: layout
                )
                handled = true
            }
            return handled

        case .secondRemote:
            guard let secondClient = layout.secondRemoteClient(speedLimit: speedLimit) else {
                error = L10n.tr("请先在右侧连接第二个服务器。", "Connect the second server in the right pane first.")
                return false
            }
            var handled = false
            if !localSources.isEmpty {
                transferLocalToRemote(
                    localFileEntries(from: localSources),
                    client: secondClient,
                    toRemoteDir: targetDir,
                    targetRole: .secondRemote,
                    layout: layout
                )
                handled = true
            }
            let fromPrimaryRemote = remoteSources.filter { $0.profileID == connectedProfile?.id && $0.profileID != secondClient.profile.id }
            if !fromPrimaryRemote.isEmpty, let primaryClient = client {
                transferServerToServer(
                    fromPrimaryRemote.map(\.entry),
                    sourceClient: primaryClient,
                    destinationClient: secondClient,
                    destinationDir: targetDir,
                    targetRole: .secondRemote,
                    layout: layout
                )
                handled = true
            }
            return handled
        }
    }

    private func partitionDroppedItems(_ items: [DroppedItem]) -> (local: [URL], remote: [DraggedFile]) {
        var localSources: [URL] = []
        var remoteSources: [DraggedFile] = []
        for item in items {
            switch item {
            case .app(let file) where file.remote: remoteSources.append(file)
            case .app(let file): localSources.append(URL(fileURLWithPath: file.path))
            case .file(let url) where url.isFileURL: localSources.append(url)
            case .file: continue
            }
        }
        return (localSources, remoteSources)
    }

    private func localFileEntries(from urls: [URL]) -> [FileEntry] {
        urls.map { url -> FileEntry in
            let isDir: Bool = {
                if let vals = try? url.resourceValues(forKeys: [.isDirectoryKey]), let d = vals.isDirectory {
                    return d
                }
                var check: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &check) {
                    return check.boolValue
                }
                return false
            }()
            let fileSize: Int64 = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            return FileEntry(name: url.lastPathComponent, path: url.path, isDirectory: isDir, size: fileSize)
        }
    }

    /// 把远程项目下载到临时目录供文件承诺/外部接收使用；每个文件都进入传输队列，可在队列中查看进度或取消。
    func exportRemoteForDrag(_ item: DraggedFile, using overrideClient: RemoteClient? = nil, progress: Progress? = nil) async throws -> URL {
        let resolvedClient: RemoteClient?
        if let overrideClient, overrideClient.profile.id == item.profileID {
            resolvedClient = overrideClient
        } else if let client, connectedProfile?.id == item.profileID {
            resolvedClient = client
        } else {
            resolvedClient = nil
        }
        guard let activeClient = resolvedClient else {
            throw TransferError.remote(L10n.tr("连接已变化，无法完成拖出的下载。", "The connection changed; the dragged download cannot finish."))
        }
        let base = Self.dragExportRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = base.appendingPathComponent(item.name)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        do {
            if item.isDirectory {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                var files: [(remote: String, local: URL, label: String, size: Int64)] = []
                for child in try await activeClient.listRecursive(item.path) {
                    guard let rel = DragPathHelper.relativeSubpath(base: item.path, child: child.path) else { continue }
                    let local = destination.appendingPathComponent(rel)
                    if child.isDirectory {
                        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
                    } else {
                        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
                        files.append((child.path, local, "\(item.name)/\(rel)", child.size))
                    }
                }
                let totalBytes = files.reduce(Int64(0)) { $0 + max(0, $1.size) }
                if let progress, totalBytes > 0 {
                    progress.totalUnitCount = totalBytes
                }
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for file in files {
                        group.addTask {
                            try await self.enqueueDownloadAndWait(name: file.label, remote: file.remote, local: file.local, client: activeClient, parentProgress: progress)
                        }
                    }
                    try await group.waitForAll()
                }
            } else {
                if let progress, item.size > 0 {
                    progress.totalUnitCount = item.size
                }
                try await enqueueDownloadAndWait(name: item.name, remote: item.path, local: destination, client: activeClient, parentProgress: progress)
            }
        } catch {
            try? FileManager.default.removeItem(at: base)
            throw error
        }
        // 目标应用拿到文件后会自行复制；稍后清理临时副本，下次启动时也会清空残留。
        Task {
            try? await Task.sleep(for: .seconds(1800))
            try? FileManager.default.removeItem(at: base)
        }
        return destination
    }

    private func enqueueDownloadAndWait(name: String, remote: String, local: URL, client: RemoteClient, parentProgress: Progress? = nil) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            var transferID: UUID?
            transferID = enqueueTransfer(name: name, direction: .download, operation: { progress in
                let task = try ResumableTransfer(direction: .download, local: local, remote: remote,
                                                 profile: client.profile, overwrite: false)
                try await task.run(client: client, progress: { tp in
                    progress(tp)
                    if let parentProgress {
                        Task { @MainActor in
                            parentProgress.completedUnitCount = tp.completed
                            if tp.total > 0 {
                                parentProgress.totalUnitCount = tp.total
                            }
                        }
                    }
                })
            }, onFinish: { state, message in
                switch state {
                case .completed: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                default: continuation.resume(throwing: TransferError.remote(message ?? L10n.tr("下载失败。", "Download failed.")))
                }
            })
            if let parentProgress, let id = transferID {
                parentProgress.cancellationHandler = { [weak self] in
                    Task { @MainActor in
                        self?.cancelTransfer(id)
                    }
                }
            }
        }
    }
}
