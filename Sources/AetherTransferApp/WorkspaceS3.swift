import Foundation
import AetherTransferCore

extension Workspace {
    func uploadS3URLs(_ urls: [URL], client: S3Client, prefix: String, existing: [FileEntry]) {
        Task {
            do {
                let entries = try await Task.detached {
                    try urls.map { url in
                        let info = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
                        return FileEntry(name: url.lastPathComponent, path: url.path, isDirectory: info.isDirectory == true,
                                         isSymbolicLink: info.isSymbolicLink == true, size: Int64(info.fileSize ?? 0))
                    }
                }.value
                uploadS3(entries, client: client, prefix: prefix, existing: existing)
            } catch { self.error = error.localizedDescription }
        }
    }
    func uploadS3(_ entries: [FileEntry], client: S3Client, prefix: String, existing: [FileEntry]) {
        let rate = Int64(max(0, UserDefaults.standard.integer(forKey: "transferRateKiB"))) * 1024
        let names = Set(existing.filter { !$0.isDirectory }.map { Data($0.name.utf8) })
        for entry in entries {
            do {
                guard !entry.isDirectory, !entry.isSymbolicLink else { throw TransferError.remote("S3 当前支持普通文件；目录上传正在适配。") }
                let key = try S3BrowserPath.append(entry.name, to: prefix)
                guard let policy = names.contains(Data(entry.name.utf8)) ? conflictPolicy(entry.name, directory: false) : .reject else { continue }
                enqueue(name: entry.name, direction: "上传") { control, progress in
                    let controlled = S3Client(endpoint: client.endpoint, credentials: client.credentials, control: control, rateLimit: rate, certificateAuthority: client.certificateAuthority)
                    do { try await controlled.uploadFile(URL(fileURLWithPath: entry.path), to: key, policy: policy, progress: progress) }
                    catch S3Error.cleanupRequired(let record) {
                        do { try await S3CleanupStore.shared.add(record) }
                        catch { throw TransferError.remote("S3 分片清理未完成，清理记录保存失败：\(error.localizedDescription)") }
                        throw TransferError.remote("S3 分片清理未完成；请在“保留的传输”中重新连接并重试清理。")
                    }
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    func downloadS3(_ entries: [FileEntry], client: S3Client) {
        let rate = Int64(max(0, UserDefaults.standard.integer(forKey: "transferRateKiB"))) * 1024
        let names = Set(localFiles.map(\.name))
        for entry in entries {
            do {
                guard !entry.isDirectory else { throw TransferError.remote("S3 前缀递归下载正在适配，请先打开前缀选择文件。") }
                try S3BrowserPath.validateLocalName(entry.name)
                let destination = URL(fileURLWithPath: localPath).appendingPathComponent(entry.name)
                guard let policy = names.contains(entry.name) ? conflictPolicy(entry.name, directory: false) : .reject else { continue }
                enqueue(name: entry.name, direction: "下载") { control, progress in
                    let controlled = S3Client(endpoint: client.endpoint, credentials: client.credentials, control: control, rateLimit: rate, certificateAuthority: client.certificateAuthority)
                    try await controlled.downloadFile(entry, to: destination, policy: policy, progress: progress)
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}
