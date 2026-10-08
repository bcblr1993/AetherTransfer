import Foundation
import Darwin

public struct PreviewCacheCleanup: Sendable {
    public internal(set) var removed = 0
    public internal(set) var inUse = 0
    public internal(set) var unrecognized = 0
    public internal(set) var failed = 0
    public internal(set) var reachedLimit = false
}

enum PreviewCacheError: Error, LocalizedError {
    case unsafe, limit
    var errorDescription: String? {
        switch self {
        case .unsafe: L10n.text("预览缓存的归属或路径发生变化，已停止清理。")
        case .limit: L10n.text("预览缓存清理超过单轮上限，请检查缓存目录后重试。")
        }
    }
}

/// The locked ownership record is separate from the server-supplied file name.
/// All cleanup uses directory descriptors and never follows a payload symlink.
enum PreviewCache {
    static let prefix = "aethertransfer-preview-"
    static let recordName = ".lease"
    static let entryLimit = 4096
    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("com.aethernative.AetherTransfer.previews-v1", isDirectory: true)
    }
    static func record(_ id: UUID) -> Data {
        Data("com.aethernative.AetherTransfer/preview/v1\n\(id.uuidString)\n".utf8)
    }
    static func systemError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    static func metadata(_ descriptor: Int32) throws -> stat {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw systemError() }
        return value
    }
    static func openDirectory(_ url: URL, create: Bool) throws -> Int32 {
        if create {
            guard mkdir(url.path, 0o700) == 0 || errno == EEXIST else { throw systemError() }
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw systemError() }
        do {
            let value = try metadata(descriptor)
            guard value.st_uid == getuid(), value.st_mode & S_IFMT == S_IFDIR,
                  value.st_mode & 0o022 == 0 else { throw PreviewCacheError.unsafe }
            return descriptor
        } catch { Darwin.close(descriptor); throw error }
    }
    static func names(_ descriptor: Int32, limit: Int) throws -> (names: [String], limited: Bool) {
        let copy = dup(descriptor)
        guard copy >= 0 else { throw systemError() }
        guard let stream = fdopendir(copy) else { Darwin.close(copy); throw systemError() }
        defer { closedir(stream) }
        rewinddir(stream) // dup shares the directory offset; retries must start at the first entry.
        var result: [String] = []
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let pointer = readdir(stream) else {
                if errno != 0 { throw systemError() }
                return (result, false)
            }
            var entry = pointer.pointee
            let capacity = Int(entry.d_namlen) + 1
            let name = withUnsafePointer(to: &entry.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            guard name != ".", name != ".." else { continue }
            if result.count == limit { return (result, true) }
            result.append(name)
        }
    }
    static func validRecord(_ descriptor: Int32, id: UUID) throws -> Bool {
        let value = try metadata(descriptor), expected = record(id)
        guard value.st_uid == getuid(), value.st_mode & S_IFMT == S_IFREG,
              value.st_mode & 0o077 == 0, value.st_nlink == 1, value.st_size == expected.count else { return false }
        var data = Data(count: expected.count)
        let count = data.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
        guard count >= 0 else { throw systemError() }
        return count == expected.count && data == expected
    }
    static func sameEntry(_ descriptor: Int32, parent: Int32, name: String) throws -> Bool {
        var value = stat()
        guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return false }
            throw systemError()
        }
        let held = try metadata(descriptor)
        guard held.st_dev == value.st_dev, held.st_ino == value.st_ino else { throw PreviewCacheError.unsafe }
        return true
    }
    static func removeEntry(parent: Int32, name: String, depth: Int, budget: inout Int) throws {
        try Task.checkCancellation()
        guard depth < 16, budget > 0 else { throw PreviewCacheError.limit }
        budget -= 1
        var value = stat()
        guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw systemError()
        }
        if value.st_mode & S_IFMT == S_IFDIR {
            let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw systemError() }
            defer { Darwin.close(child) }
            guard try sameEntry(child, parent: parent, name: name) else { return }
            let entries = try names(child, limit: entryLimit)
            guard !entries.limited else { throw PreviewCacheError.limit }
            for entry in entries.names { try removeEntry(parent: child, name: entry, depth: depth + 1, budget: &budget) }
            guard try sameEntry(child, parent: parent, name: name) else { return }
            guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw systemError() }
        } else {
            // Unlink the entry itself, including symlinks; never inspect their targets.
            guard unlinkat(parent, name, 0) == 0 || errno == ENOENT else { throw systemError() }
        }
    }
    static func removeOwned(parent: Int32, directory: Int32, lease: Int32, name: String, id: UUID, budget: inout Int) throws {
        guard try sameEntry(directory, parent: parent, name: name) else { return }
        guard try validRecord(lease, id: id), try sameEntry(lease, parent: directory, name: recordName) else {
            throw PreviewCacheError.unsafe
        }
        let entries = try names(directory, limit: entryLimit)
        guard !entries.limited else { throw PreviewCacheError.limit }
        // Retain the record/lock if payload cleanup fails, so a later launch can retry.
        for entry in entries.names where entry != recordName {
            try removeEntry(parent: directory, name: entry, depth: 0, budget: &budget)
        }
        guard try sameEntry(directory, parent: parent, name: name),
              try sameEntry(lease, parent: directory, name: recordName) else { throw PreviewCacheError.unsafe }
        guard unlinkat(directory, recordName, 0) == 0 else { throw systemError() }
        guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw systemError() }
    }
    static func reclaim(_ parentURL: URL) throws -> PreviewCacheCleanup {
        let parent: Int32
        do { parent = try openDirectory(parentURL, create: false) }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { return PreviewCacheCleanup() }
        defer { Darwin.close(parent) }
        let entries = try names(parent, limit: entryLimit)
        var report = PreviewCacheCleanup(); report.reachedLimit = entries.limited
        var budget = entryLimit
        for name in entries.names {
            try Task.checkCancellation()
            guard name.hasPrefix(prefix), let id = UUID(uuidString: String(name.dropFirst(prefix.count))),
                  name == prefix + id.uuidString else { report.unrecognized += 1; continue }
            let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { report.unrecognized += 1; continue }
            defer { Darwin.close(child) }
            do {
                let value = try metadata(child)
                guard value.st_uid == getuid(), value.st_mode & 0o077 == 0 else { report.unrecognized += 1; continue }
                let lease = openat(child, recordName, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_EXLOCK | O_CLOEXEC)
                guard lease >= 0 else {
                    if errno == EWOULDBLOCK || errno == EAGAIN { report.inUse += 1 }
                    else { report.unrecognized += 1 }
                    continue
                }
                defer { Darwin.close(lease) }
                guard try validRecord(lease, id: id) else { report.unrecognized += 1; continue }
                try removeOwned(parent: parent, directory: child, lease: lease, name: name, id: id, budget: &budget)
                report.removed += 1
            } catch is CancellationError { throw CancellationError() }
            catch PreviewCacheError.limit { report.failed += 1; report.reachedLimit = true; break }
            catch { report.failed += 1 }
        }
        return report
    }
}

final class PreviewCacheLease: @unchecked Sendable {
    let directory: URL
    let payload: URL
    private let id: UUID
    private let name: String
    private let mutex = NSLock()
    private var parent: Int32
    private var child: Int32
    private var lease: Int32
    init(parentURL: URL) throws {
        id = UUID(); name = PreviewCache.prefix + id.uuidString
        directory = parentURL.appendingPathComponent(name, isDirectory: true)
        payload = directory.appendingPathComponent("payload", isDirectory: true)
        parent = try PreviewCache.openDirectory(parentURL, create: true); child = -1; lease = -1
        var created = false
        do {
            guard mkdirat(parent, name, 0o700) == 0 else { throw PreviewCache.systemError() }
            created = true
            child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw PreviewCache.systemError() }
            lease = openat(child, PreviewCache.recordName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_EXLOCK | O_CLOEXEC, 0o600)
            guard lease >= 0 else { throw PreviewCache.systemError() }
            let record = PreviewCache.record(id)
            let written = record.withUnsafeBytes { Darwin.write(lease, $0.baseAddress, $0.count) }
            guard written == record.count, fsync(lease) == 0 else { throw PreviewCache.systemError() }
            guard mkdirat(child, "payload", 0o700) == 0 else { throw PreviewCache.systemError() }
        } catch {
            if created {
                if child >= 0, lease >= 0 { _ = unlinkat(child, PreviewCache.recordName, 0) }
                _ = unlinkat(parent, name, AT_REMOVEDIR)
            }
            if lease >= 0 { Darwin.close(lease) }; if child >= 0 { Darwin.close(child) }; Darwin.close(parent)
            lease = -1; child = -1; parent = -1
            throw error
        }
    }
    deinit {
        // Releasing an unclosed result leaves a recognizable abandoned cache for the next launch.
        if lease >= 0 { Darwin.close(lease) }; if child >= 0 { Darwin.close(child) }; if parent >= 0 { Darwin.close(parent) }
    }
    func close() async throws {
        try await Task.detached { [self] in
            try mutex.withLock {
                guard lease >= 0 else { return }
                var budget = PreviewCache.entryLimit
                try PreviewCache.removeOwned(parent: parent, directory: child, lease: lease, name: name, id: id, budget: &budget)
                Darwin.close(lease); Darwin.close(child); Darwin.close(parent)
                lease = -1; child = -1; parent = -1
            }
        }.value
    }
}
