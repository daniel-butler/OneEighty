//
//  EngineInterruptionTests.swift
//  OneEightyTests
//
//  Interruptions set DESIRED state via store.mutate; the reconciler drives audio.
//  Also covers the cold-launch "start stopped" rule via hydrateForUILaunch().
//

import UIKit
import XCTest
@testable import OneEighty

@MainActor
final class EngineInterruptionTests: XCTestCase {
    /// Interruption handlers dispatch their store.mutate via `Task { @MainActor in ... }`,
    /// so posting a notification doesn't synchronously update the store — pump the
    /// runloop once to let the enqueued main-actor work run before asserting.
    private func pumpMainRunLoop() {
        let e = expectation(description: "runloop pump")
        DispatchQueue.main.async { e.fulfill() }
        wait(for: [e], timeout: 1)
    }

    func testInterruptionStopsThenResumesPlayback() {
        let store = InMemoryPlaybackStore(AppState(version: 1, bpm: 180, isPlaying: true))
        let audio = FakeAudioOutput()
        let engine = OneEightyEngine(store: store, audio: audio)
        engine.hydrate()
        engine.startObservingInterruptions()

        NotificationCenter.default.post(name: .audioInterruptionBegan, object: nil)
        // began sets desired isPlaying=false via mutate (async Task) — pump the runloop
        pumpMainRunLoop()
        XCTAssertFalse(store.state.isPlaying)

        NotificationCenter.default.post(name: .audioInterruptionEnded, object: nil)
        pumpMainRunLoop()
        XCTAssertTrue(store.state.isPlaying)
        XCTAssertTrue(audio.isRunning)
    }

    func testDuplicateBeganPreservesResumeIntent() {
        let store = InMemoryPlaybackStore(AppState(version: 1, bpm: 180, isPlaying: true))
        let audio = FakeAudioOutput()
        let engine = OneEightyEngine(store: store, audio: audio)
        engine.hydrate()
        engine.startObservingInterruptions()

        NotificationCenter.default.post(name: .audioInterruptionBegan, object: nil)
        pumpMainRunLoop()
        NotificationCenter.default.post(name: .audioInterruptionBegan, object: nil) // duplicate began
        pumpMainRunLoop()
        XCTAssertFalse(store.state.isPlaying)

        NotificationCenter.default.post(name: .audioInterruptionEnded, object: nil)
        pumpMainRunLoop()
        XCTAssertTrue(store.state.isPlaying) // resume intent survived the duplicate began
    }

    func testDidBecomeActiveResumesAfterInterruption() {
        let store = InMemoryPlaybackStore(AppState(version: 1, bpm: 180, isPlaying: true))
        let audio = FakeAudioOutput()
        let engine = OneEightyEngine(store: store, audio: audio)
        engine.hydrate()
        engine.startObservingInterruptions()

        NotificationCenter.default.post(name: .audioInterruptionBegan, object: nil)
        pumpMainRunLoop()
        XCTAssertFalse(store.state.isPlaying)

        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        pumpMainRunLoop()
        XCTAssertTrue(store.state.isPlaying) // foreground recovery resumed
    }

    func testExplicitStopClearsResumeIntent() {
        let store = InMemoryPlaybackStore(AppState(version: 1, bpm: 180, isPlaying: true))
        let audio = FakeAudioOutput()
        let engine = OneEightyEngine(store: store, audio: audio)
        engine.hydrate()
        engine.startObservingInterruptions()

        NotificationCenter.default.post(name: .audioInterruptionBegan, object: nil)
        pumpMainRunLoop()
        XCTAssertFalse(store.state.isPlaying) // stopped, resume intent pending

        engine.togglePlayback() // user starts -> playing
        engine.togglePlayback() // user explicitly stops -> should clear resume intent
        XCTAssertFalse(store.state.isPlaying)

        NotificationCenter.default.post(name: .audioInterruptionEnded, object: nil)
        pumpMainRunLoop()
        XCTAssertFalse(store.state.isPlaying) // must NOT auto-resume against explicit stop
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
