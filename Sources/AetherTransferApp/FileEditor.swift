import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AetherTransferCore

@MainActor final class FileEditorManager {
    private var windows: [String: FileEditorWindow] = [:]
    func open(_ entry: FileEntry, source: FileEditSource) {
        let key: String
        switch source {
        case .local(let url): key = "local|\(url.standardizedFileURL.path)"
        case .remote(let client, let path):
            let p = client.profile
            key = "\(p.protocolKind.rawValue)|\(p.host.lowercased())|\(p.port)|\(p.username)|\(RemotePath.normalize(path))"
        }
        if let existing = windows[key] { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return }
        guard windows.count < 12 else {
            let alert = NSAlert(); alert.messageText = L10n.text("请先关闭部分编辑窗口"); alert.informativeText = L10n.text("最多同时打开 12 个文本文件。"); alert.runModal(); return
        }
        let controller = FileEditorWindow(name: entry.name, source: source) { [weak self] in self?.windows[key] = nil }
        windows[key] = controller; controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    func approveQuit() -> Bool { windows.values.allSatisfy { $0.approveClose() } }
    func shutdown() async {
        let current = Array(windows.values)
        for controller in current { await controller.model.shutdown(); controller.close() }
        windows = [:]
    }
    var hasWindows: Bool { !windows.isEmpty }
}

@MainActor final class TransferAppDelegate: NSObject, NSApplicationDelegate {
    weak var editors: FileEditorManager?
    weak var tabs: BrowserTabs?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if tabs?.tabs.contains(where: { tab in
            tab.workspace.activities.contains { ["等待中", "传输中", "已暂停", "保留中", "清理中"].contains($0.state) }
        }) == true {
            let alert = NSAlert(); alert.messageText = L10n.text("仍有文件操作正在进行")
            alert.informativeText = L10n.text("请先在活动列表保留单个文件的进度，或取消任务，再退出。目录传输和同步目前需要先完成或取消。")
            alert.addButton(withTitle: L10n.text("返回传输"))
            alert.runModal(); return .terminateCancel
        }
        guard editors?.approveQuit() != false else { return .terminateCancel }
        guard editors?.hasWindows == true || tabs?.previews.needsShutdown == true else { return .terminateNow }
        Task {
            await tabs?.previews.shutdown(); await editors?.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@MainActor private final class FileEditorWindow: NSWindowController, NSWindowDelegate {
    let model: FileEditorModel
    private let didClose: () -> Void
    private var closing = false
    init(name: String, source: FileEditSource, didClose: @escaping () -> Void) {
        model = FileEditorModel(name: name, source: source); self.didClose = didClose
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 650),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = name; window.minSize = NSSize(width: 640, height: 440)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self; window.contentViewController = NSHostingController(rootView: FileEditorView(model: model).modifier(AppPresentation()))
        window.center(); model.load()
    }
    required init?(coder: NSCoder) { fatalError("Not supported") }
    func approveClose() -> Bool {
        if closing { return true }
        if model.loading || model.saving {
            let alert = NSAlert(); alert.messageText = L10n.text("文件操作仍在进行")
            alert.informativeText = L10n.text("请完成保存，或取消当前操作后再关闭。")
            alert.addButton(withTitle: L10n.text("返回编辑器")); alert.addButton(withTitle: L10n.text("取消当前操作"))
            if alert.runModal() == .alertSecondButtonReturn { model.cancelOperation() }
            return false
        }
        if model.isDirty || model.external {
            let alert = NSAlert(); alert.messageText = L10n.format("结束“%@”的编辑？", String(describing: model.name))
            alert.informativeText = model.external ? L10n.text("结束后外部编辑器的保存不会再回传；此会话的本机草稿将清理。可先导出草稿。") : L10n.text("仍有未保存的更改。可先导出草稿，或放弃更改。")
            alert.addButton(withTitle: L10n.text("继续编辑")); alert.addButton(withTitle: L10n.text("导出草稿…")); alert.addButton(withTitle: L10n.text("结束并放弃草稿"))
            switch alert.runModal() {
            case .alertSecondButtonReturn: model.exportDraft(); return false
            case .alertThirdButtonReturn: return true
            default: return false
            }
        }
        return true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { approveClose() }
    func windowWillClose(_ notification: Notification) {
        closing = true
        // Keep the manager's reference until cleanup finishes, including an immediate App quit.
        Task { await model.shutdown(); didClose() }
    }
}

@MainActor private final class FileEditorModel: ObservableObject {
    let name: String
    let source: FileEditSource
    @Published var text = ""
    @Published var loading = true
    @Published var saving = false
    @Published var external = false
    @Published var notice = L10n.text("正在读取文件…")
    @Published var error: String?
    @Published private var savedText = ""
    @Published private var externalDirty = false
    private var session: FileEditSession?
    private var operation: Task<Void, Never>?
    private var draftTask: Task<Void, Never>?
    private var watcher: FileEditWatcher?
    private var closed = false
    private var pendingExternal = false
    private var automaticBlocked = false
    private var shutdownTask: Task<Void, Never>?
    var isDirty: Bool { text != savedText || externalDirty }
    var ready: Bool { session != nil && !loading && !saving && !closed }
    var location: String {
        switch source {
        case .local(let url): L10n.format("本地 · %@", String(describing: url.path))
        case .remote(let client, let path): "\(client.profile.protocolKind.title) · \(path)"
        }
    }
    init(name: String, source: FileEditSource) { self.name = name; self.source = source }
    func load() {
        guard !closed, session == nil, !saving else { return }
        loading = true; error = nil; notice = L10n.text("正在读取文件…")
        operation = Task {
            do {
                let opened = try await FileEditSession.open(source)
                do {
                    let snapshot = try await opened.snapshot()
                    try Task.checkCancellation()
                    guard !closed else { throw CancellationError() }
                    // Publish a ready session only after its initial text is available.
                    session = opened
                    text = snapshot.text; savedText = snapshot.text; notice = L10n.format("已载入 · UTF-8%@", String(describing: snapshot.hasUTF8BOM ? " BOM" : ""))
                } catch {
                    // Closing on the cancelled reader would also cancel its cleanup worker.
                    await Task.detached { try? await opened.close() }.value
                    throw error
                }
            } catch is CancellationError { notice = L10n.text("读取已取消") }
            catch { self.error = error.localizedDescription; notice = L10n.text("无法打开文件") }
            loading = false
        }
    }
    func changeText(_ value: String) {
        guard !external && ready else { return }
        text = value
        draftTask?.cancel()
        guard let session else { return }
        draftTask = Task {
            do { try await Task.sleep(for: .milliseconds(400)); try await session.persistDraft(value) }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
    func save() {
        guard ready, let session else { return }
        let pendingDraft = draftTask
        pendingDraft?.cancel(); saving = true; error = nil; notice = L10n.text("正在核对并保存…")
        let contents = external ? nil : text
        operation = Task {
            await pendingDraft?.value
            do {
                let snapshot = try await session.save(text: contents)
                text = snapshot.text; savedText = snapshot.text; externalDirty = false; automaticBlocked = false
                notice = external ? L10n.text("已回传 · 外部保存后继续自动回传") : L10n.text("已保存")
            } catch is CancellationError { notice = external ? L10n.text("自动回传已暂停 · 草稿保留") : L10n.text("保存已取消 · 草稿保留"); automaticBlocked = external }
            catch { self.error = error.localizedDescription; notice = external ? L10n.text("自动回传已暂停 · 草稿保留") : L10n.text("保存未完成 · 草稿保留"); automaticBlocked = external }
            saving = false
            NotificationCenter.default.post(name: .init("AetherTransferEditedFile"), object: nil)
            if pendingExternal { pendingExternal = false; externalChanged() }
        }
    }
    func reload() {
        guard ready, !external, let session else { return }
        if isDirty {
            let alert = NSAlert(); alert.messageText = L10n.text("重新载入原文件？"); alert.informativeText = L10n.text("将放弃此窗口未保存的更改。可以先导出草稿。")
            alert.addButton(withTitle: L10n.text("取消")); alert.addButton(withTitle: L10n.text("重新载入"))
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        let pendingDraft = draftTask
        pendingDraft?.cancel(); loading = true; error = nil
        operation = Task {
            await pendingDraft?.value
            do {
                let snapshot = try await session.reload(); text = snapshot.text; savedText = snapshot.text
                externalDirty = false; automaticBlocked = false; notice = L10n.text("已重新载入")
            } catch { self.error = error.localizedDescription }
            loading = false
        }
    }
    func openExternal() {
        guard ready, !external, let session else { return }
        let panel = NSOpenPanel(); panel.title = L10n.text("选择外部编辑器")
        panel.allowedContentTypes = [.applicationBundle]; panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let appURL = panel.url else { return }
        let pendingDraft = draftTask
        pendingDraft?.cancel(); saving = true; error = nil
        let contents = text
        operation = Task { [self] in
            await pendingDraft?.value
            do {
                try await session.persistDraft(contents)
                let url = session.draftURL
                watcher = try await Task.detached { [weak self] in
                    try FileEditWatcher(file: url) { [weak self] in Task { @MainActor in self?.externalChanged() } }
                }.value
                external = true
                _ = try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
                notice = L10n.text("外部编辑器保存后自动回传")
            } catch { watcher?.stop(); watcher = nil; external = false; self.error = error.localizedDescription }
            saving = false
            if pendingExternal { pendingExternal = false; externalChanged() }
        }
    }
    private func externalChanged() {
        guard external, !closed else { return }
        externalDirty = true
        if saving { pendingExternal = true; return }
        draftTask?.cancel()
        draftTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(450)); try Task.checkCancellation()
                guard external, let session, !closed else { return }
                let snapshot = try await session.snapshot(); text = snapshot.text
                if !automaticBlocked { save() }
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription; automaticBlocked = true; notice = L10n.text("自动回传暂停 · 草稿保留") }
        }
    }
    func stopExternal() {
        guard ready else { return }
        watcher?.stop(); watcher = nil; draftTask?.cancel(); external = false; pendingExternal = false
        notice = L10n.text("自动回传已停止")
        guard let session else { return }
        loading = true
        operation = Task {
            do { text = try await session.snapshot().text }
            catch { self.error = error.localizedDescription }
            loading = false
        }
    }
    func exportDraft() {
        guard ready, let session else { return }
        let panel = NSSavePanel(); panel.title = L10n.text("导出本机草稿"); panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let contents = external ? nil : text
        saving = true; error = nil
        operation = Task {
            do { try await session.exportDraft(to: destination, text: contents); notice = L10n.text("草稿已导出") }
            catch { self.error = error.localizedDescription }
            saving = false
        }
    }
    func revealDraft() { if let session { NSWorkspace.shared.activateFileViewerSelecting([session.draftURL]) } }
    func cancelOperation() { operation?.cancel() }
    func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        closed = true; watcher?.stop(); watcher = nil; draftTask?.cancel(); operation?.cancel()
        let pendingDraft = draftTask, pendingOperation = operation
        let task = Task {
            await pendingDraft?.value; await pendingOperation?.value
            try? await session?.close(); session = nil
        }
        shutdownTask = task
        await task.value
    }
}

private struct FileEditorView: View {
    @Environment(\.locale) private var interfaceLocale
    @ObservedObject var model: FileEditorModel
    @AppStorage("appearance") private var appearance = "system"
    var body: some View {
        let _ = interfaceLocale
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label(model.name, systemImage: "doc.text").font(.headline).lineLimit(1)
                if model.isDirty { Circle().fill(.orange).frame(width: 6, height: 6).accessibilityLabel(L10n.text("有未保存更改")) }
                Spacer()
                if model.external {
                    Button(L10n.text("停止自动回传"), systemImage: "stop.circle") { model.stopExternal() }.disabled(!model.ready)
                } else {
                    Button(L10n.text("外部编辑器…"), systemImage: "square.and.pencil") { model.openExternal() }.disabled(!model.ready)
                }
                Menu {
                    Button(L10n.text("重新载入")) { model.reload() }.disabled(!model.ready || model.external)
                    Button(L10n.text("导出草稿…")) { model.exportDraft() }.disabled(!model.ready)
                    Button(L10n.text("在 Finder 中显示草稿")) { model.revealDraft() }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 22)
                    .accessibilityLabel(L10n.text("编辑选项"))
                Button(model.external ? L10n.text("回传") : L10n.text("保存"), systemImage: "arrow.up.doc") { model.save() }
                    .buttonStyle(.glassProminent).keyboardShortcut("s").disabled(!model.ready || !model.isDirty)
            }.padding(.horizontal, 18).padding(.vertical, 12)
            Text(model.location).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18).padding(.bottom, 12)
            Divider()
            NativeTextEditor(text: Binding(get: { model.text }, set: { model.changeText($0) }), editable: model.ready && !model.external)
                .overlay { if model.loading { ProgressView(L10n.text("正在读取文本…")).padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            if let error = model.error {
                Divider()
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
            Divider()
            HStack(spacing: 10) {
                if model.saving { ProgressView().controlSize(.small) }
                Text(model.notice).lineLimit(1)
                if model.saving || model.loading { Button(L10n.text("取消")) { model.cancelOperation() }.buttonStyle(.borderless) }
                else if !model.ready { Button(L10n.text("重新读取")) { model.load() }.buttonStyle(.borderless) }
                Spacer(); Text(L10n.text("UTF-8 · 5 MiB 上限"))
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).frame(height: 36)
        }
        .preferredColorScheme(appearance == "dark" ? .dark : (appearance == "light" ? .light : nil))
    }
}

private struct NativeTextEditor: NSViewRepresentable {
    @Binding var text: String
    let editable: Bool
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let view = NSTextView(usingTextLayoutManager: true)
        view.isRichText = false; view.isEditable = editable; view.isSelectable = true; view.allowsUndo = true
        view.usesFindBar = true; view.isIncrementalSearchingEnabled = true
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.textColor = .textColor; view.backgroundColor = .textBackgroundColor
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false; view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false; view.isGrammarCheckingEnabled = false
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        view.textContainerInset = NSSize(width: 16, height: 14); view.string = text
        view.setAccessibilityLabel(L10n.text("文本内容")); view.delegate = context.coordinator
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        view.isEditable = editable
        if view.string != text {
            let selection = view.selectedRange()
            view.string = text; view.undoManager?.removeAllActions()
            view.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
        }
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeTextEditor
        init(_ parent: NativeTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView, parent.editable else { return }
            parent.text = view.string
        }
    }
}
