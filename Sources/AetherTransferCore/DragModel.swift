import Foundation

/// 从某个窗格拖出的文件或文件夹。
public struct DraggedFile: Codable, Hashable, Sendable {
    public let remote: Bool
    public let profileID: UUID?
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let size: Int64

    public init(remote: Bool, profileID: UUID?, path: String, name: String, isDirectory: Bool, size: Int64 = 0) {
        self.remote = remote
        self.profileID = profileID
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
    }

    public var entry: FileEntry {
        FileEntry(name: name, path: path, isDirectory: isDirectory, size: size)
    }
}

/// 保证同一拖拽项目的多次外部类型请求（例如 Finder 同时查询 fileURL 与特定 UTI）只执行一次实际导出/下载。
public actor DragExportSession {
    private var inFlightTask: Task<URL, any Error>?

    public init() {}

    public func export(using perform: @Sendable @escaping () async throws -> URL) async throws -> URL {
        if let existing = inFlightTask {
            return try await existing.value
        }
        let task = Task {
            try await perform()
        }
        inFlightTask = task
        return try await task.value
    }
}

/// 拖放路径与条目解析工具。
public enum DragPathHelper {
    /// 计算递归子路径相对于基础路径的相对路径。
    public static func relativeSubpath(base: String, child: String) -> String? {
        let normBase = RemotePath.normalize(base)
        let normChild = RemotePath.normalize(child)
        guard normChild != normBase else { return nil }
        var rel = normChild
        if rel.hasPrefix(normBase) {
            rel = String(rel.dropFirst(normBase.count))
        }
        if rel.hasPrefix("/") {
            rel = String(rel.dropFirst())
        }
        return rel.isEmpty ? nil : rel
    }
}
