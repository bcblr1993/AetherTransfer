import AppKit
import SwiftUI
import AetherTransferCore

/// A fixed-height, reusable AppKit table keeps large folder changes out of SwiftUI's row diffing.
struct NativeFileTable: NSViewRepresentable {
    let files: [FileEntry]
    let revision: UUID
    @Binding var selection: Set<String>
    @Binding var sortField: FileSortField
    @Binding var descending: Bool
    let remote: Bool
    let workspace: Workspace

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = FileBrowserScrollView()
        scroll.workspace = workspace; scroll.remote = remote
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        let table = BrowserTable()
        InterfaceStyle.configure(table); table.allowsMultipleSelection = true
        table.allowsEmptySelection = true; table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.autoresizingMask = [.width]; table.intercellSpacing = NSSize(width: 6, height: 2)
        for (key, title, width) in [("name", L10n.text("名称"), 250.0), ("size", L10n.text("大小"), 90.0), ("modified", L10n.text("修改日期"), 140.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = title; column.width = width; column.minWidth = key == "name" ? 120 : 70
            column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true)
            table.addTableColumn(column)
        }
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.openSelection)
        table.menuProvider = { [weak coordinator = context.coordinator] event in coordinator?.menu(event) }
        table.openSelected = { [weak coordinator = context.coordinator] in coordinator?.openKeyboardSelection() }
        table.copyEntries = { [weak coordinator = context.coordinator] in coordinator?.copySelection() ?? [] }
        table.hasCopySelection = { [weak coordinator = context.coordinator] in coordinator?.canCopySelection == true }
        table.previewSelected = { [weak coordinator = context.coordinator] in
            guard let coordinator else { return }
            coordinator.parent.workspace.previewSelection(remote: coordinator.parent.remote)
        }
        table.focused = { [weak coordinator = context.coordinator] in
            guard let coordinator else { return }
            if coordinator.parent.workspace.focusedRemote != coordinator.parent.remote {
                coordinator.parent.workspace.focusedRemote = coordinator.parent.remote
            }
        }
        table.initialFocusRequested = { [weak coordinator = context.coordinator] in
            guard let coordinator else { return false }
            return coordinator.parent.workspace.focusedRemote == coordinator.parent.remote
        }
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        scroll.documentView = table
        context.coordinator.table = table
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if let drop = scroll as? FileBrowserScrollView {
            drop.workspace = workspace; drop.remote = remote; drop.isDropEnabled = context.environment.isEnabled
        }
        guard let table = coordinator.table else { return }
        table.isEnabled = context.environment.isEnabled
        coordinator.updating = true
        defer { coordinator.updating = false }
        let languageChanged = coordinator.locale != context.environment.locale
        if languageChanged {
            coordinator.locale = context.environment.locale
            coordinator.updateFormatters()
            for (key, title) in [("name", "名称"), ("size", "大小"), ("modified", "修改日期")] {
                table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(key))?.title = L10n.text(title)
            }
        }
        if coordinator.revision != revision {
            coordinator.files = files; coordinator.revision = revision
            coordinator.rowByID = files.enumerated().reduce(into: [:]) { $0[$1.element.id] = $1.offset }
            table.reloadData()
        } else if languageChanged {
            let range = table.rows(in: table.visibleRect)
            if range.location != NSNotFound, range.length > 0 {
                let end = min(files.count, range.location + range.length)
                if range.location < end {
                    table.reloadData(forRowIndexes: IndexSet(integersIn: range.location..<end),
                                     columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
                }
            }
        }
        let indexes = IndexSet(selection.compactMap { coordinator.rowByID[$0] })
        if table.selectedRowIndexes != indexes { table.selectRowIndexes(indexes, byExtendingSelection: false) }
        let key = sortField == .size ? "size" : (sortField == .modified ? "modified" : "name")
        if table.sortDescriptors.first?.key != key || table.sortDescriptors.first?.ascending != !descending {
            table.sortDescriptors = [NSSortDescriptor(key: key, ascending: !descending)]
        }
        table.focusIfNeeded()
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: NativeFileTable
        weak var table: BrowserTable?
        var files: [FileEntry] = []
        var rowByID: [String: Int] = [:]
        var revision: UUID?
        var updating = false
        var locale: Locale?
        private let actions = FileBrowserActions()
        private let dateFormatter: DateFormatter = {
            let value = DateFormatter(); value.dateStyle = .short; value.timeStyle = .short; return value
        }()
        private var byteStyle = ByteCountFormatStyle(style: .file, spellsOutZero: false)
        init(_ parent: NativeFileTable) { self.parent = parent; super.init() }
        func updateFormatters() {
            dateFormatter.locale = locale
            byteStyle.locale = locale ?? .current
        }
        func numberOfRows(in tableView: NSTableView) -> Int { files.count }
        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            files.indices.contains(row) ? files[row].name : nil
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard files.indices.contains(row), let column = tableColumn else { return nil }
            let entry = files[row], nameColumn = column.identifier.rawValue == "name"
            let cell = (tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTableCellView) ?? makeCell(column.identifier, name: nameColumn)
            switch column.identifier.rawValue {
            case "size": cell.textField?.stringValue = entry.isDirectory ? "—" : byteStyle.format(entry.size)
            case "modified": cell.textField?.stringValue = entry.modified.map { dateFormatter.string(from: $0) } ?? "—"
            default:
                (cell as? FileNameCell)?.configure(entry)
            }
            return cell
        }
        private func makeCell(_ identifier: NSUserInterfaceItemIdentifier, name: Bool) -> NSTableCellView {
            if name { return FileNameCell(identifier: identifier) }
            let cell = NSTableCellView(); cell.identifier = identifier
            let text = NSTextField(labelWithString: "")
            text.font = InterfaceStyle.listFont
            text.textColor = name ? .labelColor : .secondaryLabelColor
            text.lineBreakMode = name ? .byTruncatingMiddle : .byTruncatingTail
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text); cell.textField = text
            NSLayoutConstraint.activate([text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                                         text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4)])
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4).isActive = true
            return cell
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            let selection = Set(table.selectedRowIndexes.compactMap { files.indices.contains($0) ? files[$0].id : nil })
            if parent.selection != selection { parent.selection = selection }
            if parent.workspace.focusedRemote != parent.remote { parent.workspace.focusedRemote = parent.remote }
        }
        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !updating, let descriptor = tableView.sortDescriptors.first else { return }
            parent.sortField = descriptor.key == "size" ? .size : (descriptor.key == "modified" ? .modified : .name)
            parent.descending = !descriptor.ascending
        }
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard table?.isEnabled == true, !parent.remote, files.indices.contains(row) else { return nil }
            return URL(fileURLWithPath: files[row].path) as NSURL
        }
        @objc func openSelection() {
            guard let table, table.isEnabled else { return }
            let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
            guard files.indices.contains(row) else { return }
            parent.workspace.open(files[row], remote: parent.remote)
        }
        func openKeyboardSelection() {
            guard let table, table.isEnabled, files.indices.contains(table.selectedRow) else { return }
            let row = table.selectedRow
            parent.workspace.open(files[row], remote: parent.remote)
        }
        var canCopySelection: Bool {
            guard let table, table.isEnabled, !updating, revision == parent.revision,
                  !(parent.remote ? parent.workspace.loadingRemote || parent.workspace.connecting : parent.workspace.loadingLocal),
                  let row = table.selectedRowIndexes.first else { return false }
            return files.indices.contains(row)
        }
        func copySelection() -> [FileEntry] {
            guard canCopySelection, let table else { return [] }
            return table.selectedRowIndexes.compactMap { files.indices.contains($0) ? files[$0] : nil }
        }
        func menu(_ event: NSEvent) -> NSMenu? {
            guard let table, table.isEnabled else { return nil }
            let row = table.row(at: table.convert(event.locationInWindow, from: nil))
            guard files.indices.contains(row) else { return nil }
            if !table.selectedRowIndexes.contains(row) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            parent.workspace.focusedRemote = parent.remote
            return actions.menu(for: files[row], selection: files.filter { parent.selection.contains($0.id) },
                                remote: parent.remote, workspace: parent.workspace)
        }
    }
}

@MainActor final class BrowserTable: NSTableView {
    var menuProvider: ((NSEvent) -> NSMenu?)?
    var openSelected: (() -> Void)?
    var previewSelected: (() -> Void)?
    var copyEntries: (() -> [FileEntry])?
    var hasCopySelection: (() -> Bool)?
    var focused: (() -> Void)?
    var initialFocusRequested: (() -> Bool)?
    var moveLeft: (() -> Void)?
    var moveRight: (() -> Void)?
    private var initialFocusPending = true
    func focusIfNeeded() {
        guard initialFocusPending, isEnabled, initialFocusRequested?() == true else { return }
        if BrowserInitialFocus.request(self) { initialFocusPending = false }
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); focusIfNeeded() }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { initialFocusPending = false; focused?() }
        return result
    }
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?(event) }
    @objc func copy(_ sender: Any?) {
        guard isEnabled else { return }
        FilePathCopy.write(copyEntries?() ?? [])
    }
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return isEnabled && hasCopySelection?() == true }
        return super.validateUserInterfaceItem(item)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 123 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty, let moveLeft { moveLeft() }
        else if event.keyCode == 124 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty, let moveRight { moveRight() }
        else if event.keyCode == 36 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty { openSelected?() }
        else if event.keyCode == 49 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty { previewSelected?() }
        else { super.keyDown(with: event) }
    }
}
