//
//  TickSchedulerTests.swift
//  OneEightyTests
//
//  Tests for TickScheduler sample-position math.
//

import XCTest
@testable import OneEighty

final class TickSchedulerTests: XCTestCase {

    // MARK: - Sample interval math

    func testSamplesPerBeatAt180BPM() {
        // 60 / 180 = 0.3333s * 24000 Hz = 8000 samples
        let samples = TickScheduler.samplesPerBeat(bpm: 180, sampleRate: 24000)
        XCTAssertEqual(samples, 8000)
    }

    func testSamplesPerBeatAt150BPM() {
        // 60 / 150 = 0.4s * 24000 Hz = 9600 samples
        let samples = TickScheduler.samplesPerBeat(bpm: 150, sampleRate: 24000)
        XCTAssertEqual(samples, 9600)
    }

    func testSamplesPerBeatAt230BPM() {
        // 60 / 230 = 0.26087s * 24000 Hz = 6260.87 -> 6261 samples (rounded)
        let samples = TickScheduler.samplesPerBeat(bpm: 230, sampleRate: 24000)
        XCTAssertEqual(samples, 6261)
    }

    func testSamplesPerBeatAt44100Hz() {
        // 60 / 180 = 0.3333s * 44100 Hz = 14700 samples
        let samples = TickScheduler.samplesPerBeat(bpm: 180, sampleRate: 44100)
        XCTAssertEqual(samples, 14700)
    }
}
