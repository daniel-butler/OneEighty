//
//  OneEightyUITests.swift
//  OneEightyUITests
//
//  Created by Daniel Butler on 12/21/25.
//

import XCTest

final class OneEightyUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    // MARK: - Launch State

    @MainActor
    func testLaunchShowsDefaultBPM() throws {
        let bpmDisplay = app.staticTexts["bpmDisplay"]
        XCTAssertTrue(bpmDisplay.waitForExistence(timeout: 5))
        XCTAssertEqual(bpmDisplay.label, "180")
    }

    @MainActor
    func testLaunchShowsStartButton() throws {
        let startButton = app.buttons["togglePlayback"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 5))
        XCTAssertEqual(startButton.label, "START")
    }

    @MainActor
    func testLaunchShowsSPMLabel() throws {
        XCTAssertTrue(app.staticTexts["SPM"].waitForExistence(timeout: 5))
    }

    // MARK: - BPM Controls

    @MainActor
    func testIncrementBPM() throws {
        let bpmDisplay = app.staticTexts["bpmDisplay"]
        XCTAssertTrue(bpmDisplay.waitForExistence(timeout: 5))

        let increment = app.buttons["incrementBPM"]
        increment.tap()

        XCTAssertEqual(app.staticTexts["bpmDisplay"].label, "181")
    }

    @MainActor
    func testDecrementBPM() throws {
        let bpmDisplay = app.staticTexts["bpmDisplay"]
        XCTAssertTrue(bpmDisplay.waitForExistence(timeout: 5))

        let decrement = app.buttons["decrementBPM"]
        decrement.tap()

        XCTAssertEqual(app.staticTexts["bpmDisplay"].label, "179")
    }

    @MainActor
    func testMultipleIncrements() throws {
        let bpmDisplay = app.staticTexts["bpmDisplay"]
        XCTAssertTrue(bpmDisplay.waitForExistence(timeout: 5))

        let increment = app.buttons["incrementBPM"]
        for _ in 0..<5 {
            increment.tap()
        }

        XCTAssertEqual(app.staticTexts["bpmDisplay"].label, "185")
    }

    @MainActor
    func testBPMUpperBound() throws {
        let bpmDisplay = app.staticTexts["bpmDisplay"]
        XCTAssertTrue(bpmDisplay.waitForExistence(timeout: 5))

        let increment = app.buttons["incrementBPM"]
        // Default is 180, upper bound is 230 → tap 55 times to be sure
        for _ in 0..<55 {
            increment.tap()
        }

        XCTAssertEqual(app.staticTexts["bpmDisplay"].label, "230")
    }

    @MainActor
    func testBPMLowerBound() throws {
        let bpmDisplay = app.staticTexts["bpmDisplay"]
        XCTAssertTrue(bpmDisplay.waitForExistence(timeout: 5))

        let decrement = app.buttons["decrementBPM"]
        // Default is 180, lower bound is 150 → tap 35 times to be sure
        for _ in 0..<35 {
            decrement.tap()
        }

        XCTAssertEqual(app.staticTexts["bpmDisplay"].label, "150")
    }

    // MARK: - Start/Stop Toggle

    @MainActor
    func testStartStopToggle() throws {
        let toggle = app.buttons["togglePlayback"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.label, "START")

        // Tap to start
        toggle.tap()

        // Button label should change to STOP
        let stopButton = app.buttons["togglePlayback"]
        XCTAssertTrue(stopButton.waitForExistence(timeout: 3))
        XCTAssertEqual(stopButton.label, "STOP")

        // Tap to stop
        stopButton.tap()

        // Back to START
        let startButton = app.buttons["togglePlayback"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 3))
        XCTAssertEqual(startButton.label, "START")
    }

    @MainActor
    func testBPMChangesWhilePlaying() throws {
        let toggle = app.buttons["togglePlayback"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))

        // Start playing
        toggle.tap()
        XCTAssertEqual(app.buttons["togglePlayback"].label, "STOP")

        // Change BPM while playing
        let increment = app.buttons["incrementBPM"]
        increment.tap()
        increment.tap()

        // BPM should update even while playing
        XCTAssertEqual(app.staticTexts["bpmDisplay"].label, "182")

        // Should still be playing (STOP label)
        XCTAssertEqual(app.buttons["togglePlayback"].label, "STOP")

        // Stop
        app.buttons["togglePlayback"].tap()
        XCTAssertEqual(app.buttons["togglePlayback"].label, "START")
    }

    // MARK: - Volume Slider

    @MainActor
    func testVolumeSliderExists() throws {
        let slider = app.sliders.firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
    }
}
