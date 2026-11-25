import Foundation

public enum SyncDirection: String, Codable, Sendable, CaseIterable {
    case localToRemote = "上传同步 (本地 ➔ 远程)"
    case remoteToLocal = "下载同步 (远程 ➔ 本地)"
    case bidirectional = "双向同步 (最新为主)"

    public var localizedTitle: String {
        switch self {
        case .localToRemote: return L10n.tr("上传同步 (本地 ➔ 远程)", "Upload Sync (Local ➔ Remote)")
        case .remoteToLocal: return L10n.tr("下载同步 (远程 ➔ 本地)", "Download Sync (Remote ➔ Local)")
        case .bidirectional: return L10n.tr("双向同步 (最新为主)", "Bidirectional (Newest Wins)")
        }
    }
}

public enum SyncComparisonRule: String, Codable, Sendable {
    case sizeAndDate = "大小与修改时间"
    case sizeOnly = "仅比较文件大小"

    public var localizedTitle: String {
        switch self {
        case .sizeAndDate: return L10n.tr("大小与修改时间", "Size & Modification Date")
        case .sizeOnly: return L10n.tr("仅比较文件大小", "File Size Only")
        }
    }
}

public enum SyncActionType: String, Codable, Sendable {
    case upload = "上传"
    case download = "下载"
    case deleteRemote = "删除远程"
    case deleteLocal = "删除本地"
    case skipIdentical = "跳过 (无变化)"

    public var localizedTitle: String {
        switch self {
        case .upload: return L10n.tr("上传", "Upload")
        case .download: return L10n.tr("下载", "Download")
        case .deleteRemote: return L10n.tr("删除远程", "Delete Remote")
        case .deleteLocal: return L10n.tr("删除本地", "Delete Local")
        case .skipIdentical: return L10n.tr("跳过 (无变化)", "Skip (Identical)")
        }
    }

    public var iconName: String {
        switch self {
        case .upload: return "arrow.up.circle.fill"
        case .download: return "arrow.down.circle.fill"
        case .deleteRemote, .deleteLocal: return "trash.circle.fill"
        case .skipIdentical: return "checkmark.circle.fill"
        }
    }
}

public struct SyncItem: Identifiable, Sendable {
    public let id: UUID
    public let relativePath: String
    public let actionType: SyncActionType
    public let localURL: URL?
    public let remotePath: String?
    public let size: Int64
    public let sourceDate: Date?
    public let targetDate: Date?
    public let isDirectory: Bool
    public var isEnabled: Bool

    public init(id: UUID = UUID(), relativePath: String, actionType: SyncActionType,
                localURL: URL? = nil, remotePath: String? = nil, size: Int64 = 0,
                sourceDate: Date? = nil, targetDate: Date? = nil, isDirectory: Bool = false,
                isEnabled: Bool = true) {
        self.id = id
        self.relativePath = relativePath
        self.actionType = actionType
        self.localURL = localURL
        self.remotePath = remotePath
        self.size = size
        self.sourceDate = sourceDate
        self.targetDate = targetDate
        self.isDirectory = isDirectory
        self.isEnabled = isEnabled
    }
}

public struct SyncPlan: Sendable {
    public let direction: SyncDirection
    public let rule: SyncComparisonRule
    public let deleteOrphans: Bool
    public let simulateOnly: Bool
    public var items: [SyncItem]

    public init(direction: SyncDirection, rule: SyncComparisonRule = .sizeAndDate,
                deleteOrphans: Bool = false, simulateOnly: Bool = false, items: [SyncItem] = []) {
        self.direction = direction
        self.rule = rule
        self.deleteOrphans = deleteOrphans
        self.simulateOnly = simulateOnly
        self.items = items
    }

    public var activeItems: [SyncItem] {
        items.filter { $0.isEnabled && $0.actionType != .skipIdentical }
    }

    public var uploadItems: [SyncItem] {
        items.filter { $0.isEnabled && $0.actionType == .upload }
    }

    public var downloadItems: [SyncItem] {
        items.filter { $0.isEnabled && $0.actionType == .download }
    }

    public var deleteItems: [SyncItem] {
        items.filter { $0.isEnabled && ($0.actionType == .deleteRemote || $0.actionType == .deleteLocal) }
    }

    public var skipItems: [SyncItem] {
        items.filter { $0.actionType == .skipIdentical }
    }

    public var totalTransferBytes: Int64 {
        activeItems.reduce(0) { total, item in
            if item.actionType == .upload || item.actionType == .download {
                return total + item.size
            }
            return total
        }
    }

    public func exportReportMarkdown() -> String {
        var lines: [String] = [
            "# AetherTransfer Folder Sync Plan",
            "- Direction: \(direction.localizedTitle)",
            "- Rule: \(rule.localizedTitle)",
            "- Delete Orphans: \(deleteOrphans ? "Yes" : "No")",
            "- Simulate Only: \(simulateOnly ? "Yes" : "No")",
            "- Uploads: \(uploadItems.count) | Downloads: \(downloadItems.count) | Deletions: \(deleteItems.count) | Skipped: \(skipItems.count)",
            ""
        ]
        for item in activeItems {
            lines.append("- [\(item.actionType.localizedTitle)] `\(item.relativePath)` (\(item.size) bytes)")
        }
        return lines.joined(separator: "\n")
    }

    public func exportReportCSV() -> String {
        let formatter = ISO8601DateFormatter()
        var rows: [String] = ["RelativePath,Action,SizeBytes,SourceDate,TargetDate,Enabled"]
        rows.reserveCapacity(items.count + 1)
        for item in items {
            let sourceStr = item.sourceDate.map { formatter.string(from: $0) } ?? ""
            let targetStr = item.targetDate.map { formatter.string(from: $0) } ?? ""
            let enabledStr = item.isEnabled ? "true" : "false"
            let fields = [
                escapeCSVField(item.relativePath),
                escapeCSVField(item.actionType.localizedTitle),
                String(item.size),
                escapeCSVField(sourceStr),
                escapeCSVField(targetStr),
                enabledStr
            ]
            rows.append(fields.joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    private func escapeCSVField(_ field: String) -> String {
        if field.unicodeScalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            let doubled = field.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(doubled)\""
        }
        return field
    }
}

public enum SyncIgnoreFilter {
    public static let defaultPatternString = ".DS_Store, .git, node_modules, .svn, *.swp"

    public static func parsePatterns(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public static func shouldIgnore(relativePath: String, patterns: [String]) -> Bool {
        guard !patterns.isEmpty else { return false }
        let components = relativePath.split(separator: "/").map(String.init)
        let fileName = components.last ?? relativePath
        for rawPattern in patterns {
            let pattern = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pattern.isEmpty else { continue }
            if components.contains(pattern) || fileName == pattern || relativePath == pattern {
                return true
            }
            if fnmatch(pattern, fileName, 0) == 0 || fnmatch(pattern, relativePath, 0) == 0 {
                return true
            }
        }
        return false
    }
}

public enum SyncEngine {
    public static func generatePlan(
        localRoot: URL,
        localFiles: [LocalFileItem],
        remoteRoot: String,
        remoteFiles: [FileEntry],
        direction: SyncDirection = .localToRemote,
        rule: SyncComparisonRule = .sizeAndDate,
        deleteOrphans: Bool = false,
        ignorePatterns: [String] = [],
        skipRules: [SkipRule] = [],
        options: SyncOptions = SyncOptions(),
        referenceDate: Date = Date()
    ) -> SyncPlan {
        let normalizedRemoteRoot = RemotePath.normalize(remoteRoot)
        let enabledRules = skipRules.filter { $0.isEnabled && $0.scope.appliesToSync }
        let modifiedCutoff: Date? = options.modifiedWithinSeconds.map { referenceDate.addingTimeInterval(-$0) }

        func isOutsideModifiedWindow(_ date: Date?, isDirectory: Bool) -> Bool {
            guard !isDirectory, let cutoff = modifiedCutoff, let date else { return false }
            return date < cutoff
        }

        func makeUpload(
            rel: String,
            local: LocalFileItem,
            remotePath: String,
            targetDate: Date?
        ) -> SyncItem {
            let outsideWindow = isOutsideModifiedWindow(local.modified, isDirectory: local.isDirectory)
            return SyncItem(
                relativePath: rel,
                actionType: outsideWindow ? .skipIdentical : .upload,
                localURL: local.fileURL,
                remotePath: remotePath,
                size: local.size,
                sourceDate: local.modified,
                targetDate: targetDate,
                isDirectory: local.isDirectory,
                isEnabled: !outsideWindow
            )
        }

        func makeDownload(
            rel: String,
            localURL: URL,
            remote: FileEntry,
            targetDate: Date?
        ) -> SyncItem {
            let adjustedRemoteDate = remote.modified?.addingTimeInterval(options.timeOffsetSeconds)
            let outsideWindow = isOutsideModifiedWindow(adjustedRemoteDate, isDirectory: remote.isDirectory)
            return SyncItem(
                relativePath: rel,
                actionType: outsideWindow ? .skipIdentical : .download,
                localURL: localURL,
                remotePath: remote.path,
                size: remote.size,
                sourceDate: remote.modified,
                targetDate: targetDate,
                isDirectory: remote.isDirectory,
                isEnabled: !outsideWindow
            )
        }

        // Pre-pass directory skip set for local & remote so child ordering does not matter
        var skippedLocalDirs: Set<String> = []
        if !enabledRules.isEmpty {
            for item in localFiles where item.isDirectory {
                guard let rel = normalizedLocalRelativePath(item.relativePath) else { continue }
                let name = (rel as NSString).lastPathComponent
                if enabledRules.contains(where: {
                    $0.matches(name: name, relativePath: rel, isDirectory: true, size: item.size, modified: item.modified)
                }) {
                    skippedLocalDirs.insert(rel)
                }
            }
        }

        // Build index of local files keyed by relative path
        var localDict: [String: LocalFileItem] = [:]
        for item in localFiles {
            guard let rel = normalizedLocalRelativePath(item.relativePath) else { continue }
            if !shouldSkipSyncItem(
                relativePath: rel,
                isDirectory: item.isDirectory,
                size: item.size,
                modified: item.modified,
                ignorePatterns: ignorePatterns,
                enabledRules: enabledRules,
                skippedDirectoryPrefixes: skippedLocalDirs
            ) {
                localDict[rel] = item
            }
        }

        var skippedRemoteDirs: Set<String> = []
        if !enabledRules.isEmpty {
            for entry in remoteFiles where entry.isDirectory {
                if !options.followSymlinks && entry.isSymbolicLink { continue }
                guard let rel = normalizedRemoteRelativePath(entry.path, normalizedRemoteRoot: normalizedRemoteRoot) else { continue }
                if enabledRules.contains(where: {
                    $0.matches(name: entry.name, relativePath: rel, isDirectory: true, size: entry.size, modified: entry.modified)
                }) {
                    skippedRemoteDirs.insert(rel)
                }
            }
        }

        // Build index of remote files keyed by relative path
        var remoteDict: [String: FileEntry] = [:]
        for entry in remoteFiles {
            if !options.followSymlinks && entry.isSymbolicLink { continue }
            guard let rel = normalizedRemoteRelativePath(entry.path, normalizedRemoteRoot: normalizedRemoteRoot) else { continue }
            if !shouldSkipSyncItem(
                relativePath: rel,
                isDirectory: entry.isDirectory,
                size: entry.size,
                modified: entry.modified,
                ignorePatterns: ignorePatterns,
                enabledRules: enabledRules,
                skippedDirectoryPrefixes: skippedRemoteDirs
            ) {
                remoteDict[rel] = entry
            }
        }

        let allRelativePaths = Set(localDict.keys).union(remoteDict.keys).sorted()
        var plannedItems: [SyncItem] = []

        for rel in allRelativePaths {
            let localItem = localDict[rel]
            let remoteItem = remoteDict[rel]

            let fullRemotePath: String = {
                if normalizedRemoteRoot == "/" {
                    return "/" + rel
                } else {
                    return normalizedRemoteRoot + "/" + rel
                }
            }()

            let fullLocalURL: URL = {
                if let existing = localItem?.fileURL {
                    return existing
                }
                return localRoot.appendingPathComponent(rel)
            }()

            // Directories: if missing on destination, ensure directory sync
            let isDir = (localItem?.isDirectory == true) || (remoteItem?.isDirectory == true)

            switch (localItem, remoteItem) {
            case (.some(let local), .none):
                // File exists only locally
                switch direction {
                case .localToRemote, .bidirectional:
                    plannedItems.append(makeUpload(rel: rel, local: local, remotePath: fullRemotePath, targetDate: nil))
                case .remoteToLocal:
                    if deleteOrphans {
                        plannedItems.append(SyncItem(
                            relativePath: rel,
                            actionType: .deleteLocal,
                            localURL: local.fileURL,
                            remotePath: nil,
                            size: local.size,
                            sourceDate: local.modified,
                            targetDate: nil,
                            isDirectory: local.isDirectory,
                            isEnabled: true
                        ))
                    } else {
                        plannedItems.append(SyncItem(
                            relativePath: rel,
                            actionType: .skipIdentical,
                            localURL: local.fileURL,
                            remotePath: nil,
                            size: local.size,
                            sourceDate: local.modified,
                            targetDate: nil,
                            isDirectory: local.isDirectory,
                            isEnabled: false
                        ))
                    }
                }

            case (.none, .some(let remote)):
                // File exists only remotely
                switch direction {
                case .remoteToLocal, .bidirectional:
                    plannedItems.append(makeDownload(rel: rel, localURL: fullLocalURL, remote: remote, targetDate: nil))
                case .localToRemote:
                    if deleteOrphans {
                        plannedItems.append(SyncItem(
                            relativePath: rel,
                            actionType: .deleteRemote,
                            localURL: nil,
                            remotePath: remote.path,
                            size: remote.size,
                            sourceDate: nil,
                            targetDate: remote.modified,
                            isDirectory: remote.isDirectory,
                            isEnabled: true
                        ))
                    } else {
                        plannedItems.append(SyncItem(
                            relativePath: rel,
                            actionType: .skipIdentical,
                            localURL: nil,
                            remotePath: remote.path,
                            size: remote.size,
                            sourceDate: nil,
                            targetDate: remote.modified,
                            isDirectory: remote.isDirectory,
                            isEnabled: false
                        ))
                    }
                }

            case (.some(let local), .some(let remote)):
                // Exists in both locations
                if isDir {
                    // Directories existing in both are identical/skipped
                    continue
                }

                let sameSize = local.size == remote.size
                let adjustedRemoteDate = remote.modified?.addingTimeInterval(options.timeOffsetSeconds)
                let dateDiff: TimeInterval? = {
                    guard let ld = local.modified, let rd = adjustedRemoteDate else { return nil }
                    return ld.timeIntervalSince(rd)
                }()

                let isIdentical: Bool = {
                    if rule == .sizeOnly {
                        return sameSize
                    }
                    if let diff = dateDiff {
                        return sameSize && abs(diff) <= 2.0
                    }
                    return sameSize
                }()

                if isIdentical {
                    plannedItems.append(SyncItem(
                        relativePath: rel,
                        actionType: .skipIdentical,
                        localURL: local.fileURL,
                        remotePath: remote.path,
                        size: local.size,
                        sourceDate: local.modified,
                        targetDate: remote.modified,
                        isDirectory: false,
                        isEnabled: false
                    ))
                } else {
                    switch direction {
                    case .localToRemote:
                        plannedItems.append(makeUpload(rel: rel, local: local, remotePath: remote.path, targetDate: remote.modified))
                    case .remoteToLocal:
                        plannedItems.append(makeDownload(rel: rel, localURL: local.fileURL, remote: remote, targetDate: local.modified))
                    case .bidirectional:
                        if let diff = dateDiff {
                            if diff > 2.0 {
                                // Local is newer
                                plannedItems.append(makeUpload(rel: rel, local: local, remotePath: remote.path, targetDate: remote.modified))
                            } else if diff < -2.0 {
                                // Remote is newer
                                plannedItems.append(makeDownload(rel: rel, localURL: local.fileURL, remote: remote, targetDate: local.modified))
                            } else {
                                // Dates within 2 seconds but size differs -> default to upload
                                plannedItems.append(makeUpload(rel: rel, local: local, remotePath: remote.path, targetDate: remote.modified))
                            }
                        } else {
                            // No date info -> upload local
                            plannedItems.append(makeUpload(rel: rel, local: local, remotePath: remote.path, targetDate: remote.modified))
                        }
                    }
                }

            case (.none, .none):
                break
            }
        }

        return SyncPlan(
            direction: direction,
            rule: rule,
            deleteOrphans: deleteOrphans,
            simulateOnly: options.simulateOnly,
            items: plannedItems
        )
    }

    public static func estimateTimeOffset(
        localFiles: [LocalFileItem],
        remoteFiles: [FileEntry],
        remoteRoot: String
    ) -> TimeInterval {
        let normalizedRemoteRoot = RemotePath.normalize(remoteRoot)
        var localByPath: [String: LocalFileItem] = [:]
        for item in localFiles where !item.isDirectory {
            guard let rel = normalizedLocalRelativePath(item.relativePath) else { continue }
            localByPath[rel] = item
        }

        var diffs: [TimeInterval] = []
        for entry in remoteFiles where !entry.isDirectory {
            guard let rel = normalizedRemoteRelativePath(entry.path, normalizedRemoteRoot: normalizedRemoteRoot),
                  let local = localByPath[rel],
                  local.size == entry.size,
                  let localDate = local.modified,
                  let remoteDate = entry.modified else {
                continue
            }
            let diff = localDate.timeIntervalSince(remoteDate)
            if abs(diff) > 2.0 {
                diffs.append(diff)
            }
        }

        guard !diffs.isEmpty else { return 0 }
        let sorted = diffs.sorted()
        let mid = sorted.count / 2
        let median: TimeInterval = sorted.count % 2 == 1
            ? sorted[mid]
            : (sorted[mid - 1] + sorted[mid]) / 2.0

        let nearestHour = (median / 3600.0).rounded() * 3600.0
        let nearestMinute = (median / 60.0).rounded() * 60.0
        let rounded: TimeInterval
        if abs(median) >= 1800.0 && abs(median - nearestHour) <= 120.0 {
            rounded = nearestHour
        } else {
            rounded = nearestMinute
        }
        return rounded == 0 ? 0 : rounded
    }

    private static func normalizedLocalRelativePath(_ rawPath: String) -> String? {
        var rel = rawPath
        if rel.hasPrefix("/") { rel.removeFirst() }
        return rel.isEmpty ? nil : rel
    }

    private static func normalizedRemoteRelativePath(_ entryPath: String, normalizedRemoteRoot: String) -> String? {
        let normalized = RemotePath.normalize(entryPath)
        guard normalized.hasPrefix(normalizedRemoteRoot) else { return nil }
        var rel = String(normalized.dropFirst(normalizedRemoteRoot.count))
        if rel.hasPrefix("/") { rel.removeFirst() }
        return rel.isEmpty ? nil : rel
    }

    private static func shouldSkipSyncItem(
        relativePath: String,
        isDirectory: Bool,
        size: Int64,
        modified: Date?,
        ignorePatterns: [String],
        enabledRules: [SkipRule],
        skippedDirectoryPrefixes: Set<String>
    ) -> Bool {
        if SyncIgnoreFilter.shouldIgnore(relativePath: relativePath, patterns: ignorePatterns) {
            return true
        }
        return FileRulesStore.shouldSkipItem(
            relativePath: relativePath,
            isDirectory: isDirectory,
            size: size,
            modified: modified,
            enabledRules: enabledRules,
            skippedDirectoryPrefixes: skippedDirectoryPrefixes
        )
    }
}
