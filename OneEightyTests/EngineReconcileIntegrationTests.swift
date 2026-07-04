//
//  EngineReconcileIntegrationTests.swift
//  OneEightyTests
//
//  End-to-end integration: statePublisher -> syncFromStore -> reconcileAudio,
//  driven by a realistic multi-step sequence of external (cross-process)
//  changes via InMemoryPlaybackStore.simulateExternal. Existing tests each
//  cover a single external change in isolation; this pins the full path
//  under a sequence of changes, including repeated/identical syncs.
//

import XCTest
@testable import OneEighty

@MainActor
final class EngineReconcileIntegrationTests: XCTestCase {
    func testMultiStepExternalSequenceReconcilesAudioWithoutRedundantStarts() {
        let store = InMemoryPlaybackStore()
        let audio = FakeAudioOutput()
        let engine = OneEightyEngine(store: store, audio: audio)
        engine.hydrate()

        // Step 1: external play at 190 — off -> on transition, one start().
        store.simulateExternal { $0.isPlaying = true; $0.bpm = 190 }
        XCTAssertTrue(audio.isRunning)
        XCTAssertEqual(audio.lastBPM, 190)
        XCTAssertEqual(audio.startCount, 1)
        XCTAssertEqual(audio.stopCount, 0)

        // Repeated identical sync (e.g. a duplicate Darwin wake) while still
        // playing at the same bpm must not re-start.
        store.simulateExternal { $0.isPlaying = true; $0.bpm = 190 }
        XCTAssertTrue(audio.isRunning)
        XCTAssertEqual(audio.startCount, 1, "identical re-sync while already running must not re-start")

        // Step 2: external bpm change to 200 while still playing — tempo
        // update only, no additional start.
        store.simulateExternal { $0.bpm = 200 }
        XCTAssertTrue(audio.isRunning)
        XCTAssertEqual(audio.lastBPM, 200)
        XCTAssertEqual(audio.startCount, 1, "bpm-only change must update tempo, not restart audio")

        // Step 3: external stop.
        store.simulateExternal { $0.isPlaying = false }
        XCTAssertFalse(audio.isRunning)
        XCTAssertEqual(audio.stopCount, 1)
        XCTAssertEqual(audio.startCount, 1)

        // Repeated identical stop must not double-stop.
        store.simulateExternal { $0.isPlaying = false }
        XCTAssertFalse(audio.isRunning)
        XCTAssertEqual(audio.stopCount, 1, "identical re-sync while already stopped must not re-stop")

        // Step 4: external play again at 210 — genuine second off -> on
        // transition, so startCount increments again.
        store.simulateExternal { $0.isPlaying = true; $0.bpm = 210 }
        XCTAssertTrue(audio.isRunning)
        XCTAssertEqual(audio.lastBPM, 210)
        XCTAssertEqual(audio.startCount, 2)
        XCTAssertEqual(audio.stopCount, 1)

        // Final idempotency check via direct reconcileAudio() calls, as in
        // OneEightyEngineTests.testReconcileIsIdempotent.
        engine.reconcileAudio()
        engine.reconcileAudio()
        XCTAssertEqual(audio.startCount, 2)
        XCTAssertEqual(audio.stopCount, 1)

        withExtendedLifetime(engine) {}
    }
}
