//
//  WatchSessionManager.swift
//  OneEightyWatch Watch App
//
//  WatchConnectivity manager for the watchOS side.
//  Sends commands to the phone and receives state updates.
//

import WatchConnectivity
import os

private let logger = Logger(subsystem: "app.rekuro.OneEighty.watchkitapp", category: "WatchSession")

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

    /// Per-launch nonce combined into every outbound command id so ids are
    /// unique across watch relaunches. Without it, the sequence resets to 1 on
    /// relaunch and collides with ids the (still-alive) phone process already
    /// dedupes, dropping the first post-relaunch taps. Paired with the phone's
    /// commandId dedupe (PhoneSessionManager.seenCommandIds).
    private let launchNonce = UUID().uuidString

    /// Monotonic per-launch sequence; combined with `launchNonce` in mintCommandId.
    private var nextCommandSeq = 0

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
        let resolveCount = pendingBatchBeginCount
        pendingBatchBeginCount = 0
        guard pendingBPMDelta != 0 else {
            // Net-zero batch (e.g. +1 then -1 inside the 80ms coalescing
            // window): no command will ever be sent, so no reply/error will
            // ever arrive to resolve the folded beginCommand() holds. Release
            // them here instead of leaving inFlight stuck forever. There's no
            // real pending edit in this case, so it's correct to snap to
            // authoritative state once this brings in-flight to zero.
            if resolveCount > 0 {
                endCommand(success: true, count: resolveCount, adopt: true)
            }
            return
        }
        let delta = pendingBPMDelta
        pendingBPMDelta = 0
        sendCommand("adjustBPM", commandId: mintCommandId(), extra: ["count": delta], resolveCount: resolveCount)
    }

    /// Flush pending BPM delta and invalidate all timers.
    /// Call when the app goes to background to avoid keeping the CPU awake.
    func flushAndInvalidateTimers() {
        batchTimer?.invalidate()
        batchTimer = nil
        // Flush whenever there's a pending delta OR folded beginCommand()
        // holds waiting on a net-zero batch — otherwise a net-zero batch's
        // holds would never be released (see flushBatchedBPMDelta).
        if pendingBPMDelta != 0 || pendingBatchBeginCount > 0 {
            flushBatchedBPMDelta()
        }
    }

    // MARK: - In-Flight Command Tracking

    private func mintCommandId() -> String {
        nextCommandSeq += 1
        return "\(launchNonce)-\(nextCommandSeq)"
    }

    /// Test seam — exposes the minted compound id so uniqueness within and
    /// across launches can be asserted.
    func mintCommandIdForTesting() -> String { mintCommandId() }

    private func beginCommand(count: Int = 1) {
        inFlight += count
    }

    /// Resolves `count` in-flight command(s). When this brings `inFlight` to
    /// zero, the watch goes quiescent and — only if `adopt` is true — snaps
    /// to the latest remembered authoritative snapshot. `adopt` distinguishes
    /// "this edit is queued and will eventually apply on the phone" (keep
    /// the optimistic value; the phone's reconciliation echo will correct
    /// it) from "this edit failed / never happened" (snap to truth).
    private func endCommand(success: Bool, count: Int = 1, adopt: Bool = true) {
        inFlight = max(0, inFlight - count)
        if inFlight == 0 && adopt {
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
    func failInFlightForTesting() { endCommand(success: false, adopt: true) }
    /// Simulates the resolution of a queued (unreachable / transferUserInfo)
    /// send: the command WILL eventually apply on the phone, so keep the
    /// optimistic value rather than snapping to stale authoritative state.
    func resolveQueuedSendForTesting(count: Int = 1) { endCommand(success: true, count: count, adopt: false) }

    private func sendCommand(_ command: String, commandId: String, extra: [String: Any] = [:], resolveCount: Int = 1) {
        guard let session = wcSession else {
            logger.warning("No WCSession — command \(command) dropped")
            // No session means the command is truly dropped — it will never
            // reach the phone. Resolve immediately so in-flight can't get
            // stuck, and snap to authoritative once quiescent (self-heal),
            // since this edit will never actually apply.
            endCommand(success: true, count: resolveCount, adopt: true)
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
                    // Reply carries fresh authoritative state — refresh
                    // latestAuthoritative before resolving, then snap to it.
                    self?.applyState(reply)
                    self?.endCommand(success: true, count: resolveCount, adopt: true)
                }
            }, errorHandler: { [weak self] error in
                logger.error("sendMessage failed for \(command): \(error.localizedDescription)")
                // Fall back to transferUserInfo for queued delivery
                session.transferUserInfo(payload)
                Task { @MainActor [weak self] in
                    // Genuine failure — the edit likely didn't apply. Self-heal
                    // by snapping to authoritative once quiescent.
                    self?.endCommand(success: false, count: resolveCount, adopt: true)
                }
            })
            logger.info("Sent command to phone via message: \(command)")
        } else {
            // Phone not reachable — queue for delivery when it wakes. There's
            // no ack channel for transferUserInfo, so resolve now (treat as
            // sent), but keep the optimistic value: the command WILL apply
            // once delivered, and the phone's periodic reconciliation will
            // echo back the correct state then. Snapping to the last known
            // (stale) authoritative here would visibly revert a real edit.
            session.transferUserInfo(payload)
            logger.info("Queued command to phone via transferUserInfo: \(command)")
            endCommand(success: true, count: resolveCount, adopt: false)
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
