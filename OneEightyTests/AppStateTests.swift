//  AppStateTests.swift
import XCTest
@testable import OneEighty

final class AppStateTests: XCTestCase {
    func testDefaultState() {
        XCTAssertEqual(AppState.defaultState, AppState(version: 0, bpm: 180, isPlaying: false))
    }

    func testClampPinsBPMToRange() {
        var high = AppState(version: 1, bpm: 999, isPlaying: false)
        high.clampInvariants()
        XCTAssertEqual(high.bpm, 230)

        var low = AppState(version: 1, bpm: 10, isPlaying: true)
        low.clampInvariants()
        XCTAssertEqual(low.bpm, 150)
    }

    func testCodableRoundTrip() throws {
        let original = AppState(version: 7, bpm: 200, isPlaying: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppState.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
