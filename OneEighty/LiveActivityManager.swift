//
//  LiveActivityManager.swift
//  OneEighty
//
//  Created by Claude on 12/23/25.
//

import ActivityKit
import Foundation
import os

private let logger = Logger(subsystem: "com.danielbutler.OneEighty", category: "LiveActivity")

/// Local content snapshot for pushing a Live Activity update. Distinct from
/// the transitional `PlaybackState` (OneEightyEngine.swift) — this manager is
/// fully migrated onto `AppState`/store-backed dedupe and no longer needs the
/// shared transitional type.
struct PlaybackStateSnapshot: Equatable {
    let bpm: Int
    let isPlaying: Bool
}

@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager(store: AppGroupPlaybackStore.shared)

    private let store: PlaybackStore

    private var currentActivity: Activity<OneEightyActivityAttributes>?
    private var contentUpdateTask: Task<Void, Never>?

    private(set) var tracker: ActivityUpdateTracker
    private(set) var lastSentState: OneEightyActivityAttributes.ContentState?
    private(set) var confirmedState: PlaybackStateSnapshot?

    /// Latest NORMAL (bpm-only) update deferred while throttled. Coalesced into
    /// a single push when `coalesceTimer` fires. Only the most recent value is
    /// kept — intermediate bpm values in a burst are dropped, which is correct
    /// for a metronome display.
    private var pendingState: AppState?
    private var coalesceTimer: Timer?

    static func makeForTesting(store: PlaybackStore, tracker: ActivityUpdateTracker? = nil) -> LiveActivityManager {
        let manager = LiveActivityManager(store: store)
        if let tracker { manager.tracker = tracker }
        return manager
    }

    private init(store: PlaybackStore) {
        self.store = store
        tracker = ActivityUpdateTracker()
    }

    /// Single entry point. Correctness (no duplicate pushes across processes)
    /// comes from the store's version claim, NOT from timing — echo suppression
    /// is gone. Budget throttling is a real ActivityKit OS constraint, so it is
    /// reinstated here as a coalescing gate for NORMAL (bpm-only) updates.
    ///
    /// - CRITICAL updates (an isPlaying transition) ALWAYS push immediately.
    /// - NORMAL updates push immediately unless throttled/over-budget, in which
    ///   case the latest value is coalesced and flushed by a single timer.
    ///
    /// The version claim happens at the moment of the ACTUAL push (see
    /// `pushIfClaimed`), so a coalesced/newer push claims the newer version and
    /// a superseded pending push is dropped when its (older) version is rejected.
    func apply(_ state: AppState) {
        // No local activity handle: before assuming none exists anywhere and
        // racing to create one, check whether the system already has one —
        // e.g. this is the widget extension process, whose own LiveActivityManager
        // instance never called startActivity() itself but shares the same
        // cross-process store as the process that did. Blindly starting a new
        // activity here would tear down and replace the real, on-screen one
        // via cleanupStaleActivities(), and would burn a version claim without
        // ever reaching the activity actually visible to the user.
        if currentActivity == nil {
            adoptExistingActivityIfPresent()
        }

        guard currentActivity != nil else {
            guard store.claimActivityPush(version: state.version, at: Date()) else {
                logger.info("apply: version \(state.version) already claimed — skipping initial start")
                return
            }
            startActivity(bpm: state.bpm, isPlaying: state.isPlaying)
            tracker.recordUpdate()
            return
        }

        let isCritical = state.isPlaying != lastSentState?.isPlaying

        if isCritical {
            // Play/stop transitions bypass all throttling and supersede any
            // pending coalesced bpm update.
            coalesceTimer?.invalidate()
            coalesceTimer = nil
            pendingState = nil
            pushIfClaimed(state, reason: "critical")
            return
        }

        // NORMAL (bpm-only) update.
        if tracker.shouldThrottle(priority: .normal) {
            // Over budget / too soon: coalesce the latest value and ensure a
            // single flush timer is scheduled at the current effective interval.
            pendingState = state
            if coalesceTimer == nil {
                let interval = tracker.effectiveInterval()
                coalesceTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.flushPending()
                    }
                }
            }
        } else {
            pushIfClaimed(state, reason: "immediate")
        }
    }

    /// Adopt an existing system-registered activity into this instance, if one
    /// exists. Lets a process with no local currentActivity (the widget
    /// extension) push directly to the real, already-visible activity instead
    /// of starting a competing new one.
    private func adoptExistingActivityIfPresent() {
        guard let existing = Activity<OneEightyActivityAttributes>.activities.first else { return }
        currentActivity = existing
        lastSentState = existing.content.state
        observeActivityUpdates(existing)
        logger.info("Adopted existing activity — id=\(existing.id)")
    }

    /// Fires when the coalescing window elapses: push the latest pending value.
    private func flushPending() {
        coalesceTimer = nil
        guard let state = pendingState else { return }
        pendingState = nil
        pushIfClaimed(state, reason: "coalesced")
    }

    /// Claim the version at push time (cross-process dedupe), then record the
    /// budget update and push. If the version was already claimed (e.g. a newer
    /// critical push raced ahead of a coalesced one), this is a no-op.
    private func pushIfClaimed(_ state: AppState, reason: String) {
        guard store.claimActivityPush(version: state.version, at: Date()) else {
            logger.info("pushIfClaimed(\(reason)): version \(state.version) already claimed — skipping (bpm=\(state.bpm), isPlaying=\(state.isPlaying))")
            return
        }
        tracker.recordUpdate()
        push(PlaybackStateSnapshot(bpm: state.bpm, isPlaying: state.isPlaying), reason: reason)
    }

    func push(_ state: PlaybackStateSnapshot, reason: String = "manual") {
        guard let activity = currentActivity else { return }
        let contentState = OneEightyActivityAttributes.ContentState(bpm: state.bpm, isPlaying: state.isPlaying)
        lastSentState = contentState
        let count = tracker.totalUpdateCount
        let hourly = tracker.updatesInLastHour()
        let systemActivityCount = Activity<OneEightyActivityAttributes>.activities.count
        logger.info("Pushing update #\(count) (hourly: \(hourly), reason: \(reason), system activities: \(systemActivityCount)) — bpm=\(state.bpm), isPlaying=\(state.isPlaying)")
        Task {
            await activity.update(.init(state: contentState, staleDate: nil))
            logger.info("Activity updated — id=\(activity.id)")
        }
    }

    func resetForTesting() {
        // End all existing activities to prevent "Maximum number of activities" errors
        for activity in Activity<OneEightyActivityAttributes>.activities {
            Task {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        contentUpdateTask?.cancel()
        contentUpdateTask = nil
        coalesceTimer?.invalidate()
        coalesceTimer = nil
        pendingState = nil
        currentActivity = nil
        lastSentState = nil
        confirmedState = nil
        tracker.reset()
    }

    func cleanupStaleActivities() {
        let staleActivities = Activity<OneEightyActivityAttributes>.activities
        guard !staleActivities.isEmpty else {
            logger.info("No stale activities to clean up")
            return
        }
        logger.info("Cleaning up \(staleActivities.count) stale activit\(staleActivities.count == 1 ? "y" : "ies")")
        for activity in staleActivities {
            Task {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    func startActivity(bpm: Int, isPlaying: Bool) {
        logger.info("startActivity called — bpm=\(bpm), isPlaying=\(isPlaying)")
        endActivity()
        // A previous session may have been killed before it could end its
        // activity (e.g. SIGKILL). Without this, that orphaned activity
        // stays registered with the system while this session pushes
        // updates to a second, new one — the orphan is what stays on
        // screen, silently frozen.
        cleanupStaleActivities()

        let attributes = OneEightyActivityAttributes()
        let contentState = OneEightyActivityAttributes.ContentState(
            bpm: bpm,
            isPlaying: isPlaying
        )

        do {
            currentActivity = try Activity.request(
                attributes: attributes,
                content: .init(state: contentState, staleDate: nil)
            )
            lastSentState = contentState
            logger.info("Live Activity started successfully, id=\(self.currentActivity?.id ?? "nil")")
            if let activity = currentActivity {
                observeActivityUpdates(activity)
            }
        } catch {
            logger.error("Failed to start Live Activity: \(error.localizedDescription)")
        }
    }

    private func observeActivityUpdates(_ activity: Activity<OneEightyActivityAttributes>) {
        contentUpdateTask?.cancel()
        contentUpdateTask = Task { @MainActor in
            for await content in activity.contentUpdates {
                let delivered = content.state
                logger.info("contentUpdates delivered — bpm=\(delivered.bpm), isPlaying=\(delivered.isPlaying)")
                confirmedState = PlaybackStateSnapshot(bpm: delivered.bpm, isPlaying: delivered.isPlaying)
            }
        }
    }

    func endActivity() {
        guard let activity = currentActivity else { return }
        logger.info("endActivity called — id=\(activity.id)")

        // Clear synchronously BEFORE the async end to prevent race:
        // startActivity() calls endActivity() then immediately creates a new activity.
        // If we nil inside the Task, the async completion nils the NEW activity,
        // orphaning it and causing duplicate live activities on the lock screen.
        currentActivity = nil
        contentUpdateTask?.cancel()
        contentUpdateTask = nil

        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
            logger.info("Activity ended")
        }
    }
}
