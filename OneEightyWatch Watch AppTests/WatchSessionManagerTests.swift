//
//  WatchSessionManagerTests.swift
//  OneEightyWatch Watch AppTests
//
//  Tests for WatchSessionManager optimistic updates and state management.
//

import XCTest
@testable import OneEightyWatch_Watch_App

@MainActor
final class WatchSessionManagerTests: XCTestCase {

    private var session: WatchSessionManager!

    override func setUp() {
        session = WatchSessionManager()
    }

    override func tearDown() {
        session = nil
    }

    // MARK: - Default State

    func testDefaultBPM() {
        XCTAssertEqual(session.bpm, 180)
    }

    func testDefaultIsPlaying() {
        XCTAssertFalse(session.isPlaying)
    }

    func testDefaultIsReachable() {
        XCTAssertFalse(session.isReachable)
    }

    // MARK: - Optimistic Toggle (Bug 2 fix)

    func testToggleUpdatesIsPlayingLocally() {
        XCTAssertFalse(session.isPlaying)
        session.toggle()
        XCTAssertTrue(session.isPlaying, "toggle() should optimistically update isPlaying")
        session.toggle()
        XCTAssertFalse(session.isPlaying, "toggle() should flip isPlaying back")
    }

    // MARK: - Optimistic BPM (Bug 1 fix)

    func testIncrementBPMUpdatesLocally() {
        let initial = session.bpm
        session.incrementBPM()
        XCTAssertEqual(session.bpm, initial + 1, "incrementBPM() should optimistically update bpm")
    }

    func testDecrementBPMUpdatesLocally() {
        let initial = session.bpm
        session.decrementBPM()
        XCTAssertEqual(session.bpm, initial - 1, "decrementBPM() should optimistically update bpm")
    }

    func testIncrementBPMRespectsUpperBound() {
        session.bpm = 230
        session.incrementBPM()
        XCTAssertEqual(session.bpm, 230, "incrementBPM() should not exceed 230")
    }

    func testDecrementBPMRespectsLowerBound() {
        session.bpm = 150
        session.decrementBPM()
        XCTAssertEqual(session.bpm, 150, "decrementBPM() should not go below 150")
    }

    // MARK: - Rapid Operations

    func testRapidIncrements() {
        session.bpm = 195
        for _ in 0..<15 {
            session.incrementBPM()
        }
        XCTAssertEqual(session.bpm, 210, "15 increments from 195 should reach 210")
    }

    func testRapidIncrementsClampAtMax() {
        session.bpm = 220
        for _ in 0..<20 {
            session.incrementBPM()
        }
        XCTAssertEqual(session.bpm, 230, "Rapid increments should clamp at 230")
    }

    // MARK: - In-Flight Command Tracking (Task 15)

    func testOptimisticHeldWhileCommandInFlight() {
        let m = WatchSessionManager()
        m.incrementBPM()                                  // optimistic 181, in-flight 1
        m.applyState(["bpm": 180, "isPlaying": false, "version": UInt64(3)])
        XCTAssertEqual(m.bpm, 181)                        // ignored while in-flight
    }

    func testSnapsToAuthoritativeWhenQuiescent() {
        let m = WatchSessionManager()
        m.incrementBPM()
        m.ackInFlightForTesting()                         // command acked → in-flight 0
        m.applyState(["bpm": 200, "isPlaying": true, "version": UInt64(9)])
        XCTAssertEqual(m.bpm, 200)                        // adopts latest authoritative
        XCTAssertTrue(m.isPlaying)
    }

    func testLostOptimisticEditSelfHeals() {
        let m = WatchSessionManager()
        // Seed an authoritative snapshot BEFORE the failure so the revert
        // path is actually exercised (latestAuthoritative must be non-nil
        // at failure time, or the revert is a no-op).
        m.applyState(["bpm": 180, "isPlaying": false, "version": UInt64(3)])
        XCTAssertEqual(m.bpm, 180)                        // quiescent, so this applies immediately
        m.incrementBPM()                                  // optimistic 181
        m.failInFlightForTesting()                        // command failed → revert + quiescent
        XCTAssertEqual(m.bpm, 180)                        // healed back to truth
    }

    func testNetZeroBatchDoesNotLeakInFlight() {
        let m = WatchSessionManager()
        m.incrementBPM()                                  // optimistic 181, inFlight 1, batched +1
        m.decrementBPM()                                  // optimistic 180, inFlight 2, batched net 0
        XCTAssertTrue(m.hasPendingEdit)                    // holds still outstanding pre-flush
        // Force the batch flush deterministically instead of waiting on the
        // real 80ms timer.
        m.flushAndInvalidateTimers()
        XCTAssertFalse(m.hasPendingEdit, "net-zero batch must release its folded beginCommand holds, not leak them")
        // Prove there's no leak: a fresh, higher-version authoritative state
        // must now be adopted since in-flight is truly back to zero.
        m.applyState(["bpm": 200, "isPlaying": true, "version": UInt64(9)])
        XCTAssertEqual(m.bpm, 200)
        XCTAssertTrue(m.isPlaying)
    }

    func testUnreachableSendKeepsOptimisticValue() {
        let m = WatchSessionManager()
        // Seed authoritative state while quiescent.
        m.applyState(["bpm": 180, "isPlaying": false, "version": UInt64(1)])
        XCTAssertEqual(m.bpm, 180)
        m.incrementBPM()                                  // optimistic 181, inFlight 1
        // Simulate the transferUserInfo (unreachable/queued) resolution: the
        // command WILL apply later, so it resolves without adopting stale
        // authoritative state.
        m.resolveQueuedSendForTesting()
        XCTAssertFalse(m.hasPendingEdit)
        XCTAssertEqual(m.bpm, 181, "unreachable queued send must keep the optimistic value, not revert to stale authoritative")
    }

    func testApplyStateIgnoredWithoutVersion() {
        // Messages missing a version (malformed / legacy) must not be applied.
        session.applyState(["bpm": 170, "isPlaying": true])
        XCTAssertEqual(session.bpm, 180)
        XCTAssertFalse(session.isPlaying)
    }

    func testApplyStateKeepsHighestVersionAsAuthoritative() {
        let m = WatchSessionManager()
        m.incrementBPM()                                  // in-flight 1, optimistic 181
        m.applyState(["bpm": 200, "isPlaying": true, "version": UInt64(5)])
        m.applyState(["bpm": 170, "isPlaying": false, "version": UInt64(2)])  // stale, out of order
        m.ackInFlightForTesting()
        XCTAssertEqual(m.bpm, 200, "should adopt the highest-version snapshot seen while in-flight, not the last one received")
        XCTAssertTrue(m.isPlaying)
    }

    // MARK: - WCSession-style Version Serialization Round-Trip

    /// Every other `applyState` test hands a literal Swift `UInt64`, but a
    /// real WCSession delivery boxes numeric payload values as `NSNumber`.
    /// `applyState` drops the whole message if `version` isn't castable via
    /// `as? UInt64` — this must succeed for an NSNumber-boxed value too, or
    /// every real device message would be silently dropped.
    func testApplyStateAcceptsWCSessionBridgedNSNumberVersion() {
        let m = WatchSessionManager()
        let message: [String: Any] = ["version": NSNumber(value: UInt64(9)), "bpm": 200, "isPlaying": true]
        m.applyState(message)   // quiescent (no in-flight command) → adopts immediately
        XCTAssertEqual(m.bpm, 200, "an NSNumber-boxed UInt64 version must not be dropped by the `as? UInt64` cast in applyState")
        XCTAssertTrue(m.isPlaying)
    }

    func testApplyStateDropsMessageWithNonNumericVersion() {
        let m = WatchSessionManager()
        m.applyState(["version": "not-a-number", "bpm": 170, "isPlaying": true])
        XCTAssertEqual(m.bpm, 180, "a non-numeric version must be dropped, leaving state unchanged")
        XCTAssertFalse(m.isPlaying)
    }

    // MARK: - Command Id Uniqueness (FIX 5)

    func testCommandIdsUniqueWithinAndAcrossLaunches() {
        let a = WatchSessionManager()
        let b = WatchSessionManager()   // simulates a relaunch (new launchNonce)
        let a1 = a.mintCommandIdForTesting()
        let a2 = a.mintCommandIdForTesting()
        let b1 = b.mintCommandIdForTesting()
        XCTAssertNotEqual(a1, a2, "sequential ids within a launch must differ")
        XCTAssertNotEqual(a1, b1, "ids across launches must differ even at the same sequence")
    }

    // MARK: - Rapid Operations (existing)

    func testRapidToggles() {
        // Even number of toggles should return to original state
        let initial = session.isPlaying
        for _ in 0..<10 {
            session.toggle()
        }
        XCTAssertEqual(session.isPlaying, initial, "10 toggles should return to original state")
    }

    func testOddTogglesFlipState() {
        let initial = session.isPlaying
        for _ in 0..<7 {
            session.toggle()
        }
        XCTAssertNotEqual(session.isPlaying, initial, "7 toggles should flip state")
    }
}
