import Foundation

public struct TransferRateEstimate: Sendable {
    public let bytesPerSecond: Double
    public let remainingSeconds: Double?
}

/// Estimates the current byte stream, excluding retained bytes and verification phases.
public struct TransferRateEstimator: Sendable {
    private struct Sample: Sendable {
        let time: ContinuousClock.Instant
        let bytes: Int64
    }
    private var samples: [Sample] = []
    private var total: Int64 = 0
    public init() {}
    public mutating func reset() { samples.removeAll(keepingCapacity: true); total = 0 }

    public mutating func observe(_ progress: TransferProgress,
                                 at time: ContinuousClock.Instant = .now) -> TransferRateEstimate? {
        guard progress.phase == nil, progress.completed >= 0, progress.total >= 0 else {
            reset(); return nil
        }
        let bytes = progress.total > 0 ? min(progress.completed, progress.total) : progress.completed
        if let previous = samples.last,
           time <= previous.time || bytes < previous.bytes || total != progress.total ||
            previous.time.duration(to: time) > .seconds(3) {
            reset()
        }
        total = progress.total
        samples.append(Sample(time: time, bytes: bytes))
        let oldest = time.advanced(by: .seconds(-3))
        samples.removeAll { $0.time < oldest }
        // The native callback is throttled, but this bound also protects other callers.
        if samples.count > 64 { samples.removeFirst(samples.count - 64) }
        guard let first = samples.first, first.time.duration(to: time) >= .milliseconds(500) else { return nil }
        let elapsed = first.time.duration(to: time).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        let rate = Double(bytes - first.bytes) / seconds
        let remaining = total > bytes && rate > 0 ? Double(total - bytes) / rate : nil
        return TransferRateEstimate(bytesPerSecond: rate, remainingSeconds: remaining)
    }
}
