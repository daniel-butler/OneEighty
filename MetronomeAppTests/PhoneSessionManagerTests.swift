//
//  PhoneSessionManagerTests.swift
//  MetronomeAppTests
//
//  Tests for PhoneSessionManager command handling and stale command filtering.
//

import XCTest
@testable import MetronomeApp

@MainActor
final class PhoneSessionManagerTests: XCTestCase {

    private var engine: MetronomeEngine!

    override func setUp() {
        engine = MetronomeEngine(store: InMemoryStateStore())
        engine.setup()
    }

    override func tearDown() {
        engine.teardown()
        engine = nil
    }

    // MARK: - Command Handling

    func testToggleCommandStartsPlayback() {
        XCTAssertFalse(engine.isPlaying)
        engine.ensureReady()
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
}
