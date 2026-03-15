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

@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private var currentActivity: Activity<OneEightyActivityAttributes>?
    private var pendingState: (bpm: Int, isPlaying: Bool)?
    private var throttleTimer: Timer?
    private var lastIsPlaying: Bool = false
    private var contentUpdateTask: Task<Void, Never>?

    private(set) var tracker: ActivityUpdateTracker
    private(set) var lastSentState: OneEightyActivityAttributes.ContentState?

    private init() {
        tracker = ActivityUpdateTracker()
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
        pendingState = nil
        throttleTimer?.invalidate()
        throttleTimer = nil
        lastIsPlaying = false
        lastSentState = nil
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
            lastIsPlaying = isPlaying
            logger.info("Live Activity started successfully, id=\(self.currentActivity?.id ?? "nil")")
            if let activity = currentActivity {
                observeActivityUpdates(activity)
            }
        } catch {
            logger.error("Failed to start Live Activity: \(error.localizedDescription)")
        }
    }

    func updateActivity(bpm: Int, isPlaying: Bool) {
        let priority: UpdatePriority = (isPlaying != lastIsPlaying) ? .critical : .normal
        let priorityLabel = priority == .critical ? "critical" : "normal"
        logger.info("updateActivity — bpm=\(bpm), isPlaying=\(isPlaying), priority=\(priorityLabel)")

        lastSentState = OneEightyActivityAttributes.ContentState(bpm: bpm, isPlaying: isPlaying)

        guard currentActivity != nil else {
            logger.warning("No current activity, falling back to startActivity")
            startActivity(bpm: bpm, isPlaying: isPlaying)
            if currentActivity != nil {
                tracker.recordUpdate()
            }
            return
        }

        // Critical updates (play/stop) bypass throttling entirely
        if priority == .critical {
            throttleTimer?.invalidate()
            throttleTimer = nil
            pendingState = nil
            lastIsPlaying = isPlaying
            pushUpdate(bpm: bpm, isPlaying: isPlaying)
            return
        }

        // Normal updates: coalesce within minimum interval
        pendingState = (bpm, isPlaying)

        if throttleTimer == nil {
            // First update in burst: send immediately if tracker allows
            if !tracker.shouldThrottle(priority: .normal) {
                pendingState = nil
                pushUpdate(bpm: bpm, isPlaying: isPlaying)
            }

            // Start cooldown — pending updates flush when timer fires
            throttleTimer = Timer.scheduledTimer(
                withTimeInterval: tracker.minimumInterval,
                repeats: false
            ) { _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.throttleTimer = nil
                    if let pending = self.pendingState {
                        self.pendingState = nil
                        self.pushUpdate(bpm: pending.bpm, isPlaying: pending.isPlaying)
                    }
                }
            }
        }
    }

    private func pushUpdate(bpm: Int, isPlaying: Bool) {
        guard let activity = currentActivity else { return }

        let contentState = OneEightyActivityAttributes.ContentState(
            bpm: bpm,
            isPlaying: isPlaying
        )

        tracker.recordUpdate()
        tracker.markUpdateSent()
        let count = tracker.totalUpdateCount
        let hourly = tracker.updatesInLastHour()
        logger.info("Pushing update #\(count) (hourly: \(hourly)) — bpm=\(bpm), isPlaying=\(isPlaying)")

        Task {
            await activity.update(.init(state: contentState, staleDate: nil))
            logger.info("Activity updated — id=\(activity.id)")
        }
    }

    private func observeActivityUpdates(_ activity: Activity<OneEightyActivityAttributes>) {
        contentUpdateTask?.cancel()
        contentUpdateTask = Task { @MainActor in
            for await content in activity.contentUpdates {
                let delivered = content.state
                logger.info("contentUpdates delivered — bpm=\(delivered.bpm), isPlaying=\(delivered.isPlaying)")

                if let sent = lastSentState, delivered == sent {
                    tracker.markUpdateConfirmed()
                    logger.info("Delivery confirmed — matches lastSentState")
                } else if let sent = lastSentState {
                    logger.warning("Delivery mismatch — sent bpm=\(sent.bpm) isPlaying=\(sent.isPlaying), delivered bpm=\(delivered.bpm) isPlaying=\(delivered.isPlaying)")
                }
            }
        }
    }

    func endActivity() {
        guard let activity = currentActivity else { return }
        logger.info("endActivity called — id=\(activity.id)")
        contentUpdateTask?.cancel()
        contentUpdateTask = nil

        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
            currentActivity = nil
            logger.info("Activity ended")
        }
    }
}
