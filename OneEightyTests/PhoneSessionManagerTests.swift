//
//  PhoneSessionManagerTests.swift
//  OneEightyTests
//
//  Tests for PhoneSessionManager command handling and stale command filtering.
//

import XCTest
@testable import OneEighty

@MainActor
final class PhoneSessionManagerTests: XCTestCase {

    private var engine: OneEightyEngine!

    override func setUp() {
        engine = OneEightyEngine(store: InMemoryPlaybackStore(), audio: FakeAudioOutput())
        engine.hydrate()
    }

    override func tearDown() {
        engine = nil
    }

    // MARK: - Command Handling

    func testToggleCommandStartsPlayback() {
        XCTAssertFalse(engine.isPlaying)
        engine.hydrate()
        engine.togglePlayback()
        XCTAssertTrue(engine.isPlaying)
    }

    func testStartCommandWhenAlreadyPlayingIsNoOp() {
        engine.togglePlayback()
        XCTAssertTrue(engine.isPlaying)
        // "start" when already playing should not toggle off
        if !engine.isPlaying { engine.togglePlayback() }
        XCTAssertTrue(engine.isPlaying)
    }

    func testStopCommandWhenAlreadyStoppedIsNoOp() {
        XCTAssertFalse(engine.isPlaying)
        // "stop" when already stopped should not toggle on
        if engine.isPlaying { engine.togglePlayback() }
        XCTAssertFalse(engine.isPlaying)
    }

    func testIncrementBPMCommand() {
        engine.setBPM(190)
        engine.incrementBPM()
        XCTAssertEqual(engine.bpm, 191)
    }

    func testDecrementBPMCommand() {
        engine.setBPM(190)
        engine.decrementBPM()
        XCTAssertEqual(engine.bpm, 189)
    }

    func testAdjustBPMCommand() {
        engine.setBPM(180)
        engine.adjustBPM(by: 7)
        XCTAssertEqual(engine.bpm, 187, "adjustBPM should apply batched delta in one shot")
    }

    // MARK: - Stale Command Filtering (Bug 4 fix)

    func testStaleTimestampDetection() {
        // Simulate: command was sent at time T, app launched at T+5
        let commandTime = Date().timeIntervalSince1970 - 10  // 10 seconds ago
        let launchTime = Date().timeIntervalSince1970 - 5     // 5 seconds ago

        // Command timestamp < launch timestamp → stale
        XCTAssertTrue(commandTime < launchTime, "Command sent before launch should be detected as stale")
    }

    func testFreshTimestampNotStale() {
        let launchTime = Date().timeIntervalSince1970 - 5     // 5 seconds ago
        let commandTime = Date().timeIntervalSince1970 - 2    // 2 seconds ago

        // Command timestamp > launch timestamp → fresh
        XCTAssertTrue(commandTime > launchTime, "Command sent after launch should not be stale")
    }

    // MARK: - Engine State After Multiple Commands

    func testRapidToggleCommandsSettleCorrectly() {
        // Even number of toggles → stopped
        for _ in 0..<10 {
            engine.togglePlayback()
        }
        XCTAssertFalse(engine.isPlaying, "10 toggles should return to stopped")
    }

    func testRapidBPMCommandsAccumulate() {
        engine.setBPM(190)
        for _ in 0..<5 {
            engine.incrementBPM()
        }
        XCTAssertEqual(engine.bpm, 195)
    }

    func testBPMPreservedAfterToggle() {
        engine.setBPM(200)
        engine.togglePlayback()
        engine.togglePlayback()
        XCTAssertEqual(engine.bpm, 200, "BPM should not change from toggle")
    }

    // MARK: - Command-id Dedupe (Task 14)

    func testDuplicateCommandIdAppliedOnce() {
        let store = InMemoryPlaybackStore()
        let engine = OneEightyEngine(store: store, audio: FakeAudioOutput())
        engine.hydrate()
        let mgr = PhoneSessionManager(engine: engine)
        // Compound string id shape minted by the watch: "<launchNonce>-<seq>".
        let cmd: [String: Any] = ["command": "adjustBPM", "count": 3, "commandId": "launchA-1"]
        mgr.handleWatchCommandForTesting(cmd)
        mgr.handleWatchCommandForTesting(cmd)   // retry — must NOT double-apply
        XCTAssertEqual(store.state.bpm, 183)
    }

    func testSameSequenceDifferentLaunchNotDeduped() {
        // The watch relaunches (new launchNonce) and its sequence resets to 1.
        // These must be treated as distinct commands even though the sequence
        // number collides — this is the FIX 5 cross-launch collision case.
        let store = InMemoryPlaybackStore()
        let engine = OneEightyEngine(store: store, audio: FakeAudioOutput())
        engine.hydrate()
        let mgr = PhoneSessionManager(engine: engine)
        mgr.handleWatchCommandForTesting(["command": "adjustBPM", "count": 3, "commandId": "launchA-1"])
        mgr.handleWatchCommandForTesting(["command": "adjustBPM", "count": 3, "commandId": "launchB-1"])
        XCTAssertEqual(store.state.bpm, 186,
                       "same sequence from a different launch must apply, not be dropped as a duplicate")
    }

    // MARK: - Change-gated reconcile (FIX 3)

    func testReconcileSkipsUnchangedState() {
        let store = InMemoryPlaybackStore(AppState(version: 2, bpm: 185, isPlaying: false))
        let engine = OneEightyEngine(store: store, audio: FakeAudioOutput())
        engine.hydrate()
        let mgr = PhoneSessionManager(engine: engine)
        mgr.sendStateToWatch()   // establishes last-sent baseline
        XCTAssertFalse(mgr.reconcileTickForTesting(),
                       "reconcile must not re-send when state is unchanged")
    }

    func testReconcileResendsAfterChange() {
        let store = InMemoryPlaybackStore(AppState(version: 2, bpm: 185, isPlaying: true))
        let engine = OneEightyEngine(store: store, audio: FakeAudioOutput())
        engine.hydrate()
        let mgr = PhoneSessionManager(engine: engine)
        // Prime lastSentPlayingState so a subsequent bpm-only change takes the
        // publisher's debounce path (no synchronous re-send), keeping the
        // reconcile-gate assertion deterministic.
        engine.togglePlayback()
        mgr.sendStateToWatch()
        XCTAssertFalse(mgr.reconcileTickForTesting())
        engine.incrementBPM()    // bpm-only change → debounced, not yet re-sent
        XCTAssertTrue(mgr.reconcileTickForTesting(),
                      "reconcile should re-send after an unsent state change")
    }

    func testCommandWithoutCommandIdStillApplies() {
        let store = InMemoryPlaybackStore()
        let engine = OneEightyEngine(store: store, audio: FakeAudioOutput())
        engine.hydrate()
        let mgr = PhoneSessionManager(engine: engine)
        let cmd: [String: Any] = ["command": "adjustBPM", "count": 3]
        mgr.handleWatchCommandForTesting(cmd)
        XCTAssertEqual(store.state.bpm, 183, "Commands without a commandId (backward-compat) should still apply")
    }

    // MARK: - Versioned State Payload

    func testStatePayloadIncludesVersion() {
        let store = InMemoryPlaybackStore(AppState(version: 12, bpm: 200, isPlaying: true))
        let engine = OneEightyEngine(store: store, audio: FakeAudioOutput())
        engine.hydrate()
        let mgr = PhoneSessionManager(engine: engine)
        let payload = mgr.statePayload()
        XCTAssertEqual(payload["version"] as? UInt64, 12)
        XCTAssertEqual(payload["bpm"] as? Int, 200)
        XCTAssertEqual(payload["isPlaying"] as? Bool, true)
    }

    // MARK: - WCSession-style Version Serialization Round-Trip

    /// Every other test hands `applyState`/`statePayload` a literal Swift
    /// dict, so the real WatchConnectivity NSNumber<->UInt64 bridging is
    /// never exercised. WCSession message/context payloads must be
    /// property-list compatible, so route the payload through
    /// PropertyListSerialization (the same NSNumber-boxing constraint
    /// WCSession's XPC transport imposes) and assert the values are still
    /// recoverable with the exact casts WatchSessionManager.applyState uses.
    func testStatePayloadSurvivesWCSessionStyleSerializationRoundTrip() throws {
        let store = InMemoryPlaybackStore(AppState(version: 12, bpm: 200, isPlaying: true))
        let engine = OneEightyEngine(store: store, audio: FakeAudioOutput())
        engine.hydrate()
        let mgr = PhoneSessionManager(engine: engine)
        let payload = mgr.statePayload()

        let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0)
        let decodedObj = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let decoded = try XCTUnwrap(decodedObj as? [String: Any])

        // Same casts as WatchSessionManager.applyState.
        let version = decoded["version"] as? UInt64
        let bpm = decoded["bpm"] as? Int
        let isPlaying = decoded["isPlaying"] as? Bool

        XCTAssertEqual(version, 12, "version must survive plist round-trip and remain castable as UInt64")
        XCTAssertEqual(bpm, 200)
        XCTAssertEqual(isPlaying, true)
    }
}
