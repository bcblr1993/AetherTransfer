import XCTest
@testable import AetherTransferCore

final class DockTransferTrackerTests: XCTestCase {
    func testConcurrentBytesIncludeFinishedTaskUntilBatchEnds() {
        var tracker = DockTransferTracker()
        let a = UUID(), b = UUID()
        tracker.update(a, state: .active, progress: TransferProgress(completed: 50, total: 100))
        tracker.update(b, state: .active, progress: TransferProgress(completed: 0, total: 300))
        XCTAssertEqual(tracker.snapshot.percent, 12)
        tracker.update(a, state: .completed)
        XCTAssertEqual(tracker.snapshot.activeCount, 1); XCTAssertEqual(tracker.snapshot.percent, 25)
        tracker.update(b, state: .active, progress: TransferProgress(completed: 300, total: 300))
        XCTAssertEqual(tracker.snapshot.percent, 99) // Still verifying; no premature success.
        tracker.update(b, state: .completed)
        XCTAssertEqual(tracker.snapshot.activeCount, 0); XCTAssertNil(tracker.snapshot.percent)
        tracker.update(a, state: .completed)
        tracker.update(UUID(), state: .active, progress: TransferProgress(completed: 0, total: 100))
        XCTAssertEqual(tracker.snapshot.percent, 0)
    }
    func testUnknownQueuedTaskPauseCancellationAndRetainedRemoval() {
        var tracker = DockTransferTracker()
        let a = UUID(), b = UUID()
        tracker.update(a, state: .active, progress: TransferProgress(completed: 20, total: 100))
        tracker.update(b, state: .active)
        XCTAssertNil(tracker.snapshot.percent)
        tracker.update(a, state: .paused)
        XCTAssertFalse(tracker.snapshot.paused)
        tracker.update(b, state: .removed)
        XCTAssertTrue(tracker.snapshot.paused); XCTAssertEqual(tracker.snapshot.percent, 20)
        tracker.update(a, state: .removed)
        XCTAssertEqual(tracker.snapshot.activeCount, 0)
    }
    func testEmptyDirectoryUsesItemCountAndScanningDoesNotInventTotal() {
        var tracker = DockTransferTracker()
        let id = UUID()
        tracker.update(id, state: .active, progress: TransferProgress(completed: 0, total: 0, scope: .directory))
        XCTAssertNil(tracker.snapshot.percent)
        tracker.update(id, state: .active, progress: TransferProgress(completed: 0, total: 0, scope: .directory, completedItems: 2, totalItems: 4))
        XCTAssertEqual(tracker.snapshot.percent, 50)
        tracker.update(id, state: .completed)
        XCTAssertEqual(tracker.snapshot.activeCount, 0)
    }
}
