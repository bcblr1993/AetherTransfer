import AppKit

/// Receive file URLs at the native scroll view, including the empty file area.
@MainActor final class FileBrowserScrollView: NSScrollView {
    weak var workspace: Workspace?
    var remote = false
    var isDropEnabled = true { didSet { if !isDropEnabled { highlight(false) } } }
    private var highlighted = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        return draggingUpdated(sender)
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let accepted = remote && isDropEnabled && workspace?.canReceiveUpload == true
            && sender.draggingSourceOperationMask.contains(.copy) && !fileURLs(sender).isEmpty
        highlight(accepted)
        return accepted ? .copy : []
    }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        draggingUpdated(sender) == .copy
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { highlight(false) }
        guard draggingUpdated(sender) == .copy, let workspace else { return false }
        let urls = fileURLs(sender)
        workspace.focusedRemote = true
        workspace.uploadURLs(urls)
        return true
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { highlight(false) }
    override func draggingEnded(_ sender: any NSDraggingInfo) { highlight(false) }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { highlight(false) }

    private func fileURLs(_ sender: any NSDraggingInfo) -> [URL] {
        let values = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        var seen = Set<URL>()
        return values.filter { $0.isFileURL && seen.insert($0.standardizedFileURL).inserted }
    }
    private func highlight(_ value: Bool) {
        guard highlighted != value else { return }
        highlighted = value
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = value ? 2 : 0
    }
}
