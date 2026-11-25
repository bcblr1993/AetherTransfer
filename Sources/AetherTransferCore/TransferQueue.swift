import Foundation

public enum TransferDirection: String, Codable, Sendable {
    case upload = "上传"
    case download = "下载"

    public var localizedTitle: String {
        switch self {
        case .upload: return L10n.tr("上传", "Upload")
        case .download: return L10n.tr("下载", "Download")
        }
    }
}

public enum TransferState: String, Codable, Sendable {
    case queued = "等待中"
    case inProgress = "传输中"
    case completed = "完成"
    case failed = "失败"
    case cancelled = "已取消"

    public var localizedTitle: String {
        switch self {
        case .queued: return L10n.tr("等待中", "Queued")
        case .inProgress: return L10n.tr("传输中", "Transferring")
        case .completed: return L10n.tr("完成", "Completed")
        case .failed: return L10n.tr("失败", "Failed")
        case .cancelled: return L10n.tr("已取消", "Cancelled")
        }
    }
}

public enum TransferFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case active
    case completed
    case failed
    case cancelled

    public var id: String { rawValue }

    public var localizedTitle: String {
        switch self {
        case .all: return L10n.tr("全部", "All")
        case .active: return L10n.tr("进行中", "Active")
        case .completed: return L10n.tr("已完成", "Completed")
        case .failed: return L10n.tr("失败", "Failed")
        case .cancelled: return L10n.tr("已取消", "Cancelled")
        }
    }
}

public struct TransferTaskItem: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let direction: TransferDirection
    public var state: TransferState
    public var progress: Double
    public var completedBytes: Int64
    public var totalBytes: Int64
    public var speedBytesPerSec: Double
    public var etaSeconds: Double?
    public var copyURLOnComplete: Bool
    public var remoteURLString: String?
    public var error: String?
    public let createdDate: Date

    public init(id: UUID = UUID(), name: String, direction: TransferDirection, state: TransferState = .queued,
                progress: Double = 0, completedBytes: Int64 = 0, totalBytes: Int64 = 0,
                speedBytesPerSec: Double = 0, error: String? = nil, createdDate: Date = Date(),
                etaSeconds: Double? = nil, copyURLOnComplete: Bool = false, remoteURLString: String? = nil) {
        self.id = id
        self.name = name
        self.direction = direction
        self.state = state
        self.progress = progress
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.speedBytesPerSec = speedBytesPerSec
        self.etaSeconds = etaSeconds
        self.copyURLOnComplete = copyURLOnComplete
        self.remoteURLString = remoteURLString
        self.error = error
        self.createdDate = createdDate
    }
}

public typealias TransferOperation = @Sendable (@escaping @Sendable (TransferProgress) -> Void) async throws -> Void
/// 任务第一次进入终态（完成、失败、取消）时调用一次；之后的重试不再回调。
public typealias TransferFinishHandler = @Sendable (TransferState, String?) -> Void

public final class TransferQueueManager: @unchecked Sendable {
    private var maxConcurrent: Int
    private let lock = NSLock()
    private var taskItems: [TransferTaskItem] = []
    private var queuedOrder: [UUID] = []
    private var operations: [UUID: TransferOperation] = [:]
    private var finishHandlers: [UUID: TransferFinishHandler] = [:]
    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    private var speedTrackers: [UUID: (lastTime: Date, lastBytes: Int64)] = [:]
    private var speedLimit: Int64?
    private var paused: Bool = false
    public var onQueueUpdated: (@Sendable () -> Void)?

    public init(maxConcurrentTransfers: Int = 3, speedLimitBytesPerSec: Int64? = nil) {
        self.maxConcurrent = min(10, max(1, maxConcurrentTransfers))
        self.speedLimit = speedLimitBytesPerSec
    }

    public var maxConcurrentTransfers: Int {
        lock.lock()
        defer { lock.unlock() }
        return maxConcurrent
    }

    public func setMaxConcurrentTransfers(_ count: Int) {
        lock.lock()
        maxConcurrent = min(10, max(1, count))
        lock.unlock()
        notify()
        processNext()
    }

    public var isPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return paused
    }

    public func pause() {
        lock.lock()
        paused = true
        lock.unlock()
        notify()
    }

    public func resume() {
        lock.lock()
        paused = false
        lock.unlock()
        notify()
        processNext()
    }

    public var speedLimitBytesPerSec: Int64? {
        lock.lock()
        defer { lock.unlock() }
        return speedLimit
    }

    public func setSpeedLimit(_ limit: Int64?) {
        lock.lock()
        self.speedLimit = limit
        lock.unlock()
        notify()
    }

    public var items: [TransferTaskItem] {
        lock.lock()
        defer { lock.unlock() }
        return taskItems
    }

    public var activeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return taskItems.filter { $0.state == .inProgress || $0.state == .queued }.count
    }

    public var totalSpeed: Double {
        lock.lock()
        defer { lock.unlock() }
        return taskItems.filter { $0.state == .inProgress }.reduce(0.0) { $0 + $1.speedBytesPerSec }
    }

    public func filteredItems(_ filter: TransferFilter) -> [TransferTaskItem] {
        lock.lock()
        let snapshot = taskItems
        lock.unlock()
        switch filter {
        case .all:
            return snapshot
        case .active:
            return snapshot.filter { $0.state == .queued || $0.state == .inProgress }
        case .completed:
            return snapshot.filter { $0.state == .completed }
        case .failed:
            return snapshot.filter { $0.state == .failed }
        case .cancelled:
            return snapshot.filter { $0.state == .cancelled }
        }
    }

    @discardableResult
    public func enqueue(name: String, direction: TransferDirection,
                        copyURLOnComplete: Bool = false, remoteURLString: String? = nil,
                        operation: @escaping TransferOperation,
                        onFinish: TransferFinishHandler? = nil) -> UUID {
        let id = UUID()
        let item = TransferTaskItem(
            id: id,
            name: name,
            direction: direction,
            state: .queued,
            copyURLOnComplete: copyURLOnComplete,
            remoteURLString: remoteURLString
        )
        lock.lock()
        taskItems.insert(item, at: 0)
        queuedOrder.append(id)
        operations[id] = operation
        finishHandlers[id] = onFinish
        lock.unlock()
        notify()
        processNext()
        return id
    }

    public func moveToTop(id: UUID) {
        lock.lock()
        guard let index = taskItems.firstIndex(where: { $0.id == id }),
              taskItems[index].state == .queued else {
            lock.unlock()
            return
        }
        let item = taskItems.remove(at: index)
        taskItems.insert(item, at: 0)
        queuedOrder.removeAll { $0 == id }
        queuedOrder.insert(id, at: 0)
        lock.unlock()
        notify()
    }

    public func cancel(id: UUID) {
        var handler: TransferFinishHandler?
        lock.lock()
        queuedOrder.removeAll { $0 == id }
        if let task = runningTasks[id] {
            task.cancel()
        } else if let index = taskItems.firstIndex(where: { $0.id == id && $0.state == .queued }) {
            taskItems[index].state = .cancelled
            operations.removeValue(forKey: id)
            handler = finishHandlers.removeValue(forKey: id)
        }
        lock.unlock()
        handler?(.cancelled, nil)
        notify()
    }

    public func retry(id: UUID) {
        lock.lock()
        guard let index = taskItems.firstIndex(where: { $0.id == id }),
              taskItems[index].state == .failed || taskItems[index].state == .cancelled,
              operations[id] != nil else {
            lock.unlock()
            return
        }
        taskItems[index].state = .queued
        taskItems[index].progress = 0
        taskItems[index].completedBytes = 0
        taskItems[index].speedBytesPerSec = 0
        taskItems[index].etaSeconds = nil
        taskItems[index].error = nil
        queuedOrder.removeAll { $0 == id }
        queuedOrder.append(id)
        lock.unlock()
        notify()
        processNext()
    }

    @discardableResult
    public func retryAllFailed() -> Int {
        lock.lock()
        var retriedCount = 0
        for index in taskItems.indices.reversed() {
            let id = taskItems[index].id
            if taskItems[index].state == .failed, operations[id] != nil {
                taskItems[index].state = .queued
                taskItems[index].progress = 0
                taskItems[index].completedBytes = 0
                taskItems[index].speedBytesPerSec = 0
                taskItems[index].etaSeconds = nil
                taskItems[index].error = nil
                queuedOrder.removeAll { $0 == id }
                queuedOrder.append(id)
                retriedCount += 1
            }
        }
        lock.unlock()
        if retriedCount > 0 {
            notify()
            processNext()
        }
        return retriedCount
    }

    public func clearCompleted() {
        lock.lock()
        taskItems.removeAll { $0.state == .completed }
        lock.unlock()
        notify()
    }

    public func cancelAll() {
        lock.lock()
        for (_, task) in runningTasks {
            task.cancel()
        }
        queuedOrder.removeAll()
        var handlers: [TransferFinishHandler] = []
        for i in 0..<taskItems.count {
            if taskItems[i].state == .queued {
                taskItems[i].state = .cancelled
                if let handler = finishHandlers.removeValue(forKey: taskItems[i].id) { handlers.append(handler) }
            }
        }
        lock.unlock()
        handlers.forEach { $0(.cancelled, nil) }
        notify()
    }

    private func processNext() {
        lock.lock()
        guard !paused else {
            lock.unlock()
            return
        }
        let runningCount = taskItems.filter { $0.state == .inProgress }.count
        var availableSlots = maxConcurrent - runningCount
        guard availableSlots > 0 else {
            lock.unlock()
            return
        }

        var toStart: [(UUID, TransferOperation)] = []
        var remainingQueue: [UUID] = []
        for id in queuedOrder {
            if availableSlots > 0,
               let index = taskItems.firstIndex(where: { $0.id == id && $0.state == .queued }),
               let op = operations[id] {
                taskItems[index].state = .inProgress
                speedTrackers[id] = (Date(), 0)
                toStart.append((id, op))
                availableSlots -= 1
            } else if taskItems.contains(where: { $0.id == id && $0.state == .queued }) {
                remainingQueue.append(id)
            }
        }
        queuedOrder = remainingQueue
        lock.unlock()

        guard !toStart.isEmpty else { return }
        notify()

        for (id, op) in toStart {
            startTask(id: id, operation: op)
        }
    }

    private func startTask(id: UUID, operation: @escaping TransferOperation) {
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await operation { [weak self] progress in
                    self?.handleProgress(id: id, progress: progress)
                }
                self.finishTask(id: id, state: .completed, error: nil)
            } catch is CancellationError {
                self.finishTask(id: id, state: .cancelled, error: nil)
            } catch {
                self.finishTask(id: id, state: .failed, error: error.localizedDescription)
            }
        }

        lock.lock()
        runningTasks[id] = task
        if speedTrackers[id] == nil {
            speedTrackers[id] = (Date(), 0)
        }
        lock.unlock()
    }

    private func handleProgress(id: UUID, progress: TransferProgress) {
        lock.lock()
        guard let index = taskItems.firstIndex(where: { $0.id == id && $0.state == .inProgress }) else {
            lock.unlock()
            return
        }
        taskItems[index].completedBytes = progress.completed
        taskItems[index].totalBytes = progress.total
        taskItems[index].progress = progress.total > 0 ? min(1.0, Double(progress.completed) / Double(progress.total)) : 0

        // Calculate speed
        let now = Date()
        if let tracker = speedTrackers[id] {
            let elapsed = now.timeIntervalSince(tracker.lastTime)
            if elapsed >= 0.5 {
                let bytesDelta = progress.completed - tracker.lastBytes
                let speed = max(0, Double(bytesDelta) / elapsed)
                taskItems[index].speedBytesPerSec = speed
                speedTrackers[id] = (now, progress.completed)
            } else if taskItems[index].speedBytesPerSec <= 0, elapsed >= 0.0001, progress.completed > 0 {
                taskItems[index].speedBytesPerSec = max(0, Double(progress.completed) / elapsed)
            }
        } else {
            speedTrackers[id] = (now, progress.completed)
        }

        let currentSpeed = taskItems[index].speedBytesPerSec
        if currentSpeed > 0, progress.total > 0 {
            let remainingBytes = max(0, progress.total - progress.completed)
            taskItems[index].etaSeconds = Double(remainingBytes) / currentSpeed
        } else {
            taskItems[index].etaSeconds = nil
        }
        lock.unlock()
        notify()
    }

    private func finishTask(id: UUID, state: TransferState, error: String?) {
        lock.lock()
        queuedOrder.removeAll { $0 == id }
        if let index = taskItems.firstIndex(where: { $0.id == id }) {
            taskItems[index].state = state
            taskItems[index].error = error
            taskItems[index].speedBytesPerSec = 0
            taskItems[index].etaSeconds = nil
            if state == .completed {
                taskItems[index].progress = 1.0
            }
        }
        runningTasks.removeValue(forKey: id)
        speedTrackers.removeValue(forKey: id)
        let handler = finishHandlers.removeValue(forKey: id)
        lock.unlock()
        handler?(state, error)
        notify()
        processNext()
    }

    private func notify() {
        if let callback = onQueueUpdated {
            callback()
        }
    }

    public static func formatSpeed(_ bytesPerSec: Double) -> String {
        if bytesPerSec <= 0 { return "0 B/s" }
        if bytesPerSec < 1024 { return "\(Int(bytesPerSec)) B/s" }
        if bytesPerSec < 1024 * 1024 {
            let kb = bytesPerSec / 1024.0
            return kb.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(kb)) KB/s" : String(format: "%.1f KB/s", kb)
        }
        let mb = bytesPerSec / (1024.0 * 1024.0)
        return mb.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(mb)) MB/s" : String(format: "%.1f MB/s", mb)
    }

    public static func formatETA(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "--" }
        let total = Int(seconds.rounded(.up))
        if total < 60 { return "\(total)s" }
        let mins = total / 60
        let secs = total % 60
        if mins < 60 { return String(format: "%dm %02ds", mins, secs) }
        let hours = mins / 60
        let remMins = mins % 60
        return String(format: "%dh %02dm", hours, remMins)
    }
}
