//
//  WatchSessionManager.swift
//  OneEightyWatch Watch App
//
//  WatchConnectivity manager for the watchOS side.
//  Sends commands to the phone and receives state updates.
//

import WatchConnectivity
import os

private let logger = Logger(subsystem: "com.danielbutler.OneEighty.watchkitapp", category: "WatchSession")

@Observable
@MainActor
final class WatchSessionManager: NSObject {
    var bpm: Int = 180
    var isPlaying: Bool = false
    var isReachable: Bool = false

    /// True while an optimistic edit is unconfirmed by the phone. UI-facing
    /// replacement for the old isCoolingDown timer — reflects the same
    /// "value not yet settled" intent, now driven by in-flight commands
    /// rather than a fixed timer.
    var hasPendingEdit: Bool { inFlight > 0 }

    private var wcSession: WCSession?
    private var pendingBPMDelta: Int = 0
    private var batchTimer: Timer?

    // MARK: - In-Flight Command Tracking
    //
    // The watch holds optimistic local state and has no version authority —
    // it must not version-gate incoming state. Instead, every command sent to
    // the phone is tracked as "in-flight". While any command is in-flight,
    // incoming authoritative state is remembered (kept as the highest-version
    // snapshot seen) but not applied — the optimistic value wins. Once the
    // watch goes quiescent (all commands acked or failed), it snaps to the
    // latest remembered authoritative snapshot. A failed command additionally
    // reverts the optimistic edit before snapping (self-heal).

    /// Number of commands sent to the phone that haven't yet been resolved
    /// (acked via reply, failed via error, or resolved as fire-and-forget).
    private var inFlight = 0

    /// Monotonic id attached to each outbound command, paired with the
    /// phone's commandId dedupe (PhoneSessionManager.seenCommandIds).
    private var nextCommandId = 0

    /// Number of optimistic edits (incrementBPM/decrementBPM taps) folded
    /// into the not-yet-sent, debounced batch delta. All of them resolve
    /// together when the single batched `adjustBPM` command they produced
    /// is acked or fails.
    private var pendingBatchBeginCount = 0

    /// Highest-version authoritative snapshot received from the phone since
    /// the watch last went quiescent. Applied once in-flight returns to 0.
    private var latestAuthoritative: (bpm: Int, isPlaying: Bool, version: UInt64)?

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
        beginCommand()
        sendCommand("toggle", commandId: mintCommandId())
    }

    func incrementBPM() {
        // Optimistic local update
        if bpm < 230 {
            bpm += 1
        }
        beginCommand()
        pendingBatchBeginCount += 1
        batchBPMDelta(1)
    }

    func decrementBPM() {
        // Optimistic local update
        if bpm > 150 {
            bpm -= 1
        }
        beginCommand()
        pendingBatchBeginCount += 1
        batchBPMDelta(-1)
    }

    private func batchBPMDelta(_ delta: Int) {
        pendingBPMDelta += delta
        batchTimer?.invalidate()
        batchTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.flushBatchedBPMDelta()
            }
        }
    }

    /// Sends the coalesced BPM delta as a single `adjustBPM` command. All the
    /// optimistic taps folded into it (see `pendingBatchBeginCount`) resolve
    /// together when this one command is acked or fails.
    private func flushBatchedBPMDelta() {
        guard pendingBPMDelta != 0 else { return }
        let delta = pendingBPMDelta
        pendingBPMDelta = 0
        let resolveCount = pendingBatchBeginCount
        pendingBatchBeginCount = 0
        sendCommand("adjustBPM", commandId: mintCommandId(), extra: ["count": delta], resolveCount: resolveCount)
    }

    /// Flush pending BPM delta and invalidate all timers.
    /// Call when the app goes to background to avoid keeping the CPU awake.
    func flushAndInvalidateTimers() {
        batchTimer?.invalidate()
        batchTimer = nil
        // Send any pending batched delta before going to background
        if pendingBPMDelta != 0 {
            flushBatchedBPMDelta()
        }
    }

    // MARK: - In-Flight Command Tracking

    private func mintCommandId() -> Int {
        nextCommandId += 1
        return nextCommandId
    }

    private func beginCommand(count: Int = 1) {
        inFlight += count
    }

    private func endCommand(success: Bool, count: Int = 1) {
        inFlight = max(0, inFlight - count)
        if inFlight == 0 {
            adoptLatestIfAny()
        }
    }

    /// Adopts the latest remembered authoritative snapshot (if any) into
    /// bpm/isPlaying. Used both to snap when quiescent and to revert a
    /// failed optimistic edit back to the last known truth (self-heal) —
    /// the watch can no longer trust its local optimistic value once the
    /// phone rejects a command.
    private func adoptLatestIfAny() {
        if let snapshot = latestAuthoritative {
            bpm = snapshot.bpm
            isPlaying = snapshot.isPlaying
        }
    }

    // test seams
    func ackInFlightForTesting() { endCommand(success: true) }
    func failInFlightForTesting() { adoptLatestIfAny(); endCommand(success: false) }

    private func sendCommand(_ command: String, commandId: Int, extra: [String: Any] = [:], resolveCount: Int = 1) {
        guard let session = wcSession else {
            logger.warning("No WCSession — command \(command) dropped")
            // No session means no reply/error will ever arrive — resolve
            // immediately so in-flight can't get stuck (self-heal).
            endCommand(success: true, count: resolveCount)
            return
        }

        var payload: [String: Any] = [
            "command": command,
            "commandId": commandId,
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
                    self?.endCommand(success: true, count: resolveCount)
                }
            }, errorHandler: { [weak self] error in
                logger.error("sendMessage failed for \(command): \(error.localizedDescription)")
                // Fall back to transferUserInfo for queued delivery
                session.transferUserInfo(payload)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.adoptLatestIfAny()
                    self.endCommand(success: false, count: resolveCount)
                }
            })
            logger.info("Sent command to phone via message: \(command)")
        } else {
            // Phone not reachable — queue for delivery when it wakes. There's
            // no ack channel for transferUserInfo, so resolve now (treat as
            // sent); the phone's periodic reconciliation will self-heal any
            // drift once it eventually delivers.
            session.transferUserInfo(payload)
            logger.info("Queued command to phone via transferUserInfo: \(command)")
            endCommand(success: true, count: resolveCount)
        }
    }

    // MARK: - State from Phone

    /// Applies authoritative state from the phone. The watch has no version
    /// authority of its own, so it never rejects a message outright — it
    /// always remembers the highest-version snapshot seen. It only *adopts*
    /// (writes it into bpm/isPlaying) once quiescent (inFlight == 0);
    /// otherwise the optimistic value is held until the in-flight command(s)
    /// resolve.
    func applyState(_ message: [String: Any]) {
        guard let version = message["version"] as? UInt64,
              let newBPM = message["bpm"] as? Int,
              let newIsPlaying = message["isPlaying"] as? Bool else {
            logger.warning("Ignoring malformed/unversioned state message: \(message)")
            return
        }

        if latestAuthoritative == nil || version > latestAuthoritative!.version {
            latestAuthoritative = (newBPM, newIsPlaying, version)
        }

        guard inFlight == 0 else {
            logger.info("Holding optimistic state — \(self.inFlight) command(s) in flight")
            return
        }

        adoptLatestIfAny()
        logger.info("State updated — bpm=\(self.bpm), isPlaying=\(self.isPlaying), version=\(version)")
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
