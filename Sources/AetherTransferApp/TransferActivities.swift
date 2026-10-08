import Combine
import Foundation
import AetherTransferCore

struct ActivityItem: Identifiable {
    let id: UUID
    let name: String
    let direction: String
    var progress: Double = 0
    var bytes: Int64 = 0
    var total: Int64 = 0
    var state: String = "等待中"
    var error: String?
    var canRetry = true
    var canRetain = false
    var requiresRestart = false
    var phase: String?
    var scope: TransferProgress.Scope = .file
    var hasKnownTotal = false
    var completedItems: Int?
    var totalItems: Int?
    var skippedItems = 0
    var rate: TransferRateEstimate?
    var rateEstimator = TransferRateEstimator()
}

/// Progress belongs to the activity panel, not the file browser or its sheets.
/// The window subscribes only to count changes to reveal newly queued tasks.
@MainActor final class TransferActivities: ObservableObject {
    @Published var items: [ActivityItem] = []
    @Published private(set) var resumeIDs: Set<UUID> = []

    var itemCountChanges: AnyPublisher<Int, Never> {
        $items.map(\.count).removeDuplicates().eraseToAnyPublisher()
    }

    func updateResumeIDs(_ value: Set<UUID>) {
        guard resumeIDs != value else { return }
        resumeIDs = value
    }
}
