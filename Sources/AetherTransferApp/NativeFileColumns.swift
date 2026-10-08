import AppKit
import SwiftUI
import AetherTransferCore

struct FileColumnContent: Identifiable, Sendable {
    var id: String { snapshot.id }
    let snapshot: FileColumnSnapshot
    let files: [FileEntry]
    let revision: UUID
    let branchSelection: Set<String>
}

/// Reusable AppKit tables consume visited snapshots. Listing/filtering never
/// happens in a native data-source callback or in a per-file hosting view.
struct NativeFileColumns: NSViewRepresentable {
    let columns: [FileColumnContent]
    @Binding var selection: Set<String>
    let remote: Bool
    let workspace: Workspace
    let emptyMessage: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> ColumnScrollView {
        let scroll = ColumnScrollView()
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        scroll.documentView = ColumnStrip()
        return scroll
    }
    func updateNSView(_ scroll: ColumnScrollView, context: Context) {
        guard let strip = scroll.documentView as? ColumnStrip else { return }
        let coordinator = context.coordinator
        let namespace = remote ? workspace.connectionRevision : workspace.id
        if coordinator.workspaceID != workspace.id || coordinator.namespace != namespace {
            coordinator.controllers.removeAll()
            coordinator.workspaceID = workspace.id; coordinator.namespace = namespace
        }
        coordinator.parent = self
        let previousIDs = strip.columns.map(\.id), ids = Set(columns.map(\.id))
        coordinator.controllers = coordinator.controllers.filter { ids.contains($0.key) }
        var views: [ColumnView] = []
        for column in columns {
            let controller = coordinator.controllers[column.id] ?? ColumnCoordinator(owner: coordinator, column: column)
            coordinator.controllers[column.id] = controller
            controller.update(column, selection: column.id == columns.last?.id ? selection : column.branchSelection,
                              locale: context.environment.locale, enabled: context.environment.isEnabled)
            views.append(controller.view)
        }
        strip.setColumns(views)
        if previousIDs != columns.map(\.id) {
            scroll.tile(); strip.layoutSubtreeIfNeeded()
        }
        if previousIDs != columns.map(\.id), let last = strip.columns.last {
            strip.scrollToVisible(last.frame)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        coordinator.controllers[columns.last?.id ?? ""]?.view.table.focusIfNeeded()
    }

    @MainActor final class Coordinator {
        var parent: NativeFileColumns
        var workspaceID: UUID?
        var namespace: UUID?
        var controllers: [String: ColumnCoordinator] = [:]
        init(_ parent: NativeFileColumns) { self.parent = parent }
        func focusPrevious(to id: String) {
            guard let index = parent.columns.firstIndex(where: { $0.id == id }), index > 0 else { return }
            let previous = parent.columns[index - 1]
            parent.workspace.activateColumn(previous.snapshot, remote: parent.remote, selection: previous.branchSelection)
            if let table = controllers[previous.id]?.view.table { table.window?.makeFirstResponder(table) }
        }
    }

    @MainActor final class ColumnCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var owner: Coordinator?
        var column: FileColumnContent
        let view: ColumnView
        private var rowByID: [String: Int] = [:]
        private var revision: UUID?
        private var locale: Locale?
        private var updating = false
        private let actions = FileBrowserActions()
        init(owner: Coordinator, column: FileColumnContent) {
            self.owner = owner; self.column = column; view = ColumnView(id: column.id)
            super.init()
            let table = view.table
            table.delegate = self; table.dataSource = self
            table.target = self; table.doubleAction = #selector(openDoubleClick)
            table.menuProvider = { [weak self] event in self?.menu(event) }
            table.openSelected = { [weak self] in self?.openSelection() }
            table.previewSelected = { [weak self] in
                guard let self, self.view.table.isEnabled, let owner = self.owner else { return }
                self.activate()
                owner.parent.workspace.previewSelection(remote: owner.parent.remote)
            }
            table.focused = { [weak self] in
                guard let self, let owner = self.owner else { return }
                owner.parent.workspace.focusedRemote = owner.parent.remote
            }
            table.initialFocusRequested = { [weak self] in
                guard let self, let owner = self.owner else { return false }
                return owner.parent.columns.last?.id == self.column.id && owner.parent.workspace.focusedRemote == owner.parent.remote
            }
            table.moveLeft = { [weak self] in
                guard let self, self.view.table.isEnabled else { return }
                self.owner?.focusPrevious(to: self.column.id)
            }
            table.moveRight = { [weak self] in self?.openSelection(directoriesOnly: true) }
            table.setDraggingSourceOperationMask(.copy, forLocal: false)
            table.setDraggingSourceOperationMask(.copy, forLocal: true)
            view.scroll.receiveURLs = { [weak self] urls in
                guard let self, let owner = self.owner, self.view.table.isEnabled,
                      owner.parent.remote, owner.parent.workspace.canReceiveUpload else { return false }
                owner.parent.workspace.activateColumn(self.column.snapshot, remote: true, selection: [])
                owner.parent.workspace.uploadURLs(urls)
                return true
            }
        }
        func update(_ column: FileColumnContent, selection: Set<String>, locale: Locale, enabled: Bool) {
            guard let owner else { return }
            updating = true; defer { updating = false }
            self.column = column
            let table = view.table, languageChanged = self.locale != locale
            self.locale = locale
            if table.isEnabled != enabled { table.isEnabled = enabled; table.setAccessibilityEnabled(enabled) }
            view.scroll.workspace = owner.parent.workspace; view.scroll.remote = owner.parent.remote; view.scroll.isDropEnabled = enabled
            let title = column.snapshot.path.isEmpty ? L10n.text("存储桶根目录") : column.snapshot.path
            if view.header.stringValue != title || languageChanged {
                view.header.stringValue = title; view.header.toolTip = title
                table.setAccessibilityLabel(L10n.format("目录：%@", title))
            }
            if view.empty.stringValue != owner.parent.emptyMessage { view.empty.stringValue = owner.parent.emptyMessage }
            if view.empty.isHidden != !column.files.isEmpty { view.empty.isHidden = !column.files.isEmpty }
            if revision != column.revision {
                revision = column.revision
                rowByID = column.files.enumerated().reduce(into: [:]) { $0[$1.element.id] = $1.offset }
                table.reloadData()
            } else if languageChanged {
                let rows = table.rows(in: table.visibleRect)
                if rows.location != NSNotFound, rows.length > 0 {
                    let end = min(column.files.count, rows.location + rows.length)
                    if rows.location < end { table.reloadData(forRowIndexes: IndexSet(integersIn: rows.location..<end), columnIndexes: [0]) }
                }
            }
            let indexes = IndexSet(selection.compactMap { rowByID[$0] })
            if table.selectedRowIndexes != indexes { table.selectRowIndexes(indexes, byExtendingSelection: false) }
        }
        func numberOfRows(in tableView: NSTableView) -> Int { column.files.count }
        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            column.files.indices.contains(row) ? column.files[row].name : nil
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard column.files.indices.contains(row) else { return nil }
            let id = NSUserInterfaceItemIdentifier("name")
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? FileNameCell) ?? FileNameCell(identifier: id, showsDisclosure: true)
            cell.configure(column.files[row]); return cell
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, view.table.isEnabled else { return }
            activate()
            let indexes = view.table.selectedRowIndexes
            if indexes.count == 1, let row = indexes.first, column.files.indices.contains(row), column.files[row].isDirectory {
                owner?.parent.workspace.open(column.files[row], remote: owner?.parent.remote ?? false)
            }
        }
        private var selectedIDs: Set<String> {
            Set(view.table.selectedRowIndexes.compactMap { column.files.indices.contains($0) ? column.files[$0].id : nil })
        }
        private func activate() {
            guard let owner else { return }
            let listingPath = owner.parent.remote ? owner.parent.workspace.remoteListingPath : owner.parent.workspace.localListingPath
            if Data(listingPath.utf8) == Data(column.snapshot.path.utf8) {
                owner.parent.selection = selectedIDs; owner.parent.workspace.focusedRemote = owner.parent.remote
            } else {
                owner.parent.workspace.activateColumn(column.snapshot, remote: owner.parent.remote, selection: selectedIDs)
            }
        }
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard view.table.isEnabled, owner?.parent.remote == false, column.files.indices.contains(row) else { return nil }
            return URL(fileURLWithPath: column.files[row].path) as NSURL
        }
        func openSelection(directoriesOnly: Bool = false) {
            guard view.table.isEnabled, let owner, column.files.indices.contains(view.table.selectedRow) else { return }
            let entry = column.files[view.table.selectedRow]
            guard !directoriesOnly || entry.isDirectory else { return }
            activate(); owner.parent.workspace.open(entry, remote: owner.parent.remote)
        }
        @objc private func openDoubleClick() {
            let row = view.table.clickedRow
            guard view.table.isEnabled, let owner, column.files.indices.contains(row), !column.files[row].isDirectory else { return }
            activate(); owner.parent.workspace.open(column.files[row], remote: owner.parent.remote)
        }
        private func menu(_ event: NSEvent) -> NSMenu? {
            guard view.table.isEnabled, let owner else { return nil }
            let row = view.table.row(at: view.table.convert(event.locationInWindow, from: nil))
            guard column.files.indices.contains(row) else { return nil }
            // Right-click selects the row without opening a folder first.
            updating = true
            if !view.table.selectedRowIndexes.contains(row) { view.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            updating = false; activate()
            let selected = selectedIDs
            return actions.menu(for: column.files[row], selection: column.files.filter { selected.contains($0.id) },
                                remote: owner.parent.remote, workspace: owner.parent.workspace)
        }
    }
}

@MainActor final class ColumnScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let strip = documentView as? ColumnStrip else { return }
        strip.frame.size = NSSize(width: max(contentView.bounds.width, CGFloat(strip.columns.count) * InterfaceStyle.columnWidth),
                                  height: contentView.bounds.height)
        strip.needsLayout = true
    }
}

@MainActor final class ColumnStrip: NSView {
    override var isFlipped: Bool { true }
    private(set) var columns: [ColumnView] = []
    func setColumns(_ newColumns: [ColumnView]) {
        guard columns.count != newColumns.count || !zip(columns, newColumns).allSatisfy({ $0 === $1 }) else { return }
        for column in columns where !newColumns.contains(where: { $0 === column }) { column.removeFromSuperview() }
        for column in newColumns where column.superview !== self { addSubview(column) }
        columns = newColumns; needsLayout = true
    }
    override func layout() {
        super.layout()
        for (index, column) in columns.enumerated() {
            column.frame = NSRect(x: CGFloat(index) * InterfaceStyle.columnWidth, y: 0, width: InterfaceStyle.columnWidth, height: bounds.height)
        }
    }
}

@MainActor final class ColumnView: NSView {
    let id: String
    let table = BrowserTable()
    let scroll = FileBrowserScrollView()
    let header = NSTextField(labelWithString: "")
    let empty = ColumnEmptyLabel(wrappingLabelWithString: "")
    init(id: String) {
        self.id = id; super.init(frame: .zero)
        header.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        header.textColor = .secondaryLabelColor; header.lineBreakMode = .byTruncatingMiddle
        empty.font = .systemFont(ofSize: NSFont.smallSystemFontSize); empty.textColor = .secondaryLabelColor
        empty.alignment = .center; empty.setAccessibilityElement(false)
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        InterfaceStyle.configure(table); table.allowsMultipleSelection = true; table.allowsEmptySelection = true
        table.headerView = nil; table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.autoresizingMask = [.width]; table.intercellSpacing = NSSize(width: 6, height: 2)
        let name = NSTableColumn(identifier: .init("name")); name.width = InterfaceStyle.columnWidth; name.minWidth = 120
        table.addTableColumn(name); scroll.documentView = table
        let divider = NSBox(); divider.boxType = .separator
        let edge = NSBox(); edge.boxType = .separator
        for view in [header, scroll, divider, edge, empty] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: InterfaceStyle.paneInset),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -InterfaceStyle.paneInset),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 7), header.heightAnchor.constraint(equalToConstant: 16),
            divider.topAnchor.constraint(equalTo: topAnchor, constant: 30), divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor), divider.heightAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor), scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            edge.trailingAnchor.constraint(equalTo: trailingAnchor), edge.topAnchor.constraint(equalTo: topAnchor), edge.bottomAnchor.constraint(equalTo: bottomAnchor),
            edge.widthAnchor.constraint(equalToConstant: 1),
            empty.leadingAnchor.constraint(equalTo: leadingAnchor, constant: InterfaceStyle.paneInset),
            empty.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -InterfaceStyle.paneInset),
            empty.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 24)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Empty-state text must not intercept Finder drops over the native receiver.
@MainActor final class ColumnEmptyLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
