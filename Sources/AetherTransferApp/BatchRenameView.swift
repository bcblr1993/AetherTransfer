import SwiftUI
import AppKit
import AetherTransferCore

struct BatchRenameRequest: Identifiable {
    let id = UUID()
    let entries: [FileEntry]
    let remote: Bool
    let connection: UUID
    let client: RemoteClient?
}

@MainActor final class BatchRenameModel: ObservableObject {
    @Published var rule = RenameRule()
    @Published var start = "1"
    @Published var increment = "1"
    @Published var digits = "3"
    @Published private(set) var loading = false
    @Published private(set) var preparing = false
    @Published private(set) var applying = false
    @Published private(set) var completed = 0
    @Published private(set) var error: String?
    @Published private(set) var plan: BatchRenamePlan?
    @Published private(set) var result: BatchRenameResult?
    @Published private(set) var revision = UUID()
    let request: BatchRenameRequest
    private weak var workspace: Workspace?
    private var snapshot: BatchRenameSnapshot?
    private var excluded: Set<String> = []
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    init(_ request: BatchRenameRequest, workspace: Workspace) { self.request = request; self.workspace = workspace }
    var canApply: Bool { !loading && !preparing && !applying && result == nil && plan?.canApply == true }
    private var connectionMatches: Bool { !request.remote || workspace?.connectionRevision == request.connection }
    func load() {
        guard !applying, connectionMatches else { error = BatchRenameError.changed.localizedDescription; return }
        operation?.cancel(); generation = UUID(); let token = generation
        loading = true; preparing = false; result = nil; error = nil; plan = nil; snapshot = nil; revision = UUID()
        operation = Task {
            do {
                let snapshot = try await BatchRename.preview(request.entries, client: request.client)
                try Task.checkCancellation(); guard generation == token else { return }
                self.snapshot = snapshot; loading = false; rebuild(immediate: true)
            } catch {
                guard generation == token else { return }; loading = false
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }
    func rebuild(immediate: Bool = false) {
        guard !applying, result == nil, let snapshot else { return }
        operation?.cancel(); generation = UUID(); let token = generation
        preparing = true; error = nil
        var rule = rule; rule.start = Int(start) ?? -1; rule.increment = Int(increment) ?? -1; rule.digits = Int(digits) ?? -1
        let resolvedRule = rule, excluded = excluded
        operation = Task {
            do {
                if !immediate { try await Task.sleep(for: .milliseconds(180)) }
                let worker = Task.detached { try snapshot.plan(rule: resolvedRule, excluded: excluded) }
                let plan = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation(); guard generation == token else { return }
                self.plan = plan; revision = UUID()
            } catch {
                guard generation == token else { return }
                if !(error is CancellationError) { self.error = error.localizedDescription; plan = nil; revision = UUID() }
            }
            if generation == token { preparing = false }
        }
    }
    func include(_ enabled: Bool, id: String) {
        if enabled { excluded.remove(id) } else { excluded.insert(id) }; rebuild(immediate: true)
    }
    func apply() {
        guard canApply, let plan else { return }
        guard connectionMatches else { error = BatchRenameError.changed.localizedDescription; return }
        applying = true; completed = 0; workspace?.batchRenameBusy = true
        operation = Task { [self] in
            let result = await BatchRename.apply(plan, client: request.client) { [weak self = self] count in
                Task { @MainActor in if let self, self.applying { self.completed = count } }
            }
            self.result = result; completed = result.completed; applying = false; workspace?.batchRenameBusy = false; revision = UUID()
            if connectionMatches {
                if request.remote { workspace?.refreshRemote() } else { workspace?.refreshLocal() }
            }
        }
    }
    func cancel() { operation?.cancel() }
    func revealResults() {
        guard connectionMatches, let snapshot else { return }
        if result?.outcomes.contains(where: { $0.staged || $0.unconfirmedDestination != nil }) == true { workspace?.showHidden = true }
        if request.remote { workspace?.remotePath = snapshot.parent; workspace?.refreshRemote() }
        else { workspace?.localPath = snapshot.parent; workspace?.refreshLocal() }
    }
}

struct BatchRenameView: View {
    @Environment(\.locale) private var interfaceLocale
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: BatchRenameModel
    @FocusState private var focused: Bool
    init(request: BatchRenameRequest, workspace: Workspace) { _model = StateObject(wrappedValue: BatchRenameModel(request, workspace: workspace)) }
    var body: some View {
        let _ = interfaceLocale
        VStack(spacing: 0) {
            SheetHeader(title: L10n.text("批量重命名"), subtitle: L10n.text("先核对新名称，再重命名所选项目。"), symbol: "character.cursor.ibeam")
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: InterfaceStyle.fieldGap) {
                    Text(model.plan?.snapshot.parent ?? RemotePath.parent(model.request.entries[0].path))
                        .font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    FormFieldRow(title: L10n.text("命名方式")) {
                        Picker(L10n.text("命名方式"), selection: $model.rule.kind) {
                            Text(L10n.text("替换文字")).tag(RenameRule.Kind.replace)
                            Text(L10n.text("添加文字")).tag(RenameRule.Kind.add)
                            Text(L10n.text("名称与编号")).tag(RenameRule.Kind.number)
                        }.pickerStyle(.segmented).labelsHidden()
                    }
                    switch model.rule.kind {
                    case .replace:
                        FormFieldRow(title: L10n.text("查找文字")) { TextField(L10n.text("查找文字"), text: $model.rule.find).focused($focused) }
                        FormFieldRow(title: L10n.text("替换为")) { TextField(L10n.text("替换为"), text: $model.rule.replacement) }
                    case .add:
                        FormFieldRow(title: L10n.text("前缀")) { TextField(L10n.text("前缀"), text: $model.rule.prefix).focused($focused) }
                        FormFieldRow(title: L10n.text("后缀")) { TextField(L10n.text("后缀"), text: $model.rule.suffix) }
                    case .number:
                        FormFieldRow(title: L10n.text("基本名称")) { TextField(L10n.text("基本名称"), text: $model.rule.base).focused($focused) }
                        FormFieldRow(title: L10n.text("分隔符")) { TextField(L10n.text("分隔符"), text: $model.rule.separator) }
                        FormFieldRow(title: L10n.text("起始编号")) { TextField("1", text: $model.start).accessibilityLabel(L10n.text("起始编号")) }
                        FormFieldRow(title: L10n.text("编号间隔")) { TextField("1", text: $model.increment).accessibilityLabel(L10n.text("编号间隔")) }
                        FormFieldRow(title: L10n.text("最少位数")) { TextField("3", text: $model.digits).accessibilityLabel(L10n.text("最少位数")) }
                    }
                    Toggle(L10n.text("包括文件扩展名"), isOn: $model.rule.includeExtension).toggleStyle(.checkbox)
                    SupportingText(L10n.text("编号按原名称的固定顺序生成；排除项目保留其编号，文件夹名称始终完整处理。"))
                    if model.request.remote {
                        SupportingText(L10n.text("每步重新核对目录。FTP 与 SFTP 无法保证并发改名时原子拒绝覆盖，请避免其他客户端同时修改此目录。"))
                    }
                }.padding(InterfaceStyle.pageInset)
            }.frame(maxHeight: 265).disabled(model.loading || model.applying || model.result != nil)
            Divider()
            if model.loading || (model.preparing && model.plan == nil) {
                ProgressView(model.loading ? L10n.text("读取重命名范围…") : L10n.text("生成名称预览…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let plan = model.plan {
                NativeRenameTable(plan: plan, result: model.result, revision: model.revision, include: model.include)
                    .disabled(model.preparing || model.applying || model.result != nil)
            } else { Spacer() }
            VStack(alignment: .leading, spacing: 8) {
                if model.applying, let plan = model.plan {
                    ProgressView(value: Double(model.completed), total: Double(max(1, plan.count)))
                    Text(L10n.format("已核对重命名 %@ / %@", String(model.completed), String(plan.count))).font(.caption).monospacedDigit()
                } else if let result = model.result {
                    Label(result.cancelled ? L10n.text("重命名已停止") : (result.error == nil ? L10n.text("重命名已完成") : L10n.text("重命名未全部完成")),
                          systemImage: result.error == nil && !result.cancelled ? "checkmark.circle" : "exclamationmark.circle")
                    SupportingText(L10n.format("已核对重命名 %@ / %@；已完成的修改不会回滚。", String(result.completed), String(result.total)))
                    if result.outcomes.contains(where: { $0.staged || $0.unconfirmedDestination != nil }) {
                        SupportingText(L10n.text("表中保留暂存名称和未核对的两个可能名称。点击查看结果会显示隐藏项目；请核对后继续处理。"))
                    }
                    if let error = result.error { InterfaceMessage(text: error) }
                } else if model.preparing {
                    ProgressView(L10n.text("生成名称预览…")).controlSize(.small)
                } else if let plan = model.plan {
                    Text(L10n.format("将重命名 %@ 项，共选择 %@ 项", String(plan.count), String(plan.items.count))).font(.caption).monospacedDigit()
                    if plan.items.contains(where: { $0.included && $0.issue != nil }) {
                        InterfaceMessage(text: L10n.text("请调整规则或排除冲突项；当前不会执行重命名。"))
                    }
                }
                if let error = model.error { InterfaceMessage(text: error) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(InterfaceStyle.pageInset)
            Divider()
            SheetActions {
                Button(model.applying ? L10n.text("停止") : (model.result == nil ? L10n.text("取消") : L10n.text("完成"))) {
                    if model.applying { model.cancel() } else { model.cancel(); dismiss() }
                }.keyboardShortcut(.cancelAction)
                Spacer()
                if model.result != nil {
                    Button(L10n.text("查看结果")) { model.revealResults(); dismiss() }
                } else {
                    Button(L10n.text("重新读取")) { model.load() }.disabled(model.loading || model.applying)
                    Button(L10n.text("重命名所选项目")) { model.apply() }.buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction).disabled(!model.canApply)
                }
            }
        }.frame(width: InterfaceStyle.renameWidth, height: 640)
            .interactiveDismissDisabled(model.applying)
            .task { model.load(); focused = true }
            .onChange(of: model.rule) { _, _ in model.rebuild() }
            .onChange(of: model.rule.kind) { _, _ in focused = true }
            .onChange(of: [model.start, model.increment, model.digits]) { _, _ in model.rebuild() }
            .onDisappear { model.cancel() }
    }
}

/// Reusable native rows keep large previews out of SwiftUI's per-field layout.
private struct NativeRenameTable: NSViewRepresentable {
    let plan: BatchRenamePlan
    let result: BatchRenameResult?
    let revision: UUID
    let include: (Bool, String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let table = NSTableView(); table.style = .inset; table.rowHeight = InterfaceStyle.listRowHeight; table.usesAutomaticRowHeights = false
        table.usesAlternatingRowBackgroundColors = true; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for (key, title, width) in [("check", L10n.text("执行"), 44.0), ("original", L10n.text("原名称"), 270.0), ("proposed", L10n.text("新名称 / 实际名称"), 310.0), ("status", L10n.text("状态"), 200.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key)); column.title = title; column.width = width; column.minWidth = key == "check" ? 44 : 100
            if key == "check" { column.maxWidth = 44 }; table.addTableColumn(column)
        }
        table.delegate = context.coordinator; table.dataSource = context.coordinator; context.coordinator.table = table; scroll.documentView = table
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator; coordinator.parent = self
        guard let table = coordinator.table else { return }; table.isEnabled = context.environment.isEnabled
        if coordinator.revision != revision || coordinator.locale != context.environment.locale {
            coordinator.revision = revision; coordinator.locale = context.environment.locale
            coordinator.outcomes = Dictionary(uniqueKeysWithValues: (result?.outcomes ?? []).map { ($0.id, $0) })
            for (key, title) in [("check", "执行"), ("original", "原名称"), ("proposed", "新名称 / 实际名称"), ("status", "状态")] {
                table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(key))?.title = L10n.text(title)
            }
            table.reloadData()
        } else {
            let range = table.rows(in: table.visibleRect)
            if range.location != NSNotFound, range.length > 0 {
                let end = min(plan.items.count, range.location + range.length)
                if range.location < end { table.reloadData(forRowIndexes: IndexSet(integersIn: range.location..<end), columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns)) }
            }
        }
    }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: NativeRenameTable
        weak var table: NSTableView?
        var revision: UUID?
        var locale: Locale?
        var outcomes: [String: BatchRenameOutcome] = [:]
        init(_ parent: NativeRenameTable) { self.parent = parent }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.plan.items.count }
        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? { parent.plan.items.indices.contains(row) ? parent.plan.items[row].entry.name : nil }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard parent.plan.items.indices.contains(row), let column = tableColumn else { return nil }; let item = parent.plan.items[row]
            if column.identifier.rawValue == "check" {
                let cell = (tableView.makeView(withIdentifier: column.identifier, owner: self) as? CheckCell) ?? CheckCell(column.identifier)
                cell.button.identifier = NSUserInterfaceItemIdentifier(item.id); cell.button.state = item.included ? .on : .off; cell.button.isEnabled = tableView.isEnabled
                cell.button.target = self; cell.button.action = #selector(checked(_:)); cell.button.setAccessibilityLabel(L10n.format("重命名 %@", item.entry.name)); return cell
            }
            let cell = (tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTableCellView) ?? NSTableCellView()
            if cell.textField == nil {
                cell.identifier = column.identifier; let text = NSTextField(labelWithString: ""); text.font = .systemFont(ofSize: 12); text.lineBreakMode = .byTruncatingMiddle
                text.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(text); cell.textField = text
                NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            }
            let outcome = outcomes[item.id]
            let status: String
            if let outcome, outcome.unconfirmedDestination != nil { status = L10n.text("结果未核对") }
            else if outcome?.completed == true { status = L10n.text("已重命名") }
            else if outcome?.staged == true { status = L10n.text("暂存名称") }
            else { status = item.explanation }
            let proposed = outcome.map { $0.currentName + ($0.unconfirmedDestination.map { " / " + $0 } ?? "") } ?? item.proposedName
            cell.textField?.stringValue = column.identifier.rawValue == "original" ? item.entry.name : (column.identifier.rawValue == "proposed" ? proposed : status)
            cell.textField?.textColor = column.identifier.rawValue == "status" && (item.issue != nil || outcome?.unconfirmedDestination != nil || outcome?.staged == true) ? .systemOrange : .labelColor
            cell.toolTip = item.entry.name + " → " + proposed + "\n" + status; return cell
        }
        @objc func checked(_ sender: NSButton) { if let id = sender.identifier?.rawValue { parent.include(sender.state == .on, id) } }
    }
    private final class CheckCell: NSTableCellView {
        let button = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        init(_ id: NSUserInterfaceItemIdentifier) {
            super.init(frame: .zero); identifier = id; button.translatesAutoresizingMaskIntoConstraints = false; addSubview(button)
            NSLayoutConstraint.activate([button.centerXAnchor.constraint(equalTo: centerXAnchor), button.centerYAnchor.constraint(equalTo: centerYAnchor)])
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}
