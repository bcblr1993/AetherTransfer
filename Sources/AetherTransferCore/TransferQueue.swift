import Foundation

public enum QueueEvent: Sendable {
    case queued, running, progress(TransferProgress), completed, failed(String), cancelled
}

/// Limits active operations independently of UI selection and window refreshes.
public actor TransferQueue {
    public typealias Operation = @Sendable (@escaping @Sendable (TransferProgress) -> Void) async throws -> Void
    public typealias Observer = @Sendable (UUID, QueueEvent) -> Void
    private struct Job: Sendable {
        let id: UUID
        let operation: Operation
        let observer: Observer
    }
    private let limit: Int
    private var pending: [Job] = []
    private var running: [UUID: Task<Void, Never>] = [:]
    public init(limit: Int = 2) { self.limit = max(1, min(limit, 16)) }
    public func enqueue(id: UUID, operation: @escaping Operation, observer: @escaping Observer) {
        guard !pending.contains(where: { $0.id == id }), running[id] == nil else { return }
        pending.append(Job(id: id, operation: operation, observer: observer))
        observer(id, .queued)
        startNext()
    }
    public func cancel(_ id: UUID) {
        if let index = pending.firstIndex(where: { $0.id == id }) {
            let job = pending.remove(at: index); job.observer(id, .cancelled)
        } else { running[id]?.cancel() }
    }
    public func counts() -> (pending: Int, running: Int) { (pending.count, running.count) }
    private func startNext() {
        while running.count < limit && !pending.isEmpty {
            let job = pending.removeFirst()
            running[job.id] = Task {
                job.observer(job.id, .running)
                let result: QueueEvent
                do {
                    try Task.checkCancellation()
                    try await job.operation { progress in job.observer(job.id, .progress(progress)) }
                    try Task.checkCancellation()
                    result = .completed
                } catch is CancellationError { result = .cancelled }
                catch { result = .failed(error.localizedDescription) }
                finish(job, result: result)
            }
        }
    }
    private func finish(_ job: Job, result: QueueEvent) {
        running[job.id] = nil
        job.observer(job.id, result)
        startNext()
    }
}
