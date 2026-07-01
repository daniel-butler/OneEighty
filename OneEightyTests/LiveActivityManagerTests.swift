//
//  LiveActivityManagerTests.swift
//  OneEightyTests
//

import ActivityKit
import XCTest
@testable import OneEighty

@MainActor
final class LiveActivityManagerTests: XCTestCase {

    /// ActivityKit's simulator activity cap is shared process-wide across every test in
    /// this file (each test constructs its own manager/store). Await-end leftover
    /// activities from the previous test before starting the next, or `Activity.request`
    /// throws "Maximum number of activities" and `startActivity` silently no-ops.
    override func setUp() async throws {
        try await super.setUp()
        for activity in Activity<OneEightyActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    func testApplyStartsActivityOnFirstCall() {
        let manager = LiveActivityManager.makeForTesting(store: InMemoryPlaybackStore())
        manager.apply(AppState(version: 1, bpm: 180, isPlaying: true))
        XCTAssertEqual(manager.tracker.totalUpdateCount, 1,
                       "First apply should start the activity and record one update")
    }

    func testApplyPushesOncePerVersion() {
        let store = InMemoryPlaybackStore()
        let manager = LiveActivityManager.makeForTesting(store: store)
        manager.startActivity(bpm: 180, isPlaying: true)     // creates activity
        let before = manager.tracker.totalUpdateCount
        let s = AppState(version: 4, bpm: 190, isPlaying: true)
        manager.apply(s)
        manager.apply(s)   // same version → deduped, no second push
        XCTAssertEqual(manager.tracker.totalUpdateCount, before + 1)
    }

    func testApplyIgnoresStaleVersion() {
        let manager = LiveActivityManager.makeForTesting(store: InMemoryPlaybackStore())
        manager.startActivity(bpm: 180, isPlaying: true)
        manager.apply(AppState(version: 5, bpm: 190, isPlaying: true))
        let before = manager.tracker.totalUpdateCount
        manager.apply(AppState(version: 3, bpm: 200, isPlaying: false))   // older → skip
        XCTAssertEqual(manager.tracker.totalUpdateCount, before,
                       "Stale version must not push")
    }

    func testTrackerRecordsBudgetOnUpdate() {
        let manager = LiveActivityManager.makeForTesting(store: InMemoryPlaybackStore())
        manager.apply(AppState(version: 1, bpm: 180, isPlaying: true))

        XCTAssertGreaterThan(manager.tracker.totalUpdateCount, 0,
                             "Tracker should record updates dispatched by manager")
        XCTAssertEqual(manager.tracker.updatesInLastHour(), manager.tracker.totalUpdateCount,
                       "All recent updates should appear in the hourly window")
        XCTAssertFalse(manager.tracker.isApproachingBudgetLimit(),
                       "A single update should not approach the budget limit")
    }

    func testLastSentStateTrackedAfterPush() {
        let manager = LiveActivityManager.makeForTesting(store: InMemoryPlaybackStore())
        manager.startActivity(bpm: 180, isPlaying: true)

        manager.apply(AppState(version: 1, bpm: 190, isPlaying: true))

        XCTAssertEqual(manager.lastSentState?.bpm, 190,
                       "lastSentState should reflect the most recently pushed BPM")
        XCTAssertEqual(manager.lastSentState?.isPlaying, true,
                       "lastSentState should reflect the most recently pushed isPlaying")
    }

    func testCleanupStaleActivitiesDoesNotCrash() {
        let manager = LiveActivityManager.makeForTesting(store: InMemoryPlaybackStore())
        // Should succeed even when no stale activities exist
        manager.cleanupStaleActivities()
    }

    func testResetClearsLastSentState() {
        let manager = LiveActivityManager.makeForTesting(store: InMemoryPlaybackStore())
        manager.startActivity(bpm: 180, isPlaying: true)
        manager.apply(AppState(version: 1, bpm: 180, isPlaying: true))
        XCTAssertNotNil(manager.lastSentState)

        manager.resetForTesting()
        XCTAssertNil(manager.lastSentState,
                     "resetForTesting should clear lastSentState")
    }
}
