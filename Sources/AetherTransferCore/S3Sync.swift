import Foundation

/// S3 participates in the shared synchronization plan without treating object keys as POSIX paths.
enum S3Sync {
    static func key(prefix: String, relative: String, directory: Bool = false) throws -> String {
        try S3BrowserPath.validatePrefix(prefix); try SyncPath.validate(relative)
        for part in relative.split(separator: "/") { try S3BrowserPath.validateLocalName(String(part)) }
        let key = prefix + relative + (directory ? "/" : "")
        try S3Endpoint.validateKey(key)
        return key
    }
    static func marker(_ client: S3Client, prefix: String) async throws -> RemoteFileVersion? {
        do {
            let version = try await client.fileVersion(prefix)
            try S3TreeSnapshot.validateMarker(version, name: prefix)
            return version
        } catch S3Error.notFound { return nil }
    }
    static func validateRoot(_ client: S3Client, prefix: String) async throws {
        try client.endpoint.validate(); try S3BrowserPath.validatePrefix(prefix)
        if prefix.isEmpty { return }
        if try await marker(client, prefix: prefix) != nil { return }
        guard !(try await client.list(prefix: prefix)).isEmpty else { throw SyncError.invalidPlan }
    }
    static func file(_ version: RemoteFileVersion, digest: String? = nil) -> SyncRecord {
        SyncRecord(kind: .file, size: version.size, modified: version.modified.map { Date(timeIntervalSince1970: Double($0)) },
                   digest: digest, remoteVersion: version)
    }
    static func digest(_ client: S3Client, key: String, version: RemoteFileVersion) async throws -> String {
        let digest = try await client.contentDigest(key, version: version)
        guard try await client.fileVersion(key) == version else { throw SyncError.changed(key) }
        return digest.base64EncodedString()
    }
    static func record(_ client: S3Client, key: String, contents: Bool) async throws -> SyncRecord? {
        do {
            let version = try await client.fileVersion(key)
            return file(version, digest: contents ? try await digest(client, key: key, version: version) : nil)
        } catch S3Error.notFound { }
        // A maximum-length file key cannot also have a legal directory delimiter.
        if key.utf8.count == 1024 { return nil }
        let prefix = key + "/"; try S3Endpoint.validateKey(prefix)
        if let version = try await marker(client, prefix: prefix) { return SyncRecord(kind: .directory, remoteVersion: version) }
        return try await client.list(prefix: prefix).isEmpty ? nil : SyncRecord(kind: .directory)
    }
    static func scan(_ client: S3Client, prefix: String, rootID: String, options: SyncOptions) async throws -> SyncSnapshot {
        try options.validate()
        var pending = [(relative: "", depth: 0)], records: [String: SyncRecord] = [:], metadataBytes = 0
        while let directory = pending.popLast() {
            try await TreeIO.boundary(client.control)
            guard directory.depth < 128 else { throw SyncError.limitExceeded }
            let directoryKey = directory.relative.isEmpty ? prefix : try key(prefix: prefix, relative: directory.relative, directory: true)
            let children = try await client.list(prefix: directoryKey)
            if !directory.relative.isEmpty, children.isEmpty,
               try await marker(client, prefix: directoryKey) == nil { throw SyncError.changed(directory.relative) }
            // Validate all names before filtering; excluded aliases must not disguise a lossy local mapping.
            try S3TreeSnapshot.validateChildren(children)
            for child in children {
                try await TreeIO.boundary(client.control)
                let relative = directory.relative.isEmpty ? child.name : directory.relative + "/" + child.name
                if options.excludes(relative) { continue }
                guard records[relative] == nil, records.count < 100_000 else { throw SyncError.limitExceeded }
                metadataBytes += relative.utf8.count * 2 + child.key.utf8.count * 2 + (child.etag?.utf8.count ?? 0) + 512
                guard metadataBytes <= 32 * 1024 * 1024 else {
                    throw TransferError.invalidListing(L10n.text("S3 目录元数据超出限制，请浏览更具体的前缀。"))
                }
                if child.isPrefix {
                    let version = try await marker(client, prefix: child.key)
                    records[relative] = SyncRecord(kind: .directory, remoteVersion: version)
                    pending.append((relative, directory.depth + 1))
                } else {
                    let version = try await client.fileVersion(child.key)
                    guard version.size == child.size, version.etag == child.etag else { throw SyncError.changed(relative) }
                    let hash = options.comparison == .contents ? try await digest(client, key: child.key, version: version) : nil
                    records[relative] = file(version, digest: hash)
                }
            }
        }
        return SyncSnapshot(rootID: rootID, records: records)
    }
    static func validateDestination(prefix: String, snapshot: SyncSnapshot, writes: [(SyncItem, SyncOperation)]) throws {
        var paths = Set(snapshot.records.keys)
        for (item, _) in writes { paths.insert(item.path) }
        let newDirectories = Set(writes.compactMap { item, operation -> String? in
            if case .createDirectory = operation { return item.path }; return nil
        })
        var aliases: [String: Set<String>] = [:]
        for relative in paths {
            let directory = snapshot.records[relative]?.kind == .directory || newDirectories.contains(relative)
            _ = try key(prefix: prefix, relative: relative, directory: directory)
            let parts = relative.split(separator: "/"), parent = parts.dropLast().joined(separator: "/"), name = String(parts.last!)
            let alias = name.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard aliases[parent, default: []].insert(alias).inserted else {
                throw TransferError.remote(L10n.format("S3 对象名称在本地可能重合，请分别选择文件并指定保存名称：%@", String(describing: name)))
            }
        }
    }
    static func validateExistingNames(_ client: S3Client, prefix: String, writes: [(SyncItem, SyncOperation)]) async throws {
        let groups = Dictionary(grouping: writes) { pair in pair.0.path.split(separator: "/").dropLast().joined(separator: "/") }
        for (parent, children) in groups {
            try await TreeIO.boundary(client.control)
            let directoryKey = parent.isEmpty ? prefix : try key(prefix: prefix, relative: parent, directory: true)
            let existing = try await client.list(prefix: directoryKey)
            try S3TreeSnapshot.validateChildren(existing)
            func alias(_ name: String) -> String {
                name.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            }
            let names = Dictionary(uniqueKeysWithValues: existing.map { (alias($0.name), Data($0.name.utf8)) })
            for (item, _) in children {
                let name = String(item.path.split(separator: "/").last!)
                if let other = names[alias(name)], other != Data(name.utf8) {
                    throw TransferError.remote(L10n.format("S3 对象名称在本地可能重合，请分别选择文件并指定保存名称：%@", String(describing: name)))
                }
            }
        }
    }
}
