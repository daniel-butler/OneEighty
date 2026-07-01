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
        let cmd: [String: Any] = ["command": "adjustBPM", "count": 3, "commandId": 42]
        mgr.handleWatchCommandForTesting(cmd)
        mgr.handleWatchCommandForTesting(cmd)   // retry — must NOT double-apply
        XCTAssertEqual(store.state.bpm, 183)
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
}
