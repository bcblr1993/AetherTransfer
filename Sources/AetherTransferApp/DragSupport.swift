import AppKit
import SwiftUI
import UniformTypeIdentifiers
import AetherTransferCore

extension UTType {
    /// 应用内拖动项目的描述，只对本进程可见；Info.plist 中以 UTExportedTypeDeclarations 声明。
    static let aetherTransferItem = UTType(exportedAs: "com.aethernative.aethertransfer.item", conformingTo: .data)
}

/// 从某个窗格拖出的文件或文件夹。
struct DraggedFile: Codable, Hashable, Sendable {
    let remote: Bool
    let profileID: UUID?
    let path: String
    let name: String
    let isDirectory: Bool
    let size: Int64

    var entry: FileEntry { FileEntry(name: name, path: path, isDirectory: isDirectory, size: size) }
}

/// 投放到窗格或文件夹上的内容：本应用拖出的项目优先，其次是 Finder 等其他应用提供的文件。
enum DroppedItem: Transferable {
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
    /// 远程项目以文件承诺提供：放下后才经传输队列下载，校验完成才交给目标位置。
    func dragProvider(for entry: FileEntry, remote: Bool) -> NSItemProvider {
        let item = DraggedFile(remote: remote, profileID: remote ? connectedProfile?.id : nil, path: entry.path,
                               name: entry.name, isDirectory: entry.isDirectory, size: entry.size)
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
            provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { [weak self] completion in
                let progress = Progress(totalUnitCount: 1)
                Task { @MainActor in
                    guard let self else { completion(nil, false, CocoaError(.userCancelled)); return }
                    do {
                        let url = try await self.exportRemoteForDrag(item)
                        progress.completedUnitCount = 1
                        completion(url, false, nil)
                    } catch {
                        completion(nil, false, error)
                    }
                }
                return progress
            }
        } else {
            let url = URL(fileURLWithPath: entry.path)
            provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
                completion(url, false, nil)
                return nil
            }
        }
        return provider
    }

    /// 处理投放。`directory` 为 nil 时投放到窗格当前目录，否则投放到该文件夹。
    @discardableResult
    func handleDrop(_ items: [DroppedItem], toRemote: Bool, directory: String?) -> Bool {
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
        if toRemote {
            // 远程窗格之间的拖动（服务器端移动）不在本版本范围内。
            guard !localSources.isEmpty else { return false }
            let entries = localSources.map { url in
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                return FileEntry(name: url.lastPathComponent, path: url.path, isDirectory: isDir)
            }
            upload(entries, to: directory)
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

    /// 把远程项目下载到临时目录供文件承诺使用；每个文件都进入传输队列，可在队列中查看进度或取消。
    func exportRemoteForDrag(_ item: DraggedFile) async throws -> URL {
        guard let client, connectedProfile?.id == item.profileID else {
            throw TransferError.remote(L10n.tr("连接已变化，无法完成拖出的下载。", "The connection changed; the dragged download cannot finish."))
        }
        let base = Self.dragExportRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = base.appendingPathComponent(item.name)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        do {
            if item.isDirectory {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                var files: [(remote: String, local: URL, label: String)] = []
                for child in try await client.listRecursive(item.path) where child.path != item.path {
                    var rel = String(child.path.dropFirst(item.path.count))
                    if rel.hasPrefix("/") { rel.removeFirst() }
                    guard !rel.isEmpty else { continue }
                    let local = destination.appendingPathComponent(rel)
                    if child.isDirectory {
                        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
                    } else {
                        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
                        files.append((child.path, local, "\(item.name)/\(rel)"))
                    }
                }
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for file in files {
                        group.addTask { try await self.enqueueDownloadAndWait(name: file.label, remote: file.remote, local: file.local, client: client) }
                    }
                    try await group.waitForAll()
                }
            } else {
                try await enqueueDownloadAndWait(name: item.name, remote: item.path, local: destination, client: client)
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

    private func enqueueDownloadAndWait(name: String, remote: String, local: URL, client: RemoteClient) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            enqueueTransfer(name: name, direction: .download, operation: { [weak self] progress in
                let activeClient = await MainActor.run { self?.client ?? client }
                let task = try ResumableTransfer(direction: .download, local: local, remote: remote,
                                                 profile: activeClient.profile, overwrite: false)
                try await task.run(client: activeClient, progress: progress)
            }, onFinish: { state, message in
                switch state {
                case .completed: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                default: continuation.resume(throwing: TransferError.remote(message ?? L10n.tr("下载失败。", "Download failed.")))
                }
            })
        }
    }
}
