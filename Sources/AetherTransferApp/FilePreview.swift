import AppKit
import SwiftUI
import QuickLookUI
import AetherTransferCore

@MainActor final class FilePreviewManager {
    private var controller: FilePreviewWindow?
    private var pending: (FileEntry, FilePreviewSource)?
    private var quitting = false
    private var reclamation: Task<Void, Never>?
    init() {
        reclamation = Task { [weak self] in
            guard let self else { return }
            defer { reclamation = nil }
            do {
                let report = try await FilePreview.reclaimAbandoned()
                if report.failed > 0 || report.reachedLimit {
                    reportCacheFailure(L10n.format("%@ 个已确认归属的缓存未能清理。%@", String(describing: report.failed), String(describing: report.reachedLimit ? L10n.text("本轮扫描已到上限，余下项目将在下次启动重试。") : L10n.text("下次启动将再次尝试。"))))
                }
            } catch is CancellationError { }
            catch { reportCacheFailure(error.localizedDescription) }
        }
    }
    private func reportCacheFailure(_ message: String) {
        guard !quitting else { return }
        let alert = NSAlert(); alert.messageText = L10n.text("临时预览清理未完成")
        alert.informativeText = message; alert.addButton(withTitle: L10n.text("确定")); alert.runModal()
    }
    var needsShutdown: Bool { controller != nil || reclamation != nil }
    func open(_ entry: FileEntry, source: FilePreviewSource) {
        guard !entry.isDirectory, !entry.isSymbolicLink else { return }
        guard !quitting else { return }
        if controller?.closing == true { pending = (entry, source); return }
        if controller == nil {
            controller = FilePreviewWindow { [weak self] in
                guard let self else { return }
                self.controller = nil
                if let pending = self.pending { self.pending = nil; self.open(pending.0, source: pending.1) }
            }
        }
        controller?.load(entry, source: source)
        controller?.showWindow(nil); controller?.window?.makeKeyAndOrderFront(nil)
    }
    func shutdown() async {
        quitting = true; pending = nil
        reclamation?.cancel(); await reclamation?.value
        guard let current = controller else { return }
        current.window?.contentViewController = nil // Release the Quick Look renderer before removing its file.
        await current.model.shutdown(); current.reportCleanupFailure(); current.close(); controller = nil
    }
}

@MainActor private final class FilePreviewWindow: NSWindowController, NSWindowDelegate {
    let model = FilePreviewModel()
    private(set) var closing = false
    private var cleanupFailureReported = false
    private let didClose: () -> Void
    init(didClose: @escaping () -> Void) {
        self.didClose = didClose
        let window = FilePreviewNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.text("快速查看"); window.minSize = NSSize(width: 500, height: 380)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self; window.center()
        window.contentViewController = NSHostingController(rootView: FilePreviewView(model: model,
            refreshTitle: { [weak self] in self?.refreshTitle() }).modifier(AppPresentation()))
    }
    required init?(coder: NSCoder) { fatalError("Not supported") }
    func load(_ entry: FileEntry, source: FilePreviewSource) {
        model.load(entry, source: source); refreshTitle()
    }
    private func refreshTitle() {
        window?.title = model.name.isEmpty ? L10n.text("快速查看") : L10n.format("快速查看 · %@", model.name)
    }
    func windowWillClose(_ notification: Notification) {
        closing = true
        window?.contentViewController = nil
        Task { await model.shutdown(); reportCleanupFailure(); didClose() }
    }
    func reportCleanupFailure() {
        guard !cleanupFailureReported, let message = model.cleanupError else { return }
        cleanupFailureReported = true
        let alert = NSAlert(); alert.messageText = L10n.text("临时预览清理未完成")
        alert.informativeText = message; alert.addButton(withTitle: L10n.text("确定")); alert.runModal()
    }
}

@MainActor private final class FilePreviewModel: ObservableObject {
    @Published var name = ""
    @Published var url: URL?
    @Published var loading = false
    @Published var progress: TransferProgress?
    @Published var error: String?
    @Published var notice = ""
    private(set) var cleanupError: String?
    private var preview: FilePreview?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var closed = false
    private var source: FilePreviewSource?
    private var entry: FileEntry?
    private var shutdownTask: Task<Void, Never>?
    func load(_ entry: FileEntry, source: FilePreviewSource) {
        guard !closed else { return }
        let previous = operation, token = UUID()
        previous?.cancel(); generation = token
        self.entry = entry; self.source = source
        name = entry.name; url = nil; progress = nil; error = nil; loading = true; notice = L10n.text("正在准备预览…")
        operation = Task { [self] in
            await previous?.value
            var unpublished: FilePreview?
            do {
                try Task.checkCancellation()
                if let preview { try await preview.close(); self.preview = nil }
                let result = try await FilePreview.open(source) { [weak self] value in
                    Task { @MainActor in
                        guard let self, token == self.generation, self.loading else { return }
                        self.progress = value
                    }
                }
                unpublished = result
                try Task.checkCancellation()
                guard token == generation, !closed else { throw CancellationError() }
                preview = result; unpublished = nil; url = result.url
                notice = "\(DisplayFormat.bytes(result.byteCount)) · Quick Look"
            } catch is CancellationError {
                if token == generation { notice = L10n.text("预览已取消") }
            } catch {
                if token == generation { self.error = error.localizedDescription; notice = L10n.text("预览未完成") }
            }
            if let unpublished {
                do { try await unpublished.close() }
                catch { if token == generation { self.error = L10n.format("临时预览清理失败：%@", String(describing: error.localizedDescription)) } }
            }
            if token == generation { loading = false; progress = nil }
        }
    }
    func cancel() { operation?.cancel() }
    func retry() { if let entry, let source { load(entry, source: source) } }
    func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        closed = true; generation = UUID(); url = nil
        operation?.cancel()
        let previous = operation
        let task = Task {
            await previous?.value; operation = nil
            if let preview {
                do { try await preview.close(); self.preview = nil }
                catch { cleanupError = "\(error.localizedDescription)\n\(preview.directory?.path ?? "")" }
            }
        }
        shutdownTask = task; await task.value
    }
}

private struct FilePreviewView: View {
    @Environment(\.locale) private var interfaceLocale
    @ObservedObject var model: FilePreviewModel
    let refreshTitle: @MainActor () -> Void
    var body: some View {
        let _ = interfaceLocale
        VStack(spacing: 0) {
            if let url = model.url { NativeQuickLook(url: url).id(url) }
            else {
                VStack(spacing: 14) {
                    Image(systemName: "doc.viewfinder").font(.system(size: 38)).foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(model.name).font(.headline).lineLimit(2).truncationMode(.middle).help(model.name)
                    if model.loading {
                        if let progress = model.progress, progress.hasKnownTotal {
                            ProgressView(value: progress.fraction).frame(width: 230)
                        } else { ProgressView().controlSize(.small) }
                        Text(model.progress?.phase ?? L10n.text("正在读取文件…")).font(.callout).foregroundStyle(.secondary)
                        Button(L10n.text("取消预览")) { model.cancel() }
                    } else {
                        if let error = model.error {
                            InterfaceMessage(text: error).frame(maxWidth: 420)
                        } else {
                            SupportingText(model.notice).multilineTextAlignment(.center).frame(maxWidth: 420)
                        }
                        Button(L10n.text("重新读取")) { model.retry() }.buttonStyle(.glassProminent)
                    }
                }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            InterfaceStatusBar { Text(model.notice).lineLimit(1).help(model.notice); Spacer(); Text(L10n.text("快速查看")) }
        }
        .onChange(of: interfaceLocale) { refreshTitle() }
        .onExitCommand { NSApp.keyWindow?.performClose(nil) }
    }
}

private final class QuickLookItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    init(_ url: URL) { previewItemURL = url }
}
@MainActor private final class FilePreviewNativeWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            performClose(nil); return
        }
        super.sendEvent(event)
    }
}
private struct NativeQuickLook: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        // SwiftUI dismantling owns closure; automatic window closure would
        // deactivate the same Quick Look view twice during hosting teardown.
        view.autostarts = false; view.shouldCloseWithWindow = false
        view.previewItem = QuickLookItem(url)
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) { }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}
