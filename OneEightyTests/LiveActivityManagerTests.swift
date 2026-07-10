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

    func testStartActivityEndsOrphanedActivityFromPreviousSession() async throws {
        // Simulate a previous app session that started a Live Activity and was
        // killed (e.g. SIGKILL / Xcode stop) before it could end the activity.
        // Nothing local references it anymore, but ActivityKit still has it
        // registered.
        let orphan = LiveActivityManager.makeForTesting(store: InMemoryPlaybackStore())
        orphan.startActivity(bpm: 180, isPlaying: true)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(Activity<OneEightyActivityAttributes>.activities.count, 1,
                       "precondition: orphaned activity should be registered with the system")

        // A brand-new process launch: a fresh manager instance with no
        // knowledge of the orphaned activity starts its own.
        let fresh = LiveActivityManager.makeForTesting(store: InMemoryPlaybackStore())
        fresh.startActivity(bpm: 190, isPlaying: true)
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(Activity<OneEightyActivityAttributes>.activities.count, 1,
                       "starting a new session must end orphaned activities from a previous session, not stack a second one")
    }

    /// Reproduces the widget-extension bug: IncrementBPMIntent/DecrementBPMIntent
    /// run in the extension process, which has its own LiveActivityManager.shared
    /// singleton with currentActivity == nil (it never called startActivity itself),
    /// but shares the SAME cross-process store/claim ledger as the main app.
    /// Before the fix, apply() with currentActivity == nil always tried to START a
    /// new activity, competing for the same monotonic version claim the main app's
    /// activity relies on — so the extension's push went nowhere (no real activity
    /// handle) while burning a version the main app could otherwise have pushed.
    func testApplyAdoptsExistingActivityInsteadOfRacingToStartANewOne() async throws {
        let store = InMemoryPlaybackStore()
        let mainApp = LiveActivityManager.makeForTesting(store: store)
        mainApp.startActivity(bpm: 180, isPlaying: true)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(Activity<OneEightyActivityAttributes>.activities.count, 1)
        let originalID = Activity<OneEightyActivityAttributes>.activities.first?.id

        // A second manager instance sharing the same store, with no local
        // currentActivity — exactly the widget extension's situation.
        let extensionSide = LiveActivityManager.makeForTesting(store: store)
        extensionSide.apply(AppState(version: UInt64(mainApp.tracker.totalUpdateCount) + 1, bpm: 190, isPlaying: true))
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(Activity<OneEightyActivityAttributes>.activities.count, 1,
                       "must adopt the existing activity rather than starting a competing second one")
        XCTAssertEqual(Activity<OneEightyActivityAttributes>.activities.first?.id, originalID,
                       "the real, already-visible activity must not be torn down and replaced")
        XCTAssertEqual(extensionSide.tracker.totalUpdateCount, 1,
                       "adopting and pushing to the existing activity should count as a real update")
    }

    /// After the very first startActivity(), lastSentState must reflect the
    /// activity's initial content — otherwise the next update's isPlaying
    /// comparison is against nil, is always treated as a critical transition,
    /// bypassing coalescing/throttling unintentionally.
    func testStartActivitySetsLastSentStateToInitialContent() {
        let manager = LiveActivityManager.makeForTesting(store: InMemoryPlaybackStore())
        manager.startActivity(bpm: 180, isPlaying: true)
        XCTAssertEqual(manager.lastSentState?.bpm, 180)
        XCTAssertEqual(manager.lastSentState?.isPlaying, true)
    }

    // MARK: - Budget throttling / coalescing (FIX 1)

    func testNormalBurstOverBudgetCoalesces() {
        // A huge minimumInterval forces every update after the first to be
        // throttled, so a burst of NORMAL (isPlaying-constant) bpm updates must
        // coalesce into far fewer real pushes than inputs.
        let tracker = ActivityUpdateTracker(minimumInterval: 100, budgetWarningThreshold: 40)
        let manager = LiveActivityManager.makeForTesting(store: InMemoryPlaybackStore(), tracker: tracker)
        manager.startActivity(bpm: 180, isPlaying: true)

        for v in 1...10 {
            manager.apply(AppState(version: UInt64(v), bpm: 180 + v, isPlaying: true))
        }

        XCTAssertLessThan(tracker.totalUpdateCount, 10,
                          "NORMAL updates while throttled must coalesce, not push once per input")
        XCTAssertGreaterThanOrEqual(tracker.totalUpdateCount, 1,
                                    "at least the first update should push")
    }

    func testCriticalUpdateBypassesThrottle() {
        let tracker = ActivityUpdateTracker(minimumInterval: 100, budgetWarningThreshold: 40)
        let manager = LiveActivityManager.makeForTesting(store: InMemoryPlaybackStore(), tracker: tracker)
        manager.startActivity(bpm: 180, isPlaying: true)
        manager.apply(AppState(version: 1, bpm: 181, isPlaying: true))   // first push, records timestamp
        let before = tracker.totalUpdateCount

        // Under heavy throttle a bpm-only change would coalesce, but an
        // isPlaying transition is CRITICAL and must push immediately.
        manager.apply(AppState(version: 2, bpm: 181, isPlaying: false))

        XCTAssertEqual(tracker.totalUpdateCount, before + 1,
                       "CRITICAL isPlaying transition must bypass throttle and push immediately")
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
