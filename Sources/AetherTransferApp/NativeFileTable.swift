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
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        let table = BrowserTable()
        table.style = .inset; table.rowHeight = 26; table.usesAutomaticRowHeights = false
        table.usesAlternatingRowBackgroundColors = true; table.allowsMultipleSelection = true
        table.allowsEmptySelection = true; table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.autoresizingMask = [.width]; table.intercellSpacing = NSSize(width: 6, height: 2)
        for (key, title, width) in [("name", "名称", 250.0), ("size", "大小", 90.0), ("modified", "修改日期", 140.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = title; column.width = width; column.minWidth = key == "name" ? 120 : 70
            column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true)
            table.addTableColumn(column)
        }
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.openSelection)
        table.menuProvider = { [weak coordinator = context.coordinator] event in coordinator?.menu(event) }
        table.openSelected = { [weak coordinator = context.coordinator] in coordinator?.openKeyboardSelection() }
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
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        scroll.documentView = table
        context.coordinator.table = table
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let table = coordinator.table else { return }
        table.isEnabled = context.environment.isEnabled
        coordinator.updating = true
        defer { coordinator.updating = false }
        if coordinator.revision != revision {
            coordinator.files = files; coordinator.revision = revision
            coordinator.rowByID = files.enumerated().reduce(into: [:]) { $0[$1.element.id] = $1.offset }
            table.reloadData()
        }
        let indexes = IndexSet(selection.compactMap { coordinator.rowByID[$0] })
        if table.selectedRowIndexes != indexes { table.selectRowIndexes(indexes, byExtendingSelection: false) }
        let key = sortField == .size ? "size" : (sortField == .modified ? "modified" : "name")
        if table.sortDescriptors.first?.key != key || table.sortDescriptors.first?.ascending != !descending {
            table.sortDescriptors = [NSSortDescriptor(key: key, ascending: !descending)]
        }
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: NativeFileTable
        weak var table: BrowserTable?
        var files: [FileEntry] = []
        var rowByID: [String: Int] = [:]
        var revision: UUID?
        var updating = false
        private let dateFormatter: DateFormatter = {
            let value = DateFormatter(); value.dateStyle = .short; value.timeStyle = .short; return value
        }()
        private let byteFormatter = ByteCountFormatter()
        init(_ parent: NativeFileTable) { self.parent = parent; super.init(); byteFormatter.countStyle = .file }
        func numberOfRows(in tableView: NSTableView) -> Int { files.count }
        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            files.indices.contains(row) ? files[row].name : nil
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard files.indices.contains(row), let column = tableColumn else { return nil }
            let entry = files[row], nameColumn = column.identifier.rawValue == "name"
            let cell = (tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTableCellView) ?? makeCell(column.identifier, name: nameColumn)
            switch column.identifier.rawValue {
            case "size": cell.textField?.stringValue = entry.isDirectory ? "—" : byteFormatter.string(fromByteCount: entry.size)
            case "modified": cell.textField?.stringValue = entry.modified.map { dateFormatter.string(from: $0) } ?? "—"
            default:
                cell.textField?.stringValue = entry.name
                cell.imageView?.image = NSImage(systemSymbolName: symbol(entry), accessibilityDescription: entry.isDirectory ? "文件夹" : "文件")
                cell.imageView?.contentTintColor = entry.isDirectory ? .controlAccentColor : .secondaryLabelColor
            }
            return cell
        }
        private func makeCell(_ identifier: NSUserInterfaceItemIdentifier, name: Bool) -> NSTableCellView {
            let cell = NSTableCellView(); cell.identifier = identifier
            let text = NSTextField(labelWithString: "")
            text.font = .systemFont(ofSize: NSFont.systemFontSize)
            text.textColor = name ? .labelColor : .secondaryLabelColor
            text.lineBreakMode = name ? .byTruncatingMiddle : .byTruncatingTail
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text); cell.textField = text
            NSLayoutConstraint.activate([text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                                         text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4)])
            if name {
                let image = NSImageView(); image.translatesAutoresizingMaskIntoConstraints = false
                image.symbolConfiguration = .init(pointSize: 14, weight: .regular)
                cell.addSubview(image); cell.imageView = image
                NSLayoutConstraint.activate([image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                                             image.centerYAnchor.constraint(equalTo: cell.centerYAnchor), image.widthAnchor.constraint(equalToConstant: 18),
                                             image.heightAnchor.constraint(equalToConstant: 18), text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 7)])
            } else { text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4).isActive = true }
            return cell
        }
        private func symbol(_ entry: FileEntry) -> String {
            if entry.isDirectory { return "folder.fill" }
            switch URL(fileURLWithPath: entry.name).pathExtension.lowercased() {
            case "png", "jpg", "jpeg", "heic", "gif", "webp": return "photo"
            case "mp4", "mov", "mkv": return "film"
            case "mp3", "flac", "m4a", "wav": return "music.note"
            case "zip", "gz", "tar", "7z": return "doc.zipper"
            case "swift", "js", "ts", "py", "json", "yaml", "yml", "html", "css": return "curlybraces"
            default: return "doc"
            }
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
            guard !parent.remote, files.indices.contains(row) else { return nil }
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
        func menu(_ event: NSEvent) -> NSMenu? {
            guard let table, table.isEnabled else { return nil }
            let row = table.row(at: table.convert(event.locationInWindow, from: nil))
            guard files.indices.contains(row) else { return nil }
            if !table.selectedRowIndexes.contains(row) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            let entry = files[row], menu = NSMenu()
            func add(_ title: String, _ selector: Selector, enabled: Bool = true) {
                let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
                item.target = self; item.representedObject = entry; item.isEnabled = enabled; menu.addItem(item)
            }
            add(entry.isDirectory ? "打开" : (parent.remote ? "下载" : "打开"), #selector(openItem(_:)))
            if !entry.isDirectory && !entry.isSymbolicLink { add("编辑文本…", #selector(editItem(_:))) }
            add("快速查看", #selector(previewItem(_:)), enabled: !entry.isDirectory && !entry.isSymbolicLink)
            add("文件信息", #selector(informationItem(_:)))
            if !parent.remote { add("上传", #selector(uploadItems), enabled: parent.workspace.client != nil) }
            menu.addItem(.separator())
            add("重命名…", #selector(renameItem(_:))); add("删除…", #selector(deleteItem(_:)))
            menu.autoenablesItems = false
            return menu
        }
        @objc private func openItem(_ sender: NSMenuItem) { if let entry = sender.representedObject as? FileEntry { parent.workspace.open(entry, remote: parent.remote) } }
        @objc private func renameItem(_ sender: NSMenuItem) { if let entry = sender.representedObject as? FileEntry { parent.workspace.rename(entry, remote: parent.remote) } }
        @objc private func editItem(_ sender: NSMenuItem) { if let entry = sender.representedObject as? FileEntry { parent.workspace.edit(entry, remote: parent.remote) } }
        @objc private func previewItem(_ sender: NSMenuItem) { if let entry = sender.representedObject as? FileEntry { parent.workspace.preview(entry, remote: parent.remote) } }
        @objc private func informationItem(_ sender: NSMenuItem) {
            parent.workspace.focusedRemote = parent.remote; parent.workspace.showInspector = true
        }
        @objc private func deleteItem(_ sender: NSMenuItem) { if let entry = sender.representedObject as? FileEntry { parent.workspace.delete(entry, remote: parent.remote) } }
        @objc private func uploadItems() { parent.workspace.upload(files.filter { parent.selection.contains($0.id) }) }
    }
}

@MainActor final class BrowserTable: NSTableView {
    var menuProvider: ((NSEvent) -> NSMenu?)?
    var openSelected: (() -> Void)?
    var previewSelected: (() -> Void)?
    var focused: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { focused?() }
        return result
    }
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?(event) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty { openSelected?() }
        else if event.keyCode == 49 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty { previewSelected?() }
        else { super.keyDown(with: event) }
    }
}
