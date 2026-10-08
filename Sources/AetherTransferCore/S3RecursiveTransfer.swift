import Foundation

extension S3Client {
    /// A directory is a sequence of conditional object commits, not a bucket transaction.
    public func uploadTree(_ source: URL, to prefix: String, policy: ConflictPolicy = .reject,
                           progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }) async throws {
        try S3BrowserPath.validatePrefix(prefix)
        guard !prefix.isEmpty else { throw TransferError.invalidPath }
        try await TreeIO.boundary(control)
        progress(TreeManifest.scanProgress())
        let manifest = try await TreeManifest.local(source, control: control, progress: progress)
        guard manifest.items.first?.entry.isDirectory == true else { throw TransferError.invalidPath }
        // Reject invalid mappings locally, before sending any endpoint request.
        try await S3TreeSnapshot.validateUpload(manifest, prefix: prefix, control: control)
        var destination = prefix, policy = policy
        if try await prefixExists(prefix) {
            switch policy {
            case .reject: throw TransferError.conflict(prefix)
            case .skip: progress(S3TreeSnapshot.skipped()); return
            case .overwrite: break
            case .keepBoth: destination = try await availablePrefix(prefix); policy = .reject
            }
        }
        // A keep-both suffix can make previously valid keys exceed the S3 limit.
        if !destination.utf8.elementsEqual(prefix.utf8) { try await S3TreeSnapshot.validateUpload(manifest, prefix: destination, control: control) }
        var counter = TreeProgress(total: manifest.bytes, totalItems: manifest.items.count)
        var directories: [String: String] = [:], skipped = Set<String>()
        progress(counter.event(phase: L10n.text("目录扫描完成")))
        for item in manifest.items {
            try await TreeIO.boundary(control)
            if !item.relative.isEmpty && skipped.contains(item.parent) {
                if item.entry.isDirectory { skipped.insert(item.relative) }
                counter.finish(item, skipped: true); progress(counter.event(phase: L10n.format("已跳过 · %@", String(describing: item.entry.name)))); continue
            }
            let local = URL(fileURLWithPath: item.entry.path)
            let current = try await TreeIO.run { try TreeIO.localEntry(local) }
            guard current.isDirectory == item.entry.isDirectory,
                  current.isDirectory || (current.size == item.entry.size && current.modified == item.entry.modified) else {
                throw ResumeTransferError.sourceChanged
            }
            let parent = item.relative.isEmpty ? "" : try S3TreeSnapshot.parent(item, directories: directories)
            var target = item.relative.isEmpty ? destination : try S3BrowserPath.append(item.entry.name, to: parent)
            if item.entry.isDirectory {
                if !item.relative.isEmpty { target += "/" }
                if try await prefixExists(target) {
                    if policy == .reject { throw TransferError.conflict(target) }
                    if policy == .skip {
                        skipped.insert(item.relative); counter.finish(item, skipped: true)
                        progress(counter.event(phase: L10n.format("已跳过 · %@", String(describing: item.entry.name)))); continue
                    }
                    if policy == .keepBoth { target = try await availablePrefix(target) }
                }
                // Never overwrite data stored at a trailing-slash key.
                if let marker = try await markerVersion(target) {
                    guard marker.size == 0 else { throw TransferError.conflict(target) }
                } else { try await createPrefix(target) }
                directories[item.relative] = target; counter.finish(item)
                progress(counter.event(phase: L10n.format("已处理目录 · %@", String(describing: item.entry.name))))
            } else {
                let reporter = TreeFileProgress(base: counter, size: item.entry.size, callback: progress)
                let committed = try await uploadFile(local, to: target, policy: policy) { reporter.receive($0) }
                counter.finish(item, skipped: !committed)
                progress(counter.event(phase: committed ? L10n.format("已提交 · %@", String(describing: item.entry.name)) : L10n.format("已跳过 · %@", String(describing: item.entry.name))))
            }
        }
        progress(counter.event(phase: L10n.text("目录处理完成")))
    }

    public func downloadTree(_ entry: FileEntry, to destination: URL, policy: ConflictPolicy = .reject,
                             progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }) async throws {
        guard entry.isDirectory, !entry.isSymbolicLink, let prefix = entry.s3Key,
              entry.path.utf8.elementsEqual(prefix.utf8) else { throw TransferError.invalidPath }
        try S3BrowserPath.validatePrefix(prefix); try await TreeIO.boundary(control)
        var destination = destination, policy = policy
        let initial = destination
        if let kind = try await TreeIO.run({ try TreeIO.localKind(initial) }) {
            guard kind else { throw TransferError.conflict(entry.name) }
            switch policy {
            case .reject: throw TransferError.conflict(entry.name)
            case .skip: progress(S3TreeSnapshot.skipped()); return
            case .overwrite: break
            case .keepBoth:
                destination = try await TreeIO.run { try S3TreeSnapshot.availableDirectory(initial) }; policy = .reject
            }
        }
        progress(TreeManifest.scanProgress())
        let snapshot = try await S3TreeSnapshot.scan(entry, client: self, progress: progress)
        var counter = TreeProgress(total: snapshot.manifest.bytes, totalItems: snapshot.manifest.items.count)
        var directories: [String: URL] = [:], skipped = Set<String>()
        progress(counter.event(phase: L10n.text("目录扫描完成")))
        for item in snapshot.manifest.items {
            try await TreeIO.boundary(control)
            if !item.relative.isEmpty && skipped.contains(item.parent) {
                if item.entry.isDirectory { skipped.insert(item.relative) }
                counter.finish(item, skipped: true); progress(counter.event(phase: L10n.format("已跳过 · %@", String(describing: item.entry.name)))); continue
            }
            let parent = item.relative.isEmpty ? destination.deletingLastPathComponent() : try S3TreeSnapshot.parent(item, directories: directories)
            try await TreeIO.run {
                guard try TreeIO.localKind(parent) == true else { throw TransferError.invalidPath }
            }
            let target = item.relative.isEmpty ? destination : parent.appendingPathComponent(item.entry.name)
            if item.entry.isDirectory {
                if let version = snapshot.versions[Data(item.entry.path.utf8)] {
                    let current = try await fileVersion(item.entry.path)
                    guard current.etag == version.etag, current.size == 0 else { throw ResumeTransferError.sourceChanged }
                }
                let decision = policy
                let result: (URL, Bool) = try await TreeIO.run {
                    if let kind = try TreeIO.localKind(target) {
                        guard kind else { throw TransferError.conflict(target.lastPathComponent) }
                        if decision == .reject { throw TransferError.conflict(target.lastPathComponent) }
                        if decision == .skip { return (target, true) }
                        if decision == .keepBoth {
                            let other = try S3TreeSnapshot.availableDirectory(target)
                            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
                            return (other, false)
                        }
                    } else { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false) }
                    return (target, false)
                }
                if result.1 { skipped.insert(item.relative) } else { directories[item.relative] = result.0 }
                counter.finish(item, skipped: result.1)
                progress(counter.event(phase: result.1 ? L10n.format("已跳过 · %@", String(describing: item.entry.name)) : L10n.format("已处理目录 · %@", String(describing: item.entry.name))))
            } else {
                guard let version = snapshot.versions[Data(item.entry.path.utf8)] else { throw TransferError.invalidListing(L10n.text("S3 扫描缺少对象版本。")) }
                let reporter = TreeFileProgress(base: counter, size: item.entry.size, callback: progress)
                let committed = try await downloadFile(item.entry, to: target, policy: policy, expectedVersion: version) { reporter.receive($0) }
                counter.finish(item, skipped: !committed)
                progress(counter.event(phase: committed ? L10n.format("已提交 · %@", String(describing: item.entry.name)) : L10n.format("已跳过 · %@", String(describing: item.entry.name))))
            }
        }
        progress(counter.event(phase: L10n.text("目录处理完成")))
    }

    fileprivate func markerVersion(_ prefix: String) async throws -> RemoteFileVersion? {
        guard !prefix.isEmpty else { return nil }
        do { return try await fileVersion(prefix) } catch S3Error.notFound { return nil }
    }
    private func prefixExists(_ prefix: String) async throws -> Bool {
        if try await markerVersion(prefix) != nil { return true }
        return try await !list(prefix: prefix).isEmpty
    }
    private func availablePrefix(_ prefix: String) async throws -> String {
        let parent = S3BrowserPath.parent(prefix)
        let name = String(decoding: prefix.dropLast().utf8.dropFirst(parent.utf8.count), as: UTF8.self)
        for number in 2...1000 {
            try await TreeIO.boundary(control)
            let candidate = try S3BrowserPath.append("\(name) (\(number))", to: parent) + "/"
            if try await !prefixExists(candidate) { return candidate }
        }
        throw TransferError.conflict(prefix)
    }
}

struct S3TreeSnapshot: Sendable {
    let manifest: TreeManifest
    let versions: [Data: RemoteFileVersion]
    static func scan(_ root: FileEntry, client: S3Client,
                     progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> Self {
        var manifest = TreeManifest(), versions: [Data: RemoteFileVersion] = [:], last = ContinuousClock.now
        func visit(_ entry: FileEntry, relative: String, depth: Int) async throws {
            try await TreeIO.boundary(client.control)
            try manifest.append(entry, relative: relative, depth: depth)
            if entry.isDirectory {
                let objects = try await client.list(prefix: entry.path), marker = try await client.markerVersion(entry.path)
                try validateMarker(marker, name: entry.name)
                guard entry.path.isEmpty || marker != nil || !objects.isEmpty else { throw ResumeTransferError.sourceChanged }
                if let marker { versions[Data(entry.path.utf8)] = marker }
                try validateChildren(objects)
                for child in objects {
                    let next = relative.isEmpty ? child.name : relative + "/" + child.name
                    if !child.isPrefix {
                        versions[Data(child.key.utf8)] = RemoteFileVersion(size: child.size, modified: nil, etag: child.etag)
                    }
                    try await visit(child.fileEntry, relative: next, depth: depth + 1)
                }
            }
            let now = ContinuousClock.now
            if last.duration(to: now) >= .milliseconds(100) { progress(TreeManifest.scanProgress(manifest.items.count)); last = now }
        }
        try await visit(root, relative: "", depth: 0)
        return Self(manifest: manifest, versions: versions)
    }
    static func validateChildren(_ children: [S3Object]) throws {
        var aliases = Set<String>()
        for child in children {
            try S3BrowserPath.validateLocalName(child.name)
            let alias = child.name.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard aliases.insert(alias).inserted else {
                throw TransferError.remote(L10n.format("S3 对象名称在本地可能重合，请分别选择文件并指定保存名称：%@", String(describing: child.name)))
            }
        }
    }
    static func validateMarker(_ version: RemoteFileVersion?, name: String) throws {
        guard version == nil || version?.size == 0 else {
            throw TransferError.remote(L10n.format("S3 前缀标记包含文件内容，不能作为空目录下载：%@", String(describing: name)))
        }
    }
    static func validateUpload(_ manifest: TreeManifest, prefix: String, control: TransferControl?) async throws {
        try await TreeIO.run {
            for item in manifest.items {
                try TreeIO.boundarySync(control)
                for component in item.relative.split(separator: "/", omittingEmptySubsequences: false) where !component.isEmpty {
                    try S3BrowserPath.validateLocalName(String(component))
                }
                try S3Endpoint.validateKey(prefix + item.relative + (item.entry.isDirectory && !item.relative.isEmpty ? "/" : ""))
            }
        }
    }
    static func parent<T>(_ item: TreeManifest.Item, directories: [String: T]) throws -> T {
        guard let parent = directories[item.parent] else { throw TransferError.invalidPath }; return parent
    }
    static func availableDirectory(_ url: URL) throws -> URL {
        for number in 2...1000 {
            try Task.checkCancellation()
            let candidate = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent) (\(number))")
            if try TreeIO.localKind(candidate) == nil { return candidate }
        }
        throw TransferError.conflict(url.lastPathComponent)
    }
    static func skipped() -> TransferProgress {
        TransferProgress(completed: 0, total: 0, phase: L10n.text("已跳过目录"), scope: .directory,
                         completedItems: 1, totalItems: 1, skippedItems: 1)
    }
}
