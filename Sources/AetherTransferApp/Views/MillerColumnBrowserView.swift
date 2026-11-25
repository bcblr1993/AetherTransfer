import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AetherTransferCore

// MARK: - Miller Column Async Controller

@MainActor final class MillerColumnController: ObservableObject {
    @Published private(set) var state: MillerColumnState
    private var loadTasks: [String: Task<Void, Never>] = [:]
    private var generations: [String: UUID] = [:]

    init(initialPath: String) {
        self.state = MillerColumnState(rootPath: "/", initialPath: initialPath)
    }

    func sync(
        toPath path: String,
        role: BrowserPaneRole,
        workspace: Workspace,
        layout: PaneLayoutController,
        showHidden: Bool,
        sortField: FileSortField,
        sortAscending: Bool
    ) {
        let missingPaths = state.sync(toPath: path)
        for colPath in missingPaths {
            loadColumn(
                path: colPath,
                role: role,
                workspace: workspace,
                layout: layout,
                showHidden: showHidden,
                sortField: sortField,
                sortAscending: sortAscending
            )
        }
    }

    func reloadAllColumns(
        role: BrowserPaneRole,
        workspace: Workspace,
        layout: PaneLayoutController,
        showHidden: Bool,
        sortField: FileSortField,
        sortAscending: Bool
    ) {
        let paths = state.markAllForReload()
        for colPath in paths {
            loadColumn(
                path: colPath,
                role: role,
                workspace: workspace,
                layout: layout,
                showHidden: showHidden,
                sortField: sortField,
                sortAscending: sortAscending
            )
        }
    }

    func resortColumns(field: FileSortField, ascending: Bool) {
        for column in state.columns where !column.entries.isEmpty {
            let sorted = FileEntry.sorted(column.entries, by: field, ascending: ascending, foldersFirst: true)
            state.setEntries(sorted, forColumnAt: column.path)
        }
    }

    func updateEntries(_ entries: [FileEntry], forColumnAt path: String) {
        state.setEntries(entries, forColumnAt: path)
    }

    func select(
        entry: FileEntry,
        inColumnAt columnIndex: Int,
        role: BrowserPaneRole,
        workspace: Workspace,
        layout: PaneLayoutController,
        showHidden: Bool,
        sortField: FileSortField,
        sortAscending: Bool
    ) -> String? {
        let opened = state.select(entry: entry, inColumnAt: columnIndex)
        if let childPath = opened {
            loadColumn(
                path: childPath,
                role: role,
                workspace: workspace,
                layout: layout,
                showHidden: showHidden,
                sortField: sortField,
                sortAscending: sortAscending
            )
        }
        return opened
    }

    func loadColumn(
        path: String,
        role: BrowserPaneRole,
        workspace: Workspace,
        layout: PaneLayoutController,
        showHidden: Bool,
        sortField: FileSortField,
        sortAscending: Bool
    ) {
        let normalized = RemotePath.normalize(path)
        loadTasks[normalized]?.cancel()
        let generation = UUID()
        generations[normalized] = generation
        state.setLoading(true, forColumnAt: normalized)

        if !role.isRemote {
            loadTasks[normalized] = Task { [weak self] in
                do {
                    let listed = try await Task.detached(priority: .userInitiated) {
                        try LocalFiles.list(URL(fileURLWithPath: normalized), showHidden: showHidden)
                    }.value
                    guard let self, self.generations[normalized] == generation else { return }
                    let sorted = FileEntry.sorted(listed, by: sortField, ascending: sortAscending, foldersFirst: true)
                    self.state.setEntries(sorted, forColumnAt: normalized)
                } catch is CancellationError {
                } catch {
                    guard let self, self.generations[normalized] == generation else { return }
                    self.state.setError(error.localizedDescription, forColumnAt: normalized)
                }
            }
        } else {
            guard let client = workspace.client(for: role, layout: layout) else {
                state.setError(L10n.tr("未连接到服务器。", "Not connected to server."), forColumnAt: normalized)
                return
            }
            loadTasks[normalized] = Task { [weak self] in
                do {
                    let listed = try await client.list(normalized)
                    guard let self, self.generations[normalized] == generation else { return }
                    let sorted = FileEntry.sorted(listed, by: sortField, ascending: sortAscending, foldersFirst: true)
                    self.state.setEntries(sorted, forColumnAt: normalized)
                } catch is CancellationError {
                } catch {
                    guard let self, self.generations[normalized] == generation else { return }
                    self.state.setError(error.localizedDescription, forColumnAt: normalized)
                }
            }
        }
    }

    func moveSelectionVertical(
        delta: Int,
        role: BrowserPaneRole,
        workspace: Workspace,
        layout: PaneLayoutController,
        showHidden: Bool,
        sortField: FileSortField,
        sortAscending: Bool
    ) -> String? {
        guard let result = state.moveSelectionVertical(delta: delta) else { return nil }
        if let opened = result.openedDirectory {
            loadColumn(
                path: opened,
                role: role,
                workspace: workspace,
                layout: layout,
                showHidden: showHidden,
                sortField: sortField,
                sortAscending: sortAscending
            )
            return opened
        }
        return state.activePath
    }

    func stepIntoSelectedDirectory(
        role: BrowserPaneRole,
        workspace: Workspace,
        layout: PaneLayoutController,
        showHidden: Bool,
        sortField: FileSortField,
        sortAscending: Bool
    ) -> String? {
        let result = state.stepIntoSelectedDirectory()
        if let opened = result.openedDirectory {
            loadColumn(
                path: opened,
                role: role,
                workspace: workspace,
                layout: layout,
                showHidden: showHidden,
                sortField: sortField,
                sortAscending: sortAscending
            )
            return opened
        }
        return result.entry != nil ? state.activePath : nil
    }

    func stepOutToParentColumn() -> String? {
        guard state.stepOutToParentColumn() else { return nil }
        return state.activePath
    }

    func focusColumn(at index: Int) -> String {
        state.focusColumn(at: index)
        return state.activePath
    }

    deinit {
        for task in loadTasks.values {
            task.cancel()
        }
    }
}

// MARK: - Cascading Miller Column Browser View

struct ColumnBrowserView: View {
    let path: String
    let files: [FileEntry]
    @Binding var selection: Set<String>
    let remote: Bool
    let role: BrowserPaneRole
    let query: String
    let sortField: FileSortField
    let sortAscending: Bool
    @ObservedObject var workspace: Workspace
    @ObservedObject var layout: PaneLayoutController
    @StateObject private var controller: MillerColumnController
    @State private var dropTargetColumnID: String?
    @State private var dropTargetRowID: String?
    @FocusState private var isMillerFocused: Bool

    init(
        path: String,
        files: [FileEntry],
        selection: Binding<Set<String>>,
        remote: Bool,
        role: BrowserPaneRole? = nil,
        query: String = "",
        sortField: FileSortField = .name,
        sortAscending: Bool = true,
        workspace: Workspace,
        layout: PaneLayoutController
    ) {
        self.path = path
        self.files = files
        self._selection = selection
        self.remote = remote
        self.role = role ?? (remote ? .primaryRemote : .leftLocal)
        self.query = query
        self.sortField = sortField
        self.sortAscending = sortAscending
        self.workspace = workspace
        self.layout = layout
        self._controller = StateObject(wrappedValue: MillerColumnController(initialPath: path))
    }

    var body: some View {
        ScrollViewReader { horizontalProxy in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 0) {
                    ForEach(Array(controller.state.columns.enumerated()), id: \.element.id) { index, column in
                        millerColumnView(column: column, index: index, horizontalProxy: horizontalProxy)
                            .id(column.id)

                        Divider()
                    }

                    if let previewEntry = controller.state.previewedFile {
                        MillerFilePreviewColumn(
                            entry: previewEntry,
                            role: role,
                            workspace: workspace,
                            layout: layout
                        )
                        .id("miller-preview-column")
                    } else if controller.state.columns.last?.selectedEntry == nil {
                        MillerEmptyPreviewPlaceholder()
                            .id("miller-empty-placeholder")
                    }
                }
                .frame(minHeight: 260, maxHeight: .infinity, alignment: .topLeading)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($isMillerFocused)
            .onKeyPress(.upArrow) {
                handleVerticalKey(delta: -1, proxy: horizontalProxy)
                return .handled
            }
            .onKeyPress(.downArrow) {
                handleVerticalKey(delta: 1, proxy: horizontalProxy)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                handleRightKey(proxy: horizontalProxy)
                return .handled
            }
            .onKeyPress(.leftArrow) {
                handleLeftKey(proxy: horizontalProxy)
                return .handled
            }
            .onKeyPress(.space) {
                if let entry = controller.state.selectedEntry {
                    workspace.previewEntry(entry, in: role, layout: layout)
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.return) {
                if let entry = controller.state.selectedEntry {
                    activateEntry(entry)
                    return .handled
                }
                return .ignored
            }
            .onAppear {
                controller.sync(
                    toPath: path,
                    role: role,
                    workspace: workspace,
                    layout: layout,
                    showHidden: workspace.showHidden,
                    sortField: sortField,
                    sortAscending: sortAscending
                )
                scrollToNewest(proxy: horizontalProxy)
            }
            .onChange(of: path) { _, newPath in
                controller.sync(
                    toPath: newPath,
                    role: role,
                    workspace: workspace,
                    layout: layout,
                    showHidden: workspace.showHidden,
                    sortField: sortField,
                    sortAscending: sortAscending
                )
                scrollToNewest(proxy: horizontalProxy)
            }
            .onChange(of: files) { _, newFiles in
                // Keep active directory column immediately synced with pane reloads (e.g. create/delete/rename).
                let sorted = FileEntry.sorted(newFiles, by: sortField, ascending: sortAscending, foldersFirst: true)
                controller.updateEntries(sorted, forColumnAt: path)
            }
            .onChange(of: workspace.showHidden) { _, _ in
                controller.reloadAllColumns(
                    role: role,
                    workspace: workspace,
                    layout: layout,
                    showHidden: workspace.showHidden,
                    sortField: sortField,
                    sortAscending: sortAscending
                )
            }
            .onChange(of: sortField) { _, newField in
                controller.resortColumns(field: newField, ascending: sortAscending)
            }
            .onChange(of: sortAscending) { _, newAscending in
                controller.resortColumns(field: sortField, ascending: newAscending)
            }
        }
    }

    private func visibleEntries(for column: BrowserColumn, at index: Int) -> [FileEntry] {
        let isTerminal = (index == controller.state.columns.count - 1)
        return column.entries.filter { entry in
            let hiddenOK = workspace.showHidden || !entry.name.hasPrefix(".")
            if !hiddenOK && entry.id != column.selectedEntryID {
                return false
            }
            if isTerminal && !query.isEmpty {
                return entry.name.localizedCaseInsensitiveContains(query) || entry.id == column.selectedEntryID
            }
            return true
        }
    }

    @ViewBuilder
    private func millerColumnView(column: BrowserColumn, index: Int, horizontalProxy: ScrollViewProxy) -> some View {
        let isActiveColumn = (index == controller.state.activeColumnIndex)
        let entries = visibleEntries(for: column, at: index)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: column.path == "/" ? "internaldrive" : "folder.fill")
                    .font(.caption2)
                    .foregroundStyle(isActiveColumn ? Color.accentColor : Color.secondary)
                Text(column.title)
                    .font(.caption.weight(isActiveColumn ? .semibold : .medium))
                    .foregroundStyle(isActiveColumn ? .primary : .secondary)
                    .lineLimit(1)
                Spacer()
                if column.isLoading {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Text("\(entries.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isActiveColumn ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.02))

            Divider()

            if let errorMessage = column.error {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button(L10n.tr("重试", "Retry")) {
                        controller.loadColumn(
                            path: column.path,
                            role: role,
                            workspace: workspace,
                            layout: layout,
                            showHidden: workspace.showHidden,
                            sortField: sortField,
                            sortAscending: sortAscending
                        )
                    }
                    .controlSize(.small)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty && !column.isLoading {
                VStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text(L10n.tr("空文件夹", "Empty Folder"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    focusEmptyColumn(index: index)
                }
            } else {
                ScrollViewReader { verticalProxy in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 1) {
                            ForEach(entries) { entry in
                                let isRowSelected = column.selectedEntryID == entry.id
                                let isRowDropTarget = dropTargetRowID == entry.id

                                MillerColumnRow(
                                    entry: entry,
                                    isSelected: isRowSelected,
                                    isActiveColumn: isActiveColumn,
                                    isDropTargeted: isRowDropTarget
                                )
                                .id(entry.id)
                                .onTapGesture {
                                    selectRow(entry: entry, columnIndex: index, horizontalProxy: horizontalProxy)
                                }
                                .simultaneousGesture(TapGesture(count: 2).onEnded {
                                    activateEntry(entry)
                                })
                                .onDrag {
                                    workspace.dragProvider(for: entry, role: role, layout: layout)
                                }
                                .dropDestination(for: DroppedItem.self) { items, _ in
                                    let destinationDir = entry.isDirectory ? entry.path : column.path
                                    return workspace.handleDrop(items, to: role, directory: destinationDir, layout: layout)
                                } isTargeted: { targeted in
                                    if entry.isDirectory {
                                        dropTargetRowID = targeted ? entry.id : (dropTargetRowID == entry.id ? nil : dropTargetRowID)
                                    }
                                }
                                .contextMenu {
                                    BrowserEntryContextMenu(
                                        entries: [entry],
                                        currentDirectory: column.path,
                                        role: role,
                                        workspace: workspace,
                                        layout: layout
                                    )
                                }
                            }
                        }
                        .padding(4)
                    }
                    .onChange(of: column.selectedEntryID) { _, newSelection in
                        if let newSelection {
                            withAnimation(.easeOut(duration: 0.12)) {
                                verticalProxy.scrollTo(newSelection, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 0)
                .fill(dropTargetColumnID == column.id ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(dropTargetColumnID == column.id ? Color.accentColor : Color.clear, lineWidth: 1.5)
                .padding(2)
                .allowsHitTesting(false)
        )
        .dropDestination(for: DroppedItem.self) { items, _ in
            workspace.handleDrop(items, to: role, directory: column.path, layout: layout)
        } isTargeted: { targeted in
            dropTargetColumnID = targeted ? column.id : (dropTargetColumnID == column.id ? nil : dropTargetColumnID)
        }
        .contextMenu {
            BrowserBackgroundContextMenu(
                directoryPath: column.path,
                role: role,
                workspace: workspace,
                layout: layout
            )
        }
    }

    private func selectRow(entry: FileEntry, columnIndex: Int, horizontalProxy: ScrollViewProxy) {
        layout.activePaneSide = (role == .leftLocal || (role == .primaryRemote && layout.leftPaneSource == .primaryRemote)) ? .left : .right
        isMillerFocused = true
        let opened = controller.select(
            entry: entry,
            inColumnAt: columnIndex,
            role: role,
            workspace: workspace,
            layout: layout,
            showHidden: workspace.showHidden,
            sortField: sortField,
            sortAscending: sortAscending
        )
        selection = [entry.id]
        if let opened {
            syncPanePathIfNeeded(opened)
        } else {
            let colPath = controller.state.columns[columnIndex].path
            syncPanePathIfNeeded(colPath)
        }
        scrollToNewest(proxy: horizontalProxy)
    }

    private func focusEmptyColumn(index: Int) {
        layout.activePaneSide = (role == .leftLocal || (role == .primaryRemote && layout.leftPaneSource == .primaryRemote)) ? .left : .right
        isMillerFocused = true
        let newPath = controller.focusColumn(at: index)
        selection = []
        syncPanePathIfNeeded(newPath)
    }

    private func activateEntry(_ entry: FileEntry) {
        if !entry.isDirectory && TextFileHelper.isTextFileName(entry.name) {
            workspace.openEditorInPane(for: entry, role: role, layout: layout)
        } else {
            workspace.openEntry(entry, in: role, layout: layout)
        }
    }

    private func handleVerticalKey(delta: Int, proxy: ScrollViewProxy) {
        if let nextPath = controller.moveSelectionVertical(
            delta: delta,
            role: role,
            workspace: workspace,
            layout: layout,
            showHidden: workspace.showHidden,
            sortField: sortField,
            sortAscending: sortAscending
        ) {
            if let id = controller.state.selectedEntry?.id {
                selection = [id]
            }
            syncPanePathIfNeeded(nextPath)
            scrollToNewest(proxy: proxy)
        }
    }

    private func handleRightKey(proxy: ScrollViewProxy) {
        if let nextPath = controller.stepIntoSelectedDirectory(
            role: role,
            workspace: workspace,
            layout: layout,
            showHidden: workspace.showHidden,
            sortField: sortField,
            sortAscending: sortAscending
        ) {
            if let id = controller.state.selectedEntry?.id {
                selection = [id]
            } else {
                selection = []
            }
            syncPanePathIfNeeded(nextPath)
            scrollToNewest(proxy: proxy)
        }
    }

    private func handleLeftKey(proxy: ScrollViewProxy) {
        if let nextPath = controller.stepOutToParentColumn() {
            if let id = controller.state.selectedEntry?.id {
                selection = [id]
            } else {
                selection = []
            }
            syncPanePathIfNeeded(nextPath)
            scrollToNewest(proxy: proxy)
        }
    }

    private func syncPanePathIfNeeded(_ targetPath: String) {
        let normalized = RemotePath.normalize(targetPath)
        guard RemotePath.normalize(path) != normalized else { return }
        workspace.navigatePane(to: normalized, role: role, layout: layout)
    }

    private func scrollToNewest(proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.16)) {
                if controller.state.previewedFile != nil {
                    proxy.scrollTo("miller-preview-column", anchor: .trailing)
                } else if let lastID = controller.state.columns.last?.id {
                    proxy.scrollTo(lastID, anchor: .trailing)
                }
            }
        }
    }
}

// MARK: - Miller Column Row

private struct MillerColumnRow: View {
    let entry: FileEntry
    let isSelected: Bool
    let isActiveColumn: Bool
    let isDropTargeted: Bool

    private var rowHighlightColor: Color {
        if isDropTargeted {
            return Color.accentColor.opacity(0.28)
        }
        if isSelected {
            return isActiveColumn ? Color.accentColor : Color.primary.opacity(0.14)
        }
        return Color.clear
    }

    private var useLightText: Bool {
        isSelected && isActiveColumn && !isDropTargeted
    }

    var body: some View {
        HStack(spacing: 7) {
            ZStack(alignment: .bottomLeading) {
                Image(systemName: entry.isDirectory ? "folder.fill" : BrowserIconHelper.symbolName(for: entry))
                    .font(.system(size: 14))
                    .foregroundStyle(useLightText ? Color.white : (entry.isDirectory ? Color.accentColor : Color.secondary))
                if entry.isSymbolicLink {
                    Image(systemName: "arrowshape.turn.up.right.fill")
                        .font(.system(size: 7, weight: .bold))
                        .padding(1.5)
                        .background(Circle().fill(.ultraThinMaterial))
                        .foregroundStyle(useLightText ? Color.white : Color.primary)
                        .offset(x: -2, y: 2)
                }
            }
            .frame(width: 18, height: 18)

            Text(entry.name)
                .font(.system(size: 12))
                .foregroundStyle(useLightText ? Color.white : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            if entry.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(useLightText ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.tertiary))
            } else {
                Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(useLightText ? Color.white.opacity(0.85) : Color.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(rowHighlightColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Miller Preview & Quick Actions Column

private struct MillerFilePreviewColumn: View {
    let entry: FileEntry
    let role: BrowserPaneRole
    @ObservedObject var workspace: Workspace
    @ObservedObject var layout: PaneLayoutController
    @State private var previewContent: QuickPreviewContent?
    @State private var resolvedPermissions: String = "—"

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                previewCanvas
                    .padding(.top, 12)

                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        if entry.isSymbolicLink {
                            Image(systemName: "arrowshape.turn.up.right.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.name)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    Text(entry.localizedKindDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)

                Divider()
                    .padding(.horizontal, 12)

                VStack(alignment: .leading, spacing: 6) {
                    metadataLine(
                        L10n.tr("大小", "Size"),
                        value: "\(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)) (\(entry.size) B)"
                    )
                    if let modified = entry.modified {
                        metadataLine(
                            L10n.tr("修改日期", "Modified"),
                            value: modified.formatted(date: .abbreviated, time: .shortened)
                        )
                    }
                    metadataLine(L10n.tr("权限", "Permissions"), value: resolvedPermissions)
                }
                .font(.caption)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()
                    .padding(.horizontal, 12)

                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Button {
                            workspace.previewEntry(entry, in: role, layout: layout)
                        } label: {
                            Label(L10n.tr("快速查看", "Quick Look"), systemImage: "eye")
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.small)
                        .buttonStyle(.glass)

                        Button {
                            workspace.openEntry(entry, in: role, layout: layout)
                        } label: {
                            Label(
                                role.isRemote ? L10n.tr("下载", "Download") : L10n.tr("打开", "Open"),
                                systemImage: role.isRemote ? "arrow.down.circle" : "arrow.up.forward.app"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .controlSize(.small)
                        .buttonStyle(.glassProminent)
                    }

                    HStack(spacing: 8) {
                        Button {
                            if role == .leftLocal || role == .primaryRemote {
                                workspace.openInExternalEditor(entry, remote: role.isRemote)
                            } else {
                                workspace.openEditorInPane(for: entry, role: role, layout: layout)
                            }
                        } label: {
                            Label(L10n.tr("外部编辑", "External Edit"), systemImage: "pencil.and.outline")
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.small)

                        transferOppositeButton
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
            }
        }
        .frame(width: 260)
        .frame(maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .task(id: "\(role):\(entry.id):\(entry.size)") {
            previewContent = nil
            resolvedPermissions = await BrowserMediaCache.shared.formattedPermissions(for: entry, remote: role.isRemote)
            let client = workspace.client(for: role, layout: layout)
            previewContent = await BrowserMediaCache.shared.loadPreview(for: entry, remote: role.isRemote, client: client)
        }
    }

    @ViewBuilder
    private var previewCanvas: some View {
        switch previewContent {
        case .image(let nsImage):
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 210, maxHeight: 150)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        case .text(let snippet):
            ScrollView {
                Text(snippet.isEmpty ? L10n.tr("(空文件)", "(Empty File)") : snippet)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(width: 224, height: 140)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        case .icon(let nsImage, _):
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 72, height: 72)
        case nil:
            ProgressView()
                .frame(width: 72, height: 72)
        }
    }

    @ViewBuilder
    private var transferOppositeButton: some View {
        let actionSpec = BrowserTransferRouter.oppositeAction(from: role, workspace: workspace, layout: layout)
        Button {
            actionSpec.perform([entry])
        } label: {
            Label(actionSpec.shortTitle, systemImage: actionSpec.systemImage)
                .frame(maxWidth: .infinity)
        }
        .disabled(!actionSpec.isEnabled)
    }

    private func metadataLine(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)
            Text(value)
                .font(.caption.monospacedDigit())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

private struct MillerEmptyPreviewPlaceholder: View {
    var body: some View {
        ContentUnavailableView(
            L10n.tr("分栏预览", "Column Preview"),
            systemImage: "sidebar.right",
            description: Text(L10n.tr("选择文件查看预览与快捷操作", "Select a file to preview metadata & quick actions"))
        )
        .frame(minWidth: 210, maxWidth: .infinity, maxHeight: .infinity)
    }
}
