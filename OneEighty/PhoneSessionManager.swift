//
//  PhoneSessionManager.swift
//  OneEighty
//
//  WatchConnectivity manager for the iOS side.
//  Receives commands from the watch and drives OneEightyEngine.
//  Sends state updates to the watch when engine state changes.
//

import Combine
import UIKit
import WatchConnectivity
import os

private let logger = Logger(subsystem: "com.danielbutler.OneEighty", category: "PhoneSession")

@MainActor
final class PhoneSessionManager: NSObject, StateSubscriber {
    private let engine: OneEightyEngine
    private let launchTimestamp: TimeInterval
    private var cancellable: AnyCancellable?
    private var echoDebounceTimer: Timer?
    private var lastSentPlayingState: Bool?
    private var reconcileTimer: Timer?
    private var didBecomeActiveObserver: NSObjectProtocol?

    private(set) var confirmedState: PlaybackState?

    /// Command ids already applied, used to dedupe retried watch commands
    /// (WatchConnectivity can deliver the same message twice: sendMessage
    /// failure falling back to transferUserInfo retry). Capped to avoid
    /// unbounded growth — commandIds are monotonically increasing from the
    /// watch, so old ones won't recur once evicted.
    private var seenCommandIds = Set<Int>()

    func push(_ state: PlaybackState) {
        sendStateToWatch()
    }

    init(engine: OneEightyEngine) {
        self.engine = engine
        self.launchTimestamp = Date().timeIntervalSince1970
        super.init()
        cancellable = engine.statePublisher.dropFirst().sink { [weak self] state in
            guard let self else { return }
            // Play/stop changes bypass debounce — send immediately
            if state.isPlaying != self.lastSentPlayingState {
                self.echoDebounceTimer?.invalidate()
                self.echoDebounceTimer = nil
                self.lastSentPlayingState = state.isPlaying
                self.sendStateToWatch()
            } else {
                // BPM-only changes: debounce 150ms
                self.echoDebounceTimer?.invalidate()
                self.echoDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
                    self?.sendStateToWatch()
                }
            }
        }
    }

    deinit {
        reconcileTimer?.invalidate()
        if let didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(didBecomeActiveObserver)
        }
    }

    func activate() {
        guard WCSession.isSupported() else {
            logger.info("WCSession not supported on this device")
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        logger.info("WCSession activating")
        startReconciliation()
    }

    /// Periodically re-send state to the watch so a dropped context/message
    /// (unreachable, app not yet installed, transient failure) eventually
    /// self-heals without requiring a user-visible engine change.
    private func startReconciliation() {
        reconcileTimer?.invalidate()
        reconcileTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sendStateToWatch()
            }
        }

        if didBecomeActiveObserver == nil {
            didBecomeActiveObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.sendStateToWatch()
                }
            }
        }
    }

    /// The message/reply payload sent to the watch. Includes `version` so the
    /// watch can reject stale snapshots (e.g. a delayed reconcile tick racing
    /// a newer app-context update).
    func statePayload() -> [String: Any] {
        ["bpm": engine.bpm, "isPlaying": engine.isPlaying, "version": engine.currentVersion]
    }

    func sendStateToWatch() {
        guard WCSession.default.activationState == .activated else { return }

        let state = statePayload()

        // Always update application context — this persists and is available
        // immediately when the watch app launches via receivedApplicationContext.
        // This must not be gated on reachability/install state, or a dropped
        // connection would also drop the state the watch reconciles against
        // once it reconnects.
        do {
            try WCSession.default.updateApplicationContext(state)
        } catch {
            logger.error("updateApplicationContext failed: \(error.localizedDescription)")
        }

        guard WCSession.default.isPaired, WCSession.default.isWatchAppInstalled else { return }

        // Also send immediate message when reachable for live updates.
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(state, replyHandler: { [weak self] reply in
                Task { @MainActor in
                    if let bpm = reply["bpm"] as? Int, let isPlaying = reply["isPlaying"] as? Bool {
                        self?.confirmedState = PlaybackState(bpm: bpm, isPlaying: isPlaying)
                    }
                }
            }) { error in
                logger.error("sendMessage failed: \(error.localizedDescription)")
            }
            logger.info("Sent state to watch — bpm=\(self.engine.bpm), isPlaying=\(self.engine.isPlaying)")
        }
    }
}

extension PhoneSessionManager: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let state = activationState.rawValue
        Task { @MainActor in
            if let error {
                logger.error("WCSession activation failed: \(error.localizedDescription)")
            } else {
                logger.info("WCSession activated — state=\(state)")
                self.sendStateToWatch()
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor in
            logger.info("WCSession became inactive")
        }
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor in
            logger.info("WCSession deactivated — reactivating")
            session.activate()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            self.handleWatchCommand(message)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in
            self.handleWatchCommand(message)
            replyHandler(self.statePayload())
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        Task { @MainActor in
            self.handleWatchCommand(userInfo, isQueued: true)
        }
    }

    /// Test seam — exercises the private command handler directly without
    /// going through WCSessionDelegate plumbing.
    func handleWatchCommandForTesting(_ m: [String: Any]) {
        handleWatchCommand(m)
    }

    @MainActor
    private func handleWatchCommand(_ message: [String: Any], isQueued: Bool = false) {
        guard let command = message["command"] as? String else {
            logger.warning("Received message without command: \(message)")
            return
        }

        // Discard commands that were queued (via transferUserInfo) before this launch
        if isQueued, let timestamp = message["timestamp"] as? TimeInterval, timestamp < launchTimestamp {
            logger.info("Discarding stale queued command: \(command) (sent \(self.launchTimestamp - timestamp)s before launch)")
            return
        }

        // Dedupe retried commands (e.g. sendMessage failure falling back to
        // transferUserInfo). Commands without a commandId are always applied
        // (backward-compat with older watch builds / Task 15 not yet landed).
        if let id = message["commandId"] as? Int {
            guard !seenCommandIds.contains(id) else {
                logger.info("Dropping duplicate watch command id \(id)")
                return
            }
            seenCommandIds.insert(id)
            if seenCommandIds.count > 256 { seenCommandIds.removeFirst() }
        }

        logger.info("Received watch command: \(command)")

        // Ensure engine is ready — handles background wake when UI hasn't appeared
        engine.ensureReady()

        switch command {
        case "start":
            if !engine.isPlaying { engine.togglePlayback() }
        case "stop":
            if engine.isPlaying { engine.togglePlayback() }
        case "toggle":
            engine.togglePlayback()
        case "incrementBPM":
            engine.incrementBPM()
        case "decrementBPM":
            engine.decrementBPM()
        case "adjustBPM":
            if let count = message["count"] as? Int {
                engine.adjustBPM(by: count)
            }
        default:
            logger.warning("Unknown command: \(command)")
        }
    }
}
