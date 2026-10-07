import Foundation

/// Incremental across tabs; completed contributions live only until the current batch ends.
public struct DockTransferTracker: Sendable {
    public enum State: Sendable { case active, paused, completed, removed }
    public struct Snapshot: Sendable, Equatable {
        public let activeCount: Int
        public let percent: Int?
        public let paused: Bool
    }
    private struct Contribution: Sendable {
        var state: State
        var weight: Double?
        var completed: Double
        var isActive: Bool { state == .active || state == .paused }
    }
    private var entries: [UUID: Contribution] = [:]
    private var active = 0, paused = 0, unknown = 0
    private var weight = 0.0, completed = 0.0
    public init() {}
    public var snapshot: Snapshot {
        Snapshot(activeCount: active, percent: unknown == 0 && weight > 0
                 ? min(99, max(0, Int((completed / weight * 100).rounded(.down)))) : nil,
                 paused: active > 0 && paused == active)
    }
    public mutating func update(_ id: UUID, state: State, progress: TransferProgress? = nil) {
        let previous = entries[id]
        // Historical completion must not enter a new batch or recreate a removed task.
        if state == .completed && previous == nil { return }
        if let previous { adjust(previous, sign: -1) }
        if state == .removed { entries[id] = nil }
        else {
            var item = previous ?? Contribution(state: state, weight: nil, completed: 0)
            item.state = state
            if let progress {
                if progress.hasKnownTotal {
                    item.weight = progress.total > 0 ? Double(progress.total) : Double(max(1, progress.totalItems ?? 1))
                    item.completed = item.weight! * progress.fraction
                } else { item.weight = nil; item.completed = 0 }
            }
            if state == .completed {
                item.weight = item.weight ?? 1; item.completed = item.weight!
            }
            entries[id] = item; adjust(item, sign: 1)
        }
        if active == 0 {
            entries.removeAll(keepingCapacity: false)
            paused = 0; unknown = 0; weight = 0; completed = 0
        }
    }
    private mutating func adjust(_ item: Contribution, sign: Int) {
        if item.isActive {
            active += sign
            if item.state == .paused { paused += sign }
            if item.weight == nil { unknown += sign }
        }
        weight += Double(sign) * (item.weight ?? 0)
        completed += Double(sign) * item.completed
    }
}
