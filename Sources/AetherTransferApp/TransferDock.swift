import AppKit
import AetherTransferCore

@MainActor final class TransferDock {
    private var tracker = DockTransferTracker()
    private var displayed: DockTransferTracker.Snapshot?
    private let content = TransferDockView()
    func receive(_ item: ActivityItem) {
        let state: DockTransferTracker.State = switch item.state {
        case "已暂停": .paused
        case "等待中", "传输中", "保留中", "清理中": .active
        case "完成": .completed
        default: .removed
        }
        let progress = TransferProgress(completed: item.bytes, total: item.hasKnownTotal ? item.total : 0,
                                        scope: item.scope, completedItems: item.completedItems,
                                        totalItems: item.hasKnownTotal ? item.totalItems : nil, skippedItems: item.skippedItems)
        tracker.update(item.id, state: state, progress: progress)
        let value = tracker.snapshot
        guard value != displayed else { return }
        displayed = value
        let tile = NSApp.dockTile
        if value.activeCount == 0 { tile.contentView = nil; tile.badgeLabel = nil }
        else {
            content.frame = NSRect(origin: .zero, size: tile.size)
            content.value = value; content.icon = NSApp.applicationIconImage
            tile.contentView = content
            tile.badgeLabel = value.activeCount > 99 ? "99+" : String(value.activeCount)
        }
        tile.display()
    }
}

@MainActor private final class TransferDockView: NSView {
    var value: DockTransferTracker.Snapshot?
    var icon: NSImage?
    override func draw(_ dirtyRect: NSRect) {
        icon?.draw(in: bounds)
        guard let value else { return }
        let track = NSRect(x: bounds.width * 0.15, y: bounds.height * 0.10,
                           width: bounds.width * 0.70, height: max(5, bounds.height * 0.075))
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2).fill()
        // Unknown totals keep a quiet track. No timer, spinner or fabricated percentage.
        if let percent = value.percent, percent > 0 {
            var fill = track.insetBy(dx: 1, dy: 1)
            fill.size.width *= Double(percent) / 100
            (value.paused ? NSColor.systemOrange : NSColor.controlAccentColor).setFill()
            NSBezierPath(roundedRect: fill, xRadius: fill.height / 2, yRadius: fill.height / 2).fill()
        }
    }
}
