import Foundation
import XCTest
@testable import AetherTransferCore

private actor QueueProbe {
    var active = 0
    var peak = 0
    var started = Set<UUID>()
    func run(_ id: UUID) async throws {
        active += 1; peak = max(peak, active); started.insert(id)
        defer { active -= 1 }
        try await Task.sleep(for: .seconds(60))
    }
    func snapshot() -> (Int, Int, Set<UUID>) { (active, peak, started) }
}

@MainActor final class TransferQueueTests: XCTestCase {
    func testBoundedQueueAndQueuedCancellation() async throws {
        let queue = TransferQueue(limit: 2), probe = QueueProbe()
        let ids = (0..<4).map { _ in UUID() }
        let started = expectation(description: "Two jobs started")
        started.expectedFulfillmentCount = 2
        let cancelled = expectation(description: "All jobs cancelled")
        cancelled.expectedFulfillmentCount = 4
        let observer: TransferQueue.Observer = { _, event in
            if case .running = event { started.fulfill() }
            if case .cancelled = event { cancelled.fulfill() }
        }
        for id in ids {
            await queue.enqueue(id: id, operation: { _ in try await probe.run(id) }, observer: observer)
        }
        await fulfillment(of: [started], timeout: 3)
        let counts = await queue.counts()
        XCTAssertEqual(counts.running, 2); XCTAssertEqual(counts.pending, 2)
        await queue.cancel(ids[2]); await queue.cancel(ids[3])
        await queue.cancel(ids[0]); await queue.cancel(ids[1])
        await fulfillment(of: [cancelled], timeout: 3)
        let final = await probe.snapshot()
        XCTAssertLessThanOrEqual(final.1, 2)
        XCTAssertFalse(final.2.contains(ids[2])); XCTAssertFalse(final.2.contains(ids[3]))
    }
}
