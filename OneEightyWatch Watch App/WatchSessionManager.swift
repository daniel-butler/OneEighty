//
//  WatchSessionManager.swift
//  OneEightyWatch Watch App
//
//  WatchConnectivity manager for the watchOS side.
//  Sends commands to the phone and receives state updates.
//

import WatchConnectivity
import os

private let logger = Logger(subsystem: "com.danielbutler.MetronomeApp.watchkitapp", category: "WatchSession")

@Observable
@MainActor
final class WatchSessionManager: NSObject {
    var bpm: Int = 180
    var isPlaying: Bool = false
    var isReachable: Bool = false

    private var wcSession: WCSession?

    override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else {
            logger.info("WCSession not supported")
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        wcSession = session
        logger.info("WCSession activating")
    }

    // MARK: - Commands to Phone

    func toggle() {
        sendCommand("toggle")
    }

    func incrementBPM() {
        sendCommand("incrementBPM")
    }

    func decrementBPM() {
        sendCommand("decrementBPM")
    }

    private func sendCommand(_ command: String) {
        guard let session = wcSession else {
            logger.warning("No WCSession — command \(command) dropped")
            return
        }

        let payload: [String: Any] = ["command": command]

        if session.isReachable {
            // Immediate delivery — phone is active
            session.sendMessage(payload, replyHandler: { [weak self] reply in
                Task { @MainActor [weak self] in
                    self?.applyState(reply)
                }
            }, errorHandler: { [weak session] error in
                logger.error("sendMessage failed for \(command): \(error.localizedDescription)")
                // Fall back to transferUserInfo for queued delivery
                session?.transferUserInfo(payload)
            })
            logger.info("Sent command to phone via message: \(command)")
        } else {
            // Phone not reachable — queue for delivery when it wakes
            session.transferUserInfo(payload)
            logger.info("Queued command to phone via transferUserInfo: \(command)")
        }
    }

    // MARK: - State from Phone

    private func applyState(_ message: [String: Any]) {
        if let newBPM = message["bpm"] as? Int {
            bpm = newBPM
        }
        if let newIsPlaying = message["isPlaying"] as? Bool {
            isPlaying = newIsPlaying
        }
        logger.info("State updated — bpm=\(self.bpm), isPlaying=\(self.isPlaying)")
    }
}

extension WatchSessionManager: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            if let error {
                logger.error("WCSession activation failed: \(error.localizedDescription)")
            } else {
                logger.info("WCSession activated — state=\(activationState.rawValue)")
                self.isReachable = session.isReachable
                // Load last known state from application context (persists across launches)
                let context = session.receivedApplicationContext
                if !context.isEmpty {
                    logger.info("Restoring state from applicationContext")
                    self.applyState(context)
                }
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            self.applyState(applicationContext)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            self.applyState(message)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        Task { @MainActor in
            self.applyState(userInfo)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isReachable = session.isReachable
            logger.info("Reachability changed: \(session.isReachable)")
        }
    }
}
