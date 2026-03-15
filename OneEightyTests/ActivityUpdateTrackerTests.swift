import XCTest
@testable import OneEighty

final class ActivityUpdateTrackerTests: XCTestCase {

    nonisolated func testRecordUpdateIncrementsCount() async {
        await MainActor.run {
            let tracker = ActivityUpdateTracker()
            XCTAssertEqual(tracker.totalUpdateCount, 0)

            tracker.recordUpdate()

            XCTAssertEqual(tracker.totalUpdateCount, 1)
        }
    }

    nonisolated func testRecordUpdateTracksTimestamps() async {
        await MainActor.run {
            let tracker = ActivityUpdateTracker()
            let now = Date()

            tracker.recordUpdate(at: now)

            XCTAssertEqual(tracker.updateTimestamps.count, 1)
            XCTAssertEqual(tracker.updateTimestamps.first, now)
        }
    }

    nonisolated func testMultipleUpdatesTracked() async {
        await MainActor.run {
            let tracker = ActivityUpdateTracker()
            let t1 = Date()
            let t2 = t1.addingTimeInterval(1.0)
            let t3 = t2.addingTimeInterval(1.0)

            tracker.recordUpdate(at: t1)
            tracker.recordUpdate(at: t2)
            tracker.recordUpdate(at: t3)

            XCTAssertEqual(tracker.totalUpdateCount, 3)
            XCTAssertEqual(tracker.updateTimestamps.count, 3)
            XCTAssertEqual(tracker.updateTimestamps, [t1, t2, t3])
        }
    }

    nonisolated func testUpdatesInLastHourCountsCorrectly() async {
        await MainActor.run {
            let tracker = ActivityUpdateTracker()
            let now = Date()
            let twoHoursAgo = now.addingTimeInterval(-7200)
            let thirtyMinutesAgo = now.addingTimeInterval(-1800)

            tracker.recordUpdate(at: twoHoursAgo)   // outside window
            tracker.recordUpdate(at: thirtyMinutesAgo) // inside window
            tracker.recordUpdate(at: now)              // inside window

            XCTAssertEqual(tracker.updatesInLastHour(relativeTo: now), 2)
        }
    }

    nonisolated func testOldTimestampsArePruned() async {
        await MainActor.run {
            let tracker = ActivityUpdateTracker()
            let now = Date()
            let twoHoursAgo = now.addingTimeInterval(-7200)

            tracker.recordUpdate(at: twoHoursAgo)
            XCTAssertEqual(tracker.updateTimestamps.count, 1)

            // Recording a new update prunes old entries
            tracker.recordUpdate(at: now)
            XCTAssertEqual(tracker.updateTimestamps.count, 1,
                           "Old timestamp should have been pruned")
            XCTAssertEqual(tracker.updateTimestamps.first, now)
        }
    }

    nonisolated func testIsApproachingBudgetLimitDefaultThreshold() async {
        await MainActor.run {
            let tracker = ActivityUpdateTracker()
            let now = Date()

            // Default threshold is 40. Add 39 updates — not yet approaching.
            for i in 0..<39 {
                tracker.recordUpdate(at: now.addingTimeInterval(Double(i)))
            }
            XCTAssertFalse(tracker.isApproachingBudgetLimit(at: now.addingTimeInterval(39)))

            // 40th update crosses threshold
            tracker.recordUpdate(at: now.addingTimeInterval(39))
            XCTAssertTrue(tracker.isApproachingBudgetLimit(at: now.addingTimeInterval(39)))
        }
    }

    nonisolated func testCustomBudgetWarningThreshold() async {
        await MainActor.run {
            let tracker = ActivityUpdateTracker(budgetWarningThreshold: 5)
            let now = Date()

            for i in 0..<5 {
                tracker.recordUpdate(at: now.addingTimeInterval(Double(i)))
            }
            XCTAssertTrue(tracker.isApproachingBudgetLimit(at: now.addingTimeInterval(4)))
        }
    }

    nonisolated func testCriticalPriorityNeverThrottled() async {
        await MainActor.run {
            let tracker = ActivityUpdateTracker(minimumInterval: 1.0)
            let now = Date()

            tracker.recordUpdate(at: now)

            // Even immediately after an update, critical is never throttled
            XCTAssertFalse(tracker.shouldThrottle(priority: .critical, at: now))
        }
    }

    nonisolated func testNormalPriorityThrottledWithinInterval() async {
        await MainActor.run {
            let tracker = ActivityUpdateTracker(minimumInterval: 0.5)
            let now = Date()

            tracker.recordUpdate(at: now)

            // 0.1s later — within minimum interval — should throttle
            let soon = now.addingTimeInterval(0.1)
            XCTAssertTrue(tracker.shouldThrottle(priority: .normal, at: soon))
        }
    }

    nonisolated func testNormalPriorityNotThrottledAfterInterval() async {
        await MainActor.run {
            let tracker = ActivityUpdateTracker(minimumInterval: 0.5)
            let now = Date()

            tracker.recordUpdate(at: now)

            // 0.6s later — past minimum interval — should not throttle
            let later = now.addingTimeInterval(0.6)
            XCTAssertFalse(tracker.shouldThrottle(priority: .normal, at: later))
        }
    }

    nonisolated func testNoUpdatesYetNeverThrottles() async {
        await MainActor.run {
            let tracker = ActivityUpdateTracker(minimumInterval: 1.0)
            XCTAssertFalse(tracker.shouldThrottle(priority: .normal, at: Date()))
        }
    }

    nonisolated func testResetClearsAllState() async {
        await MainActor.run {
            let tracker = ActivityUpdateTracker()
            let now = Date()

            tracker.recordUpdate(at: now)
            tracker.recordUpdate(at: now.addingTimeInterval(1))
            XCTAssertEqual(tracker.totalUpdateCount, 2)

            tracker.reset()

            XCTAssertEqual(tracker.totalUpdateCount, 0)
            XCTAssertEqual(tracker.updateTimestamps.count, 0)
        }
    }

    // MARK: - Delivery confirmation tracking

    nonisolated func testMarkUpdateSentSetsPending() async {
        await MainActor.run {
            let tracker = ActivityUpdateTracker()
            XCTAssertFalse(tracker.hasPendingUpdate)

            tracker.markUpdateSent()

            XCTAssertTrue(tracker.hasPendingUpdate)
        }
    }

    nonisolated func testMarkUpdateConfirmedClearsPending() async {
        await MainActor.run {
            let tracker = ActivityUpdateTracker()

            tracker.markUpdateSent()
            XCTAssertTrue(tracker.hasPendingUpdate)

            tracker.markUpdateConfirmed()

            XCTAssertFalse(tracker.hasPendingUpdate)
        }
    }

    nonisolated func testIsPendingUpdateStaleAfterTimeout() async {
        await MainActor.run {
            let tracker = ActivityUpdateTracker()
            let now = Date()

            tracker.markUpdateSent(at: now)

            // 3 seconds later with 2s timeout — stale
            let later = now.addingTimeInterval(3.0)
            XCTAssertTrue(tracker.isPendingUpdateStale(at: later, timeout: 2.0))
        }
    }

    nonisolated func testIsPendingUpdateNotStaleBeforeTimeout() async {
        await MainActor.run {
            let tracker = ActivityUpdateTracker()
            let now = Date()

            tracker.markUpdateSent(at: now)

            // 1 second later with 2s timeout — not stale
            let soon = now.addingTimeInterval(1.0)
            XCTAssertFalse(tracker.isPendingUpdateStale(at: soon, timeout: 2.0))
        }
    }

    nonisolated func testNoPendingUpdateIsNeverStale() async {
        await MainActor.run {
            let tracker = ActivityUpdateTracker()
            XCTAssertFalse(tracker.isPendingUpdateStale(at: Date(), timeout: 0.0))
        }
    }

    nonisolated func testResetClearsPendingUpdate() async {
        await MainActor.run {
            let tracker = ActivityUpdateTracker()
            tracker.markUpdateSent()
            XCTAssertTrue(tracker.hasPendingUpdate)

            tracker.reset()

            XCTAssertFalse(tracker.hasPendingUpdate)
        }
    }
}
