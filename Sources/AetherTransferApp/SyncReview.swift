import AppKit
import SwiftUI
import AetherTransferCore

struct SyncLocation: Identifiable {
    let id: String
    let title: String
    let root: SyncRoot
}

@MainActor final class SyncReviewModel: ObservableObject {
    @Published var locations: [SyncLocation]
    @Published var leftID: String
    @Published var rightID: String
    @Published var options = SyncOptions()
    @Published var exclusions = ""
    @Published private(set) var plan: SyncPlan?
    @Published private(set) var selected: Set<String> = []
    @Published private(set) var resolutions: [String: SyncDirection] = [:]
    @Published private(set) var busy = false
    @Published var error: String?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var itemsByID: [String: SyncItem] = [:]
    init(locations: [SyncLocation], leftID: String, rightID: String) {
        self.locations = locations; self.leftID = leftID; self.rightID = rightID
    }
    var left: SyncLocation? { locations.first { $0.id == leftID } }
    var right: SyncLocation? { locations.first { $0.id == rightID } }
    var unresolved: Int { selected.filter { itemsByID[$0]?.operation == .conflict && resolutions[$0] == nil }.count }
    var canExecute: Bool { plan != nil && !selected.isEmpty && unresolved == 0 && !busy }
    var deletions: Int { selected.filter { if case .delete = itemsByID[$0]?.operation { return true }; return false }.count }
    var overwrites: Int {
        selected.filter { id in
            guard let item = itemsByID[id] else { return false }
            let direction: SyncDirection?
            if case .copy(let value) = item.operation { direction = value } else { direction = resolutions[id] }
            guard let direction else { return false }
            return direction.destination == .left ? item.left != nil : item.right != nil
        }.count
    }
    var summary: String { "已选 \(selected.count) 项 · 覆盖 \(overwrites) 个文件 · 删除 \(deletions) 项" }
    func invalidate() {
        generation = UUID(); task?.cancel(); task = nil; busy = false
        plan = nil; selected = []; resolutions = [:]; itemsByID = [:]
    }
    func preview() {
        guard let left, let right else { return }
        invalidate(); error = nil; busy = true
        let generation = self.generation
        var options = self.options
        options.excludedPaths = exclusions.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        task = Task {
            do {
                let result = try await SyncEngine.preview(left: left.root, right: right.root, options: options)
                guard generation == self.generation else { return }
                plan = result; itemsByID = Dictionary(uniqueKeysWithValues: result.items.map { ($0.id, $0) })
                selected = Set(result.items.filter(\.selectedByDefault).map(\.id))
            } catch is CancellationError { }
            catch { if generation == self.generation { self.error = error.localizedDescription } }
            if generation == self.generation { busy = false; task = nil }
        }
    }
    func chooseFolder(side: SyncSide) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "选择同步目录"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let location = SyncLocation(id: UUID().uuidString, title: "本地 · \(url.lastPathComponent)", root: .local(url))
        locations.append(location)
        if side == .left { leftID = location.id } else { rightID = location.id }
        invalidate()
    }
    func setDirection(_ direction: SyncDirection?, id: String) {
        resolutions[id] = direction
        setSelected(direction != nil, id: id)
    }
    func setSelected(_ value: Bool, id: String) {
        guard let item = itemsByID[id], item.executable else { return }
        if value {
            selected.insert(id)
            if let side = resolved(item).destination {
                for parent in SyncPathForReview.parents(id) where itemsByID[parent]?.operation == .createDirectory(side) { selected.insert(parent) }
                if case .delete = item.operation {
                    for child in plan?.items ?? [] where child.path.hasPrefix(id + "/") && child.operation == .delete(side) { selected.insert(child.id) }
                }
            }
        } else {
            selected.remove(id)
            if let side = resolved(item).destination {
                if item.operation == .createDirectory(side) {
                    for child in plan?.items ?? [] where child.path.hasPrefix(id + "/") && resolved(child).destination == side { selected.remove(child.id) }
                }
                for parent in SyncPathForReview.parents(id) where itemsByID[parent]?.operation == .delete(side) { selected.remove(parent) }
            }
        }
    }
    func selectAll() {
        selected = Set((plan?.items ?? []).filter { $0.executable && ($0.operation != .conflict || resolutions[$0.id] != nil) }.map(\.id))
    }
    func selectNone() { selected = [] }
    private func resolved(_ item: SyncItem) -> SyncOperation {
        if item.operation == .conflict, let direction = resolutions[item.id] { return .copy(direction) }
        return item.operation
    }
}

private enum SyncPathForReview {
    static func parents(_ path: String) -> [String] {
        let parts = path.split(separator: "/")
        return parts.count > 1 ? (1..<parts.count).map { parts.prefix($0).joined(separator: "/") } : []
    }
}

struct SyncReviewView: View {
    @ObservedObject var workspace: Workspace
    @StateObject private var model: SyncReviewModel
    @State private var confirm = false
    @State private var advanced = false
    @Environment(\.dismiss) private var dismiss
    init(workspace: Workspace, tabs: BrowserTabs) {
        self.workspace = workspace
        var locations: [SyncLocation] = []
        for tab in tabs.tabs {
            let label = URL(fileURLWithPath: tab.workspace.localPath).lastPathComponent
            locations.append(SyncLocation(id: "\(tab.id)/local", title: "本地 · \(label)", root: .local(URL(fileURLWithPath: tab.workspace.localPath))))
            if let client = tab.workspace.client {
                locations.append(SyncLocation(id: "\(tab.id)/remote", title: "\(client.profile.name.isEmpty ? client.profile.host : client.profile.name) · \(tab.workspace.remotePath)",
                                              root: .remote(client, tab.workspace.remotePath)))
            }
        }
        _model = StateObject(wrappedValue: SyncReviewModel(locations: locations, leftID: "\(tabs.selected)/local",
                                                         rightID: workspace.client == nil ? "" : "\(tabs.selected)/remote"))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("同步目录", systemImage: "arrow.triangle.2.circlepath").font(.title2.weight(.semibold))
                Spacer()
                Text("先预览，再执行所选操作").font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 20) {
                location(.left)
                Image(systemName: model.options.mode == .bidirectional ? "arrow.left.arrow.right" : (model.options.mode == .leftToRight ? "arrow.right" : "arrow.left"))
                    .font(.title3).foregroundStyle(.blue)
                location(.right)
            }
            HStack(spacing: 20) {
                Picker("方向", selection: $model.options.mode) {
                    Text("向右").tag(SyncMode.leftToRight)
                    Text("向左").tag(SyncMode.rightToLeft)
                    Text("双向").tag(SyncMode.bidirectional)
                }.pickerStyle(.segmented).frame(width: 260)
                Picker("比较", selection: $model.options.comparison) {
                    Text("修改日期").tag(SyncComparison.modificationDate)
                    Text("文件大小").tag(SyncComparison.fileSize)
                    Text("文件内容").tag(SyncComparison.contents)
                }.frame(width: 240)
                Spacer()
                Toggle("列出镜像删除项", isOn: $model.options.mirror)
                    .disabled(model.options.mode == .bidirectional)
                    .help("列出目标中缺少源文件的项目；删除项仍需手动选中。")
            }
            DisclosureGroup("更多选项", isExpanded: $advanced) {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("包含隐藏文件", isOn: $model.options.includeHidden)
                        if model.options.comparison == .modificationDate {
                            if model.left?.root.isRemote == true { timeOffset(side: .left) }
                            if model.right?.root.isRemote == true { timeOffset(side: .right) }
                        }
                    }.frame(width: 285, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("排除路径").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $model.exclusions).font(.system(.caption, design: .monospaced))
                            .frame(height: 48).overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                        Text("每行一个相对路径或文件名，不使用通配符。").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.top, 8)
            }
            Text(model.options.comparison == .contents
                 ? "内容比较会读取所有文件；远程文件逐个临时下载，完成即清理。"
                 : "日期按分钟精度比较；相同大小或日期不能保证内容相同，可改用文件内容比较。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            preview
            Divider()
            HStack {
                Button("取消") { model.invalidate(); dismiss() }.keyboardShortcut(.cancelAction)
                if let plan = model.plan {
                    Button("全选可执行项") { model.selectAll() }.buttonStyle(.borderless).disabled(plan.items.isEmpty)
                    Button("全不选") { model.selectNone() }.buttonStyle(.borderless).disabled(model.selected.isEmpty)
                }
                Spacer()
                Button(model.busy ? "停止预览" : "生成预览") { if model.busy { model.invalidate() } else { model.preview() } }
                    .buttonStyle(.glass).disabled(model.left == nil || model.right == nil)
                Button("执行所选同步") { confirm = true }.buttonStyle(.glassProminent).disabled(!model.canExecute)
            }
        }.padding(24).frame(width: 980, height: 650)
        .onChange(of: model.leftID) { model.invalidate() }
        .onChange(of: model.rightID) { model.invalidate() }
        .onChange(of: model.options) {
            if model.options.mode == .bidirectional { model.options.mirror = false }
            model.invalidate()
        }
        .onChange(of: model.exclusions) { model.invalidate() }
        .onDisappear { model.invalidate() }
        .alert("无法生成同步预览", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("确定") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .alert("执行所选同步操作？", isPresented: $confirm) {
            Button("取消", role: .cancel) { }
            Button("执行同步", role: model.deletions > 0 ? .destructive : nil) {
                guard let plan = model.plan, let left = model.left, let right = model.right else { return }
                workspace.enqueueSync(plan, left: left.root, right: right.root, selected: model.selected, resolutions: model.resolutions)
                dismiss()
            }
        } message: {
            Text(model.summary + "\n将按预览覆盖所选文件。本地删除移到废纸篓；服务器删除无法撤销。执行过程中出错会停止，已完成的项目会保留。")
        }
    }
    @ViewBuilder private var preview: some View {
        if model.busy {
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("正在比较目录…").font(.headline)
                Text("预览不会修改任一目录。").font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let plan = model.plan {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(model.summary).font(.callout.weight(.medium))
                    Spacer()
                    Text("无差异 \(plan.unchanged) 项 · 需处理 \(plan.items.filter { $0.operation == .blocked || ($0.operation == .conflict && model.resolutions[$0.id] == nil) }.count) 项")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if plan.items.isEmpty {
                    ContentUnavailableView("两侧符合比较规则", systemImage: "checkmark.circle", description: Text("当前没有需要执行的同步操作。"))
                } else {
                    NativeSyncTable(items: plan.items, revision: plan.id, selected: model.selected, resolutions: model.resolutions,
                                    select: model.setSelected, resolve: model.setDirection)
                }
                if model.unresolved > 0 { Text("请为已选的 \(model.unresolved) 项同名差异选择方向。").font(.caption).foregroundStyle(.orange) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("预览目录差异", systemImage: "arrow.triangle.2.circlepath",
                                   description: Text("选择左右目录和比较规则，然后生成预览。可从其他标签页选择远程目录。"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private func location(_ side: SyncSide) -> some View {
        let selection = side == .left ? $model.leftID : $model.rightID
        let value = side == .left ? model.left : model.right
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker(side == .left ? "左侧" : "右侧", selection: selection) {
                    Text("选择目录…").tag("")
                    ForEach(model.locations) { Text($0.title).tag($0.id) }
                }
                Button("选择本地目录", systemImage: "folder") { model.chooseFolder(side: side) }.labelStyle(.iconOnly)
            }
            Text(value?.root.path ?? "可以选择本地目录或已连接的远程目录")
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                .truncationMode(.middle).textSelection(.enabled)
        }.frame(maxWidth: .infinity)
    }
    private func timeOffset(side: SyncSide) -> some View {
        let binding = Binding<Int>(get: { Int((side == .left ? model.options.leftTimeOffset : model.options.rightTimeOffset) / 60) },
                                   set: { value in if side == .left { model.options.leftTimeOffset = Double(value * 60) } else { model.options.rightTimeOffset = Double(value * 60) } })
        return Stepper("\(side == .left ? "左侧" : "右侧")时间校正：\(binding.wrappedValue) 分钟", value: binding, in: -1440...1440)
            .font(.caption)
    }
}
