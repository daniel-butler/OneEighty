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

    // MARK: - Budget-Aware Effective Interval

    nonisolated func testEffectiveIntervalNormalUnderBudget() async {
        await MainActor.run {
            let tracker = ActivityUpdateTracker(minimumInterval: 0.3, budgetWarningThreshold: 40)
            XCTAssertEqual(tracker.effectiveInterval(), 0.3,
                           "Under budget should use normal interval")
        }
    }

    nonisolated func testEffectiveIntervalDoublesAt75Percent() async {
        await MainActor.run {
            let tracker = ActivityUpdateTracker(minimumInterval: 0.3, budgetWarningThreshold: 40)
            let now = Date()

            // 30 updates = 75% of budget
            for i in 0..<30 {
                tracker.recordUpdate(at: now.addingTimeInterval(Double(i)))
            }

            XCTAssertEqual(tracker.effectiveInterval(at: now.addingTimeInterval(30)), 0.6,
                           "At 75% budget, interval should double")
        }
    }

    nonisolated func testEffectiveIntervalQuadruplesAtBudgetLimit() async {
        await MainActor.run {
            let tracker = ActivityUpdateTracker(minimumInterval: 0.3, budgetWarningThreshold: 40)
            let now = Date()

            // 40 updates = 100% of budget
            for i in 0..<40 {
                tracker.recordUpdate(at: now.addingTimeInterval(Double(i)))
            }

            XCTAssertEqual(tracker.effectiveInterval(at: now.addingTimeInterval(40)), 1.2,
                           "At budget limit, interval should quadruple")
        }
    }

    nonisolated func testEffectiveIntervalRecoversAfterTimePasses() async {
        await MainActor.run {
            let tracker = ActivityUpdateTracker(minimumInterval: 0.3, budgetWarningThreshold: 40)
            let now = Date()

            // Fill up budget
            for i in 0..<40 {
                tracker.recordUpdate(at: now.addingTimeInterval(Double(i)))
            }
            XCTAssertEqual(tracker.effectiveInterval(at: now.addingTimeInterval(40)), 1.2)

            // After all entries are older than 1 hour, interval returns to normal
            // Last entry was at now+39, so now+3640 puts all entries >1hr old
            let oneHourLater = now.addingTimeInterval(3640)
            tracker.recordUpdate(at: oneHourLater) // triggers prune
            XCTAssertEqual(tracker.effectiveInterval(at: oneHourLater), 0.3,
                           "After old entries expire, interval should return to normal")
        }
    }
}
