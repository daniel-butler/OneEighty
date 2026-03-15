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
    private(set) var isCoolingDown: Bool = false

    private var wcSession: WCSession?
    private var pendingBPMDelta: Int = 0
    private var batchTimer: Timer?
    private var cooldownTimer: Timer?

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
        // Optimistic local update — don't wait for phone reply
        isPlaying.toggle()
        sendCommand("toggle")
    }

    func incrementBPM() {
        // Optimistic local update
        if bpm < 230 {
            bpm += 1
        }
        startCooldown()
        batchBPMDelta(1)
    }

    func decrementBPM() {
        // Optimistic local update
        if bpm > 150 {
            bpm -= 1
        }
        startCooldown()
        batchBPMDelta(-1)
    }

    private func batchBPMDelta(_ delta: Int) {
        pendingBPMDelta += delta
        batchTimer?.invalidate()
        batchTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.pendingBPMDelta != 0 else { return }
                let delta = self.pendingBPMDelta
                self.pendingBPMDelta = 0
                self.sendCommand("adjustBPM", extra: ["count": delta])
            }
        }
    }

    private func startCooldown() {
        isCoolingDown = true
        cooldownTimer?.invalidate()
        cooldownTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isCoolingDown = false
            }
        }
    }

    private func sendCommand(_ command: String, extra: [String: Any] = [:]) {
        guard let session = wcSession else {
            logger.warning("No WCSession — command \(command) dropped")
            return
        }

        var payload: [String: Any] = [
            "command": command,
            "timestamp": Date().timeIntervalSince1970
        ]
        for (key, value) in extra {
            payload[key] = value
        }

        if session.isReachable {
            // Immediate delivery — phone is active
            session.sendMessage(payload, replyHandler: { [weak self] reply in
                Task { @MainActor [weak self] in
                    self?.applyState(reply)
                }
            }, errorHandler: { error in
                logger.error("sendMessage failed for \(command): \(error.localizedDescription)")
                // Fall back to transferUserInfo for queued delivery
                session.transferUserInfo(payload)
            })
            logger.info("Sent command to phone via message: \(command)")
        } else {
            // Phone not reachable — queue for delivery when it wakes
            session.transferUserInfo(payload)
            logger.info("Queued command to phone via transferUserInfo: \(command)")
        }
    }

    // MARK: - State from Phone

    func applyState(_ message: [String: Any]) {
        if let newBPM = message["bpm"] as? Int, !isCoolingDown {
            bpm = newBPM
        }
        if let newIsPlaying = message["isPlaying"] as? Bool {
            isPlaying = newIsPlaying
        }
        logger.info("State updated — bpm=\(self.bpm), isPlaying=\(self.isPlaying), coolingDown=\(self.isCoolingDown)")
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
