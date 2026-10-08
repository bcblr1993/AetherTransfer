import SwiftUI
import AetherTransferCore

struct PermissionRequest: Identifiable {
    let id = UUID()
    let entries: [FileEntry]
    let remote: Bool
    let connection: UUID
    let client: RemoteClient?
}

@MainActor final class PermissionEditorModel: ObservableObject {
    @Published var modeText = ""
    @Published private(set) var loading = false
    @Published private(set) var applying = false
    @Published private(set) var completed = 0
    @Published private(set) var error: String?
    @Published private(set) var result: PermissionBatchResult?
    @Published private(set) var plan: PermissionPlan?
    @Published private(set) var recursive = false
    @Published private(set) var scanned = 0
    let request: PermissionRequest
    private weak var workspace: Workspace?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    init(_ request: PermissionRequest, workspace: Workspace) { self.request = request; self.workspace = workspace }
    var mode: UnixPermissions? { try? UnixPermissions(octal: modeText) }
    var count: Int { plan?.targets.count ?? 0 }
    var canApply: Bool { mode != nil && count > 0 && !loading && !applying && result == nil }
    func setRecursive(_ value: Bool) {
        guard !applying, recursive != value else { return }
        recursive = value; load()
    }
    private var connectionMatches: Bool { !request.remote || workspace?.connectionRevision == request.connection }
    func load() {
        guard !applying, connectionMatches else { error = FilePermissionError.changed.localizedDescription; return }
        operation?.cancel(); generation = UUID(); let token = generation
        loading = true; error = nil; result = nil; plan = nil; completed = 0; scanned = 0
        let recursive = recursive
        operation = Task { [self] in
            do {
                let plan = try await PermissionBatch.preview(request.entries, client: request.client, recursive: recursive) { [weak self] count in
                    Task { @MainActor in if let self, self.generation == token, self.loading { self.scanned = count } }
                }
                try Task.checkCancellation()
                guard token == generation else { return }
                self.plan = plan; scanned = plan.targets.count + plan.skippedSymbolicLinks
                if modeText.isEmpty, let common = plan.commonMode { modeText = common.octal }
            } catch {
                guard token == generation else { return }
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
            if token == generation { loading = false }
        }
    }
    func apply() {
        guard canApply, let mode, let plan else { return }
        guard connectionMatches else { error = FilePermissionError.changed.localizedDescription; return }
        applying = true; workspace?.permissionBusy = true; error = nil; completed = 0
        let token = generation
        operation = Task { [self] in
            let result = await PermissionBatch.apply(mode, plan: plan, client: request.client) { [weak self] count in
                Task { @MainActor in if let self, self.generation == token, self.applying { self.completed = count } }
            }
            self.result = result; completed = result.completed; applying = false; workspace?.permissionBusy = false
            if connectionMatches {
                if request.remote { workspace?.refreshRemote() } else { workspace?.refreshLocal() }
            }
        }
    }
    func cancel() { operation?.cancel() }
    func bit(_ mask: UInt16) -> Binding<Bool> {
        Binding(get: { (self.mode?.rawValue ?? 0) & mask != 0 }, set: { enabled in
            let value = self.mode?.rawValue ?? 0
            self.modeText = (try? UnixPermissions(enabled ? value | mask : value & ~mask))?.octal ?? ""
        })
    }
}

struct PermissionEditorView: View {
    @Environment(\.locale) private var interfaceLocale
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: PermissionEditorModel
    @FocusState private var octalFocused: Bool
    init(request: PermissionRequest, workspace: Workspace) {
        _model = StateObject(wrappedValue: PermissionEditorModel(request, workspace: workspace))
    }
    var body: some View {
        let _ = interfaceLocale
        VStack(spacing: 0) {
            SheetHeader(title: L10n.text("编辑权限"),
                        subtitle: L10n.format("为 %@ 个所选项目设置 Unix 权限。", String(model.request.entries.count)),
                        symbol: "lock.open")
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: InterfaceStyle.sectionGap) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.request.entries.prefix(3)) { entry in
                            Text(entry.name).font(.callout).lineLimit(1).truncationMode(.middle)
                                .textSelection(.enabled).help(entry.path)
                        }
                    }
                    if model.request.entries.contains(where: \.isDirectory) {
                        Toggle(L10n.text("包括文件夹中的项目"), isOn: Binding(get: { model.recursive }, set: { model.setRecursive($0) }))
                            .toggleStyle(.checkbox)
                    }
                    SupportingText(model.recursive ? L10n.text("包括隐藏项目；文件和文件夹应用相同权限，符号链接跳过。") : L10n.text("仅修改所选项目，不递归修改文件夹中的内容。"))
                    if model.loading {
                        ProgressView(model.recursive ? L10n.text("扫描权限范围…") : L10n.text("读取权限…"))
                        if model.recursive {
                            Text(L10n.format("已扫描 %@ 项", String(model.scanned))).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    } else if let plan = model.plan {
                        Text(L10n.format("应用范围：%@ 个文件，%@ 个文件夹", String(plan.fileCount), String(plan.folderCount)))
                            .font(.callout).monospacedDigit()
                        if plan.skippedSymbolicLinks > 0 {
                            Text(L10n.format("跳过 %@ 个符号链接", String(plan.skippedSymbolicLinks)))
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: InterfaceStyle.fieldGap) {
                            GridRow {
                                Text(L10n.text("访问者"))
                                Text(L10n.text("读取")); Text(L10n.text("写入")); Text(L10n.text("执行"))
                            }.font(.caption).foregroundStyle(.secondary)
                            permissionRow("所有者", shift: 6)
                            permissionRow("用户组", shift: 3)
                            permissionRow("其他用户", shift: 0)
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: InterfaceStyle.cornerRadius))
                        HStack {
                            Text(L10n.text("八进制权限")).frame(width: InterfaceStyle.fieldLabelWidth, alignment: .leading)
                            TextField("0644", text: $model.modeText).textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced)).focused($octalFocused)
                                .accessibilityLabel(L10n.text("八进制权限"))
                            Text(model.mode?.symbolic ?? "---------").font(.system(.callout, design: .monospaced))
                        }
                        if model.mode == nil {
                            SupportingText(model.modeText.isEmpty ? L10n.text("权限不一致，请明确选择要设置的权限。") : FilePermissionError.invalidMode.localizedDescription)
                        }
                        DisclosureGroup(L10n.text("特殊权限")) {
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle(L10n.text("设置用户 ID（setuid）"), isOn: model.bit(0o4000))
                                Toggle(L10n.text("设置组 ID（setgid）"), isOn: model.bit(0o2000))
                                Toggle(L10n.text("粘滞位（sticky）"), isOn: model.bit(0o1000))
                            }.toggleStyle(.checkbox).padding(.top, 8)
                        }
                    }
                    if model.applying {
                        ProgressView(value: Double(model.completed), total: Double(max(1, model.count)))
                        Text(model.completed == 0 ? L10n.text("检查范围并应用权限…") : L10n.format("已核对完成 %@ / %@", String(model.completed), String(model.count))).font(.caption).monospacedDigit()
                    }
                    if let result = model.result {
                        Label(result.error == nil && !result.cancelled ? L10n.text("权限已应用") : (result.cancelled ? L10n.text("权限操作已停止") : L10n.text("权限操作未全部完成")),
                              systemImage: result.error == nil && !result.cancelled ? "checkmark.circle" : "exclamationmark.circle")
                        SupportingText(L10n.format("已核对完成 %@ / %@；已完成的修改不会回滚。", String(result.completed), String(result.total)))
                        if result.cancelled || result.error != nil {
                            SupportingText(L10n.text("未核对的项目可能已写入，请重新读取实际权限。"))
                        }
                        if let error = result.error { InterfaceMessage(text: error) }
                    }
                    if let error = model.error { InterfaceMessage(text: error) }
                }.padding(InterfaceStyle.pageInset)
            }.disabled(model.applying)
            Divider()
            SheetActions {
                Button(model.applying ? L10n.text("停止") : (model.result != nil ? L10n.text("完成") : L10n.text("取消"))) {
                    if model.applying { model.cancel() } else { model.cancel(); dismiss() }
                }.keyboardShortcut(.cancelAction)
                Spacer()
                if model.result != nil || model.error != nil {
                    Button(L10n.text("重新读取权限")) { model.load() }.disabled(model.loading || model.applying)
                } else {
                    Button(model.recursive ? L10n.text("应用到全部项目") : L10n.text("应用权限")) { model.apply() }.buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction).disabled(!model.canApply)
                }
            }
        }.frame(width: InterfaceStyle.connectionWidth, height: 560)
            .interactiveDismissDisabled(model.applying)
            .task { model.load(); octalFocused = true }
            .onChange(of: model.loading) { _, loading in if !loading { octalFocused = true } }
            .onDisappear { model.cancel() }
    }
    private func permissionRow(_ name: String, shift: Int) -> some View {
        GridRow {
            Text(L10n.text(name)).frame(minWidth: 110, alignment: .leading)
            ForEach([UInt16(4), 2, 1], id: \.self) { bit in
                Toggle("", isOn: model.bit(bit << shift)).toggleStyle(.checkbox)
                    .accessibilityLabel("\(L10n.text(name)) · \(bit == 4 ? L10n.text("读取") : (bit == 2 ? L10n.text("写入") : L10n.text("执行")))")
            }
        }
    }
}
