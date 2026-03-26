//
//  LiveActivityManager.swift
//  OneEighty
//
//  Created by Claude on 12/23/25.
//

import ActivityKit
import Foundation
import os
import UIKit

private let logger = Logger(subsystem: "com.danielbutler.OneEighty", category: "LiveActivity")

@MainActor
final class LiveActivityManager: StateSubscriber {
    static let shared = LiveActivityManager()

    private var currentActivity: Activity<OneEightyActivityAttributes>?
    private var pendingState: (bpm: Int, isPlaying: Bool)?
    private var throttleTimer: Timer?
    private var lastIsPlaying: Bool = false
    private var contentUpdateTask: Task<Void, Never>?

    private(set) var tracker: ActivityUpdateTracker
    private(set) var lastSentState: OneEightyActivityAttributes.ContentState?
    private(set) var confirmedState: PlaybackState?
    private(set) var reconciliationCount: Int = 0
    private var reconciliationTimer: Timer?
    private var stateProvider: (() -> PlaybackState)?

    private init() {
        tracker = ActivityUpdateTracker()
        // Wire the intent debouncer to route through this manager
        IntentActivityDebouncer.shared.setUpdateHandler { [weak self] bpm, isPlaying in
            self?.updateActivity(bpm: bpm, isPlaying: isPlaying)
        }
        startObservingAppLifecycle()
    }

    func setStateProvider(_ provider: @escaping () -> PlaybackState) {
        stateProvider = provider
    }

    func push(_ state: PlaybackState) {
        guard let activity = currentActivity else { return }
        let contentState = OneEightyActivityAttributes.ContentState(bpm: state.bpm, isPlaying: state.isPlaying)
        tracker.recordUpdate()
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
        pendingState = nil
        throttleTimer?.invalidate()
        throttleTimer = nil
        lastIsPlaying = false
        lastSentState = nil
        confirmedState = nil
        reconciliationCount = 0
        reconciliationTimer?.invalidate()
        reconciliationTimer = nil
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
        reconciliationTimer?.invalidate()
        reconciliationTimer = nil

        let priority: UpdatePriority = (isPlaying != lastIsPlaying) ? .critical : .normal
        let priorityLabel = priority == .critical ? "critical" : "normal"
        logger.info("updateActivity — bpm=\(bpm), isPlaying=\(isPlaying), priority=\(priorityLabel)")

        lastSentState = OneEightyActivityAttributes.ContentState(bpm: bpm, isPlaying: isPlaying)

        guard currentActivity != nil else {
            logger.warning("No current activity, falling back to startActivity")
            startActivity(bpm: bpm, isPlaying: isPlaying)
            if currentActivity != nil {
                tracker.recordUpdate()
                scheduleReconciliation()
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
                withTimeInterval: tracker.effectiveInterval(),
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
        push(PlaybackState(bpm: bpm, isPlaying: isPlaying))
        scheduleReconciliation()
    }

    private func observeActivityUpdates(_ activity: Activity<OneEightyActivityAttributes>) {
        contentUpdateTask?.cancel()
        contentUpdateTask = Task { @MainActor in
            for await content in activity.contentUpdates {
                let delivered = content.state
                logger.info("contentUpdates delivered — bpm=\(delivered.bpm), isPlaying=\(delivered.isPlaying)")
                confirmedState = PlaybackState(bpm: delivered.bpm, isPlaying: delivered.isPlaying)
            }
        }
    }

    private func scheduleReconciliation() {
        reconciliationTimer?.invalidate()
        reconciliationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
            Task { @MainActor [weak self] in
                guard let self, self.currentActivity != nil else { return }
                self.reconciliationTimer = nil
                self.reconciliationCount += 1
                if let provider = self.stateProvider {
                    self.reconcile(currentState: provider())
                }
            }
        }
    }

    private func startObservingAppLifecycle() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func appDidBecomeActive() {
        Task { @MainActor in
            guard currentActivity != nil, let provider = stateProvider else { return }
            reconciliationCount += 1
            reconcile(currentState: provider())
        }
    }

    func endActivity() {
        guard let activity = currentActivity else { return }
        logger.info("endActivity called — id=\(activity.id)")

        reconciliationTimer?.invalidate()
        reconciliationTimer = nil

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
