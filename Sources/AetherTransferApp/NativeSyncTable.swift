import AppKit
import SwiftUI
import AetherTransferCore

/// Preview rows use the same fixed-height reuse strategy as the file browser.
struct NativeSyncTable: NSViewRepresentable {
    let items: [SyncItem]
    let revision: UUID
    let selected: Set<String>
    let resolutions: [String: SyncDirection]
    let select: (Bool, String) -> Void
    let resolve: (SyncDirection?, String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let table = NSTableView(); table.style = .inset; table.rowHeight = InterfaceStyle.listRowHeight; table.usesAutomaticRowHeights = false
        table.usesAlternatingRowBackgroundColors = true; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsEmptySelection = true
        for (id, title, width) in [("check", L10n.text("执行"), 42.0), ("path", L10n.text("相对路径"), 370.0), ("action", L10n.text("操作"), 190.0), ("sizes", L10n.text("左侧 / 右侧大小"), 200.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title; column.width = width; column.minWidth = id == "check" ? 42 : 100
            if id == "check" { column.maxWidth = 42 }
            table.addTableColumn(column)
        }
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        scroll.documentView = table; context.coordinator.table = table
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator; coordinator.parent = self
        guard let table = coordinator.table else { return }
        table.isEnabled = context.environment.isEnabled
        if coordinator.locale != context.environment.locale {
            coordinator.locale = context.environment.locale
            coordinator.bytes.locale = context.environment.locale
            for (key, title) in [("check", "执行"), ("path", "相对路径"), ("action", "操作"), ("sizes", "左侧 / 右侧大小")] {
                table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(key))?.title = L10n.text(title)
            }
        }
        if coordinator.revision != revision {
            coordinator.items = items; coordinator.revision = revision
            coordinator.itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            table.reloadData()
        } else {
            let range = table.rows(in: table.visibleRect)
            if range.location != NSNotFound, range.length > 0 {
                let end = min(items.count, range.location + range.length)
                if range.location < end { table.reloadData(forRowIndexes: IndexSet(integersIn: range.location..<end), columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns)) }
            }
        }
    }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: NativeSyncTable
        weak var table: NSTableView?
        var revision: UUID?
        var items: [SyncItem] = []
        var itemsByID: [String: SyncItem] = [:]
        var locale: Locale?
        var bytes = ByteCountFormatStyle(style: .file, spellsOutZero: false)
        init(_ parent: NativeSyncTable) { self.parent = parent; super.init() }
        func numberOfRows(in tableView: NSTableView) -> Int { items.count }
        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            items.indices.contains(row) ? items[row].path : nil
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard items.indices.contains(row), let column = tableColumn else { return nil }
            let item = items[row]
            if column.identifier.rawValue == "check" {
                let cell = (tableView.makeView(withIdentifier: column.identifier, owner: self) as? CheckCell) ?? CheckCell(identifier: column.identifier)
                cell.button.identifier = NSUserInterfaceItemIdentifier(item.id)
                cell.button.state = parent.selected.contains(item.id) ? .on : .off
                cell.button.isEnabled = item.executable && tableView.isEnabled
                cell.button.target = self; cell.button.action = #selector(checked(_:))
                cell.button.setAccessibilityLabel(L10n.format("同步 %@", String(describing: item.path)))
                return cell
            }
            if column.identifier.rawValue == "action" {
                if item.operation == .conflict {
                    let id = NSUserInterfaceItemIdentifier("action-conflict")
                    let cell = (tableView.makeView(withIdentifier: id, owner: self) as? ActionCell) ?? ActionCell(identifier: id)
                    cell.popup.identifier = NSUserInterfaceItemIdentifier(item.id)
                    cell.popup.target = self; cell.popup.action = #selector(choseDirection(_:))
                    cell.popup.isEnabled = tableView.isEnabled
                    for (index, key) in ["选择方向…", "左侧 → 右侧", "右侧 → 左侧"].enumerated() {
                        cell.popup.item(at: index)?.title = L10n.text(key)
                    }
                    cell.popup.selectItem(at: parent.resolutions[item.id].map { $0 == .leftToRight ? 1 : 2 } ?? 0)
                    cell.popup.setAccessibilityLabel(L10n.format("传输方向 %@", String(describing: item.path)))
                    cell.toolTip = item.explanation
                    return cell
                }
                let cell = (tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTableCellView) ?? textCell(column.identifier)
                cell.textField?.stringValue = title(item)
                if case .delete = item.operation { cell.textField?.textColor = .systemRed }
                else { cell.textField?.textColor = item.operation == .blocked ? .secondaryLabelColor : .labelColor }
                cell.toolTip = item.explanation
                return cell
            }
            let cell = (tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTableCellView) ?? textCell(column.identifier)
            cell.textField?.stringValue = column.identifier.rawValue == "path" ? item.path : "\(size(item.left)) / \(size(item.right))"
            cell.toolTip = item.path + "\n" + item.explanation
            return cell
        }
        private func title(_ item: SyncItem) -> String {
            switch item.operation {
            case .copy(let direction):
                let exists = direction.destination == .left ? item.left != nil : item.right != nil
                return "\(exists ? L10n.text("覆盖") : L10n.text("复制")) · \(direction == .leftToRight ? L10n.text("向右 →") : L10n.text("← 向左"))"
            case .createDirectory(let side): return L10n.format("新建目录 · %@", String(describing: side == .left ? L10n.text("左侧") : L10n.text("右侧")))
            case .delete(let side): return L10n.format("删除 · %@", String(describing: side == .left ? L10n.text("左侧") : L10n.text("右侧")))
            case .conflict: return L10n.text("选择方向")
            case .blocked: return L10n.text("需要处理")
            }
        }
        private func size(_ record: SyncRecord?) -> String {
            guard let record else { return "—" }
            return record.kind == .directory ? L10n.text("文件夹") : bytes.format(record.size)
        }
        private func textCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView(); cell.identifier = id
            let text = NSTextField(labelWithString: ""); text.translatesAutoresizingMaskIntoConstraints = false
            text.font = .systemFont(ofSize: 12); text.lineBreakMode = .byTruncatingMiddle
            cell.addSubview(text); cell.textField = text
            NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                                         text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                                         text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            return cell
        }
        @objc private func checked(_ sender: NSButton) {
            guard let id = sender.identifier?.rawValue, itemsByID[id] != nil else { return }
            parent.select(sender.state == .on, id)
        }
        @objc private func choseDirection(_ sender: NSPopUpButton) {
            guard let id = sender.identifier?.rawValue, itemsByID[id]?.operation == .conflict else { return }
            parent.resolve(sender.indexOfSelectedItem == 0 ? nil : (sender.indexOfSelectedItem == 1 ? .leftToRight : .rightToLeft), id)
        }
    }
    @MainActor final class CheckCell: NSTableCellView {
        let button = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        init(identifier: NSUserInterfaceItemIdentifier) {
            super.init(frame: .zero); self.identifier = identifier
            button.translatesAutoresizingMaskIntoConstraints = false; addSubview(button)
            NSLayoutConstraint.activate([button.centerXAnchor.constraint(equalTo: centerXAnchor), button.centerYAnchor.constraint(equalTo: centerYAnchor)])
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    }
    @MainActor final class ActionCell: NSTableCellView {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        init(identifier: NSUserInterfaceItemIdentifier) {
            super.init(frame: .zero); self.identifier = identifier
            popup.addItems(withTitles: [L10n.text("选择方向…"), L10n.text("左侧 → 右侧"), L10n.text("右侧 → 左侧")])
            popup.controlSize = .small; popup.translatesAutoresizingMaskIntoConstraints = false; addSubview(popup)
            NSLayoutConstraint.activate([popup.leadingAnchor.constraint(equalTo: leadingAnchor),
                                         popup.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                                         popup.centerYAnchor.constraint(equalTo: centerYAnchor)])
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    }
}
