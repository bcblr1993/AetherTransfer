import AppKit
import SwiftUI
import UniformTypeIdentifiers
import AetherTransferCore

/// AppKit recycles visible items; file contents and remote thumbnails are not loaded.
struct NativeFileIcons: NSViewRepresentable {
    let files: [FileEntry]
    let revision: UUID
    @Binding var selection: Set<String>
    let remote: Bool
    let workspace: Workspace

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = FileBrowserScrollView()
        scroll.workspace = workspace; scroll.remote = remote
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        let grid = BrowserIconGrid()
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 112, height: 112)
        layout.minimumInteritemSpacing = 8; layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        grid.collectionViewLayout = layout
        grid.autoresizingMask = [.width]
        grid.backgroundColors = [.clear]; grid.isSelectable = true
        grid.allowsMultipleSelection = true; grid.allowsEmptySelection = true
        grid.register(FileIconItem.self, forItemWithIdentifier: FileIconItem.identifier)
        grid.delegate = context.coordinator; grid.dataSource = context.coordinator
        grid.setDraggingSourceOperationMask(.copy, forLocal: false)
        grid.setDraggingSourceOperationMask(.copy, forLocal: true)
        grid.menuProvider = { [weak coordinator = context.coordinator] event in coordinator?.menu(event) }
        grid.openSelected = { [weak coordinator = context.coordinator] in coordinator?.openSelection() }
        grid.openClicked = { [weak coordinator = context.coordinator] index in coordinator?.open(index) }
        grid.previewSelected = { [weak coordinator = context.coordinator] in
            guard let coordinator else { return }
            coordinator.parent.workspace.previewSelection(remote: coordinator.parent.remote)
        }
        grid.focused = { [weak coordinator = context.coordinator] in
            guard let coordinator else { return }
            if coordinator.parent.workspace.focusedRemote != coordinator.parent.remote {
                coordinator.parent.workspace.focusedRemote = coordinator.parent.remote
            }
        }
        grid.initialFocusRequested = { [weak coordinator = context.coordinator] in
            guard let coordinator else { return false }
            return coordinator.parent.workspace.focusedRemote == coordinator.parent.remote
        }
        scroll.documentView = grid; context.coordinator.grid = grid
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator; coordinator.parent = self
        if let drop = scroll as? FileBrowserScrollView {
            drop.workspace = workspace; drop.remote = remote; drop.isDropEnabled = context.environment.isEnabled
        }
        guard let grid = coordinator.grid else { return }
        grid.isEnabled = context.environment.isEnabled
        grid.setAccessibilityEnabled(grid.isEnabled)
        coordinator.updating = true; defer { coordinator.updating = false }
        let languageChanged = coordinator.locale != context.environment.locale
        if languageChanged { coordinator.locale = context.environment.locale; coordinator.bytes.locale = context.environment.locale }
        if coordinator.revision != revision {
            coordinator.files = files; coordinator.revision = revision
            coordinator.indexByID = files.enumerated().reduce(into: [:]) { $0[$1.element.id] = $1.offset }
            grid.reloadData()
        } else if languageChanged {
            grid.reloadItems(at: Set(grid.indexPathsForVisibleItems()))
        }
        let indexes = Set(selection.compactMap { coordinator.indexByID[$0].map { IndexPath(item: $0, section: 0) } })
        if grid.selectionIndexPaths != indexes { grid.selectionIndexPaths = indexes }
        grid.focusIfNeeded()
    }

    @MainActor final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        var parent: NativeFileIcons
        weak var grid: BrowserIconGrid?
        var files: [FileEntry] = []
        var indexByID: [String: Int] = [:]
        var revision: UUID?
        var updating = false
        private let actions = FileBrowserActions()
        var locale: Locale?
        var bytes = ByteCountFormatStyle(style: .file, spellsOutZero: false)
        init(_ parent: NativeFileIcons) { self.parent = parent }
        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { files.count }
        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: FileIconItem.identifier, for: indexPath) as! FileIconItem
            let entry = files[indexPath.item]
            item.configure(entry, detail: entry.isDirectory ? L10n.text("文件夹") : bytes.format(entry.size))
            item.select = { [weak self, weak collectionView] in
                guard let self, let collectionView, self.grid?.isEnabled == true else { return false }
                collectionView.selectionIndexPaths = [indexPath]; self.changedSelection()
                collectionView.window?.makeFirstResponder(collectionView)
                return true
            }
            return item
        }
        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { changedSelection() }
        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { changedSelection() }
        private func changedSelection() {
            guard !updating, let grid else { return }
            parent.selection = Set(grid.selectionIndexPaths.compactMap { files.indices.contains($0.item) ? files[$0.item].id : nil })
            parent.workspace.focusedRemote = parent.remote
        }
        func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
            guard grid?.isEnabled == true, !parent.remote, files.indices.contains(indexPath.item) else { return nil }
            return URL(fileURLWithPath: files[indexPath.item].path) as NSURL
        }
        func openSelection() {
            guard let grid, grid.isEnabled, let index = grid.selectionIndexPaths.map(\.item).min(), files.indices.contains(index) else { return }
            open(IndexPath(item: index, section: 0))
        }
        func open(_ index: IndexPath) {
            guard grid?.isEnabled == true, files.indices.contains(index.item) else { return }
            parent.workspace.open(files[index.item], remote: parent.remote)
        }
        func menu(_ event: NSEvent) -> NSMenu? {
            guard let grid, grid.isEnabled,
                  let index = grid.indexPathForItem(at: grid.convert(event.locationInWindow, from: nil)), files.indices.contains(index.item) else { return nil }
            if !grid.selectionIndexPaths.contains(index) { grid.selectionIndexPaths = [index]; changedSelection() }
            parent.workspace.focusedRemote = parent.remote
            return actions.menu(for: files[index.item], selection: files.filter { parent.selection.contains($0.id) },
                                remote: parent.remote, workspace: parent.workspace)
        }
    }
}

@MainActor private final class FileIconItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("AetherTransferFileIcon")
    private static let icons: NSCache<NSString, NSImage> = { let cache = NSCache<NSString, NSImage>(); cache.countLimit = 128; return cache }()
    private let detail = NSTextField(labelWithString: "")
    var select: (() -> Bool)? { didSet { (view as? FileIconCell)?.select = select } }
    override func loadView() {
        let cell = FileIconCell(); view = cell
        let image = NSImageView(); image.imageScaling = .scaleProportionallyUpOrDown
        let name = NSTextField(labelWithString: "")
        name.alignment = .center; name.font = .systemFont(ofSize: 12)
        name.usesSingleLineMode = false; name.cell?.wraps = true; name.cell?.isScrollable = false
        name.maximumNumberOfLines = 2; name.lineBreakMode = .byWordWrapping
        detail.alignment = .center; detail.font = .systemFont(ofSize: 10); detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        for child in [image, name, detail] { child.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(child) }
        imageView = image; textField = name
        NSLayoutConstraint.activate([
            image.topAnchor.constraint(equalTo: cell.topAnchor, constant: 6), image.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
            image.widthAnchor.constraint(equalToConstant: 44), image.heightAnchor.constraint(equalToConstant: 44),
            name.topAnchor.constraint(equalTo: image.bottomAnchor, constant: 6), name.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            name.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4), name.heightAnchor.constraint(equalToConstant: 30),
            detail.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 3), detail.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: name.trailingAnchor)
        ])
    }
    override var isSelected: Bool { didSet { (view as? FileIconCell)?.selected = isSelected } }
    override func prepareForReuse() { super.prepareForReuse(); select = nil; textField?.stringValue = ""; detail.stringValue = ""; imageView?.image = nil }
    func configure(_ entry: FileEntry, detail: String) {
        textField?.stringValue = entry.name; self.detail.stringValue = detail
        let type = entry.isDirectory ? UTType.folder : (UTType(filenameExtension: URL(fileURLWithPath: entry.name).pathExtension) ?? .data)
        let key = type.identifier as NSString
        let image = Self.icons.object(forKey: key) ?? NSWorkspace.shared.icon(for: type)
        Self.icons.setObject(image, forKey: key); imageView?.image = image
        imageView?.setAccessibilityElement(false)
        view.toolTip = entry.name; view.setAccessibilityLabel(entry.name)
        view.setAccessibilityElement(true); view.setAccessibilityRole(.cell); view.setAccessibilityValue(detail)
        (view as? FileIconCell)?.selected = isSelected
    }
}

@MainActor private final class FileIconCell: NSView {
    var select: (() -> Bool)?
    var selected = false { didSet { setAccessibilitySelected(selected); if selected != oldValue { needsDisplay = true } } }
    override func accessibilityPerformPress() -> Bool { select?() ?? false }
    override func draw(_ dirtyRect: NSRect) {
        if selected {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9).fill()
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

@MainActor final class BrowserIconGrid: NSCollectionView {
    var isEnabled = true
    var menuProvider: ((NSEvent) -> NSMenu?)?
    var openSelected: (() -> Void)?
    var openClicked: ((IndexPath) -> Void)?
    var previewSelected: (() -> Void)?
    var focused: (() -> Void)?
    var initialFocusRequested: (() -> Bool)?
    private var initialFocusPending = true
    func focusIfNeeded() {
        guard initialFocusPending, isEnabled, initialFocusRequested?() == true else { return }
        if BrowserInitialFocus.request(self) { initialFocusPending = false }
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); focusIfNeeded() }
    override func becomeFirstResponder() -> Bool {
        guard isEnabled else { return false }
        let result = super.becomeFirstResponder()
        if result { initialFocusPending = false; focused?() }; return result
    }
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?(event) }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let clicked = indexPathForItem(at: convert(event.locationInWindow, from: nil))
        super.mouseDown(with: event)
        if event.clickCount == 2, let clicked { openClicked?(clicked) }
    }
    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return }
        if event.keyCode == 36 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty { openSelected?() }
        else if event.keyCode == 49 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty { previewSelected?() }
        else { super.keyDown(with: event) }
    }
}
