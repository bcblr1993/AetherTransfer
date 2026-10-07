import XCTest
@testable import AetherTransferCore

final class TransferRateTests: XCTestCase {
    func testResumeExcludesRetainedBytesAndVerification() {
        var rate = TransferRateEstimator()
        let start = ContinuousClock.now
        XCTAssertNil(rate.observe(TransferProgress(completed: 3_000_000, total: 4_000_000), at: start))
        let result = rate.observe(TransferProgress(completed: 3_500_000, total: 4_000_000), at: start.advanced(by: .seconds(1)))
        XCTAssertEqual(result?.bytesPerSecond, 500_000)
        XCTAssertEqual(result?.remainingSeconds, 1)
        XCTAssertNil(rate.observe(TransferProgress(completed: 4_000_000, total: 4_000_000, phase: "校验并提交"), at: start.advanced(by: .seconds(2))))
        XCTAssertNil(rate.observe(TransferProgress(completed: 4_000_000, total: 4_000_000), at: start.advanced(by: .seconds(3))))
    }

    func testPauseAndFileOrAuthenticationResetStartNewSampleWindow() {
        var rate = TransferRateEstimator()
        let start = ContinuousClock.now
        _ = rate.observe(TransferProgress(completed: 0, total: 1000), at: start)
        XCTAssertEqual(rate.observe(TransferProgress(completed: 100, total: 1000), at: start.advanced(by: .seconds(1)))?.bytesPerSecond, 100)
        rate.reset() // Pause, waiting, retry and terminal states reset the window.
        XCTAssertNil(rate.observe(TransferProgress(completed: 100, total: 1000), at: start.advanced(by: .seconds(30))))
        XCTAssertEqual(rate.observe(TransferProgress(completed: 200, total: 1000), at: start.advanced(by: .seconds(31)))?.bytesPerSecond, 100)
        XCTAssertNil(rate.observe(TransferProgress(completed: 0, total: 1000), at: start.advanced(by: .seconds(32))))
        XCTAssertNil(rate.observe(TransferProgress(completed: 100, total: 2000), at: start.advanced(by: .seconds(33))))
        XCTAssertNil(rate.observe(TransferProgress(completed: 200, total: 2000), at: start.advanced(by: .seconds(38))))
    }

    func testStallDecaysToZeroAndUnknownTotalHasNoETA() {
        var rate = TransferRateEstimator()
        let start = ContinuousClock.now
        _ = rate.observe(TransferProgress(completed: 0, total: 0), at: start)
        XCTAssertEqual(rate.observe(TransferProgress(completed: 100, total: 0), at: start.advanced(by: .seconds(1)))?.bytesPerSecond, 100)
        _ = rate.observe(TransferProgress(completed: 100, total: 0), at: start.advanced(by: .seconds(2)))
        _ = rate.observe(TransferProgress(completed: 100, total: 0), at: start.advanced(by: .seconds(3)))
        let stalled = rate.observe(TransferProgress(completed: 100, total: 0), at: start.advanced(by: .seconds(4)))
        XCTAssertEqual(stalled?.bytesPerSecond, 0)
        XCTAssertNil(stalled?.remainingSeconds)
        XCTAssertNil(rate.observe(TransferProgress(completed: -1, total: 0), at: start.advanced(by: .seconds(5))))
    }
}
