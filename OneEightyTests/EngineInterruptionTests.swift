//
//  EngineInterruptionTests.swift
//  OneEightyTests
//
//  Interruptions set DESIRED state via store.mutate; the reconciler drives audio.
//  Also covers the cold-launch "start stopped" rule via hydrateForUILaunch().
//

import XCTest
@testable import OneEighty

@MainActor
final class EngineInterruptionTests: XCTestCase {
    func testInterruptionStopsThenResumesPlayback() {
        let store = InMemoryPlaybackStore(AppState(version: 1, bpm: 180, isPlaying: true))
        let audio = FakeAudioOutput()
        let engine = OneEightyEngine(store: store, audio: audio)
        engine.hydrate()
        engine.startObservingInterruptions()

        NotificationCenter.default.post(name: .audioInterruptionBegan, object: nil)
        // began sets desired isPlaying=false via mutate (async Task) — pump the runloop
        let e1 = expectation(description: "stopped")
        DispatchQueue.main.async { e1.fulfill() }
        wait(for: [e1], timeout: 1)
        XCTAssertFalse(store.state.isPlaying)

        NotificationCenter.default.post(name: .audioInterruptionEnded, object: nil)
        let e2 = expectation(description: "resumed")
        DispatchQueue.main.async { e2.fulfill() }
        wait(for: [e2], timeout: 1)
        XCTAssertTrue(store.state.isPlaying)
        XCTAssertTrue(audio.isRunning)
    }

    func testUILaunchStartsStoppedEvenIfPersistedPlaying() {
        // App was killed while playing; a fresh UI launch must start stopped.
        let store = InMemoryPlaybackStore(AppState(version: 5, bpm: 200, isPlaying: true))
        let audio = FakeAudioOutput()   // fresh: not running
        let engine = OneEightyEngine(store: store, audio: audio)
        engine.hydrateForUILaunch()
        XCTAssertFalse(store.state.isPlaying)
        XCTAssertFalse(audio.isRunning)
        XCTAssertEqual(store.state.bpm, 200)   // tempo is preserved; only playback resets
    }

    func testUILaunchPreservesIntentStartedPlayback() {
        // An AudioPlaybackIntent already started audio in this process.
        let store = InMemoryPlaybackStore(AppState(version: 2, bpm: 190, isPlaying: true))
        let audio = FakeAudioOutput()
        let engine = OneEightyEngine(store: store, audio: audio)
        engine.hydrate()                      // intent path: audio starts, isRunning == true
        XCTAssertTrue(audio.isRunning)
        engine.hydrateForUILaunch()           // user then opens the UI
        XCTAssertTrue(store.state.isPlaying)  // playback preserved, not reset
        XCTAssertTrue(audio.isRunning)
    }
}
