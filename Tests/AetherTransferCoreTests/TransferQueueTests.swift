import XCTest
@testable import AetherTransferCore

final class TransferQueueTests: XCTestCase, @unchecked Sendable {
    func testQueueRespectsMaxConcurrency() async throws {
        let queue = TransferQueueManager(maxConcurrentTransfers: 2)
        XCTAssertEqual(queue.maxConcurrentTransfers, 2)

        let exp1 = expectation(description: "Task 1 started")
        let exp2 = expectation(description: "Task 2 started")
        let canFinish1 = expectation(description: "Task 1 can finish")
        let canFinish2 = expectation(description: "Task 2 can finish")

        let id1 = queue.enqueue(name: "file1.txt", direction: .upload) { _ in
            exp1.fulfill()
            await self.fulfillment(of: [canFinish1], timeout: 2.0)
        }

        let id2 = queue.enqueue(name: "file2.txt", direction: .upload) { _ in
            exp2.fulfill()
            await self.fulfillment(of: [canFinish2], timeout: 2.0)
        }

        let id3 = queue.enqueue(name: "file3.txt", direction: .download) { _ in
            // Should only start after a task finishes
        }

        await fulfillment(of: [exp1, exp2], timeout: 2.0)

        // At this point, task 1 and task 2 are inProgress; task 3 is queued
        let items = queue.items
        let item1 = items.first(where: { $0.id == id1 })
        let item2 = items.first(where: { $0.id == id2 })
        let item3 = items.first(where: { $0.id == id3 })

        XCTAssertEqual(item1?.state, .inProgress)
        XCTAssertEqual(item2?.state, .inProgress)
        XCTAssertEqual(item3?.state, .queued)

        // Finish task 1 and 2
        canFinish1.fulfill()
        canFinish2.fulfill()

        // Wait a bit for task 3 to be picked up
        try await Task.sleep(nanoseconds: 200_000_000)

        let updatedItems = queue.items
        let updatedItem3 = updatedItems.first(where: { $0.id == id3 })
        XCTAssertTrue(updatedItem3?.state == .inProgress || updatedItem3?.state == .completed)
    }

    func testCancelAndClearCompletedTasks() async throws {
        let queue = TransferQueueManager(maxConcurrentTransfers: 1)
        let blocked = expectation(description: "Task running")

        let id1 = queue.enqueue(name: "blocking.bin", direction: .download) { _ in
            blocked.fulfill()
            while true {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        await fulfillment(of: [blocked], timeout: 2.0)
        queue.cancel(id: id1)

        try await Task.sleep(nanoseconds: 100_000_000)
        let cancelled = queue.items.first(where: { $0.id == id1 })
        XCTAssertEqual(cancelled?.state, .cancelled)

        // Add a fast completed task
        let doneExp = expectation(description: "Done task")
        _ = queue.enqueue(name: "quick.txt", direction: .upload) { _ in
            doneExp.fulfill()
        }
        await fulfillment(of: [doneExp], timeout: 2.0)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(queue.items.contains(where: { $0.state == .completed }))
        queue.clearCompleted()
        XCTAssertFalse(queue.items.contains(where: { $0.state == .completed }))
        XCTAssertTrue(queue.items.contains(where: { $0.state == .cancelled }))
    }

    func testTransferSpeedFormatting() {
        XCTAssertEqual(TransferQueueManager.formatSpeed(0), "0 B/s")
        XCTAssertEqual(TransferQueueManager.formatSpeed(1024), "1 KB/s")
        XCTAssertEqual(TransferQueueManager.formatSpeed(1024 * 1024 * 3.5), "3.5 MB/s")
    }

    func testBandwidthSpeedLimitConfiguration() {
        let queue = TransferQueueManager(maxConcurrentTransfers: 3)
        XCTAssertNil(queue.speedLimitBytesPerSec)

        queue.setSpeedLimit(1024 * 1024 * 2) // 2 MB/s
        XCTAssertEqual(queue.speedLimitBytesPerSec, 1024 * 1024 * 2)

        queue.setSpeedLimit(nil)
        XCTAssertNil(queue.speedLimitBytesPerSec)

        queue.setMaxConcurrentTransfers(5)
        XCTAssertEqual(queue.maxConcurrentTransfers, 5)
        queue.setMaxConcurrentTransfers(99)
        XCTAssertEqual(queue.maxConcurrentTransfers, 10)
    }

    func testPauseAndResumeQueue() async throws {
        let queue = TransferQueueManager(maxConcurrentTransfers: 2)
        XCTAssertFalse(queue.isPaused)

        queue.pause()
        XCTAssertTrue(queue.isPaused)

        let resumeExp = expectation(description: "Task runs after resume")

        let id = queue.enqueue(name: "paused_task.txt", direction: .upload) { _ in
            resumeExp.fulfill()
        }

        // Wait a short moment while paused; task should remain queued
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(queue.items.first(where: { $0.id == id })?.state, .queued)

        // Resume queue
        queue.resume()
        XCTAssertFalse(queue.isPaused)

        await fulfillment(of: [resumeExp], timeout: 2.0)

        let state = queue.items.first(where: { $0.id == id })?.state
        XCTAssertTrue(state == .inProgress || state == .completed)
    }
}
