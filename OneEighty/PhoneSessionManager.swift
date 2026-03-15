//
//  PhoneSessionManager.swift
//  OneEighty
//
//  WatchConnectivity manager for the iOS side.
//  Receives commands from the watch and drives OneEightyEngine.
//  Sends state updates to the watch when engine state changes.
//

import Combine
import WatchConnectivity
import os

private let logger = Logger(subsystem: "com.danielbutler.OneEighty", category: "PhoneSession")

@MainActor
final class PhoneSessionManager: NSObject {
    private let engine: OneEightyEngine
    private let launchTimestamp: TimeInterval
    private var cancellable: AnyCancellable?
    private var echoDebounceTimer: Timer?
    private var lastSentPlayingState: Bool?

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

    func activate() {
        guard WCSession.isSupported() else {
            logger.info("WCSession not supported on this device")
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        logger.info("WCSession activating")
    }

    func sendStateToWatch() {
        guard WCSession.default.activationState == .activated,
              WCSession.default.isPaired,
              WCSession.default.isWatchAppInstalled else { return }

        let state: [String: Any] = [
            "bpm": engine.bpm,
            "isPlaying": engine.isPlaying
        ]

        // Always update application context — this persists and is available
        // immediately when the watch app launches via receivedApplicationContext.
        do {
            try WCSession.default.updateApplicationContext(state)
        } catch {
            logger.error("updateApplicationContext failed: \(error.localizedDescription)")
        }

        // Also send immediate message when reachable for live updates.
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(state, replyHandler: nil) { error in
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
            replyHandler(["bpm": self.engine.bpm, "isPlaying": self.engine.isPlaying])
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        Task { @MainActor in
            self.handleWatchCommand(userInfo, isQueued: true)
        }
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
