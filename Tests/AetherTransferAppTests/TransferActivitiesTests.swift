import Combine
import XCTest
@testable import AetherTransferApp

@MainActor final class TransferActivitiesTests: XCTestCase {
    func testProgressDoesNotRepeatedlyNotifyTheWindow() {
        let store = TransferActivities()
        var counts: [Int] = [], progressUpdates = 0, lastBytes: Int64 = -1
        let countSubscription = store.itemCountChanges.sink { counts.append($0) }
        let progressSubscription = store.$items.dropFirst().sink {
            progressUpdates += 1; lastBytes = $0.first?.bytes ?? -1
        }
        defer { countSubscription.cancel(); progressSubscription.cancel() }

        let id = UUID()
        store.items = [ActivityItem(id: id, name: "fixture", direction: "上传")]
        for bytes in 1...1000 { store.items[0].bytes = Int64(bytes) }
        XCTAssertEqual(counts, [0, 1], "Progress must update the panel without reopening or invalidating the window")
        XCTAssertEqual(progressUpdates, 1001)
        XCTAssertEqual(lastBytes, 1000)
        XCTAssertEqual(store.items[0].id, id)

        store.items.removeAll()
        store.items.append(ActivityItem(id: UUID(), name: "next", direction: "下载"))
        XCTAssertEqual(counts, [0, 1, 0, 1], "A new job after clearing still reveals its activity panel")
    }

    func testResumeMembershipPublishesOnlyOwnershipChanges() {
        let store = TransferActivities(), record = UUID(), job = UUID()
        var memberships: [Set<UUID>] = []
        let subscription = store.$resumeIDs.sink { memberships.append($0) }
        defer { subscription.cancel() }

        store.items = [ActivityItem(id: job, name: "fixture", direction: "下载")]
        store.updateResumeIDs([record])
        store.updateResumeIDs([record])
        for bytes in 1...1000 { store.items[0].bytes = Int64(bytes) }
        XCTAssertEqual(memberships, [[], [record]])
        XCTAssertEqual(store.resumeIDs, [record])

        store.updateResumeIDs([])
        store.updateResumeIDs([])
        XCTAssertEqual(memberships, [[], [record], []], "Release membership exactly once so recovery can display the record")
    }

}
