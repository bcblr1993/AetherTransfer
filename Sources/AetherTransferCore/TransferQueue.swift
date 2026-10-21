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

public struct TransferTaskItem: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let direction: TransferDirection
    public var state: TransferState
    public var progress: Double
    public var completedBytes: Int64
    public var totalBytes: Int64
    public var speedBytesPerSec: Double
    public var error: String?
    public let createdDate: Date

    public init(id: UUID = UUID(), name: String, direction: TransferDirection, state: TransferState = .queued,
                progress: Double = 0, completedBytes: Int64 = 0, totalBytes: Int64 = 0,
                speedBytesPerSec: Double = 0, error: String? = nil, createdDate: Date = Date()) {
        self.id = id
        self.name = name
        self.direction = direction
        self.state = state
        self.progress = progress
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.speedBytesPerSec = speedBytesPerSec
        self.error = error
        self.createdDate = createdDate
    }
}

public typealias TransferOperation = @Sendable (@escaping @Sendable (TransferProgress) -> Void) async throws -> Void

public final class TransferQueueManager: @unchecked Sendable {
    private var maxConcurrent: Int
    private let lock = NSLock()
    private var taskItems: [TransferTaskItem] = []
    private var operations: [UUID: TransferOperation] = [:]
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

    @discardableResult
    public func enqueue(name: String, direction: TransferDirection, operation: @escaping TransferOperation) -> UUID {
        let id = UUID()
        let item = TransferTaskItem(id: id, name: name, direction: direction, state: .queued)
        lock.lock()
        taskItems.insert(item, at: 0)
        operations[id] = operation
        lock.unlock()
        notify()
        processNext()
        return id
    }

    public func cancel(id: UUID) {
        lock.lock()
        if let task = runningTasks[id] {
            task.cancel()
        } else if let index = taskItems.firstIndex(where: { $0.id == id && $0.state == .queued }) {
            taskItems[index].state = .cancelled
            operations.removeValue(forKey: id)
        }
        lock.unlock()
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
        taskItems[index].error = nil
        lock.unlock()
        notify()
        processNext()
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
        for i in 0..<taskItems.count {
            if taskItems[i].state == .queued {
                taskItems[i].state = .cancelled
            }
        }
        lock.unlock()
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
        // Look from the oldest queued item to preserve FIFO queue behavior
        for index in taskItems.indices.reversed() {
            guard availableSlots > 0 else { break }
            if taskItems[index].state == .queued, let op = operations[taskItems[index].id] {
                taskItems[index].state = .inProgress
                toStart.append((taskItems[index].id, op))
                availableSlots -= 1
            }
        }
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
        speedTrackers[id] = (Date(), 0)
        lock.unlock()
    }

    private func handleProgress(id: UUID, progress: TransferProgress) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = taskItems.firstIndex(where: { $0.id == id && $0.state == .inProgress }) else { return }
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
            }
        } else {
            speedTrackers[id] = (now, progress.completed)
        }
        notify()
    }

    private func finishTask(id: UUID, state: TransferState, error: String?) {
        lock.lock()
        if let index = taskItems.firstIndex(where: { $0.id == id }) {
            taskItems[index].state = state
            taskItems[index].error = error
            taskItems[index].speedBytesPerSec = 0
            if state == .completed {
                taskItems[index].progress = 1.0
            }
        }
        runningTasks.removeValue(forKey: id)
        speedTrackers.removeValue(forKey: id)
        lock.unlock()
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
}
