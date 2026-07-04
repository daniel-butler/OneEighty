//
//  OneEightyEngineTests.swift
//  OneEightyTests
//
//  Reconciler tests: the engine owns no independent truth. It mirrors
//  store.state into UI projections and drives AudioOutput to match.
//

import Combine
import XCTest
@testable import OneEighty

@MainActor
final class OneEightyEngineTests: XCTestCase {
    private func makeEngine(_ initial: AppState = .defaultState)
        -> (OneEightyEngine, InMemoryPlaybackStore, FakeAudioOutput) {
        let store = InMemoryPlaybackStore(initial)
        let audio = FakeAudioOutput()
        let engine = OneEightyEngine(store: store, audio: audio)
        engine.hydrate()
        return (engine, store, audio)
    }

    func testHydrateStartsAudioWhenDesiredPlaying() {
        let (_, _, audio) = makeEngine(AppState(version: 3, bpm: 210, isPlaying: true))
        XCTAssertTrue(audio.isRunning)
        XCTAssertEqual(audio.lastBPM, 210)   // real tempo, not hardcoded 180
    }

    func testTogglePlaybackMutatesStoreAndDrivesAudio() {
        let (engine, store, audio) = makeEngine()
        engine.togglePlayback()
        XCTAssertTrue(store.state.isPlaying)
        XCTAssertTrue(audio.isRunning)
        engine.togglePlayback()
        XCTAssertFalse(store.state.isPlaying)
        XCTAssertFalse(audio.isRunning)
    }

    func testBPMChangeWhilePlayingUpdatesTempoNotRestart() {
        let (engine, _, audio) = makeEngine(AppState(version: 1, bpm: 180, isPlaying: true))
        let startsBefore = audio.startCount
        engine.incrementBPM()
        XCTAssertEqual(audio.lastBPM, 181)
        XCTAssertEqual(audio.startCount, startsBefore)   // updateBPM, not restart
    }

    func testExternalStateChangeReconciles() {
        // Bind `engine` so it outlives the external change: the reconciler drives
        // audio via a `[weak self]` store subscription, so the engine must be alive
        // (as it always is in real usage) for the change to reconcile.
        let (engine, store, audio) = makeEngine()
        store.simulateExternal { $0.isPlaying = true; $0.bpm = 195 }
        XCTAssertTrue(audio.isRunning)
        XCTAssertEqual(audio.lastBPM, 195)
        withExtendedLifetime(engine) {}
    }

    func testReconcileIsIdempotent() {
        let (engine, _, audio) = makeEngine(AppState(version: 1, bpm: 180, isPlaying: true))
        engine.reconcileAudio(); engine.reconcileAudio(); engine.reconcileAudio()
        XCTAssertEqual(audio.startCount, 1)   // already running → no re-start
    }

    func testFailedStartRollsBackDesiredState() {
        let store = InMemoryPlaybackStore()
        let audio = FailingAudioOutput()   // start() never sets isRunning
        let engine = OneEightyEngine(store: store, audio: audio)
        engine.hydrate()
        engine.togglePlayback()
        XCTAssertFalse(store.state.isPlaying)   // rolled back to reality
    }
}

@MainActor
final class FailingAudioOutput: AudioOutput {
    var isRunning = false            // never becomes true
    func start(bpm: Int) {}
    func stop() {}
    func updateBPM(_ bpm: Int) {}
    func setVolume(_ volume: Float) {}
}
