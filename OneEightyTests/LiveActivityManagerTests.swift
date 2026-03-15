//
//  LiveActivityManagerTests.swift
//  OneEightyTests
//

import XCTest
@testable import OneEighty

final class LiveActivityManagerTests: XCTestCase {

    nonisolated func testRapidUpdatesAreThrottled() async {
        await MainActor.run {
            let manager = LiveActivityManager.shared
            manager.resetForTesting()

            for bpm in 180...189 {
                manager.updateActivity(bpm: bpm, isPlaying: false)
            }
        }

        try? await Task.sleep(for: .milliseconds(500))

        await MainActor.run {
            let manager = LiveActivityManager.shared
            let updateCount = manager.tracker.totalUpdateCount
            XCTAssertLessThan(updateCount, 10,
                              "Rapid updates should be throttled, not sent individually")
            XCTAssertGreaterThan(updateCount, 0,
                                 "At least one update should go through")
        }
    }

    nonisolated func testPlayStateUpdatesImmediately() async {
        await MainActor.run {
            let manager = LiveActivityManager.shared
            manager.resetForTesting()

            manager.updateActivity(bpm: 180, isPlaying: true)
        }

        try? await Task.sleep(for: .milliseconds(50))

        await MainActor.run {
            let manager = LiveActivityManager.shared
            XCTAssertEqual(manager.tracker.totalUpdateCount, 1,
                           "Play state change should update immediately")
        }
    }

    nonisolated func testTrackerRecordsBudgetOnUpdate() async {
        await MainActor.run {
            let manager = LiveActivityManager.shared
            manager.resetForTesting()

            manager.updateActivity(bpm: 180, isPlaying: true)
        }

        try? await Task.sleep(for: .milliseconds(50))

        await MainActor.run {
            let manager = LiveActivityManager.shared
            XCTAssertGreaterThan(manager.tracker.totalUpdateCount, 0,
                                 "Tracker should record updates dispatched by manager")
            XCTAssertEqual(manager.tracker.updatesInLastHour(), manager.tracker.totalUpdateCount,
                           "All recent updates should appear in the hourly window")
            XCTAssertFalse(manager.tracker.isApproachingBudgetLimit(),
                           "A single update should not approach the budget limit")
        }
    }

    nonisolated func testLastSentStateTrackedAfterUpdate() async {
        await MainActor.run {
            let manager = LiveActivityManager.shared
            manager.resetForTesting()

            manager.updateActivity(bpm: 190, isPlaying: true)

            XCTAssertEqual(manager.lastSentState?.bpm, 190,
                           "lastSentState should reflect the most recent pushed BPM")
            XCTAssertEqual(manager.lastSentState?.isPlaying, true,
                           "lastSentState should reflect the most recent pushed isPlaying")
        }
    }

    nonisolated func testCleanupStaleActivitiesDoesNotCrash() async {
        await MainActor.run {
            let manager = LiveActivityManager.shared
            manager.resetForTesting()
            // Should succeed even when no stale activities exist
            manager.cleanupStaleActivities()
        }
    }

    nonisolated func testResetClearsLastSentState() async {
        await MainActor.run {
            let manager = LiveActivityManager.shared
            manager.resetForTesting()

            manager.updateActivity(bpm: 180, isPlaying: true)
            XCTAssertNotNil(manager.lastSentState)

            manager.resetForTesting()
            XCTAssertNil(manager.lastSentState,
                         "resetForTesting should clear lastSentState")
        }
    }
}
