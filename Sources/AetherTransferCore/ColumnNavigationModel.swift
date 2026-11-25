import Foundation
import CryptoKit
import CTransfer

/// Represents one vertical directory column inside a Finder/Transmit-style Miller Column Browser.
public struct BrowserColumn: Identifiable, Hashable, Sendable {
    public let id: String
    public var path: String
    public var title: String
    public var entries: [FileEntry]
    public var selectedEntryID: String?
    public var isLoading: Bool
    public var error: String?

    public init(
        path: String,
        title: String? = nil,
        entries: [FileEntry] = [],
        selectedEntryID: String? = nil,
        isLoading: Bool = false,
        error: String? = nil
    ) {
        let normalized = RemotePath.normalize(path)
        self.id = normalized
        self.path = normalized
        if let title, !title.isEmpty {
            self.title = title
        } else {
            let last = (normalized as NSString).lastPathComponent
            self.title = (normalized == "/" || last.isEmpty) ? "/" : last
        }
        self.entries = entries
        self.selectedEntryID = selectedEntryID
        self.isLoading = isLoading
        self.error = error
    }

    public var selectedEntry: FileEntry? {
        guard let selectedEntryID else { return nil }
        return entries.first(where: { $0.id == selectedEntryID })
    }
}

/// Pure, testable state machine modeling cascading Miller columns, selection, tree truncation,
/// ancestor path building, and keyboard navigation.
public struct MillerColumnState: Equatable, Sendable {
    public private(set) var rootPath: String
    public private(set) var columns: [BrowserColumn]
    public private(set) var activeColumnIndex: Int

    public init(rootPath: String = "/", initialPath: String? = nil) {
        let normalizedRoot = RemotePath.normalize(rootPath)
        let normalizedInitial = RemotePath.normalize(initialPath ?? normalizedRoot)
        if normalizedRoot != "/",
           normalizedInitial != normalizedRoot,
           !normalizedInitial.hasPrefix(normalizedRoot + "/") {
            self.rootPath = "/"
        } else {
            self.rootPath = normalizedRoot
        }

        let paths = Self.ancestorPaths(from: self.rootPath, to: normalizedInitial)
        self.columns = paths.enumerated().map { index, path in
            let nextSelected: String? = (index + 1 < paths.count) ? paths[index + 1] : nil
            return BrowserColumn(path: path, selectedEntryID: nextSelected, isLoading: true)
        }
        self.activeColumnIndex = max(0, self.columns.count - 1)
    }

    /// Deepest directory path represented by the current column chain.
    public var activePath: String {
        columns.last?.path ?? rootPath
    }

    /// Currently keyboard-focused column.
    public var activeColumn: BrowserColumn? {
        columns.indices.contains(activeColumnIndex) ? columns[activeColumnIndex] : nil
    }

    /// Directory path of the currently keyboard-focused column.
    public var focusedColumnPath: String {
        activeColumn?.path ?? activePath
    }

    /// Currently selected entry in the focused column (or most recent ancestor selection).
    public var selectedEntry: FileEntry? {
        if let selected = activeColumn?.selectedEntry {
            return selected
        }
        for column in columns.reversed() {
            if let selected = column.selectedEntry {
                return selected
            }
        }
        return nil
    }

    /// Non-directory file selected in the trailing column, used to drive the Preview & Quick Actions column.
    public var previewedFile: FileEntry? {
        guard let entry = columns.last?.selectedEntry, !entry.isDirectory else { return nil }
        return entry
    }

    /// Builds ordered ancestor paths from `rootPath` down to `targetPath`.
    /// If `targetPath` falls outside `rootPath`, falls back to building from `"/"`.
    public static func ancestorPaths(from rootPath: String, to targetPath: String) -> [String] {
        let root = RemotePath.normalize(rootPath)
        let target = RemotePath.normalize(targetPath)

        if target == root {
            return [root]
        }
        if root == "/" {
            return RemotePath.breadcrumbs(for: target).map(\.path)
        }
        guard target.hasPrefix(root + "/") else {
            return RemotePath.breadcrumbs(for: target).map(\.path)
        }

        let suffix = String(target.dropFirst(root.count))
        let components = suffix.split(separator: "/").map(String.init)
        var result = [root]
        var current = root
        for component in components {
            current = RemotePath.normalize(current + "/" + component)
            result.append(current)
        }
        return result
    }

    /// Synchronizes the column hierarchy with an external pane path while preserving unchanged prefix columns.
    /// Returns the paths of columns that still need to be loaded.
    @discardableResult
    public mutating func sync(toPath path: String) -> [String] {
        let target = RemotePath.normalize(path)
        if rootPath != "/", target != rootPath, !target.hasPrefix(rootPath + "/") {
            rootPath = "/"
        }

        let desiredPaths = Self.ancestorPaths(from: rootPath, to: target)
        let existingPaths = columns.map(\.path)

        // If the column hierarchy already matches the target path chain, preserve active selection/focus.
        if existingPaths == desiredPaths {
            return columns.filter { $0.isLoading && $0.entries.isEmpty && $0.error == nil }.map(\.path)
        }

        var updatedColumns: [BrowserColumn] = []
        updatedColumns.reserveCapacity(desiredPaths.count)

        for (index, columnPath) in desiredPaths.enumerated() {
            let expectedSelection: String? = (index + 1 < desiredPaths.count) ? desiredPaths[index + 1] : nil
            if index < columns.count && columns[index].path == columnPath {
                var reused = columns[index]
                if let expectedSelection {
                    reused.selectedEntryID = expectedSelection
                } else if index == desiredPaths.count - 1 {
                    // Truncated child columns: clear directory selection in the new terminal column.
                    if reused.selectedEntry?.isDirectory == true || columns.count > desiredPaths.count {
                        reused.selectedEntryID = nil
                    }
                }
                updatedColumns.append(reused)
            } else {
                updatedColumns.append(BrowserColumn(path: columnPath, selectedEntryID: expectedSelection, isLoading: true))
            }
        }

        columns = updatedColumns
        activeColumnIndex = max(0, columns.count - 1)
        return columns.filter { $0.isLoading && $0.entries.isEmpty && $0.error == nil }.map(\.path)
    }

    /// Selects `entry` inside `columnIndex`, truncates deeper columns, and opens column `N+1` if `entry` is a folder.
    /// Returns the newly opened directory path when `entry.isDirectory` is true.
    @discardableResult
    public mutating func select(entry: FileEntry, inColumnAt columnIndex: Int) -> String? {
        guard columns.indices.contains(columnIndex) else { return nil }

        columns[columnIndex].selectedEntryID = entry.id
        activeColumnIndex = columnIndex

        if columns.count > columnIndex + 1 {
            columns.removeSubrange((columnIndex + 1)..<columns.count)
        }

        guard entry.isDirectory else {
            return nil
        }

        let childPath = RemotePath.normalize(entry.path)
        columns.append(BrowserColumn(path: childPath, entries: [], selectedEntryID: nil, isLoading: true, error: nil))
        return childPath
    }

    /// Moves focus to an existing column and clears deeper selection/columns beyond it.
    public mutating func focusColumn(at columnIndex: Int) {
        guard columns.indices.contains(columnIndex) else { return }
        activeColumnIndex = columnIndex
        columns[columnIndex].selectedEntryID = nil
        if columns.count > columnIndex + 1 {
            columns.removeSubrange((columnIndex + 1)..<columns.count)
        }
    }

    /// Populates entries for any column matching `path`.
    public mutating func setEntries(_ entries: [FileEntry], forColumnAt path: String) {
        let normalized = RemotePath.normalize(path)
        for index in columns.indices where columns[index].path == normalized {
            columns[index].entries = entries
            columns[index].isLoading = false
            columns[index].error = nil
            if let currentSelection = columns[index].selectedEntryID {
                let existsInEntries = entries.contains(where: { $0.id == currentSelection })
                let linkedToNextColumn = (index + 1 < columns.count) && (columns[index + 1].path == currentSelection)
                if !existsInEntries && !linkedToNextColumn {
                    columns[index].selectedEntryID = nil
                }
            }
        }
    }

    /// Records a load failure on the column matching `path`.
    public mutating func setError(_ message: String, forColumnAt path: String) {
        let normalized = RemotePath.normalize(path)
        for index in columns.indices where columns[index].path == normalized {
            columns[index].isLoading = false
            columns[index].error = message
        }
    }

    /// Updates loading indicator for a specific column path.
    public mutating func setLoading(_ loading: Bool, forColumnAt path: String) {
        let normalized = RemotePath.normalize(path)
        for index in columns.indices where columns[index].path == normalized {
            columns[index].isLoading = loading
            if loading {
                columns[index].error = nil
            }
        }
    }

    /// Marks every column in the chain as loading and returns all column paths to refresh.
    @discardableResult
    public mutating func markAllForReload() -> [String] {
        for index in columns.indices {
            columns[index].isLoading = true
            columns[index].error = nil
        }
        return columns.map(\.path)
    }

    /// Navigates up one parent level from `activePath` and returns column paths needing reload.
    @discardableResult
    public mutating func navigateUp() -> [String] {
        guard columns.count > 1 else { return [] }
        let parentPath = RemotePath.parent(activePath)
        return sync(toPath: parentPath)
    }

    /// Moves vertical selection up (`delta < 0`) or down (`delta > 0`) inside the active column.
    @discardableResult
    public mutating func moveSelectionVertical(delta: Int) -> (entry: FileEntry, openedDirectory: String?)? {
        guard delta != 0, columns.indices.contains(activeColumnIndex) else { return nil }
        let entries = columns[activeColumnIndex].entries
        guard !entries.isEmpty else { return nil }

        let nextIndex: Int
        if let selectedID = columns[activeColumnIndex].selectedEntryID,
           let currentIndex = entries.firstIndex(where: { $0.id == selectedID }) {
            nextIndex = max(0, min(entries.count - 1, currentIndex + delta))
        } else {
            nextIndex = delta > 0 ? 0 : entries.count - 1
        }

        let target = entries[nextIndex]
        let opened = select(entry: target, inColumnAt: activeColumnIndex)
        return (target, opened)
    }

    /// Steps right (`→`) into the child column opened by the selected directory, selecting its first entry if loaded.
    @discardableResult
    public mutating func stepIntoSelectedDirectory() -> (entry: FileEntry?, openedDirectory: String?) {
        guard columns.indices.contains(activeColumnIndex) else { return (nil, nil) }

        if activeColumnIndex + 1 < columns.count {
            activeColumnIndex += 1
            if columns[activeColumnIndex].selectedEntryID == nil,
               let first = columns[activeColumnIndex].entries.first {
                let opened = select(entry: first, inColumnAt: activeColumnIndex)
                return (first, opened)
            }
            return (columns[activeColumnIndex].selectedEntry, nil)
        }

        if columns[activeColumnIndex].selectedEntryID == nil,
           let first = columns[activeColumnIndex].entries.first {
            let opened = select(entry: first, inColumnAt: activeColumnIndex)
            return (first, opened)
        }

        return (nil, nil)
    }

    /// Steps left (`←`) back to the parent column and truncates any deeper grandchild columns.
    @discardableResult
    public mutating func stepOutToParentColumn() -> Bool {
        guard activeColumnIndex > 0, columns.indices.contains(activeColumnIndex) else {
            return false
        }
        let parentIndex = activeColumnIndex - 1
        columns[activeColumnIndex].selectedEntryID = nil
        if columns.count > activeColumnIndex + 1 {
            columns.removeSubrange((activeColumnIndex + 1)..<columns.count)
        }
        activeColumnIndex = parentIndex
        return true
    }
}

// MARK: - SFTP Symlink Support via CTransfer Quote Command

private final class SymlinkRequestBox: @unchecked Sendable {
    let pointer: OpaquePointer
    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }
    deinit { at_destroy(pointer) }
    func cancel() { at_cancel(pointer) }
}

public extension TransferProgress {
    init(completedBytes: Int64, totalBytes: Int64) {
        self.init(completed: completedBytes, total: totalBytes)
    }
}

public extension RemoteClient {
    /// Creates a symbolic link at `linkPath` pointing to `target` on protocols that support remote symlinks (SFTP).
    func createSymlink(target: String, at linkPath: String) async throws {
        try Task.checkCancellation()
        try RemotePath.validate(target)
        try RemotePath.validate(linkPath)
        guard profile.protocolKind == .sftp else {
            throw TransferError.remote(L10n.tr(
                "仅本地与 SFTP 连接支持创建符号链接。",
                "Symbolic links are only supported locally and over SFTP."
            ))
        }

        let url = try profile.url(path: "/", directory: true)
        let request = url.withCString { urlPtr in
            profile.username.withCString { userPtr in
                credentials.password.withCString { passPtr in
                    profile.privateKeyPath.withCString { keyPtr in
                        credentials.passphrase.withCString { phrasePtr in
                            (profile.trustedHostKey ?? "").withCString { fpPtr in
                                at_create(urlPtr, userPtr, passPtr, keyPtr, phrasePtr, fpPtr)
                            }
                        }
                    }
                }
            }
        }
        guard let request else {
            throw TransferError.remote(L10n.tr("无法创建传输连接。", "Unable to create transfer connection."))
        }
        if profile.useSSHAgent {
            _ = at_set_ssh_agent(request, 1)
        }
        let command = "symlink \(try RemotePath.quoted(target)) \(try RemotePath.quoted(linkPath))"
        let box = SymlinkRequestBox(pointer: request)

        try await withTaskCancellationHandler {
            try await Task.detached {
                let code = "".withCString { emptyLocal in
                    command.withCString { cmdPtr in
                        at_perform(box.pointer, 3, emptyLocal, cmdPtr, { _, _, _ in }, nil)
                    }
                }
                if code == 42 { throw CancellationError() }
                if code != 0 {
                    let key = String(cString: at_host_key(box.pointer))
                    if !key.isEmpty && key != profile.trustedHostKey {
                        throw TransferError.hostKeyRequired(key: key, changed: profile.trustedHostKey != nil)
                    }
                    throw TransferError.remote(String(cString: at_error(box.pointer)))
                }
            }.value
        } onCancel: {
            box.cancel()
        }
    }
}
