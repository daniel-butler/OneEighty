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

    // MARK: - Inbound Cooldown

    func testIncrementSetsCoolingDown() {
        session.incrementBPM()
        XCTAssertTrue(session.isCoolingDown, "incrementBPM should activate cooldown")
    }

    func testDecrementSetsCoolingDown() {
        session.decrementBPM()
        XCTAssertTrue(session.isCoolingDown, "decrementBPM should activate cooldown")
    }

    func testCooldownExpiresAfterDelay() {
        let expectation = expectation(description: "Cooldown expires")
        session.incrementBPM()
        XCTAssertTrue(session.isCoolingDown)

        // Cooldown is 200ms — wait 300ms to be safe
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
        XCTAssertFalse(session.isCoolingDown, "Cooldown should expire after 200ms")
    }

    func testApplyStateIgnoresBPMDuringCooldown() {
        session.incrementBPM()
        XCTAssertTrue(session.isCoolingDown)
        let bpmAfterIncrement = session.bpm

        // Simulate stale echo from phone
        session.applyState(["bpm": 170, "isPlaying": false])
        XCTAssertEqual(session.bpm, bpmAfterIncrement, "BPM should be ignored during cooldown")
    }

    func testApplyStateAcceptsIsPlayingDuringCooldown() {
        session.incrementBPM()
        XCTAssertTrue(session.isCoolingDown)
        XCTAssertFalse(session.isPlaying)

        // Play/stop should always be applied, even during cooldown
        session.applyState(["bpm": 170, "isPlaying": true])
        XCTAssertTrue(session.isPlaying, "isPlaying should be applied even during cooldown")
    }

    func testApplyStateAcceptsBPMAfterCooldownExpires() {
        let expectation = expectation(description: "Cooldown expires")
        session.incrementBPM()
        XCTAssertTrue(session.isCoolingDown)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
        XCTAssertFalse(session.isCoolingDown)

        session.applyState(["bpm": 200, "isPlaying": false])
        XCTAssertEqual(session.bpm, 200, "BPM should be applied after cooldown expires")
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
