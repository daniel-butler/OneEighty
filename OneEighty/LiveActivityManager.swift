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

    static func makeForTesting(store: PlaybackStore) -> LiveActivityManager {
        LiveActivityManager(store: store)
    }

    private init(store: PlaybackStore) {
        self.store = store
        tracker = ActivityUpdateTracker()
    }

    /// Single entry point. Pushes only if `state.version` hasn't already been
    /// claimed (the store's cross-process dedupe + budget gate). Echo
    /// suppression and client-side coalescing are gone — correctness comes
    /// from the version check, not from timing.
    func apply(_ state: AppState) {
        guard store.claimActivityPush(version: state.version, at: Date()) else { return }
        guard currentActivity != nil else {
            startActivity(bpm: state.bpm, isPlaying: state.isPlaying)
            tracker.recordUpdate()
            return
        }
        tracker.recordUpdate()
        push(PlaybackStateSnapshot(bpm: state.bpm, isPlaying: state.isPlaying))
    }

    func push(_ state: PlaybackStateSnapshot) {
        guard let activity = currentActivity else { return }
        let contentState = OneEightyActivityAttributes.ContentState(bpm: state.bpm, isPlaying: state.isPlaying)
        lastSentState = contentState
        let count = tracker.totalUpdateCount
        let hourly = tracker.updatesInLastHour()
        logger.info("Pushing update #\(count) (hourly: \(hourly)) — bpm=\(state.bpm), isPlaying=\(state.isPlaying)")
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
