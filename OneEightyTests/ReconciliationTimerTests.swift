import XCTest
@testable import OneEighty

final class ReconciliationTimerTests: XCTestCase {

    nonisolated func testReconciliationFiresAfterThrottleSettles() async {
        await MainActor.run {
            let manager = LiveActivityManager.shared
            manager.resetForTesting()
            manager.updateActivity(bpm: 180, isPlaying: true)
        }
        // Wait for throttle (0.3s) + reconciliation (0.5s) + margin
        try? await Task.sleep(for: .milliseconds(1000))
        await MainActor.run {
            let manager = LiveActivityManager.shared
            XCTAssertGreaterThanOrEqual(manager.reconciliationCount, 1,
                                        "Reconciliation should fire after throttle settles")
        }
    }

    nonisolated func testReconciliationCancelledByNewUpdate() async {
        await MainActor.run {
            let manager = LiveActivityManager.shared
            manager.resetForTesting()
            manager.updateActivity(bpm: 180, isPlaying: true)
        }
        // Wait past throttle but before reconciliation
        try? await Task.sleep(for: .milliseconds(400))
        await MainActor.run {
            let manager = LiveActivityManager.shared
            let countBefore = manager.reconciliationCount
            manager.updateActivity(bpm: 181, isPlaying: true)
            XCTAssertEqual(manager.reconciliationCount, countBefore,
                           "New update should cancel pending reconciliation")
        }
    }

    nonisolated func testReconciliationCancelledByEndActivity() async {
        await MainActor.run {
            let manager = LiveActivityManager.shared
            manager.resetForTesting()
            manager.updateActivity(bpm: 180, isPlaying: true)
            manager.endActivity()
        }
        // Wait for reconciliation timer — should NOT fire
        try? await Task.sleep(for: .milliseconds(1000))
        await MainActor.run {
            let manager = LiveActivityManager.shared
            XCTAssertEqual(manager.reconciliationCount, 0,
                           "Reconciliation should not fire after endActivity")
        }
    }
}
