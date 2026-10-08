import Foundation

/// A visited directory, never a synchronous request from an AppKit data source.
/// Construct on a worker: estimating metadata walks the listing once.
public struct FileColumnSnapshot: Identifiable, Sendable {
    public let id: String
    public let path: String
    public let files: [FileEntry]
    public let revision: UUID
    public let estimatedBytes: Int

    public init(path: String, files: [FileEntry], revision: UUID = UUID()) {
        self.path = path; self.files = files; self.revision = revision
        // String equality normalizes Unicode. S3 prefixes must stay byte-exact.
        id = Data(path.utf8).base64EncodedString()
        estimatedBytes = files.reduce(path.utf8.count + 128) { total, entry in
            total + 256 + entry.name.utf8.count + entry.path.utf8.count
                + entry.permissions.utf8.count + (entry.s3Key?.utf8.count ?? 0)
        }
    }
}

/// Limits apply to retained ancestors; the current listing is never truncated.
/// A jump outside the visited branch starts a new browser root.
public struct FileColumnHistory: Sendable {
    public private(set) var columns: [FileColumnSnapshot] = []
    public static let maximumColumns = 24
    public static let maximumAncestorEntries = 50_000
    public static let maximumAncestorBytes = 16 * 1024 * 1024

    public init() {}
    public mutating func accept(_ snapshot: FileColumnSnapshot) {
        if let index = columns.firstIndex(where: { $0.id == snapshot.id }) {
            columns.removeSubrange(index..<columns.count)
        } else if let previous = columns.last, !previous.files.contains(where: {
            $0.isDirectory && Data($0.path.utf8) == Data(snapshot.path.utf8)
        }) {
            columns.removeAll(keepingCapacity: false)
        }
        columns.append(snapshot)
        var entries = columns.dropLast().reduce(0) { $0 + $1.files.count }
        var bytes = columns.dropLast().reduce(0) { $0 + $1.estimatedBytes }
        while columns.count > Self.maximumColumns || entries > Self.maximumAncestorEntries || bytes > Self.maximumAncestorBytes {
            let removed = columns.removeFirst()
            entries -= removed.files.count; bytes -= removed.estimatedBytes
        }
    }

    /// The directory row leading to the next visible column is highlighted.
    public func branchSelection(at index: Int) -> Set<String> {
        guard columns.indices.contains(index), columns.indices.contains(index + 1) else { return [] }
        let path = Data(columns[index + 1].path.utf8)
        return Set(columns[index].files.lazy.filter { $0.isDirectory && Data($0.path.utf8) == path }.map(\.id))
    }
}
