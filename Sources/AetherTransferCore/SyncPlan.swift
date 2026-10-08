import Foundation

public enum SyncSide: String, Sendable, Hashable {
    case left, right
    public var opposite: Self { self == .left ? .right : .left }
}
public enum SyncDirection: String, CaseIterable, Sendable {
    case leftToRight, rightToLeft
    public var source: SyncSide { self == .leftToRight ? .left : .right }
    public var destination: SyncSide { source.opposite }
}
public enum SyncMode: String, CaseIterable, Sendable {
    case leftToRight, rightToLeft, bidirectional
}
public enum SyncComparison: String, CaseIterable, Sendable {
    case modificationDate, fileSize, contents
}
public struct SyncOptions: Sendable, Equatable {
    public var mode: SyncMode = .leftToRight
    public var comparison: SyncComparison = .modificationDate
    public var mirror = false
    public var includeHidden = false
    public var excludedPaths: [String] = []
    public var leftTimeOffset: TimeInterval = 0
    public var rightTimeOffset: TimeInterval = 0
    public init() {}
    func excludes(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        if !includeHidden && parts.contains(where: { $0.hasPrefix(".") }) { return true }
        if parts.contains(where: { $0.hasPrefix(".aethertransfer-") && $0.hasSuffix(".part") }) { return true }
        return excludedPaths.contains { rule in
            rule.contains("/") ? path == rule || path.hasPrefix(rule + "/") : parts.contains(rule)
        }
    }
    func validate() throws {
        guard leftTimeOffset.isFinite, rightTimeOffset.isFinite else { throw SyncError.invalidPlan }
        for path in excludedPaths { try SyncPath.validate(path) }
    }
}
public enum SyncRecordKind: Sendable, Hashable { case file, directory, symbolicLink }
public struct SyncRecord: Sendable, Hashable {
    public let kind: SyncRecordKind
    public let size: Int64
    public let modified: Date?
    public let digest: String?
    public init(kind: SyncRecordKind, size: Int64 = 0, modified: Date? = nil, digest: String? = nil) {
        self.kind = kind; self.size = kind == .directory ? 0 : max(0, size)
        self.modified = kind == .directory ? nil : modified; self.digest = digest
    }
}
public struct SyncSnapshot: Sendable, Equatable {
    public let rootID: String
    public let records: [String: SyncRecord]
    public init(rootID: String, records: [String: SyncRecord]) { self.rootID = rootID; self.records = records }
}
public enum SyncOperation: Sendable, Equatable {
    case copy(SyncDirection), createDirectory(SyncSide), delete(SyncSide), conflict, blocked
    public var destination: SyncSide? {
        switch self {
        case .copy(let direction): direction.destination
        case .createDirectory(let side), .delete(let side): side
        default: nil
        }
    }
}
public struct SyncItem: Identifiable, Sendable, Equatable {
    public var id: String { path }
    public let path: String
    public let operation: SyncOperation
    public let left: SyncRecord?
    public let right: SyncRecord?
    public let explanation: String
    public var executable: Bool { operation != .blocked }
    public var selectedByDefault: Bool {
        switch operation { case .copy, .createDirectory: true; default: false }
    }
}
public struct SyncPlan: Sendable {
    public let id = UUID()
    public let left: SyncSnapshot
    public let right: SyncSnapshot
    public let options: SyncOptions
    public let items: [SyncItem]
    public let unchanged: Int
}
public enum SyncError: Error, LocalizedError, Sendable {
    case invalidPlan, overlappingRoots, limitExceeded, changed(String), unresolved(String), dependency(String)
    public var errorDescription: String? {
        switch self {
        case .invalidPlan: L10n.text("同步计划或相对路径不合法，请重新预览。")
        case .overlappingRoots: L10n.text("两个同步目录不能相同，也不能互相包含。")
        case .limitExceeded: L10n.text("同步目录超过 100,000 个项目或 128 层，请选择更小的目录。")
        case .changed(let path): L10n.format("预览后文件已经变化：%@。请重新生成预览。", String(describing: path))
        case .unresolved(let path): L10n.format("请为同名差异选择传输方向：%@", String(describing: path))
        case .dependency(let path): L10n.format("请同时选择所需的目录或全部待删除子项：%@", String(describing: path))
        }
    }
}
enum SyncPath {
    static func validate(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw SyncError.invalidPlan }
        for part in parts { try RemotePath.validateName(String(part)) }
    }
    static func parents(_ path: String) -> [String] {
        let parts = path.split(separator: "/")
        guard parts.count > 1 else { return [] }
        return (1..<parts.count).map { parts.prefix($0).joined(separator: "/") }
    }
}

public enum SyncPlanner {
    public static func plan(left: SyncSnapshot, right: SyncSnapshot, options: SyncOptions) throws -> SyncPlan {
        try options.validate()
        var items: [SyncItem] = [], blockedParents = Set<String>(), unchanged = 0
        for path in Set(left.records.keys).union(right.records.keys).sorted() {
            try SyncPath.validate(path)
            if options.excludes(path) { continue }
            let a = left.records[path], b = right.records[path]
            if SyncPath.parents(path).contains(where: { blockedParents.contains($0) }) { continue }
            let operation: SyncOperation
            let explanation: String
            if a?.kind == .symbolicLink || b?.kind == .symbolicLink {
                operation = .blocked; explanation = L10n.text("符号链接需要单独处理，不会跟随或删除。"); blockedParents.insert(path)
            } else if let a, let b, a.kind != b.kind {
                operation = .blocked; explanation = L10n.text("文件与目录类型冲突，请先处理。"); blockedParents.insert(path)
            } else if let a, let b {
                if a.kind == .directory || equivalent(a, b, options: options) { unchanged += 1; continue }
                switch options.mode {
                case .leftToRight: operation = .copy(.leftToRight); explanation = L10n.text("覆盖右侧同名文件。")
                case .rightToLeft: operation = .copy(.rightToLeft); explanation = L10n.text("覆盖左侧同名文件。")
                case .bidirectional: operation = .conflict; explanation = L10n.text("两侧文件有差异，请逐项选择方向。")
                }
            } else {
                let present: SyncSide = a == nil ? .right : .left
                let record = a ?? b!
                let source: SyncSide? = options.mode == .bidirectional ? nil : (options.mode == .leftToRight ? .left : .right)
                if source == nil || source == present {
                    operation = record.kind == .directory ? .createDirectory(present.opposite) : .copy(present == .left ? .leftToRight : .rightToLeft)
                    explanation = record.kind == .directory ? L10n.text("新建目标目录。") : L10n.text("复制缺少的文件。")
                } else if options.mirror {
                    operation = .delete(present); explanation = L10n.text("目标多余项目；删除默认不选中。")
                } else { unchanged += 1; continue }
            }
            items.append(SyncItem(path: path, operation: operation, left: a, right: b, explanation: explanation))
        }
        return SyncPlan(left: left, right: right, options: options, items: items, unchanged: unchanged)
    }
    private static func equivalent(_ a: SyncRecord, _ b: SyncRecord, options: SyncOptions) -> Bool {
        switch options.comparison {
        case .fileSize: return a.size == b.size
        case .contents: return a.digest != nil && a.digest == b.digest
        case .modificationDate:
            guard let aDate = a.modified, let bDate = b.modified else { return false }
            return a.size == b.size && abs(aDate.timeIntervalSince1970 + options.leftTimeOffset - bDate.timeIntervalSince1970 - options.rightTimeOffset) < 60
        }
    }
}
